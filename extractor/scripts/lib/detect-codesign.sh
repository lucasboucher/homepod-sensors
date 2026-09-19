#!/usr/bin/env bash
# Static verification of the CodeSignKit runtime signing path used by extract.

set -euo pipefail

CODESIGNKIT_PACKAGE_OK=false
CODESIGN_SIGN_METHOD_OK=false
CODESIGN_EXTRACT_CALL_OK=false
CODESIGN_PACKAGE_LINK_OK=false
CODESIGN_ENTITLEMENTS_PAIR_OK=false
CODESIGN_RUNTIME_PATH_OK=false

CODESIGN_SWIFT="${PROJECT_DIR}/Vendored/CodeSignKit/Sources/CodeSignKit/CodeSign.swift"
CODESIGN_PACKAGE_SWIFT="${PROJECT_DIR}/Vendored/CodeSignKit/Package.swift"
EXTRACT_COMMAND_SWIFT="${PROJECT_DIR}/Sources/HomePodKeychainExtractor/ExtractCommand.swift"
ROOT_PACKAGE_SWIFT="${PROJECT_DIR}/Package.swift"
EXTRACT_ENTITLEMENTS="${PROJECT_DIR}/Sources/HomePodKeychainExtractor/HomePodKeychainExtractor.entitlements"

check_codesign_runtime_path() {
    CODESIGNKIT_PACKAGE_OK=false
    CODESIGN_SIGN_METHOD_OK=false
    CODESIGN_EXTRACT_CALL_OK=false
    CODESIGN_PACKAGE_LINK_OK=false
    CODESIGN_ENTITLEMENTS_PAIR_OK=false
    CODESIGN_RUNTIME_PATH_OK=false

    if [[ -f "${CODESIGN_PACKAGE_SWIFT}" && -f "${CODESIGN_SWIFT}" ]]; then
        CODESIGNKIT_PACKAGE_OK=true
    else
        return 1
    fi

    if grep -q 'func signMainExecutableOnceAndRun' "${CODESIGN_SWIFT}" &&
       grep -q 'findPairedEntitlementsFile' "${CODESIGN_SWIFT}" &&
       grep -q 'codesign' "${CODESIGN_SWIFT}"; then
        CODESIGN_SIGN_METHOD_OK=true
    fi

    if [[ -f "${EXTRACT_COMMAND_SWIFT}" ]] &&
       grep -q 'import CodeSignKit' "${EXTRACT_COMMAND_SWIFT}" &&
       grep -q 'CodeSign\.signMainExecutableOnceAndRun()' "${EXTRACT_COMMAND_SWIFT}"; then
        CODESIGN_EXTRACT_CALL_OK=true
    fi

    if [[ -f "${ROOT_PACKAGE_SWIFT}" ]] &&
       grep -q 'Vendored/CodeSignKit' "${ROOT_PACKAGE_SWIFT}" &&
       grep -A 20 'name: "HomePodKeychainExtractor"' "${ROOT_PACKAGE_SWIFT}" | grep -q '"CodeSignKit"'; then
        CODESIGN_PACKAGE_LINK_OK=true
    fi

    # CodeSignKit pairs entitlements from ExtractCommand.swift's directory.
    # Expected resolved file: HomePodKeychainExtractor.entitlements
    if [[ -f "${EXTRACT_ENTITLEMENTS}" ]] &&
       grep -q "${HAP_ACCESS_GROUP}" "${EXTRACT_ENTITLEMENTS}"; then
        CODESIGN_ENTITLEMENTS_PAIR_OK=true
    fi

    if [[ "${CODESIGNKIT_PACKAGE_OK}" == true &&
          "${CODESIGN_SIGN_METHOD_OK}" == true &&
          "${CODESIGN_EXTRACT_CALL_OK}" == true &&
          "${CODESIGN_PACKAGE_LINK_OK}" == true &&
          "${CODESIGN_ENTITLEMENTS_PAIR_OK}" == true ]]; then
        CODESIGN_RUNTIME_PATH_OK=true
        return 0
    fi
    return 1
}

print_codesign_summary() {
    echo "CodeSignKit package         : $( [[ "${CODESIGNKIT_PACKAGE_OK}" == true ]] && echo present || echo missing )"
    echo "signMainExecutableOnceAndRun: $( [[ "${CODESIGN_SIGN_METHOD_OK}" == true ]] && echo present || echo missing )"
    echo "ExtractCommand call site    : $( [[ "${CODESIGN_EXTRACT_CALL_OK}" == true ]] && echo present || echo missing )"
    echo "Package.swift link          : $( [[ "${CODESIGN_PACKAGE_LINK_OK}" == true ]] && echo present || echo missing )"
    echo "Paired entitlements file    : $( [[ "${CODESIGN_ENTITLEMENTS_PAIR_OK}" == true ]] && echo present || echo missing )"
    echo "Runtime signing path        : $( [[ "${CODESIGN_RUNTIME_PATH_OK}" == true ]] && echo available || echo unavailable )"
}
