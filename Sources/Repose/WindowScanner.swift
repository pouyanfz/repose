import AppKit
import ApplicationServices

/// A window as seen right now, with a live handle for moving it.
struct LiveWindow {
    let element: AXUIElement
    let bundleID: String
    let appName: String
    let index: Int
    let frame: CGRect
    let displayUUID: String
    let offset: CGPoint
    let isFullScreen: Bool
    let titleHash: String?
    let stableTitleHash: String?

    var record: WindowRecord {
        WindowRecord(
            bundleID: bundleID,
            index: index,
            displayUUID: displayUUID,
            offsetX: offset.x,
            offsetY: offset.y,
            width: frame.size.width,
            height: frame.size.height,
            x: frame.origin.x,
            y: frame.origin.y,
            isFullScreen: isFullScreen,
            titleHash: titleHash,
            stableTitleHash: stableTitleHash,
            lastSeen: Date(),
            seenCount: 1
        )
    }
}

enum WindowScanner {
    /// Enumerates every window of every regular (Dock-visible) application and
    /// maps each one to the display it is on in `layout`.
    /// Titles are hashed immediately and the plain text is discarded.
    static func scan(layout: LayoutIdentity) -> [LiveWindow] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPID
        }

        var result: [LiveWindow] = []
        for app in apps {
            guard let bundleID = app.bundleIdentifier else { continue }
            let appName = app.localizedName ?? bundleID
            let appElement = AX.application(pid: app.processIdentifier)
            let windows = AX.windows(of: appElement)

            for (index, window) in windows.enumerated() {
                guard let role = AX.string(window, kAXRoleAttribute as String),
                      role == (kAXWindowRole as String) else { continue }
                guard let position = AX.point(window, kAXPositionAttribute as String),
                      let size = AX.size(window, kAXSizeAttribute as String) else { continue }

                let isFullScreen = AX.bool(window, AX.fullScreenAttribute) ?? false
                let title = AX.string(window, kAXTitleAttribute as String) ?? ""
                let (titleHash, stableHash) = Hashing.titleHashes(for: title)

                let frame = CGRect(origin: position, size: size)
                let display = layout.display(containing: frame)
                let displayUUID = display?.uuid ?? WindowRecord.unknownDisplay
                let origin = display?.bounds.origin ?? .zero
                let offset = CGPoint(x: frame.origin.x - origin.x, y: frame.origin.y - origin.y)

                result.append(LiveWindow(
                    element: window,
                    bundleID: bundleID,
                    appName: appName,
                    index: index,
                    frame: frame,
                    displayUUID: displayUUID,
                    offset: offset,
                    isFullScreen: isFullScreen,
                    titleHash: titleHash,
                    stableTitleHash: stableHash
                ))
            }
        }
        return result
    }
}
