#!/usr/bin/env bash
# Swift toolchain and build artifact detection.

set -euo pipefail

SWIFT_VERSION=""
SWIFT_ARCH=""
XCODE_VERSION=""
XCODE_PATH=""
TEAM_ID=""
SIGNING_IDENTITY=""
BUILD_OK=false
HELP_OK=false
DARWIN_FOUNDATION_LINKED=false
MIN_OS_VERSION=""

detect_swift() {
    if ! command_exists swift; then
        return 1
    fi
    SWIFT_VERSION="$(swift --version 2>/dev/null | head -n 1 || true)"
    SWIFT_ARCH="$(uname -m)"
    return 0
}

detect_xcode() {
    if command_exists xcodebuild; then
        XCODE_VERSION="$(xcodebuild -version 2>/dev/null | head -n 1 || true)"
        XCODE_PATH="$(xcode-select -p 2>/dev/null || true)"
    fi
}

detect_signing_identity() {
    if ! command_exists security; then
        return 1
    fi
    local identities cert_subject
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    SIGNING_IDENTITY="$(echo "${identities}" | sed -n 's/.*"\(Apple Development:.*\)".*/\1/p' | head -n 1)"

    # Team ID is the certificate OU (e.g. /OU=XXXXXXXXXX/), not the parenthetical
    # suffix in the CN (e.g. Apple Development: name@example.com (TEAMIDXXXX)).
    TEAM_ID=""
    if command_exists openssl; then
        cert_subject="$(
            security find-certificate -a -c "Apple Development" -p 2>/dev/null |
            openssl x509 -noout -subject 2>/dev/null ||
            true
        )"
        TEAM_ID="$(
            echo "${cert_subject}" |
            grep -oE 'OU[= ]+[A-Z0-9]{10}' |
            head -n 1 |
            grep -oE '[A-Z0-9]{10}$' ||
            true
        )"
    fi
}

binary_exists() {
    [[ -f "${BINARY_PATH}" ]]
}

check_binary_help() {
    if ! binary_exists; then
        HELP_OK=false
        return 1
    fi
    if "${BINARY_PATH}" --help >/dev/null 2>&1; then
        HELP_OK=true
        return 0
    fi
    HELP_OK=false
    return 1
}

check_binary_linkage() {
    if ! binary_exists; then
        DARWIN_FOUNDATION_LINKED=false
        return 1
    fi
    local linkage
    linkage="$(otool -L "${BINARY_PATH}" 2>/dev/null || true)"
    if echo "${linkage}" | grep -q 'libswift_DarwinFoundation'; then
        DARWIN_FOUNDATION_LINKED=true
        return 1
    fi
    DARWIN_FOUNDATION_LINKED=false
    return 0
}

check_binary_minos() {
    if ! binary_exists; then
        MIN_OS_VERSION=""
        return 1
    fi
    MIN_OS_VERSION="$(otool -l "${BINARY_PATH}" 2>/dev/null | awk '
        /LC_BUILD_VERSION/ { in_block=1 }
        in_block && /minos/ { print $2; exit }
    ')"
    if [[ -z "${MIN_OS_VERSION}" ]]; then
        MIN_OS_VERSION="$(otool -l "${BINARY_PATH}" 2>/dev/null | awk '
            /LC_VERSION_MIN_MACOSX/ { in_block=1 }
            in_block && /version/ { print $2; exit }
        ')"
    fi
}

run_swift_build() {
    (
        cd "${PROJECT_DIR}"
        swift build
    )
    BUILD_OK=true
}

print_toolchain_summary() {
    echo "Swift                   : ${SWIFT_VERSION:-UNKNOWN}"
    echo "Architecture            : ${SWIFT_ARCH:-UNKNOWN}"
    echo "Xcode                   : ${XCODE_VERSION:-UNKNOWN}"
    echo "Xcode path              : ${XCODE_PATH:-UNKNOWN}"
    echo "Signing identity        : $( [[ -n "${SIGNING_IDENTITY}" ]] && echo present || echo missing )"
    echo "Team ID                 : $( [[ -n "${TEAM_ID}" ]] && echo present || echo missing )"
    echo "Binary path             : ${BINARY_PATH}"
    echo "Binary exists           : $( binary_exists && echo yes || echo no )"
    echo "Binary --help           : $( [[ "${HELP_OK}" == true ]] && echo ok || echo fail )"
    echo "DarwinFoundation linked : $( [[ "${DARWIN_FOUNDATION_LINKED}" == true ]] && echo yes || echo no )"
    echo "Binary minos            : ${MIN_OS_VERSION:-UNKNOWN}"
}
