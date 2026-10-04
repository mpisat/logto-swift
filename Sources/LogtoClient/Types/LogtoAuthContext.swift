//
//  LogtoAuthContext.swift
//
//
//  Created by Gao Sun on 2022/1/29.
//

#if os(iOS)
    import AuthenticationServices
    import Foundation
    import UIKit

    class LogtoAuthContext: NSObject, ASWebAuthenticationPresentationContextProviding {
        private var signInWindow: UIWindow?

        @MainActor
        func prepareSignIn(preferredScene: UIWindowScene?) -> Bool {
            if let preferredScene, preferredScene.activationState == .foregroundActive,
               let window = Self.window(in: preferredScene)
            {
                signInWindow = window
                return true
            }
            signInWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
                .compactMap(Self.window(in:))
                .first
            return signInWindow != nil
        }

        private static func window(in scene: UIWindowScene) -> UIWindow? {
            scene.windows.first { $0.isKeyWindow }
                ?? scene.windows.first { !$0.isHidden && $0.windowLevel == .normal }
        }

        func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
            if let signInWindow { return signInWindow }
            return UIApplication.shared
                .connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
#endif
