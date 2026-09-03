//
//  LogtoClient+AccessToken.swift
//
//
//  Created by Gao Sun on 2022/2/5.
//

import Foundation
import Logto

/// What a successful refresh did to the cached tokens. The provider returns
/// `refresh_token` on every success whether or not it rotated, so `changed`
/// is the comparison against the previous in-memory value and is the only
/// field that tells rotation apart from reuse. Flags only, never a value.
public struct TokenRefreshReport: Equatable, Sendable {
    public let refreshTokenReturned: Bool
    public let refreshTokenChanged: Bool
    public let idTokenReturned: Bool
    public let idTokenChanged: Bool

    public init(
        refreshTokenReturned: Bool,
        refreshTokenChanged: Bool,
        idTokenReturned: Bool,
        idTokenChanged: Bool
    ) {
        self.refreshTokenReturned = refreshTokenReturned
        self.refreshTokenChanged = refreshTokenChanged
        self.idTokenReturned = idTokenReturned
        self.idTokenChanged = idTokenChanged
    }
}

public extension LogtoClient {
    /// A cached access token with less than this much life left is refreshed
    /// instead of returned, so a request cannot reach the backend with a
    /// token that expired in transit.
    static let accessTokenExpiryMargin: TimeInterval = 60

    internal func buildAccessTokenKey(for resource: String?, in organizationId: String?) -> String {
        guard let organizationId = organizationId else {
            return resource ?? "@"
        }

        return (resource ?? "@") + "#" + organizationId
    }

    internal func getAccessToken(by refreshToken: String, for resource: String?,
                                 in organizationId: String?) async throws -> String
    {
        let key = buildAccessTokenKey(for: resource, in: organizationId)
        let oidcConfig = try await fetchOidcConfig()

        do {
            let response = try await LogtoCore.fetchToken(
                useSession: networkSession,
                byRefreshToken: refreshToken,
                tokenEndpoint: oidcConfig.tokenEndpoint,
                clientId: logtoConfig.appId,
                resource: resource,
                scopes: nil,
                organizationId: organizationId
            )

            let accessToken = AccessToken(
                token: response.accessToken,
                scope: response.scope,
                expiresAt: Date().timeIntervalSince1970 + TimeInterval(response.expiresIn)
            )

            accessTokenMap[key] = accessToken

            // Assign only on change: each assignment runs a Keychain write plus
            // read-back through `didSet`, and an unrotated token has nothing
            // new to persist. A write that is still pending from an earlier
            // failure is retried by the consumer, never by re-assignment.
            let refreshTokenChanged = response.refreshToken.map { $0 != self.refreshToken } ?? false
            if refreshTokenChanged {
                self.refreshToken = response.refreshToken
            }

            let idTokenChanged = response.idToken.map { $0 != self.idToken } ?? false
            if idTokenChanged {
                self.idToken = response.idToken
            }

            let refreshCallback = withTokenPersistLock { tokenRefreshCallback }
            refreshCallback?(TokenRefreshReport(
                refreshTokenReturned: response.refreshToken != nil,
                refreshTokenChanged: refreshTokenChanged,
                idTokenReturned: response.idToken != nil,
                idTokenChanged: idTokenChanged
            ))

            return accessToken.token
        } catch {
            throw LogtoClientErrors
                .AccessToken(type: .unableToFetchTokenByRefreshToken, innerError: error)
        }
    }

    /**
     Get an Access Token for the given resource.
     - If both `resource` and `organizationId` are `nil`, return the Access Token for user endpoint.
     - If `resource` is provided but `organizationId` is `nil`, return the Access Token for the given resource.
     - If both `resource` and `organizationId` are provided, return the Access Token for the given resource in the given organization.
     - If `resource` is `nil` but `organizationId` is provided, an error will be thrown. Use `getOrganizationToken(forId:)` instead.

     If the cached Access Token has expired, this function will try to use `refreshToken` to fetch a new Access Token from the OIDC provider.

     - Parameters:
        - for: The resource indicator.
        - organizationId: The ID of the organization that the access token is granted for.
     - Throws: An error if failed to get a valid Access Token.
     - Returns: Access Token in string.
     */
    @MainActor func getAccessToken(for resource: String?, organizationId: String? = nil) async throws -> String {
        let key = buildAccessTokenKey(for: resource, in: organizationId)

        // Cached access token is still valid
        if let accessToken = accessTokenMap[key],
           Date().timeIntervalSince1970 + LogtoClient.accessTokenExpiryMargin < accessToken.expiresAt
        {
            return accessToken.token
        }

        // Use refresh token to fetch a new access token
        guard let refreshToken = refreshToken else {
            throw LogtoClientErrors.AccessToken(type: .noRefreshTokenFound, innerError: nil)
        }

        let token = try await getAccessToken(by: refreshToken, for: resource, in: organizationId)

        return token
    }

    /**
     Get structured Access Token claims WITHOUT validation. See `getAccessToken(for:organizationId:)` for more details.

     - Parameters:
        - for: The resource indicator.
        - organizationId: The ID of the organization that the access token is granted for.
     - Throws: An error if failed to get a valid Access Token or decode token failed.
     - Returns: A dictionary of Access Token claims.
     */
    @MainActor func getAccessTokenClaims(for resource: String?,
                                         organizationId: String? = nil) async throws -> JsonObject
    {
        let accessToken = try await getAccessToken(for: resource, organizationId: organizationId)
        return try LogtoUtilities.decodeAccessToken(accessToken)
    }

    /**
     Get an Access Token for the given organization ID. Scope `UserScope.organizations` is required in the config to use organization-related
     methods.

     If the cached Access Token has expired, this function will try to use `refreshToken` to fetch a new Access Token from the OIDC provider.

     - Parameters:
        - forId: The ID of the organization that the access token is granted for.
     - Throws: An error if failed to get a valid Access Token.
     - Returns: Access Token in string.
     */
    @MainActor func getOrganizationToken(forId id: String) async throws -> String {
        try await getAccessToken(for: LogtoUtilities.buildOrganizationUrn(forId: id))
    }

    /**
     Get structured Access Token claims for the given organization ID WITHOUT validation. See `getOrganizationToken(forId:)` for more details.

     - Parameters:
        - forId: The ID of the organization that the access token is granted for.
     - Throws: An error if failed to get a valid Access Token or decode token failed.
     - Returns: A dictionary of Access Token claims.
     */
    @MainActor func getOrganizationTokenClaims(forId id: String) async throws -> JsonObject {
        let accessToken = try await getOrganizationToken(forId: id)
        return try LogtoUtilities.decodeAccessToken(accessToken)
    }
}
