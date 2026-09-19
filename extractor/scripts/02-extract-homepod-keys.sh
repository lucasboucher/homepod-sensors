#!/usr/bin/env bash
# HomePod Keychain Extractor — full workflow orchestrator.

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
# shellcheck source=lib/boot-args.sh
source "${SCRIPT_DIR}/lib/boot-args.sh"
# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"

usage() {
    cat <<EOF
Usage:
  ./scripts/02-extract-homepod-keys.sh start [--confirm]
  ./scripts/02-extract-homepod-keys.sh status
  ./scripts/02-extract-homepod-keys.sh plan
  ./scripts/02-extract-homepod-keys.sh resume
  ./scripts/02-extract-homepod-keys.sh prepare-amfi [--confirm]
  ./scripts/02-extract-homepod-keys.sh extract [--confirm]
  ./scripts/02-extract-homepod-keys.sh clear-amfi [--confirm]
  ./scripts/02-extract-homepod-keys.sh abandon [--confirm]

Read-only: status, plan
Orchestration: start --confirm arms the workflow; resume chains automated macOS steps
Manual RecoveryOS only: csrutil disable / csrutil enable

CodeSignKit uses the default "Apple Development" identity when CODESIGNKIT_DEFAULT_IDENTITY is unset.

Extraction uses the pre-built binary only:
  ${BINARY_PATH}
Dump path:
  ${DUMP_PATH}
EOF
}

cleanup_lock() {
    release_lock
}

trap cleanup_lock EXIT

current_state() {
    state_init
    state_get state idle
}

