//
//  LogtoWebViewAuthViewController.swift
//
//
//  Created by Gao Sun on 2022/3/22.
//  Native-browser fork: the WKWebView-backed view controller has been
//  removed. This file now exposes the presentation anchor used by
//  `ASWebAuthenticationSession` with multi-scene fallback so iPad
//  Stage Manager / Split View do not pick the wrong window.
//

import AuthenticationServices
import Foundation

#if !os(macOS)
    import UIKit
#endif

final class LogtoWebViewAuthPresenter: NSObject {
    #if !os(macOS)
        private weak var preferredScene: UIWindowScene?

        init(preferredScene: UIWindowScene? = nil) {
            self.preferredScene = preferredScene
            super.init()
        }
    #else
        override init() {
            super.init()
        }
    #endif

    func hasPresentationAnchor() -> Bool {
        #if os(macOS)
            return NSApplication.shared.keyWindow != nil
        #else
            return resolveAnchor() != nil
        #endif
    }

    #if !os(macOS)
        fileprivate func resolveAnchor() -> UIWindow? {
            // Prefer the caller's own scene when supplied: on iPad with
            // Stage Manager or Split View, more than one scene can be
            // `.foregroundActive` simultaneously and anchoring to the wrong
            // one either targets the wrong window or trips a "no window to
            // present from" assertion.
            if let preferredScene, let window = preferredWindow(in: [preferredScene]) {
                return window
            }

            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let activeScenes = scenes.filter { $0.activationState == .foregroundActive }

            // Only anchor to an active scene. Per LOGTO-FORK.md §4.3 step 4,
            // if no foreground-active scene exists (background launch,
            // extension, app resuming), fail rather than force-presenting
            // against an inactive window. Falling back to
            // `.foregroundInactive` would let the sheet attach to a scene
            // that is transitioning off-screen and present in the wrong
            // place (or not at all).
            return preferredWindow(in: activeScenes)
        }

        private func preferredWindow(in scenes: [UIWindowScene]) -> UIWindow? {
            for scene in scenes {
                if #available(iOS 15.0, *), let key = scene.keyWindow {
                    return key
                }
                if let key = scene.windows.first(where: { $0.isKeyWindow }) {
                    return key
                }
                if let first = scene.windows.first {
                    return first
                }
            }
            return nil
        }
    #endif
}

extension LogtoWebViewAuthPresenter: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
            return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
            return resolveAnchor() ?? ASPresentationAnchor()
        #endif
    }
}
