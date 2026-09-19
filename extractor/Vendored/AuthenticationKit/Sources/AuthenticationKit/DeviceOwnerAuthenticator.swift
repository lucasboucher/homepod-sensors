//
//  DeviceOwnerAuthenticator.swift
//  AuthenticationKit (vendored reconstruction)
//
//  Original pvieito/AuthenticationKit source is not publicly recoverable.
//  Reconstructed from KeychainKit commit 806e44f^ (LAContext flow) and
//  commit 806e44f usage: DeviceOwnerAuthenticator().grant()
//
//  See docs/VENDORED_DEPENDENCIES.md for provenance and limitations.
//

import Foundation
import LocalAuthentication

public final class DeviceOwnerAuthenticator {
    public enum Error: LocalizedError {
        case notGranted
        case underlying(Swift.Error)

        public var errorDescription: String? {
            switch self {
            case .notGranted:
                return "Device owner authentication was not granted."
            case .underlying(let error):
                return error.localizedDescription
            }
        }
    }

    private let context = LAContext()
    private let policy: LAPolicy = .deviceOwnerAuthentication

    public init() {}

    /// Requests device-owner authentication before keychain access.
    /// Used historically between CodeSignKit signing and keychain extraction
    /// (KeychainKit commit 806e44f, removed in 6ba9dc6 from upstream CLI but
    /// retained in this project for V1 conservation).
    public func grant() throws {
        var authError: NSError?
        guard context.canEvaluatePolicy(policy, error: &authError) else {
            if let authError {
                throw Error.underlying(authError)
            }
            throw Error.notGranted
        }

        let semaphore = DispatchSemaphore(value: 0)
        var grantError: Swift.Error?
        var granted = false

        context.evaluatePolicy(
            policy,
            localizedReason: ProcessInfo.processInfo.processName
        ) { success, error in
            granted = success
            grantError = error
            semaphore.signal()
        }

        semaphore.wait()

        if let grantError {
            throw Error.underlying(grantError)
        }
        guard granted else {
            throw Error.notGranted
        }
    }
}
