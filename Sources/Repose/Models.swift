import Foundation
import CoreGraphics
import ColorSync // CGDisplayCreateUUIDFromDisplayID is declared in ColorSyncDevice.h

/// One connected display, identified by its hardware UUID, with its frame in
/// global (Core Graphics, top-left origin) coordinates.
struct DisplayInfo: Codable, Hashable {
    let uuid: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let isBuiltIn: Bool

    var bounds: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// The identity of a monitor layout. The id is derived from the sorted set of
/// display UUIDs only, so the same monitors are recognised regardless of how
/// macOS arranged them this time. Frames are kept for mapping window offsets.
struct LayoutIdentity: Codable, Hashable {
    let displays: [DisplayInfo]

    /// Filename-safe identifier: hash of the sorted UUID set.
    var id: String {
        Hashing.sha256Hex(displays.map { $0.uuid }.sorted().joined(separator: ";"))
    }

    /// Human-readable arrangement, for logs only.
    var arrangement: String {
        displays
            .map { "\($0.uuid.prefix(8)):\(Int($0.x)),\(Int($0.y)),\(Int($0.width))x\(Int($0.height))\($0.isBuiltIn ? " builtin" : "")" }
            .joined(separator: " | ")
    }

    var displayCount: Int { displays.count }

    var builtInDisplay: DisplayInfo? {
        displays.first { $0.isBuiltIn }
    }

    /// Where windows go when their saved display is not connected: the built-in
    /// display, else the display at the origin (the main one), else the first.
    var fallbackDisplay: DisplayInfo? {
        builtInDisplay
            ?? displays.first { $0.bounds.contains(CGPoint.zero) }
            ?? displays.first
    }

    func display(uuid: String) -> DisplayInfo? {
        displays.first { $0.uuid == uuid }
    }

    /// The display a window frame belongs to: largest overlap, else the one
    /// whose centre is nearest, else the fallback.
    func display(containing frame: CGRect) -> DisplayInfo? {
        var best: DisplayInfo?
        var bestArea: CGFloat = 0
        for display in displays {
            let overlap = display.bounds.intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = display
            }
        }
        if let best = best { return best }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.min { a, b in
            distance(center, CGPoint(x: a.bounds.midX, y: a.bounds.midY))
                < distance(center, CGPoint(x: b.bounds.midX, y: b.bounds.midY))
        } ?? fallbackDisplay
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Short human labels per display UUID: "laptop" for the built-in display,
    /// "left", "right", "above" or "below" relative to it, or the UUID prefix
    /// when two displays would get the same word.
    func displayLabels() -> [String: String] {
        var labels: [String: String] = [:]
        guard let builtIn = builtInDisplay else {
            for display in displays {
                labels[display.uuid] = String(display.uuid.prefix(8))
            }
            return labels
        }
        labels[builtIn.uuid] = "laptop"

        var byWord: [String: [String]] = [:]
        for display in displays where display.uuid != builtIn.uuid {
            let midX = display.bounds.midX
            let word: String
            if midX < builtIn.bounds.minX {
                word = "left"
            } else if midX > builtIn.bounds.maxX {
                word = "right"
            } else {
                word = display.bounds.midY < builtIn.bounds.midY ? "above" : "below"
            }
            byWord[word, default: []].append(display.uuid)
        }
        for (word, uuids) in byWord {
            if uuids.count == 1 {
                labels[uuids[0]] = word
            } else {
                for uuid in uuids {
                    labels[uuid] = String(uuid.prefix(8))
                }
            }
        }
        return labels
    }

    /// Enumerates the active displays and builds the current layout identity.
    static func current() -> LayoutIdentity? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return nil
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return nil
        }
        let displays = ids.prefix(Int(count)).map { id -> DisplayInfo in
            let bounds = CGDisplayBounds(id)
            return DisplayInfo(
                uuid: displayUUID(id),
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: bounds.size.width,
                height: bounds.size.height,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0
            )
        }
        .sorted { $0.uuid < $1.uuid }
        return LayoutIdentity(displays: displays)
    }

    private static func displayUUID(_ id: CGDirectDisplayID) -> String {
        if let ref = CGDisplayCreateUUIDFromDisplayID(id) {
            let uuid = ref.takeRetainedValue()
            return CFUUIDCreateString(nil, uuid) as String
        }
        // Fallback for displays that report no UUID (rare, virtual displays).
        return "display-\(id)"
    }
}

