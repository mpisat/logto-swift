//
//  LogtoClient+PersistStorage.swift
//
//
//  Created by Gao Sun on 2022/2/4.
//

import Foundation
import KeychainAccess

public enum PersistedTokenReloadResult: Equatable, Sendable {
    case loaded
    case empty
    case failed
}

/// Outcome of a single persist attempt for one token.
///
/// The read side has reported a three-state result since
/// `PersistedTokenReloadResult` was added. The write side reported nothing at
/// all: it assigned through the `KeychainAccess` subscript, which swallows the
/// error, so a failed write of a rotated refresh token was indistinguishable
/// from a successful one and the next cold launch read a superseded token off
/// disk. This type closes that gap.
public enum PersistedTokenWriteResult: Equatable, Sendable {
    /// Written, or removed, and confirmed by reading the value back.
    case verified
    /// The Keychain call reported success but the read-back did not match what
    /// was intended. Treated as a failure for retry purposes.
    case unverified
    /// The write or remove threw. `OSStatus` is carried when `KeychainAccess`
    /// reported one, and is nil for any other error type.
    case failed(OSStatus?)
    /// No Keychain is configured, i.e. `usingPersistStorage` is false. Not a
    /// failure and never retried.
    case skipped
}

/// One persist attempt, reported to the host through `onTokenPersist`.
public struct PersistedTokenWriteReport: Equatable, Sendable {
    /// The raw Keychain key, `id_token` or `refresh_token`. Never the value.
    public let key: String
    public let result: PersistedTokenWriteResult
    /// True when this attempt came from `retryPendingTokenWrites()`.
    public let isRetry: Bool

    public init(key: String, result: PersistedTokenWriteResult, isRetry: Bool) {
        self.key = key
        self.result = result
        self.isRetry = isRetry
    }
}

extension LogtoClient {
    enum KeyName: String {
        case idToken = "id_token"
        case refreshToken = "refresh_token"
    }

    static let keychainServiceName = "io.logto.client"
    static let jsonEncoder = JSONEncoder()
    static let jsonDecoder = JSONDecoder()

    /// Reads the persisted tokens into memory. Sets `isLoadingFromKeychain`
    /// for the duration so the `didSet` observers on `idToken` / `refreshToken`
    /// do not write the just-read value (possibly nil from a locked-device
    /// read failure) back to the Keychain and erase the real entry.
    @discardableResult
    func loadFromKeychain() -> PersistedTokenReloadResult {
        guard let keychain = keychain else {
            return .empty
        }

        return loadFromKeychain { try keychain.get($0) }
    }

    @discardableResult
    func loadFromKeychain(
        read: (String) throws -> String?
    ) -> PersistedTokenReloadResult {
        withTokenPersistLock {
            let loadedIdToken: String?
            let loadedRefreshToken: String?
            do {
                loadedIdToken = try read(KeyName.idToken.rawValue)
                loadedRefreshToken = try read(KeyName.refreshToken.rawValue)
            } catch {
                return .failed
            }

            isLoadingFromKeychain = true
            defer { isLoadingFromKeychain = false }

            idToken = loadedIdToken
            refreshToken = loadedRefreshToken
            return loadedIdToken == nil && loadedRefreshToken == nil ? .empty : .loaded
        }
    }

    /// Re-reads persisted tokens after protected data becomes available.
    /// Failed reads preserve the current in-memory tokens and return `.failed`.
    /// Retry pending writes before reloading so a live rotation is not replaced
    /// with an older on-disk value.
    @discardableResult
    public func reloadFromKeychain() -> PersistedTokenReloadResult {
        loadFromKeychain()
    }

    /// Persists the current value of the given key. Skipped during
    /// `loadFromKeychain` so a nil read does not delete the on-disk entry.
    /// A genuine nil (e.g. after `signOut`) is written through to delete
    /// the entry as before.
    func saveToKeychain(forKey key: KeyName) {
        guard !withTokenPersistLock({ isLoadingFromKeychain }) else { return }
        guard let keychain = keychain else {
            let callback = withTokenPersistLock { tokenPersistCallback }
            callback?(
                PersistedTokenWriteReport(
                    key: key.rawValue,
                    result: .skipped,
                    isRetry: false
                )
            )
            return
        }

        let attempt: (PersistedTokenWriteReport, (@Sendable (PersistedTokenWriteReport) -> Void)?)? =
            withTokenPersistLock {
                guard !isLoadingFromKeychain else { return nil }
                let report = persistLocked(
                    key: key,
                    intended: inMemoryValue(forKey: key),
                    isRetry: false,
                    write: { try keychain.set($0, key: $1) },
                    remove: { try keychain.remove($0) },
                    read: { try keychain.get($0) }
                )
                return (report, tokenPersistCallback)
            }

        guard let (report, callback) = attempt else { return }
        callback?(report)
    }

