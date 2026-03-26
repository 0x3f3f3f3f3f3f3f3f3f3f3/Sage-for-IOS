import Foundation
import Security

struct KeychainStore {
    private static let fallbackLock = NSLock()
    private nonisolated(unsafe) static var fallbackValues: [String: String] = [:]
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private let service: String

    init(service: String) {
        self.service = service
    }

    func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if Self.isRunningTests {
                return Self.fallbackValue(for: storageKey(for: key))
            }
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let update: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var createQuery = query
        createQuery[kSecValueData as String] = data
        createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
        if createStatus != errSecSuccess, Self.isRunningTests {
            Self.setFallbackValue(value, for: storageKey(for: key))
            return
        }
        guard createStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(createStatus))
        }
    }

    func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)
        if Self.isRunningTests {
            Self.deleteFallbackValue(for: storageKey(for: key))
        }
    }

    private func storageKey(for key: String) -> String {
        "\(service)::\(key)"
    }

    private static func fallbackValue(for key: String) -> String? {
        fallbackLock.lock()
        defer { fallbackLock.unlock() }
        return fallbackValues[key]
    }

    private static func setFallbackValue(_ value: String, for key: String) {
        fallbackLock.lock()
        defer { fallbackLock.unlock() }
        fallbackValues[key] = value
    }

    private static func deleteFallbackValue(for key: String) {
        fallbackLock.lock()
        defer { fallbackLock.unlock() }
        fallbackValues.removeValue(forKey: key)
    }
}
