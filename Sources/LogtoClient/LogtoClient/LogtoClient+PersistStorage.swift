//
//  LogtoClient+PersistStorage.swift
//
//
//  Created by Gao Sun on 2022/2/4.
//

import Foundation

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
    func loadFromKeychain() {
        guard let keychain = keychain else {
            return
        }

        isLoadingFromKeychain = true
        defer { isLoadingFromKeychain = false }

        idToken = keychain[KeyName.idToken.rawValue]
        refreshToken = keychain[KeyName.refreshToken.rawValue]
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
