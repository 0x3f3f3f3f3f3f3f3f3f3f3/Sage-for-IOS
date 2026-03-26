import Foundation

@MainActor
final class APIClient {
    var tokenProvider: () -> String? = { nil }
    private unowned let settings: AppSettingsStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let session: URLSession

    init(settings: AppSettingsStore, session: URLSession? = nil) {
        self.settings = settings
        self.session = session ?? Self.makeDefaultSession()
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    private var baseURL: URL {
        URL(string: settings.normalizedServerBaseURL)
            ?? URL(string: AppSettingsStore.defaultServerBaseURL)!
    }

    private func makeRequest(path: String, method: String, body: Data? = nil) throws -> URLRequest {
        let url = try makeURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.language.rawValue, forHTTPHeaderField: "x-locale")
        request.setValue(settings.effectiveTimeZoneIdentifier, forHTTPHeaderField: "x-timezone")
        if shouldAttachAuthorization(to: path), let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func send<Response: Decodable>(
        path: String,
        method: String = "GET",
        body: Encodable? = nil
    ) async throws -> Response {
        let execution = try await performDataRequest(path: path, method: method, body: body)
        do {
            return try decoder.decode(APIEnvelope<Response>.self, from: execution.data).data
        } catch {
            logDecodingFailure(error, data: execution.data, request: execution.request)
            throw APIErrorPayload(
                code: "decoding_failure",
                message: "Failed to decode API envelope from \(execution.request.url?.absoluteString ?? path)"
            )
        }
    }

    func rawRequest(
        path: String,
        method: String = "GET",
        body: Encodable? = nil
    ) async throws -> Data {
        try await performDataRequest(path: path, method: method, body: body).data
    }

    func streamText(path: String, body: Encodable) -> AsyncThrowingStream<String, Error> {
        let urlRequest: URLRequest
        do {
            let bodyData = try encoder.encode(AnyEncodable(body))
            urlRequest = try makeRequest(path: path, method: "POST", body: bodyData)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
        let session = self.session
        logRequest(urlRequest)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw APIErrorPayload(code: "invalid_response", message: "Invalid response")
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        var errorData = Data()
                        var errorIterator = bytes.makeAsyncIterator()
                        while let byte = try await errorIterator.next(), errorData.count < 4096 {
                            errorData.append(byte)
                        }
                        logResponse(response, data: errorData, request: urlRequest)
                        if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: errorData) {
                            throw envelope.error
                        }
                        if let payload = try? decoder.decode(APIErrorPayload.self, from: errorData) {
                            throw payload
                        }
                        throw APIErrorPayload(
                            code: "http_\(httpResponse.statusCode)",
                            message: fallbackErrorMessage(statusCode: httpResponse.statusCode, data: errorData, request: urlRequest)
                        )
                    }

                    var iterator = bytes.makeAsyncIterator()
                    var buffer = Data()
                    var preview = ""
                    while let byte = try await iterator.next() {
                        buffer.append(byte)
                        if buffer.count >= 128, let chunk = String(data: buffer, encoding: .utf8) {
                            appendPreview(chunk, to: &preview)
                            continuation.yield(chunk)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }

                    if !buffer.isEmpty, let finalChunk = String(data: buffer, encoding: .utf8) {
                        appendPreview(finalChunk, to: &preview)
                        continuation.yield(finalChunk)
                    }
                    logResponse(response, data: Data(preview.utf8), request: urlRequest)
                    continuation.finish()
                } catch {
                    logTransportError(error, request: urlRequest)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func makeURL(path: String) throws -> URL {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            throw APIErrorPayload(code: "invalid_url", message: "API path is empty")
        }

        if let absoluteURL = URL(string: normalizedPath), absoluteURL.scheme != nil {
            return absoluteURL
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIErrorPayload(code: "invalid_url", message: "Invalid base URL: \(settings.normalizedServerBaseURL)")
        }

        let pathComponents = normalizedPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathPart = String(pathComponents[0])
        components.path = pathPart.hasPrefix("/") ? pathPart : "/\(pathPart)"
        components.percentEncodedQuery = pathComponents.count > 1 ? String(pathComponents[1]) : nil

        guard let url = components.url else {
            throw APIErrorPayload(code: "invalid_url", message: "Malformed URL: \(settings.normalizedServerBaseURL)\(normalizedPath)")
        }
        return url
    }

    private func shouldAttachAuthorization(to path: String) -> Bool {
        let normalizedPath = path.lowercased()
        return !normalizedPath.hasSuffix("/api/mobile/v1/auth/login")
            && !normalizedPath.hasSuffix("/api/mobile/v1/auth/register")
    }

    private func performDataRequest(
        path: String,
        method: String,
        body: Encodable?
    ) async throws -> (data: Data, response: URLResponse, request: URLRequest) {
        let bodyData = try body.map { try encoder.encode(AnyEncodable($0)) }
        let urlRequest = try makeRequest(path: path, method: method, body: bodyData)
        logRequest(urlRequest)

        do {
            let (data, response) = try await session.data(for: urlRequest)
            logResponse(response, data: data, request: urlRequest)
            try validate(response: response, data: data, request: urlRequest)
            return (data, response, urlRequest)
        } catch let apiError as APIErrorPayload {
            throw apiError
        } catch {
            logTransportError(error, request: urlRequest)
            throw error
        }
    }

    private func validate(response: URLResponse, data: Data, request: URLRequest) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data) {
                throw envelope.error
            }
            if let payload = try? decoder.decode(APIErrorPayload.self, from: data) {
                throw payload
            }
            throw APIErrorPayload(
                code: "http_\(httpResponse.statusCode)",
                message: fallbackErrorMessage(statusCode: httpResponse.statusCode, data: data, request: request)
            )
        }
    }

    private func fallbackErrorMessage(statusCode: Int, data: Data, request: URLRequest) -> String {
        let defaultMessage = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        let preview = responsePreview(from: data)
        guard !preview.isEmpty else {
            return "HTTP \(statusCode): \(defaultMessage)"
        }

        if let title = extractHTMLTitle(from: preview) {
            let urlText = request.url?.absoluteString ?? settings.serverBaseURL
            return "HTTP \(statusCode): \(title) (\(urlText))"
        }

        return "HTTP \(statusCode): \(preview)"
    }

    private func responsePreview(from data: Data, limit: Int = 300) -> String {
        guard let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else {
            return ""
        }

        return String(
            body.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .prefix(limit)
        )
    }

    private func extractHTMLTitle(from body: String) -> String? {
        guard let startRange = body.range(of: "<title>", options: .caseInsensitive),
              let endRange = body.range(of: "</title>", options: .caseInsensitive) else {
            return nil
        }

        let title = body[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : String(title)
    }

    private func appendPreview(_ chunk: String, to preview: inout String) {
        guard preview.count < 300 else { return }
        let remaining = 300 - preview.count
        preview.append(contentsOf: chunk.prefix(remaining))
    }

    private func logRequest(_ request: URLRequest) {
#if DEBUG
        let headers = sanitizedHeaders(for: request)
        print("[APIClient][Request] \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<nil>")")
        print("[APIClient][RequestHeaders] \(headers)")
#endif
    }

    private func logResponse(_ response: URLResponse, data: Data, request: URLRequest) {
#if DEBUG
        if let httpResponse = response as? HTTPURLResponse {
            print("[APIClient][Response] \(httpResponse.statusCode) \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<nil>")")
        } else {
            print("[APIClient][Response] <non-http> \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<nil>")")
        }
        print("[APIClient][ResponseBody] \(responsePreview(from: data))")
#endif
    }

    private func logTransportError(_ error: Error, request: URLRequest) {
#if DEBUG
        print("[APIClient][TransportError] \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<nil>") -> \(error.localizedDescription)")
#endif
    }

    private func logDecodingFailure(_ error: Error, data: Data, request: URLRequest) {
#if DEBUG
        print("[APIClient][DecodeError] \(request.url?.absoluteString ?? "<nil>") -> \(error.localizedDescription)")
        print("[APIClient][DecodeBody] \(responsePreview(from: data))")
#endif
    }

    private func sanitizedHeaders(for request: URLRequest) -> [String: String] {
        var headers = request.allHTTPHeaderFields ?? [:]
        if headers["Authorization"] != nil {
            headers["Authorization"] = "<present>"
        }
        return headers
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }
}

private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init<T: Encodable>(_ wrapped: T) {
        encodeClosure = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}
