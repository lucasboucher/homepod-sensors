#!/usr/bin/env bash
# HomePod Keychain Extractor — environment preflight (read-only).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/detect-security.sh
source "${SCRIPT_DIR}/lib/detect-security.sh"
# shellcheck source=lib/detect-toolchain.sh
source "${SCRIPT_DIR}/lib/detect-toolchain.sh"
# shellcheck source=lib/detect-project.sh
source "${SCRIPT_DIR}/lib/detect-project.sh"
# shellcheck source=lib/detect-codesign.sh
source "${SCRIPT_DIR}/lib/detect-codesign.sh"
# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"

BUILD_REQUESTED=false
JSON_OUTPUT=false
REPORT_REQUESTED=false
REPORT_FILE=""

usage() {
    cat <<EOF
Usage:
  ./scripts/01-check-environment.sh [--build] [--json] [--report]

Options:
  --build   Run swift build before inspecting the binary
  --json    Emit machine-readable summary on stdout
  --report  Also write a masked report under reports/
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)
            BUILD_REQUESTED=true
            ;;
        --json)
            JSON_OUTPUT=true
            ;;
        --report)
            REPORT_REQUESTED=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 2
            ;;
    esac
    shift
done

if [[ "${REPORT_REQUESTED}" == true ]]; then
    mkdir -p "${PROJECT_DIR}/reports"
    REPORT_FILE="${PROJECT_DIR}/reports/environment-$(date '+%Y%m%d-%H%M%S').txt"
    exec > >(tee "${REPORT_FILE}" | mask_identity) 2>&1
fi

PROJECT_VERDICT="PROJECT_UNKNOWN"
SECURITY_CLASSIFICATION="SECURITY_UNKNOWN"

echo "============================================================"
echo " HomePod Keychain Extractor — Environment Check"
echo "============================================================"
echo
echo "Timestamp : $(date)"
echo "Project   : ${PROJECT_DIR}"
echo "Mode      : READ-ONLY"
echo "Build     : $( [[ "${BUILD_REQUESTED}" == true ]] && echo requested || echo skipped )"

log_section "SYSTEM"
sw_vers 2>/dev/null || log_unknown "sw_vers unavailable."
echo
uname -a
ARCH="$(uname -m)"
if [[ "${ARCH}" == "arm64" ]]; then
    log_pass "Apple Silicon architecture: arm64."
else
    log_warn "Architecture is ${ARCH}, not arm64."
fi
echo
system_profiler SPHardwareDataType 2>/dev/null || true

log_section "SYSTEM INTEGRITY PROTECTION"
detect_csrutil
echo "${CSR_OUTPUT}"
if sip_is_enabled; then
    log_pass "SIP appears ENABLED."
elif sip_is_disabled; then
    log_warn "SIP appears DISABLED."
else
    log_unknown "Could not classify SIP state."
fi

log_section "NVRAM / BOOT ARGUMENTS"
detect_nvram_boot_args
echo "boot-args: ${BOOT_ARGS:-"(none)"}"
if amfi_bypass_present; then
    log_warn "Known AMFI/security-bypass boot-args detected."
else
    log_pass "No known AMFI bypass boot-args detected."
fi

log_section "SECURITY POLICY"
echo "bputil requires administrator privileges for read-only inspection."
if detect_bputil; then
    print_security_summary
    if [[ "${SECURITY_MODE}" == "Full" ]]; then
        log_pass "Security Mode is FULL."
    elif [[ "${SECURITY_MODE}" == "Reduced" ]]; then
        log_warn "Security Mode is REDUCED."
    else
        log_unknown "Security Mode is '${SECURITY_MODE:-UNKNOWN}'."
    fi
else
    log_unknown "bputil output unavailable (sudo may be required)."
fi

log_section "FILEVAULT"
FILEVAULT_OUTPUT="$(fdesetup status 2>&1 || true)"
echo "${FILEVAULT_OUTPUT}"
if echo "${FILEVAULT_OUTPUT}" | grep -qi 'FileVault is On'; then
    log_pass "FileVault is ON."
elif echo "${FILEVAULT_OUTPUT}" | grep -qi 'FileVault is Off'; then
    log_warn "FileVault is OFF."
else
    log_unknown "Could not classify FileVault state."
fi

log_section "USER / PRIVILEGES"
echo "User : (local account present)"
echo "UID  : $(id -u)"
if id -Gn | tr ' ' '\n' | grep -qx admin; then
    log_pass "Current user belongs to the admin group."
else
    log_warn "Current user does not appear to belong to the admin group."
fi

log_section "XCODE / DEVELOPER TOOLCHAIN"
detect_swift || log_fail "Swift compiler is unavailable."
detect_xcode
echo "xcode-select : ${XCODE_PATH:-UNKNOWN}"
echo "${XCODE_VERSION:-UNKNOWN}"
if command_exists xcrun; then
    echo "macOS SDK    : $(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo UNKNOWN)"
fi

log_section "CODE SIGNING IDENTITIES"
detect_signing_identity || true
if [[ -n "${SIGNING_IDENTITY}" ]]; then
    log_pass "Apple Development signing identity is available."
    echo "Identity : Apple Development: ***"
else
    log_warn "No Apple Development signing identity found."
fi
if [[ -n "${TEAM_ID}" ]]; then
    log_pass "Development Team ID detected."
    echo "Team ID  : present"
