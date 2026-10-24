import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ASOProviders
import ASOCore

/// Behaviour of the HTTP layer that must hold on every platform. Nothing here touches the network:
/// refused requests fail before they are sent.
@Suite("HTTP client")
struct HTTPClientTests {
    let client = HTTPClient(serviceName: "Test", allowedHosts: ["itunes.apple.com"])

    @Test("Plain HTTP is refused even for an allow-listed host")
    func refusesPlainHTTP() async {
        let request = HTTPClient.request(URL(string: "http://itunes.apple.com/search")!)
        await #expect(throws: ASOError.self) { try await client.send(request) }
    }

    @Test("A host that is not allow-listed is refused")
    func refusesOtherHosts() async {
        for url in ["https://example.com/", "https://itunes.apple.com.example.com/", "https://evil-itunes.apple.com/"] {
            let request = HTTPClient.request(URL(string: url)!)
            await #expect(throws: ASOError.self) { try await client.send(request) }
        }
    }

    @Test("Request builder sets method, headers, body and timeout")
    func requestBuilder() {
        let body = Data("{}".utf8)
        let r = HTTPClient.request(URL(string: "https://itunes.apple.com/x")!, method: "POST",
                                   headers: ["Content-Type": "application/json"], body: body, timeout: 12)
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(r.httpBody == body)
        #expect(r.timeoutInterval == 12)
    }

    @Test("Response headers are looked up case-insensitively")
    func headerLookup() {
        let response = HTTPResponse(status: 200, data: Data(), headers: ["Retry-After": "5"])
        #expect(response.header("retry-after") == "5")
        #expect(response.header("X-Missing") == nil)
    }

    @Test("Failure statuses map to typed errors")
    func statusMapping() throws {
        func error(_ status: Int, _ headers: [String: String] = [:], body: String = "") -> ASOError? {
            do { try client.check(HTTPResponse(status: status, data: Data(body.utf8), headers: headers)); return nil }
            catch { return error as? ASOError }
        }
        #expect(error(204) == nil)
        #expect(error(401) == .unauthorized(service: "Test"))
        #expect(error(403) == .unauthorized(service: "Test"))
        #expect(error(429, ["Retry-After": "7"]) == .rateLimited(service: "Test", retryAfterSeconds: 7))
        #expect(error(429, ["Retry-After": "7", "RateLimit-Reset": "60"]) == .rateLimited(service: "Test", retryAfterSeconds: 7))
        #expect(error(429, ["RateLimit-Reset": "60"]) == .rateLimited(service: "Test", retryAfterSeconds: 60))
        #expect(error(429) == .rateLimited(service: "Test", retryAfterSeconds: nil))
        #expect(error(500, body: "boom") == .http(service: "Test", status: 500, message: "boom"))
    }

    @Test("ISO 8601 dates parse with and without fractional seconds")
    func isoDates() {
        let plain = JSON.parseISODate("2026-08-01T10:00:00Z")
        let fractional = JSON.parseISODate("2026-08-01T10:00:00.250Z")
        #expect(plain == Date(timeIntervalSince1970: 1_785_578_400))
        #expect(fractional.map { abs($0.timeIntervalSince1970 - 1_785_578_400.25) < 0.001 } == true)
        #expect(JSON.parseISODate("2026-08-01T12:00:00+02:00") == plain)
        #expect(JSON.parseISODate("01/08/2026") == nil)
    }

    @Test("Apple Ads day strings are UTC calendar days")
    func apiDay() {
        #expect(APIDay.string(from: Date(timeIntervalSince1970: 1_785_628_799)) == "2026-08-01")   // 23:59:59 UTC
        #expect(APIDay.string(from: Date(timeIntervalSince1970: 1_785_628_800)) == "2026-08-02")
    }
}
