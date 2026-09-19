//
//  ProbeCommand.swift
//  HomePodKeychainExtractor
//
//  Exact behaviour of the original root main.swift prototype.
//  Provenance: notre prototype local.
//

import ArgumentParser
import Foundation
import Security

struct ProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "Minimal existence check for a HomeKit keychain item (no secret data copied)."
    )

    func run() throws {
        let accessGroup = "com.apple.hap.pairing"

        // Existence check only: one generic-password item in the Data Protection
        // Keychain. No attributes, no secret payload, no iCloud-sync match, no
        // enumeration. result is nil so SecItemCopyMatching cannot copy item data
        // into this process.
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccessGroup: accessGroup,
            kSecUseDataProtectionKeychain: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecAttrSynchronizable: false,
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)

        let message =
            SecCopyErrorMessageString(status, nil) as String?
            ?? "Unknown error"

        print("OSStatus: \(status)")
        print("Message: \(message)")

        Foundation.exit(status == errSecSuccess ? 0 : 1)
    }
}
