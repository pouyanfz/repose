import Foundation
import ApplicationServices

struct RestoreReport {
    /// Windows a move was attempted on, keyed by app name.
    var moved: [String: Int] = [:]
    /// Moved windows whose frame read back within tolerance.
    var verified: [String: Int] = [:]
    /// Moved windows that ended at the right position but the wrong size.
    var wrongSize: [String: Int] = [:]
    /// Moved windows that ended at the wrong position.
    var refused: [String: Int] = [:]
    /// Saved windows with no live match, keyed by app name
    /// (or bundle id when the app is not running).
    var unmatched: [String: Int] = [:]
    var skippedFullScreen = 0
    var alreadyInPlace = 0
    /// Saved non-fullscreen windows that found a live match.
    var matched = 0
    /// Saved non-fullscreen windows in total.
    var savedCount = 0

    var movedTotal: Int { moved.values.reduce(0, +) }
    var verifiedTotal: Int { verified.values.reduce(0, +) }
    var wrongSizeTotal: Int { wrongSize.values.reduce(0, +) }
    var refusedTotal: Int { refused.values.reduce(0, +) }
    var unmatchedTotal: Int { unmatched.values.reduce(0, +) }

    /// True when every matched window is now within tolerance of its saved
    /// frame and at most 20 percent of the saved windows went unmatched.
    var isVerifiedSuccess: Bool {
        guard savedCount > 0 else { return false }
        let allInPlace = verifiedTotal + alreadyInPlace == matched
        let unmatchedOK = Double(unmatchedTotal) <= 0.2 * Double(savedCount)
        return allInPlace && unmatchedOK
    }

    var summary: String {
        "moved \(movedTotal), verified \(verifiedTotal), in place \(alreadyInPlace), wrong size \(wrongSizeTotal), refused \(refusedTotal), unmatched \(unmatchedTotal), fullscreen skipped \(skippedFullScreen)"
    }
}

struct ReadinessCheck {
    let isReady: Bool
    let savedApps: Int
    let appsWithWindows: Int
    let liveWindows: Int
}

enum MoveOutcome {
    case verified
    case wrongSize
    case wrongPosition
    case refused
}

enum Restorer {
    /// A window within this many points of its target on every edge is in place.
    static let tolerance: CGFloat = 4
    static let moveAttempts = 3
    static let retryDelay: TimeInterval = 0.25

    // MARK: - Target frames

