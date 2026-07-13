//
//  LogtoClient+PersistStorage.swift
//
//
//  Created by Gao Sun on 2022/2/4.
//

import Foundation

public enum PersistedTokenReloadResult: Equatable {
    case loaded
    case empty
    case failed
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

    /// Re-reads the persisted tokens from the Keychain into the in-memory
    /// `idToken` / `refreshToken`. Use this when the singleton was
    /// initialized before the device was unlocked (background pre-warm,
    /// VoIP push wake): the initial `loadFromKeychain` reads returned
    /// nil due to `errSecInteractionNotAllowed`, the persistence guard
    /// kept the on-disk entries intact, but the in-memory state is
    /// stale. Calling this after first unlock rehydrates memory from
    /// the surviving disk entries so the next refresh succeeds without
    /// bouncing the user to sign-in.
    @discardableResult
    public func reloadFromKeychain() -> PersistedTokenReloadResult {
        loadFromKeychain()
    }

    /// Persists the current value of the given key. Skipped during
    /// `loadFromKeychain` so a nil read does not delete the on-disk entry.
    /// A genuine nil (e.g. after `signOut`) is written through to delete
    /// the entry as before.
    func saveToKeychain(forKey key: KeyName) {
        guard !isLoadingFromKeychain else { return }
        guard let keychain = keychain else {
            return
        }

        switch key {
        case .idToken:
            keychain[key.rawValue] = idToken
        case .refreshToken:
            keychain[key.rawValue] = refreshToken
        }
    }
}
