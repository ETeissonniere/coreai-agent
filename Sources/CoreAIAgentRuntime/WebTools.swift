import Foundation
import FoundationModels

public struct WebSource: Codable, Equatable, Sendable {
    public let title: String
    public let url: URL
    public let snippet: String

    public init(title: String, url: URL, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public protocol WebSearching: Sendable {
    func search(query: String, maximumResults: Int) async throws -> [WebSource]
}

public protocol WebFetching: Sendable {
    func fetch(url: URL, maximumBytes: Int, allowedMIMETypes: Set<String>) async throws -> WebFetchResponse
}

/// A keyless, fixed-origin search provider. It intentionally uses only the
/// DuckDuckGo Instant Answer endpoint and never follows model-provided URLs.
public struct DuckDuckGoSearchProvider: WebSearching, Sendable {
    private struct Envelope: Decodable {
        struct Topic: Decodable {
            var Text: String?
            var FirstURL: String?
            var Topics: [Topic]?
        }
        var AbstractText: String
        var AbstractURL: String?
        var Heading: String
        var Results: [Topic]?
        var RelatedTopics: [Topic]
    }

    private let fetcher: any WebFetching

    public init(fetcher: any WebFetching = URLSessionWebFetcher()) {
        self.fetcher = fetcher
    }

    public func search(query: String, maximumResults: Int) async throws -> [WebSource] {
        var components = URLComponents(string: "https://api.duckduckgo.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "no_redirect", value: "1")
        ]
        let response = try await fetcher.fetch(
            url: components.url!,
            maximumBytes: 128_000,
            // DuckDuckGo's JSON endpoint is served as JavaScript by some CDN
            // edges. The body is still decoded strictly as JSON below and the
            // final origin remains pinned to api.duckduckgo.com.
            allowedMIMETypes: [
                "application/json", "application/javascript",
                "application/x-javascript", "text/javascript",
            ]
        )
        guard response.finalURL.host?.lowercased() == "api.duckduckgo.com" else {
            throw WebToolError.disallowedHost
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: response.data)
        var sources: [WebSource] = []
        if let value = envelope.AbstractURL, let url = URL(string: value), !value.isEmpty,
           !envelope.AbstractText.isEmpty {
            sources.append(WebSource(title: envelope.Heading, url: url, snippet: envelope.AbstractText))
        }
        func append(_ topics: [Envelope.Topic]) {
            for topic in topics where sources.count < maximumResults {
                if let nested = topic.Topics { append(nested) }
                if let value = topic.FirstURL, let url = URL(string: value), !value.isEmpty,
                   let text = topic.Text {
                    sources.append(WebSource(title: String(text.prefix(120)), url: url, snippet: text))
                }
            }
        }
        append(envelope.Results ?? [])
        append(envelope.RelatedTopics)
        if !sources.isEmpty { return Array(sources.prefix(maximumResults)) }
        return try await searchHTML(query: query, maximumResults: maximumResults)
    }

    private func searchHTML(query: String, maximumResults: Int) async throws -> [WebSource] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let response = try await fetcher.fetch(
            url: components.url!,
            maximumBytes: 500_000,
            allowedMIMETypes: ["text/html"]
        )
        guard response.finalURL.host?.lowercased() == "html.duckduckgo.com",
              let html = String(data: response.data, encoding: .utf8) else {
            throw WebToolError.disallowedHost
        }
        let pattern = #"(?is)class=[\"']result__a[\"'][^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(html.startIndex..., in: html)
        var results: [WebSource] = []
        for match in expression.matches(in: html, range: range) where results.count < maximumResults {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let url = Self.resultURL(from: String(html[hrefRange])) else { continue }
            try PublicWebURLPolicy.validate(url)
            results.append(WebSource(
                title: Self.plainHTML(String(html[titleRange])),
                url: url,
                snippet: "Search result from DuckDuckGo"
            ))
        }
        return results
    }

    private static func resultURL(from href: String) -> URL? {
        let decoded = href.replacingOccurrences(of: "&amp;", with: "&")
        let absolute = decoded.hasPrefix("//") ? "https:\(decoded)" : decoded
        guard let url = URL(string: absolute) else { return nil }
        if url.host?.lowercased().hasSuffix("duckduckgo.com") == true,
           let escaped = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "uddg" })?.value,
           let destination = URL(string: escaped) {
            return destination
        }
        return url
    }

    private static func plainHTML(_ value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A small provider for search services that expose
/// `{ "results": [{ "title": ..., "url": ..., "snippet": ... }] }`.
/// The endpoint and every returned source must be public HTTPS URLs.
public struct JSONSearchEndpointProvider: WebSearching, Sendable {
    private struct Envelope: Decodable { let results: [Result] }
    private struct Result: Decodable { let title: String; let url: URL; let snippet: String }

    private let endpoint: URL
    private let queryParameter: String
    private let fetcher: any WebFetching
    private let maximumResponseBytes: Int

    public init(
        endpoint: URL,
        queryParameter: String = "q",
        fetcher: any WebFetching = URLSessionWebFetcher(),
        maximumResponseBytes: Int = 500_000
    ) throws {
        try PublicWebURLPolicy.validate(endpoint)
        self.endpoint = endpoint
        self.queryParameter = queryParameter
        self.fetcher = fetcher
        self.maximumResponseBytes = maximumResponseBytes
    }

    public func search(query: String, maximumResults: Int) async throws -> [WebSource] {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw WebToolError.invalidURL
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: queryParameter, value: query))
        items.append(URLQueryItem(name: "limit", value: String(maximumResults)))
        components.queryItems = items
        guard let url = components.url else { throw WebToolError.invalidURL }
        let response = try await fetcher.fetch(
            url: url,
            maximumBytes: maximumResponseBytes,
            allowedMIMETypes: ["application/json"]
        )
        let envelope = try JSONDecoder().decode(Envelope.self, from: response.data)
        return try envelope.results.prefix(maximumResults).map { result in
            try PublicWebURLPolicy.validate(result.url)
            return WebSource(title: result.title, url: result.url, snippet: result.snippet)
        }
    }
}

