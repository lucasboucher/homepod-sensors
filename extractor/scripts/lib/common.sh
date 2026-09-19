#!/usr/bin/env bash
# Shared helpers for HomePod Keychain Extractor orchestration scripts.

set -euo pipefail

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"

export PROJECT_DIR
export BINARY_PATH="${PROJECT_DIR}/.build/arm64-apple-macosx/debug/HomePodKeychainExtractor"
export ENTITLEMENTS_SOURCE="${PROJECT_DIR}/Sources/HomePodKeychainExtractor/HomePodKeychainExtractor.entitlements"
export RUN_DIR="${PROJECT_DIR}/.run"
export STATE_FILE="${RUN_DIR}/workflow.state"
export LOCK_FILE="${RUN_DIR}/workflow.lock"
export DUMP_PATH="${RUN_DIR}/dump/dump.txt"
export HAP_ACCESS_GROUP="com.apple.hap.pairing"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
UNKNOWN_COUNT=0

log_section() {
    echo
    echo "------------------------------------------------------------"
    echo " $*"
    echo "------------------------------------------------------------"
}

log_pass() {
    echo "✓ $*"
    PASS_COUNT=$((PASS_COUNT + 1))
}

log_warn() {
    echo "! $*"
    WARN_COUNT=$((WARN_COUNT + 1))
}

log_fail() {
    echo "✗ $*"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

log_unknown() {
    echo "? $*"
    UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

mask_identity() {
    sed -E \
        -e 's/(Apple Development: )[^@]+@([^ "(]+)/\1***@\2/g' \
        -e 's/[0-9A-Fa-f]{32,}/[REDACTED]/g'
}

strip_ansi_stream() {
    perl -pe 's/\e\[[0-9;]*[A-Za-z]//g'
}

strip_ansi_file_to_temp() {
    local input_file="$1"
    local temp_file
    temp_file="$(mktemp "${TMPDIR:-/tmp}/hap-dump-normalized.XXXXXX")"
    strip_ansi_stream < "${input_file}" > "${temp_file}"
    echo "${temp_file}"
}

require_confirm_flag() {
    local flag="${1:-}"
    if [[ "${flag}" != "--confirm" ]]; then
        echo "This operation requires explicit confirmation: add --confirm"
        exit 2
    fi
}

acquire_lock() {
    mkdir -p "${RUN_DIR}"
    if [[ -f "${LOCK_FILE}" ]]; then
        local pid
        pid="$(grep -E '^pid=' "${LOCK_FILE}" 2>/dev/null | cut -d= -f2- || true)"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            echo "Another workflow script is running (pid ${pid})."
            exit 2
        fi
    fi
    cat > "${LOCK_FILE}" <<EOF
pid=${$}
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

release_lock() {
    rm -f "${LOCK_FILE}"
}

setup_log_file() {
    local prefix="$1"
    mkdir -p "${RUN_DIR}/logs"
    LOG_FILE="${RUN_DIR}/logs/${prefix}-$(date '+%Y%m%d-%H%M%S').log"
    exec > >(tee "${LOG_FILE}" | mask_identity) 2>&1
}

print_assessment_footer() {
    echo
    echo "PASS    : ${PASS_COUNT}"
    echo "WARN    : ${WARN_COUNT}"
    echo "FAIL    : ${FAIL_COUNT}"
    echo "UNKNOWN : ${UNKNOWN_COUNT}"
}

validate_dump_file() {
    local dump_file="$1"
    local exit_code="${2:-0}"
    local temp_file=""
    local matched_count=""

    if [[ "${exit_code}" -ne 0 ]]; then
        return 1
    fi
    if [[ ! -f "${dump_file}" ]] || [[ ! -s "${dump_file}" ]]; then
        return 1
    fi

    temp_file="$(strip_ansi_file_to_temp "${dump_file}")"
    matched_count="$(
        grep -oE 'Keychain Items Matched:[[:space:]]*[0-9]+' "${temp_file}" 2>/dev/null |
        tail -n 1 |
        grep -oE '[0-9]+$' ||
        true
    )"
    rm -f "${temp_file}"

    if [[ -n "${matched_count}" && "${matched_count}" -gt 0 ]]; then
        return 0
    fi
    return 1
}

identity_is_configured() {
    [[ -n "${CODESIGNKIT_DEFAULT_IDENTITY:-}" ]]
}
