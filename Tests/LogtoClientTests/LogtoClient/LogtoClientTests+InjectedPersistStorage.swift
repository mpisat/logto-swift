import KeychainAccess
import Logto
@testable import LogtoClient
import LogtoMock
import XCTest

/// Regression coverage for the load-vs-save feedback loop in
/// `LogtoClient+PersistStorage.swift`. Before the `isLoadingFromKeychain`
/// guard, a transient Keychain read failure during `loadFromKeychain`
/// returned `nil` through the subscript, the `didSet` observer fired,
/// and `saveToKeychain` wrote that `nil` back, *deleting* the on-disk
/// entry. That was a silent, destructive trapdoor: any failed init-time
/// read wiped the user's session with no log line.
final class LogtoClientInjectedPersistStorageTests: XCTestCase {

    func testReloadResultDistinguishesLoadedTokensFromEmptyStorage() {
        let client = LogtoClient(
            useConfig: try! LogtoConfig(endpoint: "/", appId: "persist-result", usingPersistStorage: false),
            session: NetworkSessionMock.shared
        )

        let loaded = client.loadFromKeychain { key in
            key == LogtoClient.KeyName.refreshToken.rawValue ? "refresh" : nil
        }
        XCTAssertEqual(loaded, .loaded)

        let empty = client.loadFromKeychain { _ in nil }
        XCTAssertEqual(empty, .empty)
    }

    func testReloadFailurePreservesInMemoryTokensAndReportsFailure() {
        let client = LogtoClient(
            useConfig: try! LogtoConfig(endpoint: "/", appId: "persist-failure", usingPersistStorage: false),
            session: NetworkSessionMock.shared
        )
        client.idToken = "memory-id"
        client.refreshToken = "memory-refresh"

        let result = client.loadFromKeychain { _ in throw Status.interactionNotAllowed }

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(client.idToken, "memory-id")
        XCTAssertEqual(client.refreshToken, "memory-refresh")
    }

    // MARK: Verified writes

    /// `onTokenPersist` is `@Sendable`, so a test cannot capture a plain `var`
    /// to collect reports. This is the minimum that satisfies it.
    private final class ReportCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [PersistedTokenWriteReport] = []