else
    log_unknown "Development Team ID could not be extracted."
fi

log_section "PROJECT STRUCTURE"
for REQUIRED in Package.swift Sources Vendored docs; do
    if [[ -e "${PROJECT_DIR}/${REQUIRED}" ]]; then
        log_pass "${REQUIRED} found."
    else
        log_fail "${REQUIRED} missing."
    fi
done

log_section "HOMEKIT PRIVATE ENTITLEMENT"
check_entitlements
if [[ "${ENTITLEMENTS_SOURCE_OK}" == true ]]; then
    log_pass "com.apple.hap.pairing is present in the source entitlements file."
else
    log_fail "com.apple.hap.pairing is NOT present in the source entitlements file."
fi

log_section "SWIFT BUILD"
if [[ "${BUILD_REQUESTED}" == true ]]; then
    if run_swift_build; then
        log_pass "swift build succeeded."
    else
        log_fail "swift build failed."
    fi
else
    log_warn "Build not checked in this run (use --build)."
fi

log_section "BUILT BINARY"
if binary_exists; then
    log_pass "Built binary found."
else
    log_warn "Built binary not found at ${BINARY_PATH}."
fi

if binary_exists; then
    log_section "BINARY RUNTIME CHECKS"
    if check_binary_help; then
        log_pass "Binary --help exits successfully."
    else
        log_fail "Binary --help failed."
    fi
    if check_binary_linkage; then
        log_pass "Binary does not link libswift_DarwinFoundation dylibs."
    else
        log_fail "Binary links libswift_DarwinFoundation dylibs or linkage check failed."
    fi
    check_binary_minos || true
    echo "Binary minos : ${MIN_OS_VERSION:-UNKNOWN}"

    log_section "EFFECTIVE ENTITLEMENTS"
    if [[ "${ENTITLEMENTS_BINARY_OK}" == true ]]; then
        log_pass "Binary currently contains com.apple.hap.pairing."
    else
        log_unknown "Binary does not currently contain com.apple.hap.pairing."
        echo "  Expected before CodeSignKit runtime signing."
    fi
fi

log_section "CODESIGNKIT RUNTIME SIGNING PATH"
check_codesign_runtime_path || true
if [[ "${CODESIGN_RUNTIME_PATH_OK}" == true ]]; then
    log_pass "CodeSignKit runtime signing path is available."
else
    log_fail "CodeSignKit runtime signing path is unavailable or incomplete."
fi
print_codesign_summary

log_section "RECOVERYOS"
log_unknown "RecoveryOS state cannot be verified from macOS. Manual steps are required."

log_section "WORKFLOW STATE"
state_init
WORKFLOW_STATE="$(state_get state idle)"
echo "Current workflow state : ${WORKFLOW_STATE}"
classify_security_state "${WORKFLOW_STATE}"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    PROJECT_VERDICT="PROJECT_BLOCKED"
elif binary_exists &&
     [[ "${ENTITLEMENTS_SOURCE_OK}" == true &&
        "${CODESIGN_RUNTIME_PATH_OK}" == true &&
        "${HELP_OK}" == true &&
        "${DARWIN_FOUNDATION_LINKED}" != true ]]; then
    PROJECT_VERDICT="READY_FOR_SECURITY_WORKFLOW"
elif [[ "${UNKNOWN_COUNT}" -gt 0 ]]; then
    PROJECT_VERDICT="PROJECT_UNKNOWN"
else
    PROJECT_VERDICT="PROJECT_UNKNOWN"
fi

log_section "FINAL ASSESSMENT"
print_assessment_footer
echo
echo "PROJECT_VERDICT          : ${PROJECT_VERDICT}"
echo "SECURITY_CLASSIFICATION  : ${SECURITY_CLASSIFICATION}"
echo
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    echo "RESULT: BLOCKED"
elif [[ "${UNKNOWN_COUNT}" -gt 0 ]]; then
    echo "RESULT: READY_WITH_UNKNOWN"
elif [[ "${WARN_COUNT}" -gt 0 ]]; then
    echo "RESULT: READY_WITH_WARNINGS"
else
    echo "RESULT: READY"
fi
echo
echo "No security configuration has been changed by this script."
if [[ -n "${REPORT_FILE}" ]]; then
    echo
    echo "Report saved to:"
    echo "  ${REPORT_FILE}"
fi

if [[ "${JSON_OUTPUT}" == true ]]; then
    cat <<EOF
{
  "project_verdict": "${PROJECT_VERDICT}",
  "security_classification": "${SECURITY_CLASSIFICATION}",
  "workflow_state": "${WORKFLOW_STATE}",
  "binary_exists": $(binary_exists && echo true || echo false),
  "binary_help_ok": $( [[ "${HELP_OK}" == true ]] && echo true || echo false),
  "entitlements_source_ok": $( [[ "${ENTITLEMENTS_SOURCE_OK}" == true ]] && echo true || echo false),
  "entitlements_binary_ok": $( [[ "${ENTITLEMENTS_BINARY_OK}" == true ]] && echo true || echo false),
  "codesign_runtime_path_ok": $( [[ "${CODESIGN_RUNTIME_PATH_OK}" == true ]] && echo true || echo false),
  "pass": ${PASS_COUNT},
  "warn": ${WARN_COUNT},
  "fail": ${FAIL_COUNT},
  "unknown": ${UNKNOWN_COUNT}
}
EOF
fi

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi
exit 0
