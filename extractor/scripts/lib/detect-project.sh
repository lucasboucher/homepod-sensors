#!/usr/bin/env bash
# Project layout and entitlement detection.

set -euo pipefail

ENTITLEMENTS_SOURCE_OK=false
ENTITLEMENTS_BINARY_OK=false
ENTITLEMENTS_SOURCE_VALUE=""
ENTITLEMENTS_BINARY_VALUE=""

entitlements_source_has_hap() {
    if [[ ! -f "${ENTITLEMENTS_SOURCE}" ]]; then
        ENTITLEMENTS_SOURCE_OK=false
        return 1
    fi
    if grep -q "${HAP_ACCESS_GROUP}" "${ENTITLEMENTS_SOURCE}"; then
        ENTITLEMENTS_SOURCE_OK=true
        ENTITLEMENTS_SOURCE_VALUE="present"
        return 0
    fi
    ENTITLEMENTS_SOURCE_OK=false
    ENTITLEMENTS_SOURCE_VALUE="missing"
    return 1
}

entitlements_binary_has_hap() {
    if ! binary_exists; then
        ENTITLEMENTS_BINARY_OK=false
        return 1
    fi
    local entitlements
    entitlements="$(codesign -d --entitlements :- "${BINARY_PATH}" 2>/dev/null || true)"
    if echo "${entitlements}" | grep -q "${HAP_ACCESS_GROUP}"; then
        ENTITLEMENTS_BINARY_OK=true
        ENTITLEMENTS_BINARY_VALUE="present"
        return 0
    fi
    ENTITLEMENTS_BINARY_OK=false
    ENTITLEMENTS_BINARY_VALUE="missing"
    return 1
}

check_entitlements() {
    entitlements_source_has_hap || true
    entitlements_binary_has_hap || true
}

print_project_summary() {
    echo "Entitlements source     : ${ENTITLEMENTS_SOURCE}"
    echo "HAP in source file      : ${ENTITLEMENTS_SOURCE_VALUE:-UNKNOWN}"
    echo "HAP in signed binary    : ${ENTITLEMENTS_BINARY_VALUE:-UNKNOWN}"
}