set_state() {
    local new_state="$1"
    state_set state "${new_state}"
    state_set updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

preflight_project_ready() {
    if ! binary_exists; then
        echo "Binary not found. Run ./scripts/01-check-environment.sh --build first."
        return 1
    fi
    if ! [[ -x "${BINARY_PATH}" ]]; then
        echo "Binary is not executable: ${BINARY_PATH}"
        return 1
    fi
    check_binary_help || {
        echo "Binary --help failed. Re-run ./scripts/01-check-environment.sh --build"
        return 1
    }
    check_entitlements
    if [[ "${ENTITLEMENTS_SOURCE_OK}" != true ]]; then
        echo "Source entitlements file does not contain com.apple.hap.pairing."
        return 1
    fi
    check_codesign_runtime_path || true
    if [[ "${CODESIGN_RUNTIME_PATH_OK}" != true ]]; then
        echo "CodeSignKit runtime signing path is unavailable."
        return 1
    fi
    return 0
}

run_preflight_check() {
    if ! preflight_project_ready; then
        return 1
    fi
    detect_signing_identity || true
    if [[ -z "${SIGNING_IDENTITY}" ]]; then
        echo "Preflight failed: no Apple Development signing identity for CodeSignKit default."
        return 1
    fi
    detect_csrutil
    detect_nvram_boot_args
    if ! sip_is_enabled; then
        echo "Preflight failed: SIP is not enabled. Restore security before starting a new workflow."
        return 1
    fi
    if ! amfi_workflow_arg_absent; then
        echo "Preflight failed: AMFI workflow boot-arg already present."
        return 1
    fi
    return 0
}

require_workflow_security_confirmed() {
    if [[ "$(state_get security_confirmed "")" != "true" ]]; then
        fail_closed "Workflow security actions require ./scripts/02-extract-homepod-keys.sh start --confirm first."
        return 2
    fi
    return 0
}

show_recovery_disable_sip() {
    cat <<'EOF'
============================================================
 RECOVERYOS REQUIRED — DISABLE SIP
============================================================
1. Shut down the Mac.
2. Hold the power button until "Loading startup options..." appears.
3. Select Options → Continue.
4. Authenticate if requested.
5. Open Terminal from Utilities.
6. Run:
   csrutil disable
7. Confirm the requested change.
8. Reboot into macOS.

After macOS has booted, run:
   ./scripts/02-extract-homepod-keys.sh resume

This script did NOT execute csrutil disable.
EOF
}

show_recovery_enable_sip() {
    cat <<'EOF'
============================================================
 RECOVERYOS REQUIRED — ENABLE SIP
============================================================
Connect to a network with Internet access before re-enabling full security.

Shut down or reboot into RecoveryOS, then open Terminal and run:
   csrutil enable
Then reboot into macOS.

After macOS has booted:
   ./scripts/02-extract-homepod-keys.sh resume

This script did NOT execute csrutil enable.
EOF
}

show_full_workflow_plan() {
    cat <<'EOF'
Full workflow (only RecoveryOS steps are manual):

1. ./scripts/02-extract-homepod-keys.sh start --confirm
2. [MANUAL RecoveryOS] csrutil disable → reboot
3. ./scripts/02-extract-homepod-keys.sh resume
      → verifies SIP disabled
      → configures AMFI boot-arg
      → requests macOS reboot
4. [MANUAL] reboot macOS
5. ./scripts/02-extract-homepod-keys.sh resume
      → verifies SIP disabled + AMFI active
      → runs extraction (CodeSignKit default Apple Development identity)
      → validates dump
      → removes AMFI boot-arg
      → requests RecoveryOS SIP restore
6. [MANUAL RecoveryOS] csrutil enable → reboot
7. ./scripts/02-extract-homepod-keys.sh resume
      → verifies SIP enabled + AMFI absent
      → restored

Security confirmation is collected once at start --confirm.
EOF
}

fail_closed() {
    local reason="$1"
    state_set failure_reason "${reason}"
    echo "FAIL_CLOSED: ${reason}"
    return 2
}

verify_sip_disabled() {
    detect_csrutil
    sip_is_disabled
}

verify_amfi_ready_environment() {
    verify_sip_disabled || return 1
    amfi_workflow_arg_present || return 1
    return 0
}

verify_restored_environment() {
    detect_csrutil
    detect_nvram_boot_args
    sip_is_enabled && amfi_workflow_arg_absent
}

orchestrate_configure_amfi() {
    require_workflow_security_confirmed || return 2
    if ! verify_sip_disabled; then
        fail_closed "SIP must be disabled before configuring AMFI boot-args."
        return 2
    fi
    configure_amfi_workflow_boot_arg
    if ! amfi_workflow_arg_present; then
        fail_closed "AMFI workflow boot-arg was not configured."
        return 1
    fi
    set_state "awaiting_amfi_reboot"
    state_set expected_after_reboot "amfi_ready"
    state_set last_action "prepare_amfi"
    state_set last_action_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "AMFI boot-arg configured."
    echo "Reboot macOS manually, then run:"
    echo "  ./scripts/02-extract-homepod-keys.sh resume"
}

orchestrate_clear_amfi() {
    require_workflow_security_confirmed || return 2
    clear_amfi_workflow_boot_arg
    if amfi_workflow_arg_present; then
        fail_closed "AMFI workflow boot-arg is still present after cleanup."
        return 1
    fi
    set_state "awaiting_sip_restore"
    state_set expected_after_reboot "sip_enabled"
    state_set last_action "clear_amfi"
    state_set last_action_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "AMFI workflow boot-arg removed."
    echo "SIP is still disabled at this stage — this is expected."
    show_recovery_enable_sip
}

orchestrate_extract() {
    require_workflow_security_confirmed || return 2
    local dump_file
    dump_file="$(state_get dump_path "${DUMP_PATH}")"

    if ! verify_amfi_ready_environment; then
        fail_closed "SIP disabled and AMFI workflow boot-arg required before extraction."
        print_security_summary
        return 2
    fi
    if ! preflight_project_ready; then
        return 2
    fi

    mkdir -p "$(dirname "${dump_file}")"
    set_state "extracting"
    state_set extract_started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    state_set extract_exit_code ""

    echo "Starting extraction with pre-built binary (no swift build, no timeout)."
    echo "Signing: CodeSignKit default Apple Development identity."
    echo "Binary: ${BINARY_PATH}"
    echo "Output: ${dump_file}"

    local exit_code=0
    set +e
    "${BINARY_PATH}" extract -g "${HAP_ACCESS_GROUP}" > "${dump_file}" 2>&1
    exit_code=$?
    set -e

    state_set extract_exit_code "${exit_code}"
    state_set extract_finished_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if ! validate_dump_file "${dump_file}" "${exit_code}"; then
        set_state "extract_failed"
        state_set failure_reason "extract_failed_exit_${exit_code}"
        echo "Extraction failed (exit=${exit_code}). Partial dump preserved."
        return 1
    fi

    set_state "restore_pending"
    state_set failure_reason ""
    echo "Extraction succeeded. Dump validated (Keychain Items Matched > 0)."
    orchestrate_clear_amfi
}

advance_after_sip_restore() {
    if verify_restored_environment; then
        set_state "restored"
        state_set expected_after_reboot ""
        state_set failure_reason ""
        echo "Security restoration verified. Workflow complete (restored)."
        return 0
    fi
    set_state "restore_incomplete"
    fail_closed "SIP is not enabled and/or AMFI workflow boot-arg is still present after RecoveryOS."
    print_security_summary
    return 2
}

cmd_start() {
    local confirm="${1:-}"
    require_confirm_flag "${confirm}"
    acquire_lock
    setup_log_file "extract"

    local existing
    existing="$(current_state)"
    if [[ "${existing}" != "idle" && "${existing}" != "abandoned" && "${existing}" != "restored" ]]; then
        echo "Workflow already active (state=${existing}). Use status, plan, or resume."
        return 2
    fi

    echo "Running preflight..."
    if ! run_preflight_check; then
        echo "Start aborted. Fix preflight issues and run ./scripts/01-check-environment.sh --build"
        return 1
    fi

    state_set dump_path "${DUMP_PATH}"
    state_set expected_after_reboot "sip_disabled"
    state_set failure_reason ""
    state_set security_confirmed "true"
    state_set security_confirmed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    set_state "awaiting_recovery_disable"

    echo "Workflow started and security actions confirmed for this run."
    show_recovery_disable_sip
}

cmd_status() {
    state_init
    local workflow_state
    workflow_state="$(current_state)"
    detect_csrutil
    detect_nvram_boot_args
    classify_security_state "${workflow_state}"

    echo "Workflow state            : ${workflow_state}"
    echo "Expected after reboot     : $(state_get expected_after_reboot "")"
    echo "Security confirmed        : $(state_get security_confirmed "")"
    echo "Dump path                 : $(state_get dump_path "${DUMP_PATH}")"
    echo "Last failure reason       : $(state_get failure_reason "")"
    print_security_summary
    echo
    if binary_exists; then
        echo "Binary                    : present"
    else
        echo "Binary                    : missing"
    fi
    local dump_file
    dump_file="$(state_get dump_path "${DUMP_PATH}")"
    if [[ -f "${dump_file}" ]]; then
        echo "Dump file                 : present (contents not shown)"
    else
        echo "Dump file                 : absent"
    fi
}

cmd_plan() {
    state_init
    local workflow_state
    workflow_state="$(current_state)"
    detect_csrutil
    detect_nvram_boot_args

    echo "Workflow plan (current state: ${workflow_state})"
    echo
    case "${workflow_state}" in
        idle|abandoned|restored)
            show_full_workflow_plan
            ;;
        awaiting_recovery_disable)
            show_recovery_disable_sip
            ;;
        sip_disabled|awaiting_amfi_reboot)
            echo "Next: reboot macOS if not done yet, then:"
            echo "  ./scripts/02-extract-homepod-keys.sh resume"
            ;;
        amfi_ready|extracting|restore_pending)
            echo "Next:"
            echo "  ./scripts/02-extract-homepod-keys.sh resume"
            ;;
        awaiting_sip_restore)
            show_recovery_enable_sip
            ;;
        extract_failed)
            echo "Extraction failed. Restore security with ./scripts/03-restore-security.sh plan"
            ;;
        restore_incomplete)
            echo "Security restoration incomplete. Use ./scripts/03-restore-security.sh status and plan"
            ;;
        *)
            echo "Unhandled state. Use ./scripts/02-extract-homepod-keys.sh status"
            ;;
    esac
}

