//
//  LogtoAuthSession.swift
//
//
//  Created by Gao Sun on 2022/1/30.
//

import AuthenticationServices
import Foundation
import Logto
import LogtoSocialPlugin

#if !os(macOS)
    import UIKit
#endif

class LogtoAuthSession {
    typealias Errors = LogtoClientErrors

    let session: NetworkSession
    let authContext: LogtoAuthContext
    let state: String
    let codeVerifier: String
    let codeChallenge: String
    let logtoConfig: LogtoConfig
    let oidcConfig: LogtoCore.OidcConfigResponse
    let redirectUri: URL
    let socialPlugins: [LogtoSocialPlugin]
    let loginHint: String?
    let directSignIn: LogtoCore.DirectSignInOptions?
    let extraParams: [String: String]?

    #if !os(macOS)
        /// Caller-preferred scene for anchoring `ASWebAuthenticationSession`.
        /// Set this to the scene hosting the view controller invoking
        /// sign-in so iPad Stage Manager / Split View anchors to the right
        /// window. When `nil`, the presenter falls back to scanning
        /// foreground-active scenes globally.
        weak var preferredPresentationScene: UIWindowScene?
    #endif

    internal var callbackUri: URL?

    required init(
        useSession session: NetworkSession = URLSession.shared,
        logtoConfig: LogtoConfig,
        oidcConfig: LogtoCore.OidcConfigResponse,
        redirectUri: URL,
        socialPlugins: [LogtoSocialPlugin],
        loginHint: String? = nil,
        directSignIn: LogtoCore.DirectSignInOptions? = nil,
        extraParams: [String: String]? = nil
    ) {
        authContext = LogtoAuthContext()
        state = LogtoUtilities.generateState()
        codeVerifier = LogtoUtilities.generateCodeVerifier()
        codeChallenge = LogtoUtilities.generateCodeChallenge(codeVerifier: codeVerifier)

        self.session = session
        self.logtoConfig = logtoConfig
        self.oidcConfig = oidcConfig
        self.redirectUri = redirectUri
        self.socialPlugins = socialPlugins
        self.loginHint = loginHint
        self.directSignIn = directSignIn
        self.extraParams = extraParams
    }

    func start() async throws -> LogtoCore.CodeTokenResponse {
        do {
            let authUri = try LogtoCore.generateSignInUri(
                authorizationEndpoint: oidcConfig.authorizationEndpoint,
                clientId: logtoConfig.appId,
                redirectUri: redirectUri,
                codeChallenge: codeChallenge,
                state: state,
                scopes: logtoConfig.scopes,
                resources: logtoConfig.resources,
                prompt: logtoConfig.prompt,
                loginHint: loginHint,
                directSignIn: directSignIn,
                extraParams: extraParams
            )

            #if !os(macOS)
                return try await withCheckedThrowingContinuation { continuation in
                    // Create session
                    let session = LogtoWebViewAuthSession(
                        authUri,
                        redirectUri: redirectUri,
                        socialPlugins: socialPlugins,
                        preferredPresentationScene: preferredPresentationScene
                    ) { [self] callbackUri, error in
                        if Self.isUserCancellation(error) {
                            continuation.resume(throwing: Errors.SignIn(type: .userCancelled, innerError: error))
                            return
                        }

                        guard let callbackUri = callbackUri else {
                            continuation.resume(throwing: Errors.SignIn(type: .authFailed, innerError: error))
                            return
                        }

                        do {
                            let response = try await handle(callbackUri: callbackUri)
                            continuation.resume(returning: response)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }

                    // Capture `session` strongly in the main-queue closure so
                    // it outlives the synchronous return of this closure. The
                    // `LogtoWebViewAuthSession` itself is also retained by its
                    // own `ASWebAuthenticationSession` completion handler
                    // (see `LogtoWebViewAuthSession.start`), so nothing can
                    // deallocate it mid-flow and silently drop the callback.
                    DispatchQueue.main.async {
                        session.start()
                    }
                }
            #else
                fatalError("LogtoAuthSession does not support macOS currently.")
            #endif
        } catch let error as LogtoErrors.UrlConstruction {
            throw Errors.SignIn(type: .unableToConstructAuthUri, innerError: error)
        } catch {
            throw Errors.SignIn(type: .unknownError, innerError: error)
        }
    }

    /// Detect the "user dismissed the system sheet" error surfaced by
    /// `ASWebAuthenticationSession`. `.canceledLogin` is the canonical
    /// code, but we also recognise our own `noPresentationAnchor` fault
    /// as a cancellation — nothing was presented, so treat it as if the
    /// user walked away.
    private static func isUserCancellation(_ error: Error?) -> Bool {
        guard let error = error else { return false }

        if let asError = error as? ASWebAuthenticationSessionError,
           asError.code == .canceledLogin
        {
            return true
        }

        if case LogtoWebViewAuthViewError.noPresentationAnchor = error {
            return true
        }

        return false
    }

    func handle(callbackUri: URL) async throws -> LogtoCore.CodeTokenResponse {
        do {
            let code = try LogtoCore.verifyAndParseSignInCallbackUri(
                callbackUri,
                redirectUri: redirectUri,
                state: state
            )
            let tokenResponse = try await LogtoCore.fetchToken(
                useSession: session,
                byAuthorizationCode: code,
                codeVerifier: codeVerifier,
                tokenEndpoint: oidcConfig.tokenEndpoint,
                clientId: logtoConfig.appId,
                redirectUri: redirectUri.absoluteString
            )
            return tokenResponse
        } catch let error as LogtoErrors.UriVerification {
            throw Errors.SignIn(type: .unexpectedSignInCallback, innerError: error)
        } catch {
            throw Errors.SignIn(type: .unableToFetchToken, innerError: error)
        }
    }
}
