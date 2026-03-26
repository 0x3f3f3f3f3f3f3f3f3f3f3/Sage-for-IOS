import XCTest
@testable import SageApp

@MainActor
final class SageAppTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testKeychainWriteReadDeleteRoundTrip() throws {
        let store = KeychainStore(service: "com.sage.tests")
        let key = "token-\(UUID().uuidString)"
        let value = "secret-token"

        try store.write(value, for: key)
        XCTAssertEqual(store.read(key), value)

        store.delete(key)
        XCTAssertNil(store.read(key))
    }

    func testAPIClientDecodesEnvelopeAndThrowsStructuredError() async throws {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "APIClientTests")!)
        settings.setServerBaseURL("https://example.com")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(settings: settings, session: session)

        MockURLProtocol.handler = { request in
            if request.url?.path == "/success" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"data":{"success":true}}"#.data(using: .utf8)!
                )
            }

            return (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                #"{"error":{"code":"unauthorized","message":"Nope"}}"#.data(using: .utf8)!
            )
        }

        let success: EmptySuccessDTO = try await client.send(path: "/success")
        XCTAssertTrue(success.success)

        do {
            let _: EmptySuccessDTO = try await client.send(path: "/failure")
            XCTFail("Expected structured error")
        } catch let error as APIErrorPayload {
            XCTAssertEqual(error.code, "unauthorized")
            XCTAssertEqual(error.message, "Nope")
        }
    }

    func testInboxViewModelLoadHappyPath() async throws {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "InboxViewModelTests")!)
        settings.setServerBaseURL("https://example.com")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(settings: settings, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/mobile/v1/inbox")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                #"{"data":[{"id":"inbox-1","content":"Capture this","capturedAt":"2026-03-25T12:00:00Z","processedAt":null,"processType":"NONE"}]}"#.data(using: .utf8)!
            )
        }

        let model = InboxViewModel()
        await model.load(using: client)

        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.content, "Capture this")
        XCTAssertNil(model.errorMessage)
    }

    func testAPIClientBuildsDirectMobileURLAndAddsHeaders() async throws {
        let suiteName = "APIClientURLTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settings = AppSettingsStore(defaults: defaults)
        settings.setServerBaseURL(" http:// 154.83.158.137:3003 / ")
        settings.setLanguage(.chineseSimplified)
        settings.setTimezoneMode(.manual)
        settings.setTimezoneOverride("Asia/Shanghai")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(settings: settings, session: session)
        let currentToken = "secret-token"
        client.tokenProvider = { currentToken }

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://154.83.158.137:3003/api/mobile/v1/search?q=test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-locale"), "zh-Hans")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-timezone"), "Asia/Shanghai")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")

            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                #"{"data":{"tasks":[],"notes":[],"tags":[]}}"#.data(using: .utf8)!
            )
        }

        let results: SearchResultsDTO = try await client.send(path: "/api/mobile/v1/search?q=test")
        XCTAssertTrue(results.tasks.isEmpty)
        XCTAssertTrue(results.notes.isEmpty)
        XCTAssertTrue(results.tags.isEmpty)
    }

    func testMakeAPIPathPercentEncodesQueryItems() {
        XCTAssertEqual(
            makeAPIPath(
                "/api/mobile/v1/timeline",
                queryItems: [
                    URLQueryItem(name: "start", value: "2026-03-23T00:00:00+08:00"),
                    URLQueryItem(name: "end", value: "2026-03-30T00:00:00+08:00")
                ]
            ),
            "/api/mobile/v1/timeline?start=2026-03-23T00:00:00%2B08:00&end=2026-03-30T00:00:00%2B08:00"
        )

        XCTAssertEqual(
            makeAPIPath(
                "/api/mobile/v1/search",
                queryItems: [URLQueryItem(name: "q", value: "A+B & C")]
            ),
            "/api/mobile/v1/search?q=A%2BB%20%26%20C"
        )
    }

    func testAuthFlowStoresBearerAndLoadsProtectedResources() async throws {
        let suiteName = "AuthFlowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settings = AppSettingsStore(defaults: defaults)
        settings.setServerBaseURL(AppSettingsStore.defaultServerBaseURL)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(settings: settings, session: session)
        let keychain = KeychainStore(service: "com.sage.tests.auth.\(UUID().uuidString)")

        let loginEnvelope = #"{"data":{"token":"opaque-token","user":{"id":"owner","username":"admin","createdAt":"2026-03-25T00:00:00Z"},"settings":{"language":"zh-Hans","theme":"system","timezoneMode":"system","timezoneOverride":null,"effectiveTimezone":"America/Los_Angeles"},"session":{"id":"session-1","deviceName":"iPhone","expiresAt":"2026-04-25T00:00:00Z","lastUsedAt":"2026-03-25T00:00:00Z"}}}"#
        let meEnvelope = #"{"data":{"user":{"id":"owner","username":"admin","createdAt":"2026-03-25T00:00:00Z"},"settings":{"language":"zh-Hans","theme":"system","timezoneMode":"system","timezoneOverride":null,"effectiveTimezone":"America/Los_Angeles"},"session":{"id":"session-1","deviceName":"iPhone","expiresAt":"2026-04-25T00:00:00Z","lastUsedAt":"2026-03-25T00:00:00Z"}}}"#
        let bootstrapEnvelope = #"{"data":{"user":{"id":"owner","username":"admin","createdAt":"2026-03-25T00:00:00Z"},"settings":{"language":"zh-Hans","theme":"system","timezoneMode":"system","timezoneOverride":null,"effectiveTimezone":"America/Los_Angeles"},"summary":{"inboxCount":1,"tagCount":0,"noteCount":0,"taskCounts":{"todo":1}}}}"#
        let inboxEnvelope = #"{"data":[{"id":"inbox-1","content":"Capture this","capturedAt":"2026-03-25T12:00:00Z","processedAt":null,"processType":"NONE"}]}"#

        let authStore = AuthStore(apiClient: client, keychain: keychain, settings: settings)
        var currentToken: String?
        client.tokenProvider = { currentToken }

        MockURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/mobile/v1/auth/login"):
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let body = try XCTUnwrap(try requestBodyData(from: request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["username"] as? String, "admin")
                XCTAssertEqual(json["password"] as? String, "429841lzy")
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    loginEnvelope.data(using: .utf8)!
                )
            case ("GET", "/api/mobile/v1/me"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer opaque-token")
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    meEnvelope.data(using: .utf8)!
                )
            case ("GET", "/api/mobile/v1/bootstrap"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer opaque-token")
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    bootstrapEnvelope.data(using: .utf8)!
                )
            case ("GET", "/api/mobile/v1/inbox"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer opaque-token")
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    inboxEnvelope.data(using: .utf8)!
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.absoluteString ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await authStore.login(username: "admin", password: "429841lzy")
        currentToken = authStore.token
        XCTAssertEqual(authStore.phase, .signedIn)
        XCTAssertEqual(authStore.token, "opaque-token")
        XCTAssertEqual(keychain.read("mobileAuthToken"), "opaque-token")

        await authStore.bootstrapApp()
        XCTAssertEqual(authStore.bootstrap?.inboxCount, 1)

        let coldStartStore = AuthStore(apiClient: client, keychain: keychain, settings: settings)
        await coldStartStore.restoreSession()
        currentToken = coldStartStore.token
        XCTAssertEqual(coldStartStore.phase, .signedIn)

        await coldStartStore.bootstrapApp()
        XCTAssertEqual(coldStartStore.bootstrap?.inboxCount, 1)

        let inboxViewModel = InboxViewModel()
        await inboxViewModel.load(using: client)
        XCTAssertEqual(inboxViewModel.items.count, 1)
        XCTAssertNil(inboxViewModel.errorMessage)
    }
}

private func requestBodyData(from request: URLRequest) throws -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let bytesRead = stream.read(buffer, maxLength: bufferSize)
        if bytesRead < 0 {
            throw stream.streamError ?? URLError(.cannotDecodeRawData)
        }
        if bytesRead == 0 {
            break
        }
        data.append(buffer, count: bytesRead)
    }

    return data.isEmpty ? nil : data
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