cmd_resume() {
    acquire_lock
    setup_log_file "extract"

    local workflow_state expected
    workflow_state="$(current_state)"
    expected="$(state_get expected_after_reboot "")"

    echo "Resuming workflow from state: ${workflow_state}"
    echo "Expected after reboot       : ${expected:-"(none)"}"

    case "${workflow_state}" in
        awaiting_recovery_disable)
            if ! verify_sip_disabled; then
                fail_closed "SIP was not disabled in RecoveryOS."
                show_recovery_disable_sip
                return 2
            fi
            set_state "sip_disabled"
            orchestrate_configure_amfi
            ;;
        sip_disabled)
            if amfi_workflow_arg_present; then
                set_state "awaiting_amfi_reboot"
                state_set expected_after_reboot "amfi_ready"
                echo "AMFI boot-arg already present. Reboot macOS, then run resume again."
            else
                orchestrate_configure_amfi
            fi
            ;;
        awaiting_amfi_reboot)
            if [[ "${expected}" != "amfi_ready" ]]; then
                fail_closed "Workflow expected amfi_ready after reboot."
                return 2
            fi
            if ! verify_amfi_ready_environment; then
                fail_closed "Expected SIP disabled and AMFI workflow boot-arg after reboot."
                print_security_summary
                return 2
            fi
            set_state "amfi_ready"
            orchestrate_extract
            ;;
        amfi_ready)
            orchestrate_extract
            ;;
        extracting)
            local exit_code dump_file
            exit_code="$(state_get extract_exit_code 1)"
            dump_file="$(state_get dump_path "${DUMP_PATH}")"
            if validate_dump_file "${dump_file}" "${exit_code}"; then
                set_state "restore_pending"
                orchestrate_clear_amfi
                return 0
            fi
            set_state "extract_failed"
            state_set failure_reason "dump_validation_failed"
            echo "Extraction failed or dump validation failed (exit=${exit_code}). Partial dump preserved."
            return 1
            ;;
        restore_pending)
            orchestrate_clear_amfi
            ;;
        awaiting_sip_restore)
            if [[ "${expected}" != "sip_enabled" ]]; then
                fail_closed "Workflow expected sip_enabled after RecoveryOS reboot."
                return 2
            fi
            advance_after_sip_restore
            ;;
        extract_failed)
            echo "Previous extraction failed. Restore security with ./scripts/03-restore-security.sh plan"
            ;;
        restore_incomplete)
            echo "Restoration incomplete. Use ./scripts/03-restore-security.sh status and plan"
            ;;
        restored)
            echo "Workflow already restored."
            ;;
        idle|abandoned)
            echo "No active workflow. Run ./scripts/02-extract-homepod-keys.sh start --confirm"
            return 2
            ;;
        *)
            fail_closed "Unhandled workflow state: ${workflow_state}"
            return 2
            ;;
    esac
}

