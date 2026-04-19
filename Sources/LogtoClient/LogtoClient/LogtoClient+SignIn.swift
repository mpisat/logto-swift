//
//  LogtoClient+SignIn.swift
//
//
//  Created by Gao Sun on 2022/1/27.
//

import AuthenticationServices
import Foundation
import Logto

#if !os(macOS)
    import UIKit
#endif

extension LogtoClient {
    #if !os(macOS)
        func signInWithBrowser<AuthSession: LogtoAuthSession>(
            authSessionType _: AuthSession.Type,
            redirectUri: String,
            loginHint: String? = nil,
            directSignIn: LogtoCore.DirectSignInOptions? = nil,
            extraParams: [String: String]? = nil,
            presentationScene: UIWindowScene? = nil
        ) async throws {
            guard let redirectUri = URL(string: redirectUri) else {
                throw (LogtoClientErrors.SignIn(type: .unableToConstructRedirectUri, innerError: nil))
            }

            let oidcConfig = try await fetchOidcConfig()

            let session = AuthSession(
                logtoConfig: logtoConfig,
                oidcConfig: oidcConfig,
                redirectUri: redirectUri,
                socialPlugins: socialPlugins,
                loginHint: loginHint,
                directSignIn: directSignIn,
                extraParams: extraParams
            )
            // Thread the caller's scene into the auth session so the
            // presenter can anchor `ASWebAuthenticationSession` to the
            // correct iPad Stage Manager / Split View window. Without
            // this, multi-scene setups fall back to global scene scanning
            // and may attach the sheet to the wrong scene.
            session.preferredPresentationScene = presentationScene

            try await completeSignIn(session: session, oidcConfig: oidcConfig)
        }
    #else
        func signInWithBrowser<AuthSession: LogtoAuthSession>(
            authSessionType _: AuthSession.Type,
            redirectUri: String,
            loginHint: String? = nil,
            directSignIn: LogtoCore.DirectSignInOptions? = nil,
            extraParams: [String: String]? = nil
        ) async throws {
            guard let redirectUri = URL(string: redirectUri) else {
                throw (LogtoClientErrors.SignIn(type: .unableToConstructRedirectUri, innerError: nil))
            }

            let oidcConfig = try await fetchOidcConfig()

            let session = AuthSession(
                logtoConfig: logtoConfig,
                oidcConfig: oidcConfig,
                redirectUri: redirectUri,
                socialPlugins: socialPlugins,
                loginHint: loginHint,
                directSignIn: directSignIn,
                extraParams: extraParams
            )

            try await completeSignIn(session: session, oidcConfig: oidcConfig)
        }
    #endif

    private func completeSignIn(
        session: LogtoAuthSession,
        oidcConfig: LogtoCore.OidcConfigResponse
    ) async throws {
        let response = try await session.start()
        let jwks = try await fetchJwkSet()

        try response.idToken.map {
            try LogtoUtilities.verifyIdToken(
                $0,
                issuer: oidcConfig.issuer,
                clientId: logtoConfig.appId,
                jwks: jwks
            )
        }

        idToken = response.idToken
        refreshToken = response.refreshToken
        accessTokenMap[buildAccessTokenKey(for: nil, in: nil)] = AccessToken(
            token: response.accessToken,
            scope: response.scope,
            expiresAt: Date().timeIntervalSince1970 + TimeInterval(response.expiresIn)
        )
    }

    /**
     Start a sign in session using `ASWebAuthenticationSession` so Safari
     cookies, Keychain autofill, and Passkeys are shared with the rest of
     the system. If the function returns with no error thrown, it means
     the user has signed in successfully.

     - Parameters:
        - redirectUri: One of Redirect URIs of this application.
        - loginHint: Login hint indicates the current user (usually an email address or phone number).
        - directSignIn: Parameters for direct sign-in.
        - extraParams: Extra parameters for the authentication request.
        - presentationScene: The `UIWindowScene` hosting the view controller
          invoking sign-in. Thread this in on iPad so the system auth sheet
          anchors to the right Stage Manager / Split View window. When `nil`,
          the presenter falls back to global foreground-active scanning.
     - Throws: An error if the session failed to complete.
     */
    #if !os(macOS)
        public func signInWithBrowser(
            redirectUri: String,
            loginHint: String? = nil,
            directSignIn: LogtoCore.DirectSignInOptions? = nil,
            extraParams: [String: String]? = nil,
            presentationScene: UIWindowScene? = nil
        ) async throws {
            try await signInWithBrowser(
                authSessionType: LogtoAuthSession.self,
                redirectUri: redirectUri,
                loginHint: loginHint,
                directSignIn: directSignIn,
                extraParams: extraParams,
                presentationScene: presentationScene
            )
        }
    #else
        public func signInWithBrowser(
            redirectUri: String,
            loginHint: String? = nil,
            directSignIn: LogtoCore.DirectSignInOptions? = nil,
            extraParams: [String: String]? = nil
        ) async throws {
            try await signInWithBrowser(
                authSessionType: LogtoAuthSession.self,
                redirectUri: redirectUri,
                loginHint: loginHint,
                directSignIn: directSignIn,
                extraParams: extraParams
            )
        }
    #endif
}