    /// Re-attempts every write that has not been confirmed, using its latest
    /// captured intended value as the source of truth.
    ///
    /// Call this when protected data becomes available, i.e. after the first
    /// unlock following a background wake. It never reads disk into memory:
    /// the in-memory token is the one the running process has been using and
    /// is by definition at least as current as anything on disk. Reloading in
    /// the other direction here would overwrite a live rotated token with the
    /// superseded one that failed to be replaced.
    @discardableResult
    public func retryPendingTokenWrites() -> [PersistedTokenWriteReport] {
        guard let keychain = keychain else { return [] }

        let (reports, callback) = withTokenPersistLock {
            // Refresh token first: it is the one whose loss forces a browser
            // sign-in, so it should win any partial-success race with the
            // id token.
            let ordered: [KeyName] = [.refreshToken, .idToken]
            let reports = ordered.compactMap { key -> PersistedTokenWriteReport? in
                guard let pending = pendingTokenWrites[key] else { return nil }
                return persistLocked(
                    key: key,
                    intended: pending.value,
                    isRetry: true,
                    write: { try keychain.set($0, key: $1) },
                    remove: { try keychain.remove($0) },
                    read: { try keychain.get($0) }
                )
            }
            return (reports, tokenPersistCallback)
        }

        reports.forEach { callback?($0) }
        return reports
    }

    /// Whether any token write is still unconfirmed.
    public var hasPendingTokenWrites: Bool {
        withTokenPersistLock { !pendingTokenWrites.isEmpty }
    }

    @discardableResult
    func persist(key: KeyName, isRetry: Bool, using keychain: Keychain) -> PersistedTokenWriteReport {
        persist(
            key: key,
            isRetry: isRetry,
            write: { try keychain.set($0, key: $1) },
            remove: { try keychain.remove($0) },
            read: { try keychain.get($0) }
        )
    }

    /// Injectable core of the persist path, so the failure modes can be tested
    /// without a real Keychain. Mirrors `loadFromKeychain(read:)`.
    @discardableResult
    func persist(
        key: KeyName,
        isRetry: Bool,
        write: (String, String) throws -> Void,
        remove: (String) throws -> Void,
        read: (String) throws -> String?
    ) -> PersistedTokenWriteReport {
        let (report, callback) = withTokenPersistLock {
            let report = persistLocked(
                key: key,
                intended: inMemoryValue(forKey: key),
                isRetry: isRetry,
                write: write,
                remove: remove,
                read: read
            )
            return (report, tokenPersistCallback)
        }
        callback?(report)
        return report
    }

    private func persistLocked(
        key: KeyName,
        intended: String?,
        isRetry: Bool,
        write: (String, String) throws -> Void,
        remove: (String) throws -> Void,
        read: (String) throws -> String?
    ) -> PersistedTokenWriteReport {
        // Serialize the Keychain mutation and its read-back as one attempt;
        // a concurrent retry must not verify against another mutation.
        let name = key.rawValue
        let result: PersistedTokenWriteResult

        do {
            if let intended = intended {
                try write(intended, name)
            } else {
                try remove(name)
            }
            result = try read(name) == intended ? .verified : .unverified
        } catch let status as Status {
            result = .failed(status.rawValue)
        } catch {
            result = .failed(nil)
        }

        if result == .verified {
            pendingTokenWrites[key] = nil
        } else {
            pendingTokenWrites[key] = PendingTokenWrite(value: intended)
        }

        return PersistedTokenWriteReport(key: name, result: result, isRetry: isRetry)
    }

    private func inMemoryValue(forKey key: KeyName) -> String? {
        switch key {
        case .idToken:
            return idToken
        case .refreshToken:
            return refreshToken
        }
    }
}
