import Foundation
import ASOCore

/// Minimal URLSession wrapper with host allow-listing. Credentials are only ever
/// attached by the specific provider that owns them, and only to allow-listed hosts
///: never forward a bearer token to an arbitrary URL).
public struct HTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public let headers: [String: String]

    public var isSuccess: Bool { (200..<300).contains(status) }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

public struct HTTPClient: Sendable {
    public let session: URLSession
    public let allowedHosts: Set<String>
    /// Host suffixes (".apple.com") for services whose exact hosts are handed out at runtime (asset uploads).
    public let allowedHostSuffixes: [String]
    public let serviceName: String

    public init(serviceName: String, allowedHosts: Set<String>, allowedHostSuffixes: [String] = [], session: URLSession = .shared) {
        self.serviceName = serviceName
        self.allowedHosts = allowedHosts
        self.allowedHostSuffixes = allowedHostSuffixes
        self.session = session
    }

    private func allowed(_ host: String) -> Bool { allowedHosts.contains(host) || allowedHostSuffixes.contains { host.hasSuffix($0) } }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url, url.scheme == "https", let host = url.host, allowed(host) else {
            throw ASOError.unsupported("\(serviceName): refusing request to non-allow-listed URL \(request.url?.absoluteString ?? "<nil>").")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ASOError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ASOError.network("\(serviceName): non-HTTP response.")
        }
        // Redirect targets must also be allow-listed (URLSession follows them transparently).
        if let finalHost = http.url?.host, !allowed(finalHost) {
            throw ASOError.unsupported("\(serviceName): redirected to non-allow-listed host \(finalHost).")
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { headers[ks] = vs }
        }
        return HTTPResponse(status: http.statusCode, data: data, headers: headers)
    }

    /// Maps common failure statuses to typed errors. `Retry-After` wins over `RateLimit-Reset`
    /// (which Apple Ads expresses in remaining seconds, not epoch).
    public func check(_ response: HTTPResponse) throws {
        guard !response.isSuccess else { return }
        let body = String(decoding: response.data.prefix(600), as: UTF8.self)
        switch response.status {
        case 401, 403:
            throw ASOError.unauthorized(service: serviceName)
        case 429:
            let retry = response.header("Retry-After").flatMap(Int.init) ?? response.header("RateLimit-Reset").flatMap(Int.init)
            throw ASOError.rateLimited(service: serviceName, retryAfterSeconds: retry)
        default:
            throw ASOError.http(service: serviceName, status: response.status, message: body)
        }
    }

    public static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 30) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.httpBody = body
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }
}

/// Serialises requests to one provider with a minimum spacing, so public
/// endpoints are not hammered (ASOpulse uses ~3.1 s; the iTunes Search API is
/// documented at roughly 20 calls per minute).
public actor RequestPacer {
    private let minimumInterval: TimeInterval
    private var lastStart: Date?

    public init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    public func wait() async {
        if let last = lastStart {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minimumInterval {
                try? await Task.sleep(for: .seconds(minimumInterval - elapsed))
            }
        }
        lastStart = Date()
    }
}

enum JSON {
    /// A fresh decoder per call: Foundation formatters are not Sendable, so nothing is shared.
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let d = parseISODate(s) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }

    static func parseISODate(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

enum APIDay {
    /// `yyyy-MM-dd` in UTC, used by Apple Ads time ranges.
    static func string(from date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
