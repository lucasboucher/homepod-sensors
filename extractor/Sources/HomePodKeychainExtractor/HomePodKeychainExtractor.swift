//
//  HomePodKeychainExtractor.swift
//  HomePodKeychainExtractor
//
//  Root CLI — fusion pvieito KeychainTool + probe prototype.
//

import ArgumentParser
import Foundation

@main
struct HomePodKeychainExtractor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "HomePodKeychainExtractor",
        abstract: "Extract HomeKit pairing credentials from the macOS keychain.",
        discussion: """
        Modes:
          extract — full keychain dump; uses CodeSignKit to sign and re-exec before keychain access
          probe   — minimal existence check without reading secrets
        """,
        subcommands: [ExtractCommand.self, ProbeCommand.self],
        defaultSubcommand: ExtractCommand.self
    )
}
