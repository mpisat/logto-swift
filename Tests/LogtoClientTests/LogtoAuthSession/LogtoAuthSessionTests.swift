import Foundation
import Logto
@testable import LogtoClient
import LogtoMock
import XCTest

private let redirectUri = URL(string: "io.logto.test://callback")!

final class LogtoAuthSessionTests: XCTestCase {
    func getMockOidcConfig(
        authorizationEndpoint: String = "https://logto.dev/canceled",
        tokenEndpoint: String = "https://logto.dev/token:bad"
    ) -> LogtoCore
        .OidcConfigResponse
    {
        try! JSONDecoder().decode(LogtoCore.OidcConfigResponse.self, from: Data("""
            {
                "authorizationEndpoint": "\(authorizationEndpoint)",
                "tokenEndpoint": "\(tokenEndpoint)",
                "endSessionEndpoint": "",
                "revocationEndpoint": "",
                "userinfoEndpoint": "",
                "jwksUri": "",
                "issuer": ""
            }
        """.utf8))
    }

    func createGoodSession() -> LogtoAuthSession {
        LogtoAuthSession(
            useSession: NetworkSessionMock.shared,
            logtoConfig: try! LogtoConfig(endpoint: "https://logto.dev", appId: ""),
            oidcConfig: getMockOidcConfig(
                authorizationEndpoint: "https://logto.dev/auth",
                tokenEndpoint: "https://logto.dev/token:good"
            ),
            redirectUri: redirectUri
        )
    }

    func testHandleUnableToFetchToken() async throws {
        let session = try LogtoAuthSession(
            useSession: NetworkSessionMock.shared,
            logtoConfig: LogtoConfig(endpoint: "https://logto.dev", appId: ""),
            oidcConfig: getMockOidcConfig(authorizationEndpoint: "https://logto.dev/auth"),
            redirectUri: redirectUri
        )

        var components = try XCTUnwrap(URLComponents(url: redirectUri, resolvingAgainstBaseURL: true))
        components.queryItems = [
            URLQueryItem(name: "state", value: session.state),
            URLQueryItem(name: "code", value: "abc"),
        ]

        do {
            _ = try await session.handle(callbackUri: XCTUnwrap(components.url))
        } catch let error as LogtoClientErrors.SignIn {
            XCTAssertEqual(error.type, .unableToFetchToken)
            return
        }

        XCTFail()
    }

    func testHandleUnexpectedSignInCallback() async throws {
        let session = createGoodSession()

        do {
            _ = try await session.handle(callbackUri: XCTUnwrap(URL(string: "https://foo")))
        } catch let error as LogtoClientErrors.SignIn {
            XCTAssertEqual(error.type, .unexpectedSignInCallback)
            return
        }

        XCTFail()
    }

    func testHandleOk() async throws {
        let session = createGoodSession()

        var components = try XCTUnwrap(URLComponents(url: redirectUri, resolvingAgainstBaseURL: true))
        components.queryItems = [
            URLQueryItem(name: "state", value: session.state),
            URLQueryItem(name: "code", value: "abc"),
        ]

        _ = try await session.handle(callbackUri: XCTUnwrap(components.url))
    }
    func testCallbackRejectsHostAndPathPrefixCollisionsBeforeTokenExchange() async throws {
        for (redirect, callback) in [
            ("io.logto.test://callback", "io.logto.test://callback.evil"),
            ("io.logto.test://callback/path", "io.logto.test://callback/path-extra"),
            ("io.logto.test://callback/path", "io.logto.test://callback/PATH"),
        ] {
            NetworkSessionMock.shared.tokenRequestCount = 0
            let session = LogtoAuthSession(
                useSession: NetworkSessionMock.shared,
                logtoConfig: try LogtoConfig(endpoint: "https://logto.dev", appId: "foo"),
                oidcConfig: getMockOidcConfig(tokenEndpoint: "https://logto.dev/token:good"),
                redirectUri: try XCTUnwrap(URL(string: redirect))
            )
            let url = try XCTUnwrap(URL(string: "\(callback)?state=\(session.state)&code=abc"))
            do {
                _ = try await session.handle(callbackUri: url)
                XCTFail("A colliding redirect must be rejected")
            } catch let error as LogtoClientErrors.SignIn {
                XCTAssertEqual(error.type, .unexpectedSignInCallback)
                XCTAssertEqual(error.innerError as? LogtoErrors.UriVerification, .redirectUriMismatched)
            }
            XCTAssertEqual(NetworkSessionMock.shared.tokenRequestCount, 0)
        }
    }

    func testCallbackAcceptsCaseInsensitiveSchemeAndHostWithExactPath() async throws {
        NetworkSessionMock.shared.tokenRequestCount = 0
        let session = LogtoAuthSession(
            useSession: NetworkSessionMock.shared,
            logtoConfig: try LogtoConfig(endpoint: "https://logto.dev", appId: "foo"),
            oidcConfig: getMockOidcConfig(tokenEndpoint: "https://logto.dev/token:good"),
            redirectUri: try XCTUnwrap(URL(string: "io.logto.test://callback/path"))
        )
        let callback = try XCTUnwrap(URL(string: "IO.LOGTO.TEST://CALLBACK/path?state=\(session.state)&code=abc"))
        let response = try await session.handle(callbackUri: callback)
        XCTAssertEqual(response.accessToken, "123")
    }

}