        func append(_ report: PersistedTokenWriteReport) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(report)
        }

        var reports: [PersistedTokenWriteReport] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// Builds a client with no real Keychain so the write path can be driven
    /// through the injectable `persist` overload.
    private func makeDetachedClient(_ appId: String) -> LogtoClient {
        LogtoClient(
            useConfig: try! LogtoConfig(endpoint: "/", appId: appId, usingPersistStorage: false),
            session: NetworkSessionMock.shared
        )
    }

    /// The happy path: the value lands and the read-back matches, so nothing
    /// is left pending.
    func testVerifiedWriteReportsVerifiedAndLeavesNothingPending() {
        let client = makeDetachedClient("persist-write-ok")
        client.refreshToken = "rotated"
        var store: [String: String] = [:]

        let report = client.persist(
            key: .refreshToken,
            isRetry: false,
            write: { store[$1] = $0 },
            remove: { store[$0] = nil },
            read: { store[$0] }
        )

        XCTAssertEqual(report.result, .verified)
        XCTAssertEqual(report.key, "refresh_token")
        XCTAssertFalse(report.isRetry)
        XCTAssertFalse(client.hasPendingTokenWrites)
        XCTAssertEqual(store["refresh_token"], "rotated")
    }

    /// The defect this change exists for. Before it, this write returned
    /// nothing and the caller carried on believing the rotated token was
    /// durable.
    func testFailedWriteSurfacesOSStatusAndIsMarkedPending() {
        let client = makeDetachedClient("persist-write-fail")
        client.refreshToken = "rotated"
        let collector = ReportCollector()
        client.onTokenPersist = { collector.append($0) }

        let report = client.persist(
            key: .refreshToken,
            isRetry: false,
            write: { _, _ in throw Status.interactionNotAllowed },
            remove: { _ in },
            read: { _ in nil }
        )

        XCTAssertEqual(report.result, .failed(Status.interactionNotAllowed.rawValue))
        XCTAssertTrue(client.hasPendingTokenWrites)
        XCTAssertEqual(collector.reports.count, 1)
        XCTAssertEqual(collector.reports.first?.key, "refresh_token")
    }

    /// A write that reports success but does not actually land. The subscript
    /// could not tell this apart from success either.
    func testWriteThatDoesNotLandReportsUnverifiedAndIsMarkedPending() {
        let client = makeDetachedClient("persist-write-silent")
        client.refreshToken = "rotated"

        let report = client.persist(
            key: .refreshToken,
            isRetry: false,
            write: { _, _ in },
            remove: { _ in },
            read: { _ in nil }
        )

        XCTAssertEqual(report.result, .unverified)
        XCTAssertTrue(client.hasPendingTokenWrites)
    }

    /// Persistence bookkeeping is touched by token assignments on a generic
    /// executor and by lifecycle retries on the main actor. A state read must
    /// not race an in-flight persist operation.
    func testPendingStateReadWaitsForInFlightPersist() {
        let client = makeDetachedClient("persist-state-serialization")
        client.refreshToken = "rotated"
        let writeEntered = DispatchSemaphore(value: 0)
        let allowWrite = DispatchSemaphore(value: 0)
        let persistCompleted = DispatchSemaphore(value: 0)
        let stateReadCompleted = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            client.persist(
                key: .refreshToken,
                isRetry: false,
                write: { _, _ in
                    writeEntered.signal()
                    allowWrite.wait()
                },
                remove: { _ in },
                read: { _ in "rotated" }
            )
            persistCompleted.signal()
        }

        XCTAssertEqual(writeEntered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            _ = client.hasPendingTokenWrites
            stateReadCompleted.signal()
        }

        XCTAssertEqual(
            stateReadCompleted.wait(timeout: .now() + 0.1),
            .timedOut,
            "pending state must be serialized with the in-flight persist"
        )

        allowWrite.signal()
        XCTAssertEqual(persistCompleted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(stateReadCompleted.wait(timeout: .now() + 1), .success)
    }

    /// A non-`Status` error still reports a failure, with no `OSStatus`.
    func testNonStatusErrorReportsFailedWithoutOSStatus() {
        struct Opaque: Error {}
        let client = makeDetachedClient("persist-write-opaque")
        client.refreshToken = "rotated"

        let report = client.persist(
            key: .refreshToken,
            isRetry: false,
            write: { _, _ in throw Opaque() },
            remove: { _ in },
            read: { _ in nil }
        )

        XCTAssertEqual(report.result, .failed(nil))
    }

    /// Sign-out clears the entry, and a confirmed absence counts as verified.
    func testRemovalIsVerifiedWhenTheEntryIsGone() {
        let client = makeDetachedClient("persist-remove")
        var store: [String: String] = ["refresh_token": "stale"]

        let report = client.persist(
            key: .refreshToken,
            isRetry: false,
            write: { store[$1] = $0 },
            remove: { store[$0] = nil },
            read: { store[$0] }
        )

        XCTAssertEqual(report.result, .verified)
        XCTAssertNil(store["refresh_token"])
    }

    /// A failed removal is retryable too, otherwise sign-out could leave a
    /// live credential on disk with nothing tracking it.
    func testFailedRemovalIsMarkedPending() {
        let client = makeDetachedClient("persist-remove-fail")

        let report = client.persist(
            key: .refreshToken,
            isRetry: false,
            write: { _, _ in },
            remove: { _ in throw Status.interactionNotAllowed },
            read: { _ in "still-here" }
        )

        XCTAssertEqual(report.result, .failed(Status.interactionNotAllowed.rawValue))
        XCTAssertTrue(client.hasPendingTokenWrites)
    }

    func testRefreshOnlyLogoutDeletionFailureRetainsNilForRetry() async {
        let client = makeDetachedClient("persist-refresh-only-logout")
        var store = ["refresh_token": "stored-refresh"]
        client.loadFromKeychain { store[$0] }
        // Local clearing must still run when discovery cannot be fetched.
        let error = await client.clearCredentials()
        XCTAssertEqual(error?.type, .unableToFetchOidcConfig)
        XCTAssertNil(client.refreshToken)

        let failure = client.persist(
            key: .refreshToken, isRetry: false,
            write: { _, _ in XCTFail("Logout must delete rather than write a token") },
            remove: { _ in throw Status.interactionNotAllowed },
            read: { store[$0] }
        )
        XCTAssertEqual(failure.result, .failed(Status.interactionNotAllowed.rawValue))
        XCTAssertTrue(client.hasPendingTokenWrites)
        XCTAssertNotNil(client.pendingTokenWrites[.refreshToken])
        XCTAssertNil(client.pendingTokenWrites[.refreshToken]?.value)
        XCTAssertEqual(store["refresh_token"], "stored-refresh")

        let retry = client.persist(
            key: .refreshToken, isRetry: true,
            write: { _, _ in XCTFail("Retry must preserve the deletion intention") },
            remove: { store[$0] = nil },
            read: { store[$0] }
        )
        XCTAssertEqual(retry.result, .verified)
        XCTAssertTrue(retry.isRetry)
        XCTAssertFalse(client.hasPendingTokenWrites)
        XCTAssertNil(store["refresh_token"])
        XCTAssertNil(client.refreshToken)
    }

    /// Step 3: the retry writes the **in-memory** value, which is the current
    /// one, and clears the pending flag once the read-back matches.
    func testRetryWritesInMemoryValueAndClearsPending() {
        let client = makeDetachedClient("persist-retry")
        client.refreshToken = "rotated"
        var store: [String: String] = [:]
        var locked = true

        let write: (String, String) throws -> Void = { value, key in
            if locked { throw Status.interactionNotAllowed }
            store[key] = value
        }
        let read: (String) throws -> String? = { store[$0] }

        let first = client.persist(key: .refreshToken, isRetry: false,
                                   write: write, remove: { store[$0] = nil }, read: read)
        XCTAssertEqual(first.result, .failed(Status.interactionNotAllowed.rawValue))
        XCTAssertTrue(client.hasPendingTokenWrites)

        locked = false
        let retry = client.persist(key: .refreshToken, isRetry: true,
                                   write: write, remove: { store[$0] = nil }, read: read)

        XCTAssertEqual(retry.result, .verified)
        XCTAssertTrue(retry.isRetry)
        XCTAssertFalse(client.hasPendingTokenWrites)
        XCTAssertEqual(store["refresh_token"], "rotated")
        XCTAssertEqual(client.refreshToken, "rotated", "retry must not mutate memory")
    }

    /// The retry must never pull disk into memory. A stale on-disk value that
    /// the process already replaced stays overwritten, not restored.
    func testRetryDoesNotLoadDiskIntoMemory() {
        let client = makeDetachedClient("persist-retry-direction")
        client.refreshToken = "current"
        var store: [String: String] = ["refresh_token": "superseded"]

        client.persist(
            key: .refreshToken,
            isRetry: true,
            write: { store[$1] = $0 },
            remove: { store[$0] = nil },
            read: { store[$0] }
        )

        XCTAssertEqual(client.refreshToken, "current")
        XCTAssertEqual(store["refresh_token"], "current")
    }

    /// With no Keychain configured there is nothing to retry and the call is
    /// inert rather than an error.
    func testRetryIsInertWithoutPersistStorage() {
        let client = makeDetachedClient("persist-retry-inert")
        client.refreshToken = "rotated"

        XCTAssertTrue(client.retryPendingTokenWrites().isEmpty)
    }

    /// Disabled persistence is an intentional skipped attempt, not silence.
    /// This keeps the public callback contract exhaustive without marking the
    /// key pending.
    func testAssignmentWithoutPersistStorageReportsSkipped() {
        let client = makeDetachedClient("persist-skipped")
        let collector = ReportCollector()
        client.onTokenPersist = { collector.append($0) }

        client.refreshToken = "memory-only"

        XCTAssertEqual(
            collector.reports,
            [PersistedTokenWriteReport(key: "refresh_token", result: .skipped, isRetry: false)]
        )
        XCTAssertFalse(client.hasPendingTokenWrites)
    }

    func testSecondReadFailureDoesNotPartiallyReplaceMemory() {
        let client = makeDetachedClient("persist-atomic")
        client.idToken = "memory-id"
        client.refreshToken = "memory-refresh"
        let result = client.loadFromKeychain { key in
            if key == "refresh_token" { throw Status.interactionNotAllowed }
            return "new-id"
        }
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(client.idToken, "memory-id")
        XCTAssertEqual(client.refreshToken, "memory-refresh")
    }

    func testLoadDoesNotReportObserverWritesEvenWhenStorageIsDisabled() {
        let client = makeDetachedClient("persist-load-no-observers")
        let collector = ReportCollector()
        client.onTokenPersist = { collector.append($0) }
        XCTAssertEqual(client.loadFromKeychain { _ in "loaded" }, .loaded)
        XCTAssertTrue(collector.reports.isEmpty)
    }

    func testPersistCallbackRunsAfterLockIsReleased() {
        let client = makeDetachedClient("persist-callback-lock")
        client.refreshToken = "rotated"
        let readFinished = DispatchSemaphore(value: 0)
        let persistenceLock = client.tokenPersistLock
        client.onTokenPersist = { _ in
            DispatchQueue.global().async {
                persistenceLock.lock()
                defer { persistenceLock.unlock() }
                readFinished.signal()
            }
            XCTAssertEqual(readFinished.wait(timeout: .now() + 1), .success)
        }
        let report = client.persist(
            key: .refreshToken, isRetry: false,
            write: { _, _ in }, remove: { _ in }, read: { _ in "rotated" }
        )
        XCTAssertEqual(report.result, .verified)
    }

    func testReadBackFailureRetainsCapturedIntendedValue() {
        let client = makeDetachedClient("persist-read-back-failure")
        client.refreshToken = "rotated"
        let report = client.persist(
            key: .refreshToken, isRetry: false,
            write: { _, _ in }, remove: { _ in },
            read: { _ in throw Status.interactionNotAllowed }
        )
        XCTAssertEqual(report.result, .failed(Status.interactionNotAllowed.rawValue))
        XCTAssertEqual(client.pendingTokenWrites[.refreshToken]?.value, "rotated")
    }

    func testLaterFailedWriteReplacesEarlierPendingIntention() {
        let client = makeDetachedClient("persist-latest-intention")
        for value in ["first", "latest"] {
            client.refreshToken = value
            client.persist(
                key: .refreshToken, isRetry: false,
                write: { _, _ in throw Status.interactionNotAllowed },
                remove: { _ in }, read: { _ in nil }
            )
        }
        XCTAssertEqual(client.pendingTokenWrites[.refreshToken]?.value, "latest")
    }

}
