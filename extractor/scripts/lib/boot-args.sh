#!/usr/bin/env bash
# NVRAM boot-args helpers — preserve unrelated arguments.

set -euo pipefail

AMFI_WORKFLOW_ARG="amfi_get_out_of_my_way=0x1"

nvram_read_boot_args() {
    local nvram_line
    nvram_line="$(nvram -p 2>/dev/null | grep -E '^boot-args' | head -n 1 || true)"
    if [[ -n "${nvram_line}" ]]; then
        BOOT_ARGS="${nvram_line#boot-args}"
        BOOT_ARGS="${BOOT_ARGS#"${BOOT_ARGS%%[![:space:]]*}"}"
    else
        BOOT_ARGS=""
    fi
}

boot_args_has_amfi_workflow_arg() {
    [[ "${BOOT_ARGS}" == *"amfi_get_out_of_my_way"* ]]
}

boot_args_with_amfi_added() {
    local current="${1:-}"
    if [[ "${current}" == *"amfi_get_out_of_my_way"* ]]; then
        printf '%s' "${current}"
        return 0
    fi
    if [[ -z "${current}" ]]; then
        printf '%s' "${AMFI_WORKFLOW_ARG}"
    else
        printf '%s %s' "${current}" "${AMFI_WORKFLOW_ARG}"
    fi
}

boot_args_with_amfi_removed() {
    local current="${1:-}"
    local cleaned
    cleaned="$(
        printf '%s' "${current}" |
        sed -E 's/(^|[[:space:]])amfi_get_out_of_my_way(=[^[:space:]]*)?//g' |
        sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g'
    )"
    printf '%s' "${cleaned}"
}

nvram_write_boot_args() {
    local new_args="${1:-}"
    if [[ -z "${new_args}" ]]; then
        if sudo nvram -d boot-args 2>/dev/null; then
            return 0
        fi
        sudo nvram boot-args=""
    else
        sudo nvram boot-args="${new_args}"
    fi
}

configure_amfi_workflow_boot_arg() {
    nvram_read_boot_args
    local updated
    updated="$(boot_args_with_amfi_added "${BOOT_ARGS}")"
    nvram_write_boot_args "${updated}"
    nvram_read_boot_args
}

clear_amfi_workflow_boot_arg() {
    nvram_read_boot_args
    local updated
    updated="$(boot_args_with_amfi_removed "${BOOT_ARGS}")"
    nvram_write_boot_args "${updated}"
    nvram_read_boot_args
}
