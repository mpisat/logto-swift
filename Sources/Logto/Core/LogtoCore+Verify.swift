//
//  LogtoCore+Verify.swift
//
//
//  Created by Gao Sun on 2022/1/19.
//

import Foundation

public extension LogtoCore {
    /// Verify the given `callbackUri` matches the requirements and return `code` parameter if success.
    static func verifyAndParseSignInCallbackUri(
        _ callbackUri: URL,
        redirectUri: URL,
        state: String
    ) throws -> String {
        guard callbackUri.scheme?.lowercased() == redirectUri.scheme?.lowercased(),
              callbackUri.host?.lowercased() == redirectUri.host?.lowercased(),
              callbackUri.port == redirectUri.port,
              callbackUri.path == redirectUri.path
        else {
            throw LogtoErrors.UriVerification.redirectUriMismatched
        }

        guard let components = URLComponents(url: callbackUri, resolvingAgainstBaseURL: true) else {
            throw LogtoErrors.UriVerification.decodeComponentsFailed
        }

        guard components.queryItems?.contains(where: { $0.name == "state" && $0.value == state }) ?? false else {
            throw LogtoErrors.UriVerification.stateMismatched
        }

        let errorItems = components.queryItems?.filter { ["error", "error_description"].contains($0.name) } ?? []

        guard errorItems.count == 0 else {
            throw LogtoErrors.UriVerification.errorItemFound(items: errorItems)
        }

        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw LogtoErrors.UriVerification.missingCode
        }

        return code
    }
}
