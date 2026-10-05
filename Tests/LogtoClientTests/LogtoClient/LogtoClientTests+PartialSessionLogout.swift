import Foundation
import Logto
@testable import LogtoClient
import LogtoMock
import XCTest

extension LogtoClientTests {
    func testClearCredentialsClearsRefreshOnlySession() async {
        let session = PartialSessionLogoutNetworkSession()
        let client = buildClient(session: session)
        XCTAssertEqual(client.loadFromKeychain { key in
            key == "refresh_token" ? "stored-refresh" : nil
        }, .loaded)
        client.accessTokenMap["resource"] = AccessToken(token: "cached", scope: "", expiresAt: 600)
        let reports = PartialSessionLogoutReports()
        client.onTokenPersist = { reports.append($0) }
        XCTAssertFalse(client.isAuthenticated)

        let error = await client.clearCredentials()

        XCTAssertNil(error)
        XCTAssertNil(client.refreshToken)
        XCTAssertNil(client.idToken)
        XCTAssertTrue(client.accessTokenMap.isEmpty)
        XCTAssertEqual(session.revokedTokens, ["stored-refresh"])
        XCTAssertEqual(reports.values.map(\.key), ["refresh_token", "id_token"])
        XCTAssertEqual(reports.values.map(\.result), [.skipped, .skipped])
    }

    func testClearCredentialsClearsRefreshOnlySessionWhenOffline() async {
        let session = PartialSessionLogoutNetworkSession(offline: true)
        let client = buildClient(session: session)
        client.loadFromKeychain { $0 == "refresh_token" ? "stored-refresh" : nil }
        client.accessTokenMap["resource"] = AccessToken(token: "cached", scope: "", expiresAt: 600)

        let error = await client.clearCredentials()

        XCTAssertEqual(error?.type, .unableToRevokeToken)
        XCTAssertEqual((error?.innerError as? URLError)?.code, .notConnectedToInternet)
        XCTAssertEqual(session.revokedTokens, ["stored-refresh"])
        XCTAssertNil(client.refreshToken)
        XCTAssertNil(client.idToken)
        XCTAssertTrue(client.accessTokenMap.isEmpty)
    }

    func testClearCredentialsEmptySessionStillAttemptsDeletionWithoutNetwork() async {
        let session = PartialSessionLogoutNetworkSession()
        let client = buildClient(session: session)
        let reports = PartialSessionLogoutReports()
        client.onTokenPersist = { reports.append($0) }

        let error = await client.clearCredentials()

        XCTAssertEqual(error?.type, .notAuthenticated)
        XCTAssertEqual(reports.values.map(\.key), ["refresh_token", "id_token"])
        XCTAssertEqual(session.requestCount, 0)
    }

    func testClearCredentialsClearsAccessOnlySessionWithoutNetwork() async {
        let session = PartialSessionLogoutNetworkSession()
        let client = buildClient(session: session)
        client.accessTokenMap["resource"] = AccessToken(token: "cached", scope: "", expiresAt: 600)

        let error = await client.clearCredentials()

        XCTAssertNil(error)
        XCTAssertTrue(client.accessTokenMap.isEmpty)
        XCTAssertEqual(session.requestCount, 0)
    }
}

private final class PartialSessionLogoutReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [PersistedTokenWriteReport] = []

    func append(_ report: PersistedTokenWriteReport) {
        lock.lock()
        defer { lock.unlock() }
        reports.append(report)
    }

    var values: [PersistedTokenWriteReport] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }
}

private final class PartialSessionLogoutNetworkSession: NetworkSession {
    let offline: Bool
    var revokedTokens: [String] = []
    var requestCount = 0

    init(offline: Bool = false) { self.offline = offline }

    func loadData(with request: URLRequest) async -> (Data?, Error?) {
        requestCount += 1
        if request.httpMethod == "POST", request.url?.path == "/revoke:good" {
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let items = URLComponents(string: "https://example.test/?\(body)")?.queryItems
            revokedTokens.append(items?.first { $0.name == "token" }?.value ?? "")
            return offline ? (nil, URLError(.notConnectedToInternet)) : (nil, nil)
        }
        return await NetworkSessionMock.shared.loadData(with: request)
    }
}
