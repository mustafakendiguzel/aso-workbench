import Foundation

/// Semantic judgements about a search term (Jev through OpenRouter in ASOProviders), behind a protocol so the jobs
/// that use them can be tested without the network.
public protocol KeywordJudge: Sendable {
    var isConfigured: Bool { get async }
    /// Brand, naturalness, language fit, intent, head term, demand and genre, as probabilities.
    func classify(term: String, storefront: String, storeLanguage: String) async throws -> JevFeatures
    /// Probability that someone searching `term` wants an app like this one, judged against its own description.
    func fit(term: String, appName: String, appDescription: String, storefront: String, storeLanguage: String) async throws -> Double
}
