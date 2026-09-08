import Foundation
@testable import Logto
@testable import LogtoClient
import XCTest

private final class LostRotationResponseSession: NetworkSession {
    var errorCode: URLError.Code = .networkConnectionLost
    var responseStatus: Int?
    var delayNanoseconds: UInt64 = 0
    var failures = 1
    private(set) var tokenRequests = 0
    private(set) var presentedSameToken = true
    private(set) var retryTimeout: TimeInterval?

    func loadData(with request: URLRequest) async -> (Data?, Error?) {
        guard request.httpMethod == "POST" else {
            return (Data(#"{"authorization_endpoint":"https://example.test/auth","token_endpoint":"https://example.test/token","end_session_endpoint":"https://example.test/end","revocation_endpoint":"https://example.test/revoke","userinfo_endpoint":"https://example.test/user","jwks_uri":"https://example.test/jwks","issuer":"https://example.test"}"#.utf8), nil)
        }
        tokenRequests += 1
        if tokenRequests == 2 { retryTimeout = request.timeoutInterval }
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        presentedSameToken = presentedSameToken && body.contains("refresh_token=initial")
        if tokenRequests <= failures {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            let response = responseStatus.flatMap {
                HTTPURLResponse(url: request.url!, statusCode: $0, httpVersion: nil, headerFields: nil)
            }
            // Exercise the real transport response normalization before the
            // real SDK decides whether this failed exchange can be retried.
            return URLSession.shared.handleResponse(
                data: Data(#"{"error":"invalid_grant"}"#.utf8),
                response: response,
                error: NSError(domain: NSURLErrorDomain, code: errorCode.rawValue)
            )
        }
        // The provider permits the immediate retry within its existing grace.
        return (Data(#"{"access_token":"access-new","refresh_token":"refresh-new","id_token":"id-new","scope":"openid offline_access","expires_in":3600}"#.utf8), nil)
    }
}

extension LogtoClientTests {
    private func responseLossClient(_ session: LostRotationResponseSession) throws -> LogtoClient {
        let client = LogtoClient(
            useConfig: try LogtoConfig(endpoint: "https://example.test", appId: "test-app", usingPersistStorage: false),
            session: session
        )
        client.refreshToken = "initial"
        return client
    }

    @MainActor
    func testRecoversLostRotationResponseWithinExistingProviderGrace() async throws {
        let session = LostRotationResponseSession()
        let client = try responseLossClient(session)
        let token = try await client.getAccessToken(for: "https://api.example.test")
        XCTAssertEqual(token, "access-new")
        XCTAssertEqual(client.refreshToken, "refresh-new")
        XCTAssertEqual(session.tokenRequests, 2)
        XCTAssertTrue(session.presentedSameToken)
        XCTAssertGreaterThan(try XCTUnwrap(session.retryTimeout), 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(session.retryTimeout), 2)
    }

    @MainActor
    func testRetryTimeoutUsesRemainingOriginalBudget() async throws {
        let session = LostRotationResponseSession()
        session.delayNanoseconds = 300_000_000
        let client = try responseLossClient(session)
        let token = try await client.getAccessToken(for: "https://api.example.test")
        XCTAssertEqual(token, "access-new")
        XCTAssertEqual(client.refreshToken, "refresh-new")
        XCTAssertEqual(session.tokenRequests, 2)
        XCTAssertGreaterThan(try XCTUnwrap(session.retryTimeout), 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(session.retryTimeout), 1.7)
    }

    @MainActor
    func testSlowResponseLossDoesNotRetry() async throws {
        let session = LostRotationResponseSession()
        session.delayNanoseconds = 1_100_000_000
        try await assertResponseLossDoesNotRetry(session)
    }

    @MainActor
    func testPermanentRejectionDoesNotRetry() async throws {
        for status in [400, 401] {
            let session = LostRotationResponseSession()
            session.responseStatus = status
            try await assertResponseLossDoesNotRetry(session)
        }
    }

    @MainActor
    func testTimeoutDoesNotRetry() async throws {
        let session = LostRotationResponseSession()
        session.errorCode = .timedOut
        try await assertResponseLossDoesNotRetry(session)
    }

    @MainActor
    func testTransportCancellationDoesNotRetry() async throws {
        let session = LostRotationResponseSession()
        session.errorCode = .cancelled
        try await assertResponseLossDoesNotRetry(session)
    }

    @MainActor
    func testCancelledTaskDoesNotRetryConnectionLoss() async throws {
        let session = LostRotationResponseSession()
        let task = Task { @MainActor in
            try await self.assertResponseLossDoesNotRetry(session)
        }
        task.cancel()
        try await task.value
    }

    @MainActor
    func testSecondConnectionLossDoesNotRetryAgain() async throws {
        let session = LostRotationResponseSession()
        session.failures = 2
        try await assertResponseLossDoesNotRetry(session, expectedRequests: 2)
    }

    @MainActor
    private func assertResponseLossDoesNotRetry(
        _ session: LostRotationResponseSession,
        expectedRequests: Int = 1
    ) async throws {
        let client = try responseLossClient(session)
        do {
            _ = try await client.getAccessToken(for: "https://api.example.test")
            XCTFail("Expected the injected request failure to propagate")
        } catch {
            XCTAssertEqual(client.refreshToken, "initial")
        }
        XCTAssertEqual(session.tokenRequests, expectedRequests)
    }
}