    /// Absolute target frame for a saved window in the current layout: the
    /// saved offset applied to the display's current origin, clamped to fit.
    /// Missing displays fall back to the built-in one.
    static func targetFrame(for record: WindowRecord, in layout: LayoutIdentity) -> CGRect? {
        guard let display = layout.display(uuid: record.displayUUID) ?? layout.fallbackDisplay else {
            return nil
        }
        let bounds = display.bounds
        var width = min(record.width, bounds.width)
        var height = min(record.height, bounds.height)
        width = max(width, 1)
        height = max(height, 1)

        var x = bounds.origin.x + record.offsetX
        var y = bounds.origin.y + record.offsetY
        x = min(max(x, bounds.minX), bounds.maxX - width)
        y = min(max(y, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Matching

    struct Matching {
        var pairs: [(WindowRecord, LiveWindow)] = []
        var unmatched: [WindowRecord] = []
        var skippedFullScreen = 0
    }

    /// Per bundle id, in passes: full-title hash, then stable-part hash, then
    /// index within the app. Each pass only considers windows not matched by
    /// an earlier pass. Fullscreen windows on either side are left out.
    static func match(saved: [WindowRecord], live: [LiveWindow]) -> Matching {
        var result = Matching()
        let savedByBundle = Dictionary(grouping: saved, by: { $0.bundleID })
        let liveByBundle = Dictionary(grouping: live, by: { $0.bundleID })

        for (bundleID, savedWindows) in savedByBundle {
            var remaining = savedWindows.filter { !$0.isFullScreen }
            result.skippedFullScreen += savedWindows.count - remaining.count
            var available = (liveByBundle[bundleID] ?? []).filter { !$0.isFullScreen }

            result.pairs += matchPass(&remaining, &available) { s, l in
                s.titleHash != nil && s.titleHash == l.titleHash
            }
            result.pairs += matchPass(&remaining, &available) { s, l in
                s.stableTitleHash != nil && s.stableTitleHash == l.stableTitleHash
            }
            result.pairs += matchPass(&remaining, &available) { s, l in
                s.index == l.index
            }
            result.unmatched += remaining
        }
        return result
    }

    private static func matchPass(
        _ saved: inout [WindowRecord],
        _ available: inout [LiveWindow],
        where predicate: (WindowRecord, LiveWindow) -> Bool
    ) -> [(WindowRecord, LiveWindow)] {
        var pairs: [(WindowRecord, LiveWindow)] = []
        var stillUnmatched: [WindowRecord] = []
        for record in saved {
            if let idx = available.firstIndex(where: { predicate(record, $0) }) {
                pairs.append((record, available.remove(at: idx)))
            } else {
                stillUnmatched.append(record)
            }
        }
        saved = stillUnmatched
        return pairs
    }

    // MARK: - Checks

    /// Apps are "ready" when there is at least one live window and at least
    /// half of the apps in the snapshot have any window at all. Right after
    /// wake or unlock apps often report no windows for a while.
    static func readiness(saved: [WindowRecord], live: [LiveWindow]) -> ReadinessCheck {
        let savedApps = Set(saved.map { $0.bundleID })
        let liveApps = Set(live.map { $0.bundleID })
        let withWindows = savedApps.intersection(liveApps).count
        let ready = !live.isEmpty && (savedApps.isEmpty || withWindows * 2 >= savedApps.count)
        return ReadinessCheck(isReady: ready, savedApps: savedApps.count, appsWithWindows: withWindows, liveWindows: live.count)
    }

    // MARK: - Restore

    static func restore(saved: [WindowRecord], live: [LiveWindow], layout: LayoutIdentity) -> RestoreReport {
        var report = RestoreReport()
        report.savedCount = saved.filter { !$0.isFullScreen }.count

        let matching = match(saved: saved, live: live)
        report.skippedFullScreen = matching.skippedFullScreen
        report.matched = matching.pairs.count

        let liveNames = Dictionary(live.map { ($0.bundleID, $0.appName) }, uniquingKeysWith: { a, _ in a })
        for record in matching.unmatched {
            let name = liveNames[record.bundleID] ?? record.bundleID
            report.unmatched[name, default: 0] += 1
        }

        for (record, window) in matching.pairs {
            guard let target = targetFrame(for: record, in: layout) else { continue }
            if isClose(window.frame, target) {
                report.alreadyInPlace += 1
                continue
            }
            report.moved[window.appName, default: 0] += 1
            switch move(window, to: target) {
            case .verified:
                report.verified[window.appName, default: 0] += 1
            case .wrongSize:
                report.wrongSize[window.appName, default: 0] += 1
            case .wrongPosition, .refused:
                report.refused[window.appName, default: 0] += 1
            }
        }
        return report
    }

    static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        isClose(a.origin, b.origin) && isClose(a.size, b.size)
    }

    static func isClose(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    static func isClose(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Size, position, size, then read back. Apps that clamp the first request
    /// (or apply it asynchronously, as Electron apps do) get up to three
    /// attempts a quarter second apart. The outcome reflects the final frame.
    private static func move(_ window: LiveWindow, to target: CGRect) -> MoveOutcome {
        var anyAccepted = false
        var lastPosition: CGPoint?
        var lastSize: CGSize?

        for attempt in 1...moveAttempts {
            if attempt > 1 {
                Thread.sleep(forTimeInterval: retryDelay)
            }
            let s1 = AX.setSize(window.element, target.size)
            let p1 = AX.setPosition(window.element, target.origin)
            let s2 = AX.setSize(window.element, target.size)
            anyAccepted = anyAccepted || s1 == .success || p1 == .success || s2 == .success

            lastPosition = AX.point(window.element, kAXPositionAttribute as String)
            lastSize = AX.size(window.element, kAXSizeAttribute as String)
            if let p = lastPosition, let s = lastSize, isClose(p, target.origin), isClose(s, target.size) {
                return .verified
            }
        }

        guard anyAccepted else { return .refused }
        if let p = lastPosition, isClose(p, target.origin) {
            return .wrongSize
        }
        return .wrongPosition
    }
}
