import Foundation

struct DraftStore {
    private let defaults: UserDefaults = .standard

    func readDraft(for key: String) -> String {
        defaults.string(forKey: "sage.draft.\(key)") ?? ""
    }

    func writeDraft(_ value: String, for key: String) {
        defaults.set(value, forKey: "sage.draft.\(key)")
    }

    func clearDraft(for key: String) {
        defaults.removeObject(forKey: "sage.draft.\(key)")
    }
}
