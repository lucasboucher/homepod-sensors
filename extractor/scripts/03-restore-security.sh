#!/usr/bin/env bash
# HomePod Keychain Extractor — security restoration orchestrator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/detect-security.sh
source "${SCRIPT_DIR}/lib/detect-security.sh"
# shellcheck source=lib/boot-args.sh
source "${SCRIPT_DIR}/lib/boot-args.sh"
# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"

usage() {
    cat <<EOF
Usage:
  ./scripts/03-restore-security.sh status
  ./scripts/03-restore-security.sh plan
  ./scripts/03-restore-security.sh clear-amfi [--confirm]
  ./scripts/03-restore-security.sh verify
  ./scripts/03-restore-security.sh finalize

RecoveryOS steps (csrutil enable) are manual only. This script never runs csrutil from macOS.
EOF
}

cleanup_lock() {
    release_lock
}

trap cleanup_lock EXIT

show_recovery_enable_sip() {
    cat <<'EOF'
RecoveryOS manual step:
   csrutil enable
Then reboot into macOS.
Connect to a network with Internet access before re-enabling full security.
EOF
}

cmd_status() {
    state_init
    local workflow_state
    workflow_state="$(state_get state idle)"
    classify_security_state "${workflow_state}"
    compute_restore_status "${workflow_state}"

    echo "Workflow state            : ${workflow_state}"
    print_security_summary
    echo
    echo "RESTORE_STATUS: ${RESTORE_STATUS}"

    if [[ "${RESTORE_STATUS}" == "RESTORE_STATUS_UNKNOWN" ]]; then
        return 2
    fi
    return 0
}

cmd_plan() {
    state_init
    local workflow_state
    workflow_state="$(state_get state idle)"
    detect_csrutil
    detect_nvram_boot_args
    classify_security_state "${workflow_state}"

    echo "Restoration plan (workflow state: ${workflow_state}):"
    echo
    if amfi_workflow_arg_present; then
        echo "1. macOS: clear AMFI workflow boot-arg"
        echo "   ./scripts/03-restore-security.sh clear-amfi --confirm"
        echo "   or ./scripts/02-extract-homepod-keys.sh clear-amfi --confirm"
        echo "2. macOS: shut down or reboot manually"
        echo "   sudo shutdown -h now"
    else
        echo "1. AMFI workflow boot-arg already absent."
    fi
    if sip_is_disabled; then
        echo "2. RecoveryOS (manual): csrutil enable"
        show_recovery_enable_sip
        echo "3. macOS: verify restoration"
        echo "   ./scripts/03-restore-security.sh verify"
        echo "   ./scripts/02-extract-homepod-keys.sh resume"
    elif sip_is_enabled; then
        echo "2. SIP already appears enabled."
        echo "3. macOS: verify restoration"
        echo "   ./scripts/03-restore-security.sh verify"
    else
        echo "2. SIP state unknown — verify manually in RecoveryOS if needed."
    fi
    echo
    echo "This script never executes csrutil enable from macOS."
}

security_is_restored() {
    detect_csrutil
    detect_nvram_boot_args
    sip_is_enabled && amfi_workflow_arg_absent
}

cmd_verify() {
    state_init
    if security_is_restored; then
        echo "RESTORE_VERDICT: RESTORED"
        return 0
    fi
    echo "RESTORE_VERDICT: NOT_VERIFIED"
    print_security_summary
    return 1
}

cmd_clear_amfi() {
    local confirm="${1:-}"
    state_init

    if amfi_workflow_arg_absent; then
        echo "AMFI workflow boot-arg already absent. No change required."
        return 0
    fi

    require_confirm_flag "${confirm}"
    acquire_lock

    clear_amfi_workflow_boot_arg
    state_set expected_after_reboot "sip_enabled"
    state_set last_action "clear_amfi"
    state_set last_action_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    detect_nvram_boot_args
    if amfi_workflow_arg_absent; then
        local workflow_state
        workflow_state="$(state_get state idle)"
        if [[ "${workflow_state}" == "restore_pending" ]]; then
            state_set state "awaiting_sip_restore"
        fi
        echo "AMFI workflow boot-arg removed."
        echo "Next: shut down manually, then re-enable SIP in RecoveryOS."
        echo "  sudo shutdown -h now"
        return 0
    fi

    echo "AMFI workflow boot-arg may still be present. Verify manually."
    return 1
}

cmd_finalize() {
    state_init
    if ! security_is_restored; then
        echo "Cannot finalize: security is not verified as restored."
        cmd_verify || true
        return 1
    fi

    acquire_lock
    mkdir -p "${RUN_DIR}/archive"
    if [[ -f "${STATE_FILE}" ]]; then
        cp "${STATE_FILE}" "${RUN_DIR}/archive/workflow-$(date '+%Y%m%d-%H%M%S').state"
    fi
    state_set state "restored"
    state_set expected_after_reboot ""
    state_set finalized_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Workflow finalized. Security appears restored."
}

COMMAND="${1:-}"
shift || true

case "${COMMAND}" in
    status)
        cmd_status
        ;;
    plan)
        cmd_plan
        ;;
    clear-amfi)
        cmd_clear_amfi "${1:-}"
        ;;
    verify)
        cmd_verify
        ;;
    finalize)
        cmd_finalize
        ;;
    -h|--help|"")
        usage
        [[ -z "${COMMAND}" ]] && exit 2
        ;;
    *)
        echo "Unknown command: ${COMMAND}"
        usage
        exit 2
        ;;
esac
