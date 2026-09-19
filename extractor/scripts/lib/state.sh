#!/usr/bin/env bash
# Persistent workflow state for multi-reboot orchestration.

set -euo pipefail

STATE_VERSION=1

state_init() {
    mkdir -p "${RUN_DIR}"
    if [[ ! -f "${STATE_FILE}" ]]; then
        state_write_kv "workflow_version" "${STATE_VERSION}"
        state_write_kv "state" "idle"
        state_write_kv "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
}

state_get() {
    local key="$1"
    local default="${2:-}"
    if [[ ! -f "${STATE_FILE}" ]]; then
        echo "${default}"
        return 0
    fi
    local value
    value="$(grep -E "^${key}=" "${STATE_FILE}" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
    if [[ -n "${value}" ]]; then
        echo "${value}"
    else
        echo "${default}"
    fi
}

state_set() {
    local key="$1"
    local value="$2"
    mkdir -p "${RUN_DIR}"
    state_init
    local temp
    temp="$(mktemp)"
    if [[ -f "${STATE_FILE}" ]]; then
        grep -v -E "^${key}=" "${STATE_FILE}" > "${temp}" || true
    else
        : > "${temp}"
    fi
    echo "${key}=${value}" >> "${temp}"
    mv "${temp}" "${STATE_FILE}"
    state_write_kv "updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

state_write_kv() {
    local key="$1"
    local value="$2"
    mkdir -p "${RUN_DIR}"
    local temp
    temp="$(mktemp)"
    if [[ -f "${STATE_FILE}" ]]; then
        grep -v -E "^${key}=" "${STATE_FILE}" > "${temp}" || true
    else
        : > "${temp}"
    fi
    echo "${key}=${value}" >> "${temp}"
    mv "${temp}" "${STATE_FILE}"
}

state_show() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        echo "(no workflow state)"
        return 0
    fi
    cat "${STATE_FILE}"
}