cmd_prepare_amfi() {
    local confirm="${1:-}"
    require_confirm_flag "${confirm}"
    acquire_lock
    local workflow_state
    workflow_state="$(current_state)"

    if [[ "${workflow_state}" != "sip_disabled" ]]; then
        echo "prepare-amfi is only valid from sip_disabled (current: ${workflow_state})."
        echo "Normal workflow: use resume after start --confirm."
        return 2
    fi
    orchestrate_configure_amfi
}

cmd_extract() {
    local confirm="${1:-}"
    require_confirm_flag "${confirm}"
    acquire_lock
    setup_log_file "extract"
    local workflow_state
    workflow_state="$(current_state)"

    if [[ "${workflow_state}" != "amfi_ready" && "${workflow_state}" != "awaiting_amfi_reboot" ]]; then
        echo "extract is only valid from amfi_ready (current: ${workflow_state})."
        echo "Normal workflow: use resume after start --confirm."
        return 2
    fi
    set_state "amfi_ready"
    orchestrate_extract
}

cmd_clear_amfi() {
    local confirm="${1:-}"
    require_confirm_flag "${confirm}"
    acquire_lock
    local workflow_state
    workflow_state="$(current_state)"

    if [[ "${workflow_state}" != "restore_pending" && "${workflow_state}" != "awaiting_sip_restore" ]]; then
        echo "clear-amfi is only valid from restore_pending (current: ${workflow_state})."
        echo "Use ./scripts/03-restore-security.sh clear-amfi --confirm for manual recovery."
        return 2
    fi
    orchestrate_clear_amfi
}

cmd_abandon() {
    local confirm="${1:-}"
    require_confirm_flag "${confirm}"
    acquire_lock
    set_state "abandoned"
    state_set expected_after_reboot ""
    state_set security_confirmed ""
    state_set abandoned_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Workflow abandoned. System protections were not changed by this command."
    echo "If security was modified, run ./scripts/03-restore-security.sh plan"
}

COMMAND="${1:-}"
shift || true

case "${COMMAND}" in
    start)
        cmd_start "${1:-}"
        ;;
    status)
        cmd_status
        ;;
    plan)
        cmd_plan
        ;;
    resume)
        cmd_resume
        ;;
    prepare-amfi)
        cmd_prepare_amfi "${1:-}"
        ;;
    extract)
        cmd_extract "${1:-}"
        ;;
    clear-amfi)
        cmd_clear_amfi "${1:-}"
        ;;
    abandon)
        cmd_abandon "${1:-}"
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
