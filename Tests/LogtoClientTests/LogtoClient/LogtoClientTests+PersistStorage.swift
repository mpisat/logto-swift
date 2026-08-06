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
final class LogtoClientPersistStorageTests: XCTestCase {
    private let serviceName = LogtoClient.keychainServiceName

    private var keychain: Keychain { Keychain(service: serviceName) }

    override func setUp() {
        super.setUp()
        try? keychain.remove(LogtoClient.KeyName.idToken.rawValue)
        try? keychain.remove(LogtoClient.KeyName.refreshToken.rawValue)
    }

    override func tearDown() {
        try? keychain.remove(LogtoClient.KeyName.idToken.rawValue)
        try? keychain.remove(LogtoClient.KeyName.refreshToken.rawValue)
        super.tearDown()
    }

    /// Init with a populated Keychain loads the values into memory and
    /// leaves the on-disk entries intact.
    func testLoadFromKeychainHydratesAndPreservesEntries() {
        let seedId = "seed-id-\(UUID().uuidString)"
        let seedRefresh = "seed-refresh-\(UUID().uuidString)"
        keychain[LogtoClient.KeyName.idToken.rawValue] = seedId
        keychain[LogtoClient.KeyName.refreshToken.rawValue] = seedRefresh

        let client = LogtoClient(
            useConfig: try! LogtoConfig(endpoint: "/", appId: "persist-load-hydrate"),
            session: NetworkSessionMock.shared
        )

        XCTAssertEqual(client.idToken, seedId)
        XCTAssertEqual(client.refreshToken, seedRefresh)
        XCTAssertEqual(keychain[LogtoClient.KeyName.idToken.rawValue], seedId)
        XCTAssertEqual(keychain[LogtoClient.KeyName.refreshToken.rawValue], seedRefresh)
    }

    /// Simulates the bug: a read that returns `nil` while the disk entry
    /// is still present. With the `isLoadingFromKeychain` guard the
    /// `didSet` observer's `saveToKeychain` is skipped, so the disk
    /// entry survives. Without the guard, this assertion would fail.
    func testNilAssignmentDuringLoadDoesNotDeleteDiskEntry() {
        let preserved = "preserved-\(UUID().uuidString)"
        keychain[LogtoClient.KeyName.idToken.rawValue] = preserved
        keychain[LogtoClient.KeyName.refreshToken.rawValue] = preserved

        let client = LogtoClient(
            useConfig: try! LogtoConfig(endpoint: "/", appId: "persist-load-guard"),
            session: NetworkSessionMock.shared
        )
        XCTAssertEqual(client.idToken, preserved)
        XCTAssertEqual(client.refreshToken, preserved)

        // Replay what a failing Keychain read does inside loadFromKeychain:
        // it sets each property to nil with isLoadingFromKeychain == true.
        client.isLoadingFromKeychain = true
        client.idToken = nil
        client.refreshToken = nil
        client.isLoadingFromKeychain = false

        XCTAssertNil(client.idToken)
        XCTAssertNil(client.refreshToken)
        XCTAssertEqual(keychain[LogtoClient.KeyName.idToken.rawValue], preserved)
        XCTAssertEqual(keychain[LogtoClient.KeyName.refreshToken.rawValue], preserved)
    }

    /// Sign-out / token rotation still write through. Assigning nil
    /// outside a load run must continue to delete the Keychain entry,
    /// otherwise sign-out would leak credentials.
    func testNilAssignmentOutsideLoadDeletesDiskEntry() {
        let client = LogtoClient(
            useConfig: try! LogtoConfig(endpoint: "/", appId: "persist-signout"),
            session: NetworkSessionMock.shared
        )
        client.idToken = "should-be-cleared"
        client.refreshToken = "should-be-cleared"
        XCTAssertEqual(keychain[LogtoClient.KeyName.idToken.rawValue], "should-be-cleared")
        XCTAssertEqual(keychain[LogtoClient.KeyName.refreshToken.rawValue], "should-be-cleared")

        client.idToken = nil
        client.refreshToken = nil

        XCTAssertNil(keychain[LogtoClient.KeyName.idToken.rawValue])
        XCTAssertNil(keychain[LogtoClient.KeyName.refreshToken.rawValue])
    }

    /// Rotated tokens during a refresh still persist (these assignments
    /// happen well after `init` so `isLoadingFromKeychain` is false).
    func testTokenRotationOutsideLoadPersists() {
        let client = LogtoClient(
            useConfig: try! LogtoConfig(endpoint: "/", appId: "persist-rotate"),
            session: NetworkSessionMock.shared
        )
        client.idToken = "v1"
        client.refreshToken = "v1"

        client.idToken = "v2"
        client.refreshToken = "v2"

        XCTAssertEqual(keychain[LogtoClient.KeyName.idToken.rawValue], "v2")
        XCTAssertEqual(keychain[LogtoClient.KeyName.refreshToken.rawValue], "v2")
    }

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

    /// Exercises the public orchestration rather than the injectable persist
    /// core: both pending values are replayed, with the refresh token first.
    func testPublicRetryReplaysCapturedPendingValuesRefreshFirst() {
        let client = LogtoClient(
            useConfig: try! LogtoConfig(endpoint: "/", appId: "persist-public-retry"),
            session: NetworkSessionMock.shared
        )
        let collector = ReportCollector()
        client.onTokenPersist = { collector.append($0) }
        client.pendingTokenWrites[.idToken] = .init(value: "pending-id")
        client.pendingTokenWrites[.refreshToken] = .init(value: "pending-refresh")

        let reports = client.retryPendingTokenWrites()

        XCTAssertEqual(reports.map(\.key), ["refresh_token", "id_token"])
        XCTAssertEqual(reports.map(\.result), [.verified, .verified])
        XCTAssertEqual(collector.reports, reports)
        XCTAssertEqual(keychain["refresh_token"], "pending-refresh")
        XCTAssertEqual(keychain["id_token"], "pending-id")
        XCTAssertFalse(client.hasPendingTokenWrites)
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

    /// Real Keychain, real read-back: a rotation reports verified and the
    /// observer sees exactly one report per assignment.
    func testRealKeychainRotationReportsVerifiedPerAssignment() {
        let client = LogtoClient(
            useConfig: try! LogtoConfig(endpoint: "/", appId: "persist-observer"),
            session: NetworkSessionMock.shared
        )
        let collector = ReportCollector()
        client.onTokenPersist = { collector.append($0) }

        client.refreshToken = "r1"
        client.idToken = "i1"

        XCTAssertEqual(collector.reports.map(\.key), ["refresh_token", "id_token"])
        XCTAssertEqual(collector.reports.map(\.result), [.verified, .verified])
        XCTAssertFalse(client.hasPendingTokenWrites)
    }
}
