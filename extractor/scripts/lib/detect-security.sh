#!/usr/bin/env bash
# Read-only macOS security state detection.

set -euo pipefail

SECURITY_MODE=""
BPUTIL_SIP=""
BPUTIL_SSV=""
BPUTIL_CTRR=""
BPUTIL_BOOT_FILTER=""
PAIRING_INTEGRITY=""
CSR_OUTPUT=""
BOOT_ARGS=""
KNOWN_AMFI=false
SECURITY_CLASSIFICATION="SECURITY_UNKNOWN"

parse_bputil_field() {
    local label="$1"
    local output="$2"
    echo "${output}" | sed -n "s/^[[:space:]]*${label}[[:space:]]*:[[:space:]]*\\([^[:space:]]*\\).*$/\\1/p" | head -n 1
}

detect_nvram_boot_args() {
    local nvram_output
    nvram_output="$(nvram -p 2>/dev/null | grep -E 'boot-args|csr-active-config' || true)"
    BOOT_ARGS="$(echo "${nvram_output}" | sed -n 's/^boot-args[[:space:]]*//p' | head -n 1)"
    if echo "${BOOT_ARGS}" | grep -Eq 'amfi_get_out_of_my_way|amfi_allow_any_signature|cs_enforcement_disable|amfi_unrestrict'; then
        KNOWN_AMFI=true
    else
        KNOWN_AMFI=false
    fi
}

detect_csrutil() {
    CSR_OUTPUT="$(csrutil status 2>&1 || true)"
}

detect_bputil() {
    if ! command_exists sudo; then
        return 1
    fi
    local output
    if ! output="$(sudo bputil -d 2>&1)"; then
        return 1
    fi
    SECURITY_MODE="$(parse_bputil_field "Security Mode" "${output}")"
    BPUTIL_SIP="$(parse_bputil_field "SIP Status" "${output}")"
    BPUTIL_SSV="$(parse_bputil_field "Signed System Volume Status" "${output}")"
    BPUTIL_CTRR="$(parse_bputil_field "Kernel CTRR Status" "${output}")"
    BPUTIL_BOOT_FILTER="$(parse_bputil_field "Boot Args Filtering Status" "${output}")"
    PAIRING_INTEGRITY="$(parse_bputil_field "Pairing Integrity" "${output}")"
    return 0
}

sip_is_disabled() {
    if echo "${CSR_OUTPUT}" | grep -qi 'disabled'; then
        return 0
    fi
    if [[ "${BPUTIL_SIP}" == "Disabled" ]]; then
        return 0
    fi
    return 1
}

sip_is_enabled() {
    if echo "${CSR_OUTPUT}" | grep -qi 'enabled'; then
        return 0
    fi
    if [[ "${BPUTIL_SIP}" == "Enabled" ]]; then
        return 0
    fi
    return 1
}

amfi_bypass_present() {
    [[ "${KNOWN_AMFI}" == true ]]
}

amfi_bypass_absent() {
    [[ "${KNOWN_AMFI}" != true ]]
}

amfi_workflow_arg_present() {
    detect_nvram_boot_args
    [[ "${BOOT_ARGS}" == *"amfi_get_out_of_my_way"* ]]
}

amfi_workflow_arg_absent() {
    ! amfi_workflow_arg_present
}

classify_security_state() {
    local workflow_state="${1:-}"
    detect_csrutil
    detect_nvram_boot_args
    local bputil_ok=false
    if detect_bputil; then
        bputil_ok=true
    fi

    if [[ "${workflow_state}" == "extracted" || "${workflow_state}" == "restore_pending" || "${workflow_state}" == "amfi_cleared" || "${workflow_state}" == "awaiting_sip_restore" ]]; then
        SECURITY_CLASSIFICATION="SECURITY_RESTORATION_REQUIRED"
        return 0
    fi

    local sip_off=false
    local amfi_on=false
    if sip_is_disabled; then sip_off=true; fi
    if amfi_bypass_present; then amfi_on=true; fi

    if ${sip_off} && ${amfi_on}; then
        SECURITY_CLASSIFICATION="SECURITY_PREPARED_FOR_EXTRACTION"
    elif ${sip_off} || ${amfi_on}; then
        SECURITY_CLASSIFICATION="SECURITY_PARTIALLY_PREPARED"
    elif sip_is_enabled && amfi_bypass_absent; then
        if [[ "${bputil_ok}" == true && -n "${SECURITY_MODE}" && "${SECURITY_MODE}" != "Full" ]]; then
            SECURITY_CLASSIFICATION="SECURITY_UNKNOWN"
        else
            SECURITY_CLASSIFICATION="SECURITY_SECURE_DEFAULT"
        fi
    else
        SECURITY_CLASSIFICATION="SECURITY_UNKNOWN"
    fi
}

print_security_summary() {
    echo "Security classification : ${SECURITY_CLASSIFICATION}"
    echo "csrutil status          : ${CSR_OUTPUT:-UNKNOWN}"
    echo "boot-args               : ${BOOT_ARGS:-"(none)"}"
    echo "Security Mode           : ${SECURITY_MODE:-UNKNOWN}"
    echo "SIP Status (bputil)     : ${BPUTIL_SIP:-UNKNOWN}"
    echo "AMFI bypass boot-args   : $( [[ "${KNOWN_AMFI}" == true ]] && echo PRESENT || echo none )"
}

compute_restore_status() {
    local workflow_state="${1:-idle}"
    RESTORE_STATUS="RESTORE_STATUS_UNKNOWN"

    detect_csrutil
    detect_nvram_boot_args

    if [[ "${workflow_state}" == "restored" ]]; then
        RESTORE_STATUS="SECURITY_VERIFIED_RESTORED"
        return 0
    fi

    if [[ "${workflow_state}" == "restore_incomplete" ]]; then
        RESTORE_STATUS="RESTORATION_REQUIRED"
        return 0
    fi

    if [[ "${workflow_state}" == "awaiting_sip_restore" ]]; then
        RESTORE_STATUS="RESTORATION_RECOVERYOS_REQUIRED"
        return 0
    fi

    if [[ "${workflow_state}" == "restore_pending" || "${workflow_state}" == "extracted" ]]; then
        RESTORE_STATUS="RESTORATION_REQUIRED"
        return 0
    fi

    if amfi_workflow_arg_present; then
        RESTORE_STATUS="RESTORATION_REQUIRED"
        return 0
    fi

    if sip_is_disabled; then
        RESTORE_STATUS="RESTORATION_REQUIRED"
        return 0
    fi

    if sip_is_enabled && amfi_workflow_arg_absent; then
        RESTORE_STATUS="SECURITY_APPEARS_NORMAL"
        return 0
    fi

    RESTORE_STATUS="RESTORE_STATUS_UNKNOWN"
    return 1
}
