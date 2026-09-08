//
//  URLSessionTests.swift
//
//
//  Created by Gao Sun on 2022/4/13.
//

import Foundation
@testable import Logto
import XCTest

final class URLSessionTests: XCTestCase {
    func testMissingResponsePreservesTransportError() {
        let (data, error) = URLSession.shared.handleResponse(
            data: nil, response: nil,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        )
        XCTAssertNil(data)
        XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
    }

    func testHttpRejectionTakesPrecedenceOverTransportError() {
        for status in [400, 401] {
            let response = HTTPURLResponse(
                url: URL(string: "https://logto.dev")!, statusCode: status,
                httpVersion: nil, headerFields: nil
            )
            let (_, error) = URLSession.shared.handleResponse(
                data: nil, response: response, error: URLError(.networkConnectionLost)
            )
            guard case let .withCode(code, _, _)? = error as? LogtoErrors.Response else {
                XCTFail("Expected the HTTP rejection")
                continue
            }
            XCTAssertEqual(code, status)
        }
    }

    func testHandleResponseOk() {
        let mockData = "123".data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "https://logto.dev")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        let (data, error) = URLSession.shared.handleResponse(data: mockData, response: response, error: nil)

        XCTAssertEqual(data, mockData)
        XCTAssertNil(error)
    }

    func testHandleResponseStatusCodeError() {
        let mockData = "123".data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "https://logto.dev")!,
            statusCode: 400,
            httpVersion: nil,
            headerFields: nil
        )

        let (data, error) = URLSession.shared.handleResponse(data: mockData, response: response, error: nil)

        XCTAssertNil(data)

        guard let error = error as? LogtoErrors.Response, case .withCode = error else {
            XCTFail()
            return
        }
    }

    func testHandleResponseNotHttpResponse() {
        let mockData = "123".data(using: .utf8)!

        let (data, error) = URLSession.shared.handleResponse(data: mockData, response: nil, error: nil)

        XCTAssertNil(data)

        guard let error = error as? LogtoErrors.Response, case .notHttpResponse = error else {
            XCTFail()
            return
        }
    }
}
