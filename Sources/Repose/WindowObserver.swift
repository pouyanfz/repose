import AppKit
import ApplicationServices
import os

/// Registers one AXObserver per regular (Dock-visible) app and calls `onEvent`
/// whenever a window moves, resizes, appears, changes title or gains focus.
/// Events are only a hint that something changed; the controller coalesces
/// them and runs the normal scan. No window data arrives through this path.
final class WindowObserver {
    private struct Entry {
        let observer: AXObserver
        let element: AXUIElement
        let appName: String
    }

    /// The complete list of Accessibility notifications the app listens for.
    static let notifications: [String] = [
        kAXWindowMovedNotification as String,
        kAXWindowResizedNotification as String,
        kAXWindowCreatedNotification as String,
        kAXTitleChangedNotification as String,
        kAXFocusedWindowChangedNotification as String,
    ]

    private let log = Logger(subsystem: Log.subsystem, category: "observer")
    private let onEvent: () -> Void
    private var entries: [pid_t: Entry] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []

    var observedAppCount: Int { entries.count }

    init(onEvent: @escaping () -> Void) {
        self.onEvent = onEvent
    }

    deinit {
        stop()
    }

    /// Starts watching app launches and quits, and observes the apps running now.
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // A freshly launched app may not answer Accessibility calls yet,
            // so try a couple of times.
            self?.sync()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.sync() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self?.sync() }
        })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sync()
        })
        sync()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach { center.removeObserver($0) }
        workspaceTokens.removeAll()
        for pid in Array(entries.keys) {
            remove(pid: pid)
        }
    }

    /// Adds observers for regular apps that have none yet and drops observers
    /// for apps that have quit. Safe to call often.
    func sync() {
        guard AX.isTrusted() else { return }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPID
        }
        let livePIDs = Set(apps.map { $0.processIdentifier })

        for pid in entries.keys where !livePIDs.contains(pid) {
            remove(pid: pid)
        }
        for app in apps where entries[app.processIdentifier] == nil {
            add(app)
        }
    }

    private func add(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appName = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"

        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let observer = created else {
            log.notice("Could not create observer for \(appName, privacy: .public)")
            return
        }

        let element = AX.application(pid: pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = 0
        for name in Self.notifications {
            if AXObserverAddNotification(observer, element, name as CFString, refcon) == .success {
                registered += 1
            }
        }
        guard registered > 0 else {
            // Usually the app is still starting up; the next sync() retries.
            log.debug("No notifications accepted yet by \(appName, privacy: .public)")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        entries[pid] = Entry(observer: observer, element: element, appName: appName)
        log.notice("Observing \(appName, privacy: .public) (\(registered, privacy: .public) of \(Self.notifications.count, privacy: .public) notifications)")
    }

    private func remove(pid: pid_t) {
        guard let entry = entries.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .commonModes)
        for name in Self.notifications {
            AXObserverRemoveNotification(entry.observer, entry.element, name as CFString)
        }
        log.notice("Stopped observing \(entry.appName, privacy: .public)")
    }

    fileprivate func handleEvent() {
        onEvent()
    }
}

/// C callback trampoline. The refcon is the unretained WindowObserver.
private let axObserverCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon = refcon else { return }
    let observer = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
    observer.handleEvent()
}
