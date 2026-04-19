#if !os(macOS)
    import AuthenticationServices
    @testable import LogtoClient
    import XCTest

    private let redirectUri = URL(string: "io.logto.test://callback")!
    private let authUri = URL(string: "https://logto.dev/oidc/auth")!

    /// Covers the system-browser presenter swap introduced by the
    /// `native-browser` fork. Purely logic-level — no ASWebAuthenticationSession
    /// is spun up, so these tests stay deterministic in CI.
    final class LogtoWebViewAuthSessionTests: XCTestCase {
        private func makeSession(
            uri: URL = authUri,
            redirect: URL = redirectUri,
            onFinish: @escaping LogtoWebViewAuthSession.FinishHandler = { _, _ in }
        ) -> LogtoWebViewAuthSession {
            LogtoWebViewAuthSession(
                uri,
                redirectUri: redirect,
                socialPlugins: [],
                onFinish: onFinish
            )
        }

        // MARK: handleCompletion redirect validation

        func testHandleCompletionAcceptsMatchingRedirect() async throws {
            var received: URL?
            let session = makeSession { url, _ in received = url }

            let callback = URL(string: "io.logto.test://callback?code=abc&state=xyz")!
            await session.handleCompletion(callbackURL: callback, error: nil)

            XCTAssertEqual(received, callback)
        }

        func testHandleCompletionIsSchemeCaseInsensitive() async throws {
            var received: URL?
            let session = makeSession { url, _ in received = url }

            let callback = URL(string: "IO.LOGTO.TEST://callback?code=abc")!
            await session.handleCompletion(callbackURL: callback, error: nil)

            XCTAssertEqual(received, callback)
        }

        func testHandleCompletionRejectsMismatchedHost() async throws {
            var received: URL? = URL(string: "placeholder://x")
            var receivedError: Error?
            let session = makeSession { url, error in
                received = url
                receivedError = error
            }

            let callback = URL(string: "io.logto.test://otherhost?code=abc")!
            await session.handleCompletion(callbackURL: callback, error: nil)

            XCTAssertNil(received)
            XCTAssertNil(receivedError)
        }

        func testHandleCompletionRejectsMismatchedPath() async throws {
            var received: URL? = URL(string: "placeholder://x")
            let session = makeSession { url, _ in received = url }

            let callback = URL(string: "io.logto.test://callback/evil?code=abc")!
            await session.handleCompletion(callbackURL: callback, error: nil)

            XCTAssertNil(received)
        }

        func testHandleCompletionForwardsErrorWhenURLMissing() async throws {
            var received: URL? = URL(string: "placeholder://x")
            var receivedError: Error?
            let session = makeSession { url, error in
                received = url
                receivedError = error
            }

            let fakeError = NSError(domain: "test", code: 1)
            await session.handleCompletion(callbackURL: nil, error: fakeError)

            XCTAssertNil(received)
            XCTAssertEqual((receivedError as NSError?)?.domain, "test")
        }

        // MARK: didFinish idempotency

        func testDidFinishFiresOnFinishHandlerOnce() async throws {
            var callCount = 0
            let session = makeSession { _, _ in callCount += 1 }

            await session.didFinish(url: nil, error: LogtoWebViewAuthViewError.noPresentationAnchor)
            await session.didFinish(url: nil, error: LogtoWebViewAuthViewError.noPresentationAnchor)

            XCTAssertEqual(callCount, 1)
        }

        // MARK: start() input validation

        func testStartReturnsFalseForEmptyScheme() async throws {
            let badRedirect = URL(string: "/no-scheme")!
            let expectation = expectation(description: "onFinish fires with unableToConstructCallbackUri")
            expectation.assertForOverFulfill = true

            let session = makeSession(redirect: badRedirect) { _, error in
                if case LogtoWebViewAuthViewError.unableToConstructCallbackUri = (error ?? NSError()) {
                    expectation.fulfill()
                }
            }

            let launched = session.start()
            XCTAssertFalse(launched)
            await fulfillment(of: [expectation], timeout: 1.0)
        }
    }
#endif
