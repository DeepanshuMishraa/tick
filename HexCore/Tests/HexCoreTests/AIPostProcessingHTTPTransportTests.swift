import Foundation
import XCTest
@testable import HexCore

final class AIPostProcessingHTTPTransportTests: XCTestCase, @unchecked Sendable {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FormatterURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testStalledRequestHitsTotalDeadlineAndCancelsTransport() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        let stopped = expectation(description: "Transport cancelled")
        let finished = expectation(description: "Deadline returned without waiting for response")
        let request = request(path: "stall", stopped: stopped)
        let task = Task {
            do {
                _ = try await AIPostProcessingHTTPTransport.data(for: request, session: session, deadline: 0.04)
                XCTFail("Stalled request succeeded")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished, stopped], timeout: 0.5)
        task.cancel()
        await task.value
    }

    func testPartialResponseDoesNotExtendTotalDeadline() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        let stopped = expectation(description: "Partial response transport cancelled")
        let finished = expectation(description: "Total deadline returned")
        let request = request(path: "partial", stopped: stopped)
        let task = Task {
            do {
                _ = try await AIPostProcessingHTTPTransport.data(for: request, session: session, deadline: 0.04)
                XCTFail("Partial response succeeded")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished, stopped], timeout: 0.5)
        task.cancel()
        await task.value
    }

    func testAlreadyCancelledRequestDoesNotStartTransport() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        let started = expectation(description: "Must not start cancelled request")
        started.isInverted = true
        let request = request(path: "stall", started: started)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await AIPostProcessingHTTPTransport.data(for: request, session: session)
                XCTFail("Cancelled request succeeded")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
        await fulfillment(of: [started], timeout: 0.05)
    }

    func testSuccessfulResponsePreservesCompleteData() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await AIPostProcessingHTTPTransport.data(
            for: URLRequest(url: URL(string: "https://formatter.invalid/success")!), session: session
        )
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"edits":[]}"#)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testParentCancellationStopsTransportWithoutWaitingForDeadline() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        let stopped = expectation(description: "Transport cancelled")
        let started = expectation(description: "Transport started")
        let request = request(path: "stall", stopped: stopped, started: started)
        let task = Task {
            do {
                _ = try await AIPostProcessingHTTPTransport.data(for: request, session: session, deadline: 10)
                XCTFail("Cancelled request succeeded")
            } catch {
                XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
            }
        }
        await fulfillment(of: [started], timeout: 0.5)
        task.cancel()
        await task.value
        await fulfillment(of: [stopped], timeout: 0.5)
    }

    private func request(path: String, stopped: XCTestExpectation? = nil, started: XCTestExpectation? = nil) -> URLRequest {
        let request = NSMutableURLRequest(url: URL(string: "https://formatter.invalid/\(path)")!)
        if let stopped { URLProtocol.setProperty(stopped, forKey: "stopped", in: request) }
        if let started { URLProtocol.setProperty(started, forKey: "started", in: request) }
        return request as URLRequest
    }
}

private final class FormatterURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        (URLProtocol.property(forKey: "started", in: request) as? XCTestExpectation)?.fulfill()
        guard request.url?.path == "/success" || request.url?.path == "/partial" else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url?.path == "/partial" {
            client?.urlProtocol(self, didLoad: Data(#"{"edits":"#.utf8))
            return
        }
        client?.urlProtocol(self, didLoad: Data(#"{"edits":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        (URLProtocol.property(forKey: "stopped", in: request) as? XCTestExpectation)?.fulfill()
    }
}
