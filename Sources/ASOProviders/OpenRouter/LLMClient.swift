import Foundation
import ASOCore

/// Chat-completion client for OpenRouter (OpenAI-compatible). Used by the ASO assistant with Claude.
public actor LLMClient {
    /// DeepSeek V4 Pro: strong JSON/instruction following at roughly a sixth of Claude Sonnet's price. Changeable in Settings.
    public static let defaultModel = "deepseek/deepseek-v4-pro"
    /// Curated choices for the Settings picker (id, label, rough cost per metadata request).
    public static let modelChoices: [(id: String, label: String)] = [
        ("deepseek/deepseek-v4-pro", "DeepSeek V4 Pro · ~$0.003 per request"),
        ("deepseek/deepseek-v4-flash", "DeepSeek V4 Flash · ~$0.0003 per request"),
        ("anthropic/claude-sonnet-5", "Claude Sonnet 5 · ~$0.015 per request"),
        ("anthropic/claude-opus-5", "Claude Opus 5 · ~$0.07 per request"),
    ]
    /// The model the app is configured to use (Settings), falling back to the default.
    public static var configuredModel: String {
        let stored = UserDefaults.standard.string(forKey: "assistantModel") ?? ""
        return stored.isEmpty ? defaultModel : stored
    }
    private let http = HTTPClient(serviceName: "OpenRouter", allowedHosts: ["openrouter.ai"])
    private var apiKey: String?

    public init(apiKey: String?) { self.apiKey = apiKey }
    public func update(apiKey: String?) { self.apiKey = apiKey }
    public var isConfigured: Bool { !(apiKey ?? "").isEmpty }

    public struct Usage: Sendable { public let inputTokens: Int; public let outputTokens: Int; public let cost: Double? }

    /// Sends a system + user prompt and returns the assistant text (plus usage). Retries once on 429/5xx.
    public func complete(model: String = LLMClient.configuredModel, system: String, user: String, temperature: Double = 0.4, maxTokens: Int = 6000) async throws -> (text: String, usage: Usage?) {
        guard let key = apiKey, !key.isEmpty else { throw ASOError.notConfigured(service: "OpenRouter") }
        // Reasoning is switched off: with it on, Claude spends the whole token budget thinking and returns
        // an empty completion (finish_reason=length). The task is structured writing, not deep reasoning.
        let body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "reasoning": ["enabled": false],
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = HTTPClient.request(URL(string: "https://openrouter.ai/api/v1/chat/completions")!, method: "POST", headers: [
            "Authorization": "Bearer \(key)", "Content-Type": "application/json",
            "HTTP-Referer": AppInfo.repositoryURL.absoluteString, "X-OpenRouter-Title": "ASO Workbench",
        ], body: data, timeout: 120)
        var response = try await http.send(request)
        if response.status == 429 || response.status >= 500 {
            try? await Task.sleep(for: .seconds(3))
            response = try await http.send(request)
        }
        try http.check(response)
        let bodyPrefix = String(decoding: response.data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw ASOError.decoding(service: "OpenRouter", detail: "Not a JSON object: \(bodyPrefix)")
        }
        if let err = json["error"] as? [String: Any] {
            throw ASOError.http(service: "OpenRouter", status: err["code"] as? Int ?? 200, message: err["message"] as? String ?? bodyPrefix)
        }
        guard let choices = json["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any] else {
            throw ASOError.decoding(service: "OpenRouter", detail: "No choices in response: \(bodyPrefix)")
        }
        var content = message["content"] as? String ?? ""
        if content.isEmpty, let parts = message["content"] as? [[String: Any]] {
            content = parts.compactMap { $0["text"] as? String }.joined()
        }
        if content.isEmpty {
            let finish = choices.first?["finish_reason"] as? String ?? "?"
            let refusal = message["refusal"] as? String ?? ""
            throw ASOError.decoding(service: "OpenRouter", detail: "Empty completion (finish_reason=\(finish)\(refusal.isEmpty ? "" : ", refusal=\(refusal)")).")
        }
        var usage: Usage?
        if let u = json["usage"] as? [String: Any] {
            usage = Usage(inputTokens: u["prompt_tokens"] as? Int ?? 0, outputTokens: u["completion_tokens"] as? Int ?? 0, cost: u["cost"] as? Double)
        }
        return (content, usage)
    }

    /// Extracts the first JSON object from a completion (models sometimes wrap JSON in prose or code fences).
    public static func extractJSONObject(_ text: String) -> [String: Any]? {
        TextCompletion.jsonObject(in: text)
    }
}

/// The writer's model through OpenRouter: one client, one model.
public struct OpenRouterTextModel: TextModel {
    let client: LLMClient
    let model: String

    public init(client: LLMClient, model: String) {
        self.client = client
        self.model = model
    }

    public func complete(system: String, user: String, temperature: Double, maxTokens: Int) async throws -> TextCompletion {
        let (text, usage) = try await client.complete(model: model, system: system, user: user, temperature: temperature, maxTokens: maxTokens)
        return TextCompletion(text: text, cost: usage.map { u in u.cost.map { String(format: "$%.4f", $0) } ?? "\(u.inputTokens)+\(u.outputTokens) tokens" })
    }
}
