import Foundation
import os

/// One saved snapshot on disk.
struct SnapshotEntry {
    let url: URL
    let snapshot: LayoutSnapshot
}

enum PersistOutcome {
    /// The newest entry had the same arrangement; its records were refreshed in place.
    case updatedLatest
    /// An older entry had the same arrangement; it became the newest entry.
    case promoted(from: Date)
    /// A genuinely different arrangement; a new entry was written.
    case newEntry(total: Int)
}

/// Keeps the last few meaningfully different snapshots per layout under
/// ~/Library/Application Support/Repose/layouts/<layout id>/<timestamp>.json
final class SnapshotStore {
    static let historyLimit = 5

    private let log = Logger(subsystem: Log.subsystem, category: "store")
    let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        directory = base.appendingPathComponent("Repose/layouts", isDirectory: true)
        migrateLegacyFiles()
    }

    func layoutDirectory(for layoutID: String) -> URL {
        directory.appendingPathComponent(layoutID, isDirectory: true)
    }

    /// All readable snapshots for a layout, newest first.
    func history(layoutID: String) -> [SnapshotEntry] {
        let dir = layoutDirectory(for: layoutID)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                do {
                    let snapshot = try decoder.decode(LayoutSnapshot.self, from: data)
                    return SnapshotEntry(url: url, snapshot: Self.upgraded(snapshot))
                } catch {
                    log.error("Could not decode \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
    }

    func latest(layoutID: String) -> LayoutSnapshot? {
        history(layoutID: layoutID).first?.snapshot
    }

    /// Stores the merged record set. Entries are deduplicated by arrangement:
    /// the same arrangement refreshes the existing entry instead of adding one.
    func persist(records: [WindowRecord], layout: LayoutIdentity, now: Date) -> PersistOutcome? {
        let entries = history(layoutID: layout.id)
        let signature = LayoutSnapshot(layout: layout, savedAt: now, windows: records).arrangementSignature

        if let latest = entries.first, latest.snapshot.arrangementSignature == signature {
            let snapshot = LayoutSnapshot(layout: layout, savedAt: latest.snapshot.savedAt, windows: records, updatedAt: now)
            return write(snapshot, to: latest.url) ? .updatedLatest : nil
        }

        if let older = entries.dropFirst().first(where: { $0.snapshot.arrangementSignature == signature }) {
            let snapshot = LayoutSnapshot(layout: layout, savedAt: now, windows: records, updatedAt: now)
            let url = layoutDirectory(for: layout.id).appendingPathComponent(Self.fileName(for: now))
            guard write(snapshot, to: url) else { return nil }
            try? FileManager.default.removeItem(at: older.url)
            return .promoted(from: older.snapshot.savedAt)
        }

        let snapshot = LayoutSnapshot(layout: layout, savedAt: now, windows: records, updatedAt: now)
        let url = layoutDirectory(for: layout.id).appendingPathComponent(Self.fileName(for: now))
        guard write(snapshot, to: url) else { return nil }
        prune(layoutID: layout.id)
        return .newEntry(total: min(entries.count + 1, Self.historyLimit))
    }

    private func write(_ snapshot: LayoutSnapshot, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log.error("Could not write snapshot: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func prune(layoutID: String) {
        let dir = layoutDirectory(for: layoutID)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        let sorted = urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in sorted.dropFirst(Self.historyLimit) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Format 2 records carry no lastSeen; treat them as seen when the file
    /// was saved so they are not dropped as stale at the first merge.
    private static func upgraded(_ snapshot: LayoutSnapshot) -> LayoutSnapshot {
        guard snapshot.formatVersion < 3 else { return snapshot }
        let windows = snapshot.windows.map { record -> WindowRecord in
            var fixed = record
            if fixed.lastSeen == .distantPast {
                fixed.lastSeen = snapshot.savedAt
            }
            return fixed
        }
        return LayoutSnapshot(layout: snapshot.layout, savedAt: snapshot.savedAt, windows: windows, updatedAt: snapshot.updatedAt)
    }

    /// Timestamp names sort lexicographically in time order.
    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    private static func fileName(for date: Date) -> String {
        "\(fileNameFormatter.string(from: date)).json"
    }

    /// Format 1 stored one flat file per layout with absolute coordinates and a
    /// frame-sensitive id. Those files cannot be mapped to the new layout ids,
    /// so they are moved aside into `legacy/` rather than deleted.
    private func migrateLegacyFiles() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        let legacy = urls.filter { $0.pathExtension == "json" }
        guard !legacy.isEmpty else { return }

        let legacyDir = directory.appendingPathComponent("legacy", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
            for url in legacy {
                let target = legacyDir.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: url, to: target)
            }
            log.notice("Moved \(legacy.count, privacy: .public) format 1 snapshot file(s) to layouts/legacy. Layouts will be re-saved in the new format.")
        } catch {
            log.error("Could not move legacy snapshots: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum Log {
    static let subsystem = "com.repose.app"
}
