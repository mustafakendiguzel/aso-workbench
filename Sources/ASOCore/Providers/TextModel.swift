import Foundation

/// A chat model that writes text (the metadata writer through OpenRouter in ASOProviders), behind a protocol so the
/// writer is tested without the network.
public protocol TextModel: Sendable {
    func complete(system: String, user: String, temperature: Double, maxTokens: Int) async throws -> TextCompletion
}

public struct TextCompletion: Sendable, Equatable {
    public let text: String
    /// What the call cost, e.g. "$0.0031", or its token counts when the price is unknown.
    public let cost: String?

    public init(text: String, cost: String? = nil) {
        self.text = text
        self.cost = cost
    }

    /// The first JSON object in the text (models sometimes wrap JSON in prose or code fences).
    public var jsonObject: [String: Any]? { Self.jsonObject(in: text) }

    public static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(String(text[start...end]).utf8))) as? [String: Any]
    }
}
