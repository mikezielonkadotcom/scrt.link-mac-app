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

    /// Human label: the public note if one was set, otherwise the type.
    var displayLabel: String {
        if let note = publicNote, !note.isEmpty { return note }
        return SecretEntry.typeName(secretType)
    }

    static func typeName(_ raw: String) -> String {
        switch raw {
        case "redirect": return "Redirect"
        case "neogram":  return "Neogram"
        default:         return "Text secret"
        }
    }

    func isExpired(at now: Date = Date()) -> Bool {
        guard let exp = expiresAt else { return false }
        return exp <= now
    }
}

/// Two views over one underlying list:
///
/// - **Recent** (`recent(...)`): entries created in the last `recentWindow`
///   (24 h). This is what the sidebar shows, so it clears itself out on a
///   rolling basis — nothing is deleted, it just ages out of the sidebar.
/// - **Full log** (`load(...)`): everything retained, newest first, capped at
///   `maxEntries`. Shown in the Secret Log window.
///
/// Every function takes a `UserDefaults` so the store can be exercised
/// against an isolated suite in tests without touching real app data.
enum SecretHistoryStore {
    static let key = "scrtLinkHistory"

    /// Hard cap on retained entries (full log). Oldest fall off first.
    static let maxEntries = 500

    /// How long an entry stays in the sidebar's "Recent" list.
    static let recentWindow: TimeInterval = 24 * 60 * 60

    // MARK: - Read

    /// All retained entries, newest first.
    static func load(defaults: UserDefaults = .standard) -> [SecretEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoded = (try? JSONDecoder().decode([SecretEntry].self, from: data)) ?? []
        return sortedNewestFirst(decoded)
    }

    /// Entries created within `recentWindow` of `now`, newest first.
    static func recent(now: Date = Date(), defaults: UserDefaults = .standard) -> [SecretEntry] {
        let cutoff = now.addingTimeInterval(-recentWindow)
        return load(defaults: defaults).filter { $0.createdAt > cutoff }
    }

    static func sortedNewestFirst(_ entries: [SecretEntry]) -> [SecretEntry] {
        entries.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Write

    static func save(_ entries: [SecretEntry], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    @discardableResult
    static func add(_ entry: SecretEntry, defaults: UserDefaults = .standard) -> [SecretEntry] {
        var current = load(defaults: defaults)
        // The new entry always goes first and always survives the cap, even
        // if its timestamp is odd (clock stepped back, server-supplied date);
        // load() sorts on read, so display order stays correct regardless.
        current.insert(entry, at: 0)
        if current.count > maxEntries {
            current = Array(current.prefix(maxEntries))
        }
        save(current, defaults: defaults)
        notifyChanged()
        return current
    }

    static func remove(id: String, defaults: UserDefaults = .standard) {
        remove(ids: [id], defaults: defaults)
    }

    static func remove(ids: Set<String>, defaults: UserDefaults = .standard) {
        var current = load(defaults: defaults)
        current.removeAll { ids.contains($0.id) }
        save(current, defaults: defaults)
        notifyChanged()
    }

    /// Wipes the entire log (recent and full).
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        notifyChanged()
    }

    private static func notifyChanged() {
        NotificationCenter.default.post(name: .secretHistoryChanged, object: nil)
    }
}

extension Notification.Name {
    static let secretHistoryChanged = Notification.Name("scrtLinkHistoryChanged")
}
