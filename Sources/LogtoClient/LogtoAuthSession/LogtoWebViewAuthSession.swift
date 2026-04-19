//
//  LogtoWebViewAuthSession.swift
//
//
//  Created by Gao Sun on 2022/3/22.
//  Native-browser fork: replaces the WKWebView presenter with
//  ASWebAuthenticationSession so Safari cookies, Keychain autofill,
//  and Passkeys are shared with the rest of the system.
//

import AuthenticationServices
import Foundation
import LogtoSocialPlugin

#if !os(macOS)
    import UIKit
#endif

class LogtoWebViewAuthSession: NSObject {
    typealias FinishHandler = (URL?, Error?) async -> Void

    private var isFinished = false
    private var authSession: ASWebAuthenticationSession?
    private var presenter: LogtoWebViewAuthPresenter?

    let uri: URL
    let redirectUri: URL
    // `socialPlugins` is retained on the API for upstream compatibility but
    // is no longer invoked: the WKWebView JS bridge that dispatched native
    // plugin connectors was removed with the WebView presenter. In the
    // system-browser flow, social logins run through the browser's own
    // OAuth redirects (Universal Links / custom schemes) and do not need
    // an in-app JS bridge. See LOGTO-FORK.md §4 for the fork contract.
    let socialPlugins: [LogtoSocialPlugin]
    let onFinish: FinishHandler

    #if !os(macOS)
        private let preferredPresentationScene: UIWindowScene?
    #endif

    #if !os(macOS)
        public init(
            _ uri: URL,
            redirectUri: URL,
            socialPlugins: [LogtoSocialPlugin],
            preferredPresentationScene: UIWindowScene? = nil,
            onFinish: @escaping FinishHandler
        ) {
            self.uri = uri
            self.redirectUri = redirectUri
            self.socialPlugins = socialPlugins
            self.preferredPresentationScene = preferredPresentationScene
            self.onFinish = onFinish
            super.init()
        }
    #else
        public init(_ uri: URL, redirectUri: URL, socialPlugins: [LogtoSocialPlugin], onFinish: @escaping FinishHandler) {
            self.uri = uri
            self.redirectUri = redirectUri
            self.socialPlugins = socialPlugins
            self.onFinish = onFinish
            super.init()
        }
    #endif

    @discardableResult public func start() -> Bool {
        #if os(macOS)
            fatalError("LogtoWebViewAuthSession does not support macOS yet.")
        #else
            guard let scheme = redirectUri.scheme, !scheme.isEmpty else {
                Task { await self.didFinish(url: nil, error: LogtoWebViewAuthViewError.unableToConstructCallbackUri) }
                return false
            }

            let anchorProvider = LogtoWebViewAuthPresenter(preferredScene: preferredPresentationScene)
            guard anchorProvider.hasPresentationAnchor() else {
                Task { await self.didFinish(url: nil, error: LogtoWebViewAuthViewError.noPresentationAnchor) }
                return false
            }

            // Strong self on purpose: nothing outside this object retains us
            // once `start()` returns, so a weak capture would let the object
            // deallocate before `ASWebAuthenticationSession` ever fires its
            // completion, hanging sign-in. The retain cycle with `authSession`
            // is broken in `didFinish`, which nils out the stored reference.
            let session = ASWebAuthenticationSession(
                url: uri,
                callbackURLScheme: scheme
            ) { callbackURL, error in
                Task { await self.handleCompletion(callbackURL: callbackURL, error: error) }
            }

            session.presentationContextProvider = anchorProvider
            // Keep Safari cookies shared with the rest of the system — the
            // whole point of the fork. Explicit to guard against future
            // upstream changes to the default.
            session.prefersEphemeralWebBrowserSession = false

            presenter = anchorProvider
            authSession = session

            DispatchQueue.main.async { [self] in
                let launched = session.start()
                if !launched {
                    Task { await self.didFinish(url: nil, error: LogtoWebViewAuthViewError.webAuthFailed(innerError: nil)) }
                }
            }

            return true
        #endif
    }

    #if !os(macOS)
        // Exposed as `internal` (not `private`) so the @testable test bundle
        // can exercise the redirect-URL validation branch without having to
        // mock `ASWebAuthenticationSession`.
        internal func handleCompletion(callbackURL: URL?, error: Error?) async {
            // Strict redirect validation. Accept only when scheme (case
            // insensitive), host, and path all match the registered
            // redirectUri. Anything else (e.g. an unrelated deep link
            // that happens to use our scheme) is dropped.
            guard
                let callbackURL,
                let callbackScheme = callbackURL.scheme,
                let expectedScheme = redirectUri.scheme,
                callbackScheme.lowercased() == expectedScheme.lowercased(),
                callbackURL.host == redirectUri.host,
                callbackURL.path == redirectUri.path
            else {
                await didFinish(url: nil, error: error)
                return
            }

            await didFinish(url: callbackURL, error: nil)
        }
    #endif

    internal func didFinish(url: URL?, error: Error? = nil) async {
        guard !isFinished else { return }
        isFinished = true
        await onFinish(url, error)

        DispatchQueue.main.async { [weak self] in
            self?.authSession?.cancel()
            self?.authSession = nil
            self?.presenter = nil
        }
    }
}
