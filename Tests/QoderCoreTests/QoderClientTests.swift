import Foundation
import XCTest
@testable import QoderCore

final class QoderClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testCreateSessionEncodesAgentVersionAndMetadata() async throws {
        MockURLProtocol.handler = { request in
            MockURLProtocol.record(request)
            let data = #"{"id":"sess_test","status":"running"}"#.data(using: .utf8)!
            return (201, data)
        }

        let client = QoderClient(
            token: "test-token",
            baseURL: URL(string: "https://api.qoder.com.cn/api/v1/cloud")!,
            protocolClasses: [MockURLProtocol.self]
        )

        let (session, _) = try await client.createSession(
            agentID: "agent_test",
            agentVersion: 2,
            environmentID: "env_test",
            metadata: [
                "project_id": "demo",
                "task_id": "task_001",
                "run_id": "run_001"
            ]
        )

        XCTAssertEqual(session.id, "sess_test")
        let recorded = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(recorded.method, "POST")
        XCTAssertEqual(recorded.path, "/api/v1/cloud/sessions")

        let body = try XCTUnwrap(recorded.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let agent = try XCTUnwrap(object["agent"] as? [String: Any])
        XCTAssertEqual(agent["id"] as? String, "agent_test")
        XCTAssertEqual(agent["type"] as? String, "agent")
        XCTAssertEqual(agent["version"] as? Int, 2)
        XCTAssertEqual(object["environment_id"] as? String, "env_test")

        let metadata = try XCTUnwrap(object["metadata"] as? [String: String])
        XCTAssertEqual(metadata["project_id"], "demo")
        XCTAssertEqual(metadata["task_id"], "task_001")
        XCTAssertEqual(metadata["run_id"], "run_001")
    }

    func testCancelSessionUsesCancelEndpoint() async throws {
        MockURLProtocol.handler = { request in
            MockURLProtocol.record(request)
            return (200, #"{"status":"idle"}"#.data(using: .utf8)!)
        }

        let client = QoderClient(
            token: "test-token",
            baseURL: URL(string: "https://api.qoder.com.cn/api/v1/cloud")!,
            protocolClasses: [MockURLProtocol.self]
        )

        _ = try await client.cancelSession(sessionID: "sess_test")

        let recorded = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(recorded.method, "POST")
        XCTAssertEqual(recorded.path, "/api/v1/cloud/sessions/sess_test/cancel")
    }
}

private struct RecordedRequest {
    let method: String
    let path: String
    let body: Data?
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var requests: [RecordedRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        requests = []
    }

    static func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(RecordedRequest(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            body: bodyData(from: request)
        ))
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (statusCode, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
