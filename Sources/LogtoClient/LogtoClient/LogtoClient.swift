//
//  LogtoClient.swift
//
//
//  Created by Gao Sun on 2022/1/21.
//

#if os(iOS)
    import AuthenticationServices
#endif
import Foundation
import KeychainAccess
import Logto

public class LogtoClient {
    // MARK: Internal Constants

    let keychain: Keychain?
    let logtoConfig: LogtoConfig
    let networkSession: NetworkSession

    // MARK: Internal Variables

    var accessTokenMap = [String: AccessToken]()
    var isSigningIn = false
    #if os(iOS)
        var signOutAuthenticationSession: LogtoSystemAuthenticationSession?
        var signOutPresentationContextProvider: ASWebAuthenticationPresentationContextProviding?
    #endif

    /// Suppresses observer write-back while an atomic Keychain load assigns
    /// both tokens. Failed reads leave the in-memory pair untouched.
    internal var isLoadingFromKeychain = false

    /// Serializes persistence bookkeeping across token updates and lifecycle
    /// retries, which can arrive on different executors.
    internal let tokenPersistLock = NSRecursiveLock()

    struct PendingTokenWrite {
        let value: String?
    }

    /// Latest value whose persist attempt was not confirmed by a read-back.
    /// The captured value avoids reading token properties concurrently from a
    /// lifecycle retry running on another executor.
    internal var pendingTokenWrites = [KeyName: PendingTokenWrite]()
    internal var tokenPersistCallback: (@Sendable (PersistedTokenWriteReport) -> Void)?
    internal var tokenRefreshCallback: (@Sendable (TokenRefreshReport) -> Void)?

    @discardableResult
    internal func withTokenPersistLock<T>(_ operation: () throws -> T) rethrows -> T {
        tokenPersistLock.lock()
        defer { tokenPersistLock.unlock() }
        return try operation()
    }

    // MARK: Public Variables

    /// Called after every persist attempt, including retries. Reports the key
    /// and the outcome, never the token value.
    ///
    /// Exists because a failed Keychain write of a rotated refresh token used
    /// to be silent: the host had no way to know its session had become
    /// undurable, and the next cold launch presented a superseded token and
    /// was forced back through the browser.
    /// Invoked synchronously from the `didSet` observers, which run on
    /// whichever executor performed the assignment, so it is `@Sendable` and
    /// the host is responsible for hopping to its own isolation.
    public var onTokenPersist: (@Sendable (PersistedTokenWriteReport) -> Void)? {
        get { withTokenPersistLock { tokenPersistCallback } }
        set { withTokenPersistLock { tokenPersistCallback = newValue } }
    }

    /// Reports every successful token refresh. Carries rotation flags only,
    /// never token text. See `TokenRefreshReport`.
    public var onTokenRefresh: (@Sendable (TokenRefreshReport) -> Void)? {
        get { withTokenPersistLock { tokenRefreshCallback } }
        set { withTokenPersistLock { tokenRefreshCallback = newValue } }
    }

    /// The cached ID Token in raw string.
    /// Use `.getIdTokenClaims()` to retrieve structured data.
    public internal(set) var idToken: String? {
        didSet { saveToKeychain(forKey: .idToken) }
    }

    /// The cached Refresh Token.
    public internal(set) var refreshToken: String? {
        didSet { saveToKeychain(forKey: .refreshToken) }
    }

    /// The config fetched from [OIDC Discovery](https://openid.net/specs/openid-connect-discovery-1_0.html) endpoint.
    public internal(set) var oidcConfig: LogtoCore.OidcConfigResponse?

    // MARK: Public Computed Variables

    /// Whether the user has been authenticated.
    public var isAuthenticated: Bool {
        idToken != nil
    }

    /// Get structured [ID Token Claims](https://openid.net/specs/openid-connect-core-1_0.html#IDToken).
    /// - Throws: An error if no ID Token presents or decode token failed.
    public func getIdTokenClaims() throws -> IdTokenClaims {
        guard let idToken = idToken else {
            throw LogtoClientErrors.IdToken.notAuthenticated
        }

        return try LogtoUtilities.decodeIdToken(idToken)
    }

    // MARK: Public Init Functions

    public init(
        useConfig config: LogtoConfig,
        session: NetworkSession = URLSession.shared
    ) {
        logtoConfig = config
        networkSession = session

        if config.usingPersistStorage {
            keychain = Keychain(service: LogtoClient.keychainServiceName)
                .accessibility(.afterFirstUnlock)
            loadFromKeychain()
        } else {
            keychain = nil
        }
    }
}
