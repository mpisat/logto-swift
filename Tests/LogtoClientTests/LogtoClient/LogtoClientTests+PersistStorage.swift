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
