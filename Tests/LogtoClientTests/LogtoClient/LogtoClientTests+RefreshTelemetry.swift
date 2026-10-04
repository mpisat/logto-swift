import Logto
@testable import LogtoClient
import LogtoMock
import XCTest

/// ISSUES-LOGTO.md 1.6 step 4. Logto returns `refresh_token` on every
/// successful refresh whether or not it rotated, so only a comparison against
/// the previous in-memory value tells a consumer whether rotation happened.
/// The report carries flags only, never token text.
private final class RefreshReportSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TokenRefreshReport] = []
    private var persistCount = 0

    var reports: [TokenRefreshReport] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var persistAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return persistCount
    }

    func record(_ report: TokenRefreshReport) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(report)
    }

    func recordPersist() {
        lock.lock()
        defer { lock.unlock() }
        persistCount += 1
    }
}

extension LogtoClientTests {
    func testRefreshReportsRotatedRefreshAndIdTokens() async throws {
        NetworkSessionMock.shared.tokenRequestCount = 0
        let client = buildClient()
        client.refreshToken = "bar"
        let sink = RefreshReportSink()
        client.onTokenRefresh = { sink.record($0) }

        _ = try await client.getAccessToken(for: "resource1")

        XCTAssertEqual(sink.reports, [
            TokenRefreshReport(
                refreshTokenReturned: true,
                refreshTokenChanged: true,
                idTokenReturned: true,
                idTokenChanged: true
            ),
        ])
        XCTAssertEqual(client.refreshToken, "456")
        XCTAssertEqual(client.idToken, "789")
    }

    func testRefreshReportsUnchangedTokensAndSkipsRedundantPersistence() async throws {
        NetworkSessionMock.shared.tokenRequestCount = 0
        let client = buildClient()
        client.refreshToken = "456"
        client.idToken = "789"
        let sink = RefreshReportSink()
        client.onTokenRefresh = { sink.record($0) }
        client.onTokenPersist = { _ in sink.recordPersist() }

        _ = try await client.getAccessToken(for: "resource1")

        XCTAssertEqual(sink.reports, [
            TokenRefreshReport(
                refreshTokenReturned: true,
                refreshTokenChanged: false,
                idTokenReturned: true,
                idTokenChanged: false
            ),
        ])
        XCTAssertEqual(sink.persistAttempts, 0)
        XCTAssertEqual(client.refreshToken, "456")
        XCTAssertEqual(client.idToken, "789")
    }

    func testRefreshReportsOmittedTokens() async throws {
        let client = buildClient(withOidcEndpoint: "/oidc_config:good:no_refresh")
        client.refreshToken = "bar"
        client.idToken = "baz"
        let sink = RefreshReportSink()
        client.onTokenRefresh = { sink.record($0) }

        _ = try await client.getAccessToken(for: "resource1")

        XCTAssertEqual(sink.reports, [
            TokenRefreshReport(
                refreshTokenReturned: false,
                refreshTokenChanged: false,
                idTokenReturned: false,
                idTokenChanged: false
            ),
        ])
        XCTAssertEqual(client.refreshToken, "bar")
        XCTAssertEqual(client.idToken, "baz")
    }

    /// A cached token with only seconds of life left is refreshed ahead of
    /// time instead of being handed to a request that will reach the backend
    /// after it expired.
    func testCachedAccessTokenInsideExpiryMarginIsRefreshed() async throws {
        NetworkSessionMock.shared.tokenRequestCount = 0
        let client = buildClient()
        client.refreshToken = "bar"
        let key = client.buildAccessTokenKey(for: "resource1", in: nil)
        client.accessTokenMap[key] = AccessToken(
            token: "almost-expired",
            scope: "",
            expiresAt: Date().timeIntervalSince1970 + LogtoClient.accessTokenExpiryMargin - 5
        )

        let token = try await client.getAccessToken(for: "resource1")

        XCTAssertEqual(token, "123")
    }

    func testCachedAccessTokenOutsideExpiryMarginIsReused() async throws {
        let client = buildClient()
        let key = client.buildAccessTokenKey(for: "resource1", in: nil)
        client.accessTokenMap[key] = AccessToken(
            token: "fresh",
            scope: "",
            expiresAt: Date().timeIntervalSince1970 + LogtoClient.accessTokenExpiryMargin + 5
        )

        let token = try await client.getAccessToken(for: "resource1")

        XCTAssertEqual(token, "fresh")
    }
}
