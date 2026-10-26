import Foundation

/// Outcome of merging one scan into the living record set.
struct MergeResult {
    var records: [WindowRecord] = []
    /// Windows the scan returned (each either matched a record or was added).
    var seen = 0
    var matched = 0
    var added = 0
    var dropped = 0
    var droppedByBundle: [String: Int] = [:]
    /// Each matched record as it was before this scan, with its live window.
    var matchedPairs: [(previous: WindowRecord, live: LiveWindow)] = []

    /// True when, among the records that were actually seen in this scan and
    /// used to live on an external display, more than half are now on the
    /// built-in display. That is what a merged pile-up looks like. Records
    /// that were not seen do not count either way.
    func looksLikePileUp(builtInUUID: String) -> Bool {
        let external = matchedPairs.filter {
            !$0.previous.isFullScreen && $0.previous.hasKnownDisplay && $0.previous.displayUUID != builtInUUID
        }
        guard !external.isEmpty else { return false }
        let onBuiltIn = external.filter { $0.live.displayUUID == builtInUUID }.count
        return onBuiltIn * 2 > external.count
    }
}

/// Merges a scan into the existing records instead of replacing them. With
/// "Displays have separate Spaces", the Accessibility window list only
/// contains windows on desktops that are currently visible, so a scan is
/// usually partial and must never erase what it cannot see.
enum SnapshotMerger {
    /// Unseen records are dropped after this long.
    static let staleAfter: TimeInterval = 7 * 24 * 3600
    /// When an app is visibly present (a title matched) but has fewer windows
    /// than records, its unseen records are dropped after this long.
    static let shrinkAfter: TimeInterval = 24 * 3600

    static func merge(
        existing: [WindowRecord],
        scanned: [LiveWindow],
        runningBundleIDs: Set<String>,
        now: Date,
        forgetUnseen: Bool
    ) -> MergeResult {
        var result = MergeResult()
        result.seen = scanned.count

        var updated = existing
        var matchedIndices = Set<Int>()
        var titleMatchedBundles = Set<String>()
        var newRecords: [WindowRecord] = []

        let existingByBundle = Dictionary(grouping: existing.indices, by: { existing[$0].bundleID })
        let scannedByBundle = Dictionary(grouping: scanned, by: { $0.bundleID })

        for (bundleID, windows) in scannedByBundle {
            var candidates = existingByBundle[bundleID] ?? []
            var remaining = windows

            func runPass(countsAsTitleMatch: Bool, _ predicate: (LiveWindow, WindowRecord) -> Bool) {
                var still: [LiveWindow] = []
                for window in remaining {
                    if let position = candidates.firstIndex(where: { predicate(window, existing[$0]) }) {
                        let index = candidates.remove(at: position)
                        result.matchedPairs.append((previous: existing[index], live: window))
                        updated[index] = refreshed(existing[index], from: window, now: now)
                        matchedIndices.insert(index)
                        result.matched += 1
                        if countsAsTitleMatch {
                            titleMatchedBundles.insert(bundleID)
                        }
                    } else {
                        still.append(window)
                    }
                }
                remaining = still
            }

            runPass(countsAsTitleMatch: true) { w, r in
                w.titleHash != nil && w.titleHash == r.titleHash
            }
            runPass(countsAsTitleMatch: true) { w, r in
                w.stableTitleHash != nil && w.stableTitleHash == r.stableTitleHash
            }
            // Index fallback only within the same display, so a record from an
            // external display is never assigned to a laptop window mid pile-up.
            runPass(countsAsTitleMatch: false) { w, r in
                guard w.index == r.index else { return false }
                if r.hasKnownDisplay && w.displayUUID != WindowRecord.unknownDisplay {
                    return w.displayUUID == r.displayUUID
                }
                return true
            }

            for window in remaining {
                var record = window.record
                record.lastSeen = now
                record.seenCount = 1
                newRecords.append(record)
                result.added += 1
            }
        }

        var kept: [WindowRecord] = []
        for index in existing.indices {
            let record = updated[index]
            if matchedIndices.contains(index) {
                kept.append(record)
                continue
            }
            let bundleID = record.bundleID
            let unseenFor = now.timeIntervalSince(record.lastSeen)
            let appGone = !runningBundleIDs.contains(bundleID)
            let stale = unseenFor > staleAfter
            let shrunk = titleMatchedBundles.contains(bundleID)
                && (scannedByBundle[bundleID]?.count ?? 0) < (existingByBundle[bundleID]?.count ?? 0)
                && unseenFor > shrinkAfter

            if forgetUnseen || appGone || stale || shrunk {
                result.dropped += 1
                result.droppedByBundle[bundleID, default: 0] += 1
            } else {
                kept.append(record)
            }
        }

        result.records = kept + newRecords
        return result
    }

    private static func refreshed(_ record: WindowRecord, from window: LiveWindow, now: Date) -> WindowRecord {
        var updated = record
        let live = window.record
        updated.index = live.index
        updated.displayUUID = live.displayUUID
        updated.offsetX = live.offsetX
        updated.offsetY = live.offsetY
        updated.width = live.width
        updated.height = live.height
        updated.x = live.x
        updated.y = live.y
        updated.isFullScreen = live.isFullScreen
        updated.titleHash = live.titleHash
        updated.stableTitleHash = live.stableTitleHash
        updated.lastSeen = now
        updated.seenCount += 1
        return updated
    }
}