public struct WebFetchResponse: Equatable, Sendable {
    public let finalURL: URL
    public let mimeType: String
    public let data: Data

    public init(finalURL: URL, mimeType: String, data: Data) {
        self.finalURL = finalURL
        self.mimeType = mimeType
        self.data = data
    }
}

public enum WebToolError: Error, LocalizedError, Equatable {
    case invalidURL
    case disallowedHost
    case responseTooLarge(maximumBytes: Int)
    case unsupportedMIMEType(String)
    case invalidStatus(Int)
    case invalidEncoding
    case invalidQuery
    case toolCallLimitExceeded(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Only public HTTPS URLs are allowed."
        case .disallowedHost: "The URL host is not public."
        case .responseTooLarge(let maximumBytes): "The response exceeds \(maximumBytes) bytes."
        case .unsupportedMIMEType(let type): "The response MIME type is not allowed: \(type)."
        case .invalidStatus(let status): "The server returned HTTP \(status)."
        case .invalidEncoding: "The response is not valid UTF-8 text."
        case .invalidQuery: "The search query is empty or too long."
        case .toolCallLimitExceeded(let maximum): "This turn is limited to \(maximum) stateful tool calls."
        }
    }
}

public enum PublicWebURLPolicy {
    public static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            throw WebToolError.invalidURL
        }
        let blockedNames = ["localhost", "localhost.localdomain"]
        guard !blockedNames.contains(host), !host.hasSuffix(".local"), !host.hasSuffix(".internal") else {
            throw WebToolError.disallowedHost
        }
        if let octets = ipv4Octets(host) {
            let blocked = octets[0] == 0 || octets[0] == 10 || octets[0] == 127
                || (octets[0] == 169 && octets[1] == 254)
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
                || octets[0] >= 224
            if blocked { throw WebToolError.disallowedHost }
        }
        if host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") {
            throw WebToolError.disallowedHost
        }
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        let octets = components.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }
}

@Generable(description: "A concise public-web search request")
public struct WebSearchArguments: Sendable, Equatable {
    @Guide(description: "Search terms only, without instructions")
    public var query: String

    public init(query: String) {
        self.query = query
    }
}

public struct WebSearchTool: Tool {
    public let name = "searchWeb"
    public let description = "Searches the public web and returns source URLs with short snippets."
    private let provider: any WebSearching
    private let broker: ToolExecutionBroker?
    private let invocationNamespace: String
    private let retryDelays: [Duration]
    private let requiresApproval: @Sendable () -> Bool

    public init(
        provider: any WebSearching,
        broker: ToolExecutionBroker? = nil,
        invocationNamespace: String = "standalone",
        retryDelays: [Duration] = [.milliseconds(250), .milliseconds(750)],
        requiresApproval: @escaping @Sendable () -> Bool = { true }
    ) {
        self.provider = provider
        self.broker = broker
        self.invocationNamespace = invocationNamespace
        self.retryDelays = retryDelays
        self.requiresApproval = requiresApproval
    }

    public func call(arguments: WebSearchArguments) async throws -> String {
        try Task.checkCancellation()
        let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500 else { throw WebToolError.invalidQuery }
        let limit = 5
        let operation: @Sendable () async throws -> String = {
            return try await Self.search(
                provider: provider,
                query: query,
                limit: limit,
                retryDelays: retryDelays
            )
        }
        if let broker, requiresApproval() {
            let operationKey = "web-search:\(invocationNamespace):\(Self.stableHash("\(query)\u{1f}\(limit)"))"
            let toolCallID = await broker.claimInvocation(toolName: name) ?? UUID().uuidString
            let key = "\(operationKey):\(toolCallID)"
            let approvalID = ToolIdentity.uuid(forOpaqueID: key)
            let request = AgentApprovalRequest(
                id: approvalID,
                invocationID: key,
                toolCallID: toolCallID,
                idempotencyKey: key,
                title: "Allow web search?",
                detail: "The search terms will be sent to api.duckduckgo.com. No request is made before approval.",
                target: "api.duckduckgo.com"
            )
            return try await broker.execute(request, operation: operation)
        }
        return try await operation()
    }

