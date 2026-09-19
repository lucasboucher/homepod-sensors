//
//  ExtractCommand.swift
//  HomePodKeychainExtractor
//
//  Full extraction flow from pvieito KeychainTool + mattrohr logging +
//  historical DeviceOwnerAuthenticator (commit 806e44f).
//

import ArgumentParser
import AuthenticationKit
import CodeSignKit
import Foundation
import FoundationKit
import KeychainKit
import LoggerKit

struct ExtractCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract",
        abstract: "Extract keychain items (full historical KeychainTool behaviour)."
    )

    @Flag(name: .shortAndLong, help: "Show only synchronizable items.")
    var synchronizable: Bool = false

    @Option(name: .shortAndLong, help: "Label.")
    var label: String?

    @Option(name: [.customShort("g"), .long], help: "Access Group.")
    var accessGroup: String?

    @Option(name: .long, help: "Service.")
    var service: String?

    @Option(name: .shortAndLong, help: "Token identifier.")
    var tokenIdentifier: String?

    @Flag(name: .shortAndLong, help: "Verbose mode.")
    var verbose: Bool = false

    func run() throws {
        do {
            Logger.logMode = .commandLine
            // mattrohr e0ed9d3: force debug so credentials are always printed in extract mode.
            // pvieito -v/--verbose flag retained for CLI compatibility.
            Logger.logLevel = .debug

            // Historical self-signing step: sign the executable with entitlements, then re-exec.
            try CodeSign.signMainExecutableOnceAndRun()

            let keychainItems = try Keychain.system.getItems(
                label: self.label,
                accessGroup: self.accessGroup,
                service: self.service,
                synchronizable: self.synchronizable ? true : nil,
                tokenID: self.tokenIdentifier
            )

            Logger.log(important: "Keychain Items Matched: \(keychainItems.count)")

            for keychainItem in keychainItems {
                keychainItem.printDetails()
            }
        } catch {
            Logger.log(fatalError: error)
        }
    }
}
