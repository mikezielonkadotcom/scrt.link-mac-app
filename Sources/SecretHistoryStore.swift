import Foundation

/// Persistent log of secrets created from the native form. Stored as
/// JSON-encoded array in UserDefaults. Never stores the plaintext — only
/// the shareable link and metadata. The link's `#<key>` fragment contains
/// the decryption key, so anyone with the link can open the secret once;
/// storing it locally is effectively storing a bearer token for that secret.
struct SecretEntry: Codable, Identifiable {
    var id: String = UUID().uuidString
    var createdAt: Date = Date()
    var expiresAt: Date?
    var link: String
    var receiptId: String
    var secretType: String
    var publicNote: String?
}

enum SecretHistoryStore {
    private static let key = "scrtLinkHistory"
    private static let maxEntries = 100

    static func load() -> [SecretEntry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SecretEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [SecretEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    @discardableResult
    static func add(_ entry: SecretEntry) -> [SecretEntry] {
        var current = load()
        current.insert(entry, at: 0)
        if current.count > maxEntries {
            current = Array(current.prefix(maxEntries))
        }
        save(current)
        NotificationCenter.default.post(name: .secretHistoryChanged, object: nil)
        return current
    }

    static func remove(id: String) {
        var current = load()
        current.removeAll { $0.id == id }
        save(current)
        NotificationCenter.default.post(name: .secretHistoryChanged, object: nil)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: .secretHistoryChanged, object: nil)
    }
}

extension Notification.Name {
    static let secretHistoryChanged = Notification.Name("scrtLinkHistoryChanged")
}
