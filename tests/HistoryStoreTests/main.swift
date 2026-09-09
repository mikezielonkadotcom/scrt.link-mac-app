import Foundation

// Compiled together with Sources/SecretHistoryStore.swift by
// tests/test-history-store.sh. Uses an isolated UserDefaults suite so it
// never touches the real app's history.

var failures = 0
var checks = 0

@MainActor
func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    checks += 1
    if condition {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ \(message)  (\(file):\(line))")
    }
}

let suiteName = "com.mikezielonka.scrt-link.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }

let now = Date(timeIntervalSince1970: 1_800_000_000)
let hour: TimeInterval = 3600

func entry(_ label: String, ageHours: Double, expiresInHours: Double? = nil) -> SecretEntry {
    SecretEntry(
        createdAt: now.addingTimeInterval(-ageHours * hour),
        expiresAt: expiresInHours.map { now.addingTimeInterval($0 * hour) },
        link: "https://scrt.link/s#\(label)",
        receiptId: "rcpt-\(label)",
        secretType: "text",
        publicNote: label
    )
}

print("▸ Empty store")
check(SecretHistoryStore.load(defaults: defaults).isEmpty, "load() is empty")
check(SecretHistoryStore.recent(now: now, defaults: defaults).isEmpty, "recent() is empty")
check(SecretHistoryStore.nextRecentExpiry(now: now, defaults: defaults) == nil, "nextRecentExpiry() is nil")

print("▸ Ordering: newest first regardless of insertion order")
// Insert deliberately out of order (oldest first, then newest, then middle).
SecretHistoryStore.add(entry("three-days", ageHours: 72), defaults: defaults)
SecretHistoryStore.add(entry("now", ageHours: 0), defaults: defaults)
SecretHistoryStore.add(entry("two-hours", ageHours: 2), defaults: defaults)
SecretHistoryStore.add(entry("thirty-hours", ageHours: 30), defaults: defaults)
SecretHistoryStore.add(entry("twenty-three-hours", ageHours: 23), defaults: defaults)

let all = SecretHistoryStore.load(defaults: defaults)
check(all.count == 5, "full log has 5 entries")
check(all.map(\.publicNote) == ["now", "two-hours", "twenty-three-hours", "thirty-hours", "three-days"],
      "full log is newest → oldest: \(all.compactMap(\.publicNote))")

print("▸ Recent window: only the last 24 hours")
let recent = SecretHistoryStore.recent(now: now, defaults: defaults)
check(recent.map(\.publicNote) == ["now", "two-hours", "twenty-three-hours"],
      "recent() = \(recent.compactMap(\.publicNote))")
check(!recent.contains { $0.publicNote == "thirty-hours" }, "30-hour-old entry has aged out of recent")
check(SecretHistoryStore.load(defaults: defaults).contains { $0.publicNote == "thirty-hours" },
      "…but it is still in the full log (aging out never deletes)")

print("▸ Recent window boundary")
let boundary = entry("exactly-24h", ageHours: 24)
SecretHistoryStore.add(boundary, defaults: defaults)
check(!SecretHistoryStore.recent(now: now, defaults: defaults).contains { $0.id == boundary.id },
      "an entry exactly 24 h old is no longer recent")
let justInside = entry("23h59m", ageHours: 23.99)
SecretHistoryStore.add(justInside, defaults: defaults)
check(SecretHistoryStore.recent(now: now, defaults: defaults).contains { $0.id == justInside.id },
      "an entry 23 h 59 m old is still recent")

print("▸ Rolling clear: the same list an hour later")
let later = now.addingTimeInterval(1.5 * hour)
let recentLater = SecretHistoryStore.recent(now: later, defaults: defaults)
check(!recentLater.contains { $0.publicNote == "twenty-three-hours" },
      "23-hour-old entry drops out 1.5 h later without any write")
check(recentLater.first?.publicNote == "now", "newest is still first")

print("▸ nextRecentExpiry points at the oldest recent entry")
let expected = justInside.createdAt.addingTimeInterval(SecretHistoryStore.recentWindow)
let actual = SecretHistoryStore.nextRecentExpiry(now: now, defaults: defaults)
check(actual != nil && abs(actual!.timeIntervalSince(expected)) < 1,
      "nextRecentExpiry == oldest-recent.createdAt + 24 h")

print("▸ remove(ids:) and remove(id:)")
let idsToRemove = Set(SecretHistoryStore.load(defaults: defaults)
    .filter { ["three-days", "thirty-hours"].contains($0.publicNote ?? "") }
    .map(\.id))
SecretHistoryStore.remove(ids: idsToRemove, defaults: defaults)
check(SecretHistoryStore.load(defaults: defaults).count == 5, "two entries removed by id set")
SecretHistoryStore.remove(id: boundary.id, defaults: defaults)
check(!SecretHistoryStore.load(defaults: defaults).contains { $0.id == boundary.id }, "single entry removed by id")

print("▸ Cap at maxEntries keeps the newest")
SecretHistoryStore.clear(defaults: defaults)
for i in 0..<(SecretHistoryStore.maxEntries + 25) {
    SecretHistoryStore.add(entry("bulk-\(i)", ageHours: Double(i) / 60), defaults: defaults)
}
let capped = SecretHistoryStore.load(defaults: defaults)
check(capped.count == SecretHistoryStore.maxEntries, "count == maxEntries (\(SecretHistoryStore.maxEntries))")
check(capped.first?.publicNote == "bulk-0", "newest survives the cap")
check(!capped.contains { $0.publicNote == "bulk-\(SecretHistoryStore.maxEntries + 24)" }, "oldest is evicted")

print("▸ Legacy data: an unsorted array on disk still loads newest first")
// Simulates history written by older versions (array order == insertion order).
let legacy = [entry("old", ageHours: 10), entry("new", ageHours: 1), entry("mid", ageHours: 5)]
defaults.set(try! JSONEncoder().encode(legacy), forKey: SecretHistoryStore.key)
check(SecretHistoryStore.load(defaults: defaults).map(\.publicNote) == ["new", "mid", "old"],
      "load() sorts legacy data")

print("▸ clear() wipes everything")
SecretHistoryStore.clear(defaults: defaults)
check(SecretHistoryStore.load(defaults: defaults).isEmpty, "full log empty after clear")
check(SecretHistoryStore.recent(now: now, defaults: defaults).isEmpty, "recent empty after clear")

print("▸ Entry helpers")
let e = entry("helper", ageHours: 0, expiresInHours: 1)
check(e.displayLabel == "helper", "displayLabel prefers the public note")
check(SecretEntry(link: "x", receiptId: "r", secretType: "redirect").displayLabel == "Redirect", "displayLabel falls back to type name")
check(!e.isExpired(at: now), "not expired before expiresAt")
check(e.isExpired(at: now.addingTimeInterval(2 * hour)), "expired after expiresAt")

print("")
print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
