import Foundation

public struct URLSessionWebFetcher: WebFetching, Sendable {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(
            configuration: configuration,
            delegate: PublicRedirectPolicyDelegate(),
            delegateQueue: nil
        )
        self.timeout = timeout
    }

    public func fetch(
        url: URL,
        maximumBytes: Int,
        allowedMIMETypes: Set<String>
    ) async throws -> WebFetchResponse {
        try PublicWebURLPolicy.validate(url)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(allowedMIMETypes.sorted().joined(separator: ", "), forHTTPHeaderField: "Accept")
        request.setValue("CoreAIAgent/1", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw WebToolError.invalidStatus(0) }
        guard (200...299).contains(http.statusCode) else { throw WebToolError.invalidStatus(http.statusCode) }
        let finalURL = try http.url.map { url -> URL in
            try PublicWebURLPolicy.validate(url)
            return url
        } ?? url
        let mime = (http.mimeType ?? "application/octet-stream").lowercased()
        guard allowedMIMETypes.contains(mime) else { throw WebToolError.unsupportedMIMEType(mime) }
        if http.expectedContentLength > Int64(maximumBytes) {
            throw WebToolError.responseTooLarge(maximumBytes: maximumBytes)
        }
        var data = Data()
        data.reserveCapacity(min(max(Int(http.expectedContentLength), 0), maximumBytes))
        for try await byte in bytes {
            if data.count == maximumBytes {
                throw WebToolError.responseTooLarge(maximumBytes: maximumBytes)
            }
            data.append(byte)
        }
        return WebFetchResponse(finalURL: finalURL, mimeType: mime, data: data)
    }
}

private final class PublicRedirectPolicyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, (try? PublicWebURLPolicy.validate(url)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