    private static func search(
        provider: any WebSearching,
        query: String,
        limit: Int,
        retryDelays: [Duration]
    ) async throws -> String {
        let sources: ArraySlice<WebSource>
        do {
            sources = try await searchWithRetry(
                provider: provider,
                query: query,
                limit: limit,
                retryDelays: retryDelays
            ).prefix(limit)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where isFatalSearchError(error) {
            throw error
        } catch {
            return """
            <web_search_status outcome="temporarily_unavailable" attempts="\(retryDelays.count + 1)">Web search is temporarily unavailable. Continue without web results, clearly tell the user that current information could not be verified, and offer to try again.</web_search_status>
            """
        }
        guard !sources.isEmpty else {
            // A successful provider response with no instant answers is not a
            // tool execution failure. Returning a non-empty, structured status
            // also prevents reasoning models from treating an empty tool
            // payload as a malformed call and immediately retrying it.
            return "<web_search_status>No results were returned for this query. Try a more specific query or explain that no sources were found.</web_search_status>"
        }
        for source in sources { try PublicWebURLPolicy.validate(source.url) }
        return sources.enumerated().map { index, source in
            let title = String(source.title.prefix(300))
            let snippet = String(source.snippet.prefix(400))
            return "<untrusted_web_result index=\"\(index + 1)\">\nTitle: \(title)\nURL: \(source.url.absoluteString)\nSnippet: \(snippet)\n</untrusted_web_result>"
        }.joined(separator: "\n\n")
    }

    private static func searchWithRetry(
        provider: any WebSearching,
        query: String,
        limit: Int,
        retryDelays: [Duration]
    ) async throws -> [WebSource] {
        for attempt in 0...retryDelays.count {
            try Task.checkCancellation()
            do {
                return try await provider.search(query: query, maximumResults: limit)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error where isFatalSearchError(error) {
                throw error
            } catch {
                guard attempt < retryDelays.count else { throw error }
                try await Task.sleep(for: retryDelays[attempt])
            }
        }
        preconditionFailure("The search retry loop must return or throw")
    }

    /// Validation, policy, and resource-boundary failures must never be hidden
    /// from the caller or retried as if they were provider availability issues.
    private static func isFatalSearchError(_ error: any Error) -> Bool {
        guard let error = error as? WebToolError else { return false }
        switch error {
        case .invalidStatus(let status):
            return status != 0 && status != 408 && status != 425 && status != 429
                && !(500...599).contains(status)
        case .invalidURL, .disallowedHost, .responseTooLarge,
             .unsupportedMIMEType, .invalidEncoding, .invalidQuery,
             .toolCallLimitExceeded:
            return true
        }
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }

}

public actor ToolCallBudget {
    private let maximumCalls: Int
    private var calls = 0

    public init(maximumCalls: Int = 3) { self.maximumCalls = maximumCalls }

    public func consume() throws {
        guard calls < maximumCalls else { throw WebToolError.toolCallLimitExceeded(maximumCalls) }
        calls += 1
    }

    /// A budget limits one user turn, not the lifetime of a conversation.
    public func beginTurn() { calls = 0 }
}

@Generable(description: "A public webpage to retrieve")
public struct WebFetchArguments: Sendable, Equatable {
    @Guide(description: "An HTTPS URL from a search result")
    public var url: String

    public init(url: String) { self.url = url }
}

public struct WebFetchTool: Tool {
    public let name = "fetchWebPage"
    public let description = "Reads a public HTTPS webpage and returns bounded text with its final source URL."
    private let fetcher: any WebFetching
    private let maximumBytes: Int

    public init(fetcher: any WebFetching, maximumBytes: Int = 1_000_000) {
        self.fetcher = fetcher
        self.maximumBytes = maximumBytes
    }

    public func call(arguments: WebFetchArguments) async throws -> String {
        try Task.checkCancellation()
        guard let url = URL(string: arguments.url) else { throw WebToolError.invalidURL }
        try PublicWebURLPolicy.validate(url)
        let allowedMIMETypes: Set<String> = ["text/html", "text/plain", "application/json"]
        let response = try await fetcher.fetch(
            url: url,
            maximumBytes: maximumBytes,
            allowedMIMETypes: allowedMIMETypes
        )
        try PublicWebURLPolicy.validate(response.finalURL)
        let mimeType = response.mimeType.lowercased()
        guard allowedMIMETypes.contains(mimeType) else {
            throw WebToolError.unsupportedMIMEType(response.mimeType)
        }
        guard response.data.count <= maximumBytes else {
            throw WebToolError.responseTooLarge(maximumBytes: maximumBytes)
        }
        guard let text = String(data: response.data, encoding: .utf8) else {
            throw WebToolError.invalidEncoding
        }
        let content = mimeType == "text/html" ? Self.plainText(fromHTML: text) : text
        return "Source: \(response.finalURL.absoluteString)\nContent-Type: \(mimeType)\n\n\(content)"
    }

    static func plainText(fromHTML html: String) -> String {
        html.replacingOccurrences(of: #"(?is)<(script|style)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</li>|</h[1-6]>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