/// One window as stored on disk. No plain title is ever stored, only hashes.
/// Records live on across scans: a scan updates the ones it can see and leaves
/// the rest (windows on desktops that are not currently visible) untouched.
struct WindowRecord: Codable, Equatable {
    static let unknownDisplay = "unknown"

    let bundleID: String
    /// Position of the window inside its app's kAXWindows list when last seen.
    var index: Int
    /// UUID of the display the window was on when last seen.
    var displayUUID: String
    /// Window origin relative to that display's top-left corner, in points.
    var offsetX: Double
    var offsetY: Double
    var width: Double
    var height: Double
    /// Absolute origin when last seen. Informational only; restore uses the offset.
    var x: Double
    var y: Double
    var isFullScreen: Bool
    /// SHA-256 of the full window title, nil when the title was empty.
    var titleHash: String?
    /// SHA-256 of the stable part of the title (text after the last " - " or
    /// space, U+2014, space separator), nil when the title was empty.
    var stableTitleHash: String?
    /// When a scan last matched this record.
    var lastSeen: Date
    /// How many scans have matched this record.
    var seenCount: Int

    var size: CGSize {
        CGSize(width: width, height: height)
    }

    var hasKnownDisplay: Bool {
        displayUUID != Self.unknownDisplay
    }

    /// What counts as a meaningful difference between history entries: app,
    /// display, size and offset rounded to 10 points. Title hashes, index,
    /// lastSeen and seenCount are deliberately left out.
    var arrangementKey: String {
        func round10(_ value: Double) -> Int { Int((value / 10).rounded()) * 10 }
        return "\(bundleID)|\(displayUUID)|\(round10(width))x\(round10(height))|\(round10(offsetX)),\(round10(offsetY))"
    }
}

extension WindowRecord {
    private enum CodingKeys: String, CodingKey {
        case bundleID, index, displayUUID, offsetX, offsetY, width, height, x, y
        case isFullScreen, titleHash, stableTitleHash, lastSeen, seenCount
    }

    /// Format 2 files have no lastSeen or seenCount; the store fills lastSeen
    /// in from the file's save time after decoding.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        index = try c.decode(Int.self, forKey: .index)
        displayUUID = try c.decode(String.self, forKey: .displayUUID)
        offsetX = try c.decode(Double.self, forKey: .offsetX)
        offsetY = try c.decode(Double.self, forKey: .offsetY)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        isFullScreen = try c.decode(Bool.self, forKey: .isFullScreen)
        titleHash = try c.decodeIfPresent(String.self, forKey: .titleHash)
        stableTitleHash = try c.decodeIfPresent(String.self, forKey: .stableTitleHash)
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? .distantPast
        seenCount = try c.decodeIfPresent(Int.self, forKey: .seenCount) ?? 1
    }
}

/// Everything persisted for one layout: one living record set per entry.
struct LayoutSnapshot: Codable {
    static let currentFormatVersion = 3

    let formatVersion: Int
    let layout: LayoutIdentity
    /// When this entry was created (or re-established from an older entry).
    let savedAt: Date
    /// When the entry's records were last refreshed in place.
    let updatedAt: Date?
    let windows: [WindowRecord]

    init(layout: LayoutIdentity, savedAt: Date, windows: [WindowRecord], updatedAt: Date? = nil) {
        self.formatVersion = Self.currentFormatVersion
        self.layout = layout
        self.savedAt = savedAt
        self.updatedAt = updatedAt
        self.windows = windows
    }

    /// Multiset of arrangement keys, used to decide whether two entries differ.
    var arrangementSignature: [String] {
        windows.map { $0.arrangementKey }.sorted()
    }
}
