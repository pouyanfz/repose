import AppKit
import os

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // Timing
    private let debounceInterval: TimeInterval = 2        // quiet time after a screen change
    private let stableInterval: TimeInterval = 30         // layout must be this old before autosaving
    private let coalesceInterval: TimeInterval = 1        // wait after the last window event before saving
    private let safetyPollInterval: TimeInterval = 60     // periodic scan in case an app drops events
    private let trustPollInterval: TimeInterval = 2       // how often to check for a fresh Accessibility grant
    private let unlockSettleDelay: TimeInterval = 3       // wait after unlock before restoring
    private let protectionGrace: TimeInterval = 180       // autosave pause after a change, unless a restore verifies
    private let readinessRetryDelays: [TimeInterval] = [2, 4, 8, 16, 32, 60]
    private let secondPassDelay: TimeInterval = 3         // after the first pass
    private let thirdPassDelay: TimeInterval = 5          // after the second pass (about 8 s total)

    private static let autoRestoreKey = "autoRestoreEnabled"

    private let log = Logger(subsystem: Log.subsystem, category: "app")
    private let store = SnapshotStore()
    private var observer: WindowObserver!

    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem!
    private var permissionLine: NSMenuItem!
    private var guardLine: NSMenuItem!
    private var scanLine: NSMenuItem!
    private var autoRestoreItem: NSMenuItem!
    private var historyMenu: NSMenu!

    /// Result of the most recent merge, for the "Last scan saw N of M" line.
    private var lastScanSeen: Int?
    private var lastScanKnown: Int?

    private var lastChangeAt = Date()
    private var currentLayout: LayoutIdentity?
    private var pendingSettle: DispatchWorkItem?
    private var pendingSnapshot: DispatchWorkItem?
    private var pendingUnlock: DispatchWorkItem?
    private var safetyTimer: Timer?
    private var trustTimer: Timer?
    private var lastSavedAt: Date?

    // Lock and wake state
    private var isLocked = false
    private var layoutChangedWhileLocked = false

    // Protected state: autosave is paused for this layout until a restore
    // verifies, a manual save happens, or the grace period passes quietly.
    private var protectedLayoutID: String?
    private var protectedSince = Date.distantPast

    /// Incremented to cancel any restore sequence still scheduled.
    private var restoreGeneration = 0

    private var autoRestore: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoRestoreKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoRestoreKey) }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.autoRestoreKey: true])

        let trusted = AX.requestTrust()
        log.notice("Launched. Accessibility trusted: \(trusted, privacy: .public)")

        currentLayout = LayoutIdentity.current()
        if let layout = currentLayout {
            log.notice("Current layout: \(layout.displayCount, privacy: .public) display(s), id \(layout.id.prefix(12), privacy: .public), \(layout.arrangement, privacy: .public)")
        }

        buildMenu()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenLocked),
                                name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenUnlocked),
                                name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(didWake),
                              name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screenLocked),
                              name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screenUnlocked),
                              name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        observer = WindowObserver { [weak self] in
            self?.requestSnapshot()
        }
        observer.start()

        let safety = Timer(timeInterval: safetyPollInterval, repeats: true) { [weak self] _ in
            self?.safetyTick()
        }
        RunLoop.main.add(safety, forMode: .common)
        safetyTimer = safety

        if trusted {
            requestSnapshot()
        } else {
            startTrustWatcher()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        safetyTimer?.invalidate()
        trustTimer?.invalidate()
        pendingSettle?.cancel()
        pendingSnapshot?.cancel()
        pendingUnlock?.cancel()
        restoreGeneration += 1
        observer?.stop()
    }

    /// Polls the trust state briefly after launch (or after a failed action) so
    /// observers get installed the moment the user flips the switch.
    private func startTrustWatcher() {
        guard trustTimer == nil else { return }
        let timer = Timer(timeInterval: trustPollInterval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard AX.isTrusted() else { return }
            timer.invalidate()
            self.trustTimer = nil
            self.log.notice("Accessibility granted")
            self.observer.sync()
            self.requestSnapshot()
        }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    // MARK: - Menu

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Repose")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Repose: remembers window layouts per monitor setup"
        }

        let menu = NSMenu()
        menu.delegate = self

        statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        permissionLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        permissionLine.isEnabled = false
        menu.addItem(permissionLine)

        guardLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        guardLine.isEnabled = false
        menu.addItem(guardLine)

        scanLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        scanLine.isEnabled = false
        menu.addItem(scanLine)

        menu.addItem(.separator())

        let save = NSMenuItem(title: "Save Layout Now", action: #selector(saveNow), keyEquivalent: "")
        save.target = self
        menu.addItem(save)

        let forget = NSMenuItem(title: "Forget Unseen Windows", action: #selector(forgetUnseen), keyEquivalent: "")
        forget.target = self
        forget.toolTip = "Drop remembered windows that the current scan cannot see. Use after deliberately closing windows."
        menu.addItem(forget)

        let restore = NSMenuItem(title: "Restore Layout Now", action: #selector(restoreNow), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)

        let historyItem = NSMenuItem(title: "Restore Previous Snapshot", action: nil, keyEquivalent: "")
        historyMenu = NSMenu(title: "Restore Previous Snapshot")
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        autoRestoreItem = NSMenuItem(title: "Auto-restore", action: #selector(toggleAutoRestore), keyEquivalent: "")
        autoRestoreItem.target = self
        menu.addItem(autoRestoreItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Repose", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        refreshMenuState()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenuState()
    }

    private func refreshMenuState() {
        autoRestoreItem.state = autoRestore ? .on : .off

        let layout = LayoutIdentity.current()
        let count = layout?.displayCount ?? 0
        var text = "\(count) display\(count == 1 ? "" : "s")"
        let history = layout.map { store.history(layoutID: $0.id) } ?? []
        if history.isEmpty {
            text += ", no snapshot yet"
        } else {
            text += ", \(history.count) snapshot\(history.count == 1 ? "" : "s") on disk"
        }
        if let saved = lastSavedAt {
            text += " (saved \(Self.timeFormatter.string(from: saved)))"
        }
        statusLine.title = text

        if AX.isTrusted() {
            let watched = observer?.observedAppCount ?? 0
            permissionLine.title = "Accessibility: granted, watching \(watched) app\(watched == 1 ? "" : "s")"
        } else {
            permissionLine.title = "Accessibility: not granted"
        }

        if isLocked {
            guardLine.title = "Autosave: paused (screen locked)"
        } else if let layout = layout, isProtected(layoutID: layout.id) {
            let left = Int((protectionGrace - Date().timeIntervalSince(protectedSince)).rounded(.up))
            guardLine.title = "Autosave: paused, guarding last good snapshot (\(max(left, 0)) s left)"
        } else {
            guardLine.title = "Autosave: active"
        }

        if let seen = lastScanSeen, let known = lastScanKnown {
            scanLine.title = "Last scan saw \(seen) of \(known) known window\(known == 1 ? "" : "s")"
        } else {
            scanLine.title = "No scan yet"
        }

        historyMenu.removeAllItems()
        if history.isEmpty {
            let none = NSMenuItem(title: "No snapshots for this layout", action: nil, keyEquivalent: "")
            none.isEnabled = false
            historyMenu.addItem(none)
        } else {
            let labels = layout?.displayLabels() ?? [:]
            for (position, entry) in history.enumerated() {
                var title = "\(Self.historyFormatter.string(from: entry.snapshot.savedAt)): \(Self.describe(entry.snapshot.windows, labels: labels))"
                if position == 0 { title += " (current)" }
                let item = NSMenuItem(title: title, action: #selector(restorePrevious(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.url
                historyMenu.addItem(item)
            }
        }
    }

    /// "13 windows: 7 laptop, 1 left, 5 right"
    private static func describe(_ windows: [WindowRecord], labels: [String: String]) -> String {
        let total = windows.count
        var counts: [String: Int] = [:]
        for window in windows {
            let label = labels[window.displayUUID] ?? (window.hasKnownDisplay ? "elsewhere" : "unknown")
            counts[label, default: 0] += 1
        }
        let order = ["laptop", "left", "above", "right", "below"]
        let sortedLabels = counts.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? order.count
            let ib = order.firstIndex(of: b) ?? order.count
            return ia != ib ? ia < ib : a < b
        }
        let parts = sortedLabels.map { "\(counts[$0]!) \($0)" }
        return "\(total) window\(total == 1 ? "" : "s"): \(parts.joined(separator: ", "))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let historyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium   // includes seconds
        formatter.dateStyle = .medium
        return formatter
    }()

    // MARK: - Actions

    @objc private func saveNow() {
        guard AX.isTrusted() else {
            log.notice("Save requested but Accessibility is not granted")
            AX.requestTrust()
            startTrustWatcher()
            return
        }
        if Date().timeIntervalSince(lastChangeAt) < debounceInterval {
            log.notice("Save requested during a screen change, ignored")
            return
        }
        takeSnapshot(force: true, forgetUnseen: false)
    }

    @objc private func forgetUnseen() {
        guard AX.isTrusted() else {
            AX.requestTrust()
            startTrustWatcher()
            return
        }
        if Date().timeIntervalSince(lastChangeAt) < debounceInterval {
            log.notice("Forget requested during a screen change, ignored")
            return
        }
        takeSnapshot(force: true, forgetUnseen: true)
    }

    @objc private func restoreNow() {
        beginRestoreSequence(reason: "manual", snapshot: nil)
    }

    @objc private func restorePrevious(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let layout = LayoutIdentity.current(),
              let entry = store.history(layoutID: layout.id).first(where: { $0.url == url }) else {
            log.notice("Previous snapshot no longer available")
            return
        }
        // Promote: the chosen records become the newest entry so the autosave
        // guard protects them and the next layout change restores them.
        let now = Date()
        let promoted = LayoutSnapshot(layout: layout, savedAt: now, windows: entry.snapshot.windows, updatedAt: now)
        if store.persist(records: promoted.windows, layout: layout, now: now) != nil {
            lastSavedAt = now
            log.notice("Promoted snapshot from \(Self.historyFormatter.string(from: entry.snapshot.savedAt), privacy: .public) with \(promoted.windows.count, privacy: .public) window(s) to current")
        }
        protect(layoutID: layout.id, reason: "previous snapshot chosen")
        beginRestoreSequence(reason: "previous snapshot", snapshot: promoted)
    }

    @objc private func toggleAutoRestore() {
        autoRestore.toggle()
        log.notice("Auto-restore \(self.autoRestore ? "on" : "off", privacy: .public)")
        refreshMenuState()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startTrustWatcher()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Lock, unlock, wake

    @objc private func screenLocked() {
        guard !isLocked else { return }
        isLocked = true
        log.notice("Screen locked: restore and autosave on hold")
        pendingSnapshot?.cancel()
        pendingSnapshot = nil
        pendingUnlock?.cancel()
        pendingUnlock = nil
        restoreGeneration += 1
    }

    @objc private func screenUnlocked() {
        guard isLocked else { return }
        isLocked = false
        lastChangeAt = Date()
        if let layout = currentLayout {
            protect(layoutID: layout.id, reason: "unlock")
        }
        log.notice("Screen unlocked, settling for \(Int(self.unlockSettleDelay), privacy: .public) s")

        pendingUnlock?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingUnlock = nil
            if self.layoutChangedWhileLocked {
                self.layoutChangedWhileLocked = false
                self.currentLayout = LayoutIdentity.current()
                if self.autoRestore {
                    self.beginRestoreSequence(reason: "unlock after layout change", snapshot: nil)
                } else {
                    self.log.notice("Layout changed while locked, auto-restore is off")
                }
            }
            self.requestSnapshot()
        }
        pendingUnlock = work
        DispatchQueue.main.asyncAfter(deadline: .now() + unlockSettleDelay, execute: work)
    }

    @objc private func didWake() {
        lastChangeAt = Date()
        if let layout = currentLayout {
            protect(layoutID: layout.id, reason: "wake")
        }
        log.notice("Woke from sleep")
        // Display changes that come with waking arrive as screen parameter
        // notifications and are handled there, deferred while locked.
    }

    // MARK: - Protected state

    private func protect(layoutID: String, reason: String) {
        let wasProtected = isProtected(layoutID: layoutID)
        protectedLayoutID = layoutID
        protectedSince = Date()
        if !wasProtected {
            log.notice("Autosave paused for layout \(layoutID.prefix(12), privacy: .public) (\(reason, privacy: .public))")
        }
    }

    private func clearProtection(reason: String) {
        guard protectedLayoutID != nil else { return }
        log.notice("Autosave resumed (\(reason, privacy: .public))")
        protectedLayoutID = nil
        protectedSince = .distantPast
    }

    private func isProtected(layoutID: String) -> Bool {
        protectedLayoutID == layoutID && Date().timeIntervalSince(protectedSince) < protectionGrace
    }

    // MARK: - Screen changes

    @objc private func screenParametersChanged() {
        lastChangeAt = Date()
        if let layout = currentLayout {
            protect(layoutID: layout.id, reason: "screen change")
        }
        pendingSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.layoutSettled()
        }
        pendingSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func layoutSettled() {
        pendingSettle = nil
        guard let layout = LayoutIdentity.current() else { return }
        let previousID = currentLayout?.id
        currentLayout = layout
        protect(layoutID: layout.id, reason: "layout settled")

        // Whatever happens next, capture this layout once it is allowed again.
        requestSnapshot()

        guard layout.id != previousID else {
            log.notice("Screen parameters changed, same displays: \(layout.arrangement, privacy: .public)")
            return
        }

        let hasSnapshot = store.latest(layoutID: layout.id) != nil
        log.notice("Layout changed: \(layout.displayCount, privacy: .public) display(s), id \(layout.id.prefix(12), privacy: .public), snapshot: \(hasSnapshot, privacy: .public), \(layout.arrangement, privacy: .public)")

        guard hasSnapshot else { return }
        if isLocked {
            layoutChangedWhileLocked = true
            log.notice("Screen is locked, restore deferred until unlock")
            return
        }
        guard autoRestore else { return }
        beginRestoreSequence(reason: "layout appeared", snapshot: nil)
    }

    // MARK: - Restore sequence

    /// Starts a fresh restore sequence, cancelling any earlier one. The sequence
    /// waits for apps to be ready (with growing delays), then runs up to three
    /// verified passes.
    private func beginRestoreSequence(reason: String, snapshot: LayoutSnapshot?) {
        restoreGeneration += 1
        attemptRestore(generation: restoreGeneration, reason: reason, snapshot: snapshot, retryIndex: 0)
    }

    private func attemptRestore(generation: Int, reason: String, snapshot: LayoutSnapshot?, retryIndex: Int) {
        guard generation == restoreGeneration else { return }
        if isLocked {
            layoutChangedWhileLocked = true
            log.notice("Restore (\(reason, privacy: .public)) deferred: screen locked")
            return
        }
        guard AX.isTrusted() else {
            log.notice("Restore (\(reason, privacy: .public)) skipped: Accessibility not granted")
            AX.requestTrust()
            startTrustWatcher()
            return
        }
        guard let layout = LayoutIdentity.current() else { return }
        guard let snapshot = snapshot ?? store.latest(layoutID: layout.id) else {
            log.notice("Restore (\(reason, privacy: .public)): no snapshot for this layout")
            return
        }

        let live = WindowScanner.scan(layout: layout)
        let readiness = Restorer.readiness(saved: snapshot.windows, live: live)
        guard readiness.isReady else {
            if retryIndex < readinessRetryDelays.count {
                let delay = readinessRetryDelays[retryIndex]
                log.notice("Restore (\(reason, privacy: .public)) waiting: \(readiness.appsWithWindows, privacy: .public) of \(readiness.savedApps, privacy: .public) saved apps have windows, \(readiness.liveWindows, privacy: .public) live window(s). Retry in \(Int(delay), privacy: .public) s")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.attemptRestore(generation: generation, reason: reason, snapshot: snapshot, retryIndex: retryIndex + 1)
                }
            } else {
                log.notice("Restore (\(reason, privacy: .public)) gave up: apps never became ready")
            }
            return
        }

        runPass(generation: generation, reason: reason, snapshot: snapshot, layout: layout, live: live, pass: 1)
    }

    private func runPass(generation: Int, reason: String, snapshot: LayoutSnapshot, layout: LayoutIdentity, live: [LiveWindow]?, pass: Int) {
        guard generation == restoreGeneration, !isLocked else { return }
        guard let current = LayoutIdentity.current(), current.id == layout.id else {
            log.notice("Restore (\(reason, privacy: .public)) pass \(pass, privacy: .public) abandoned: layout changed")
            return
        }

        let windows = live ?? WindowScanner.scan(layout: current)
        let report = Restorer.restore(saved: snapshot.windows, live: windows, layout: current)
        logReport(report, reason: reason, pass: pass)

        if report.isVerifiedSuccess {
            clearProtection(reason: "restore verified on pass \(pass)")
            requestSnapshot()
            return
        }

        switch pass {
        case 1:
            DispatchQueue.main.asyncAfter(deadline: .now() + secondPassDelay) { [weak self] in
                self?.runPass(generation: generation, reason: reason, snapshot: snapshot, layout: layout, live: nil, pass: 2)
            }
        case 2:
            DispatchQueue.main.asyncAfter(deadline: .now() + thirdPassDelay) { [weak self] in
                self?.runPass(generation: generation, reason: reason, snapshot: snapshot, layout: layout, live: nil, pass: 3)
            }
        default:
            log.notice("Restore (\(reason, privacy: .public)) not fully verified after 3 passes. Autosave stays paused until the grace period ends or you choose Save Layout Now")
        }
    }

    private func logReport(_ report: RestoreReport, reason: String, pass: Int) {
        log.notice("Restore (\(reason, privacy: .public)) pass \(pass, privacy: .public): \(report.summary, privacy: .public)")
        for (app, count) in report.verified.sorted(by: { $0.key < $1.key }) {
            log.notice("  verified \(count, privacy: .public): \(app, privacy: .public)")
        }
        for (app, count) in report.wrongSize.sorted(by: { $0.key < $1.key }) {
            log.notice("  wrong size \(count, privacy: .public): \(app, privacy: .public)")
        }
        for (app, count) in report.refused.sorted(by: { $0.key < $1.key }) {
            log.notice("  refused \(count, privacy: .public): \(app, privacy: .public)")
        }
        for (app, count) in report.unmatched.sorted(by: { $0.key < $1.key }) {
            log.notice("  unmatched \(count, privacy: .public): \(app, privacy: .public)")
        }
    }

    // MARK: - Snapshot scheduling

    /// Seconds until an autosave is allowed, or nil when it is allowed now.
    /// Returns `.infinity` while locked (unlock schedules a new request).
    private func autosaveDelay(for layoutID: String) -> TimeInterval? {
        if isLocked { return .infinity }
        if pendingSettle != nil { return debounceInterval }
        let sinceChange = Date().timeIntervalSince(lastChangeAt)
        if sinceChange < stableInterval { return stableInterval - sinceChange }
        if isProtected(layoutID: layoutID) {
            return protectionGrace - Date().timeIntervalSince(protectedSince)
        }
        return nil
    }

    /// Called for every window event and after layout changes. Coalesces bursts
    /// of events into one scan, and defers until autosave is allowed.
    private func requestSnapshot() {
        pendingSnapshot?.cancel()
        guard let layoutID = currentLayout?.id else { return }
        let hold = autosaveDelay(for: layoutID) ?? 0
        guard hold.isFinite else { return }
        let delay = max(coalesceInterval, hold + 0.5)
        let work = DispatchWorkItem { [weak self] in
            self?.performRequestedSnapshot()
        }
        pendingSnapshot = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performRequestedSnapshot() {
        pendingSnapshot = nil
        guard AX.isTrusted(), let layoutID = currentLayout?.id else { return }
        if autosaveDelay(for: layoutID) != nil {
            // Something happened in the meantime; wait again.
            requestSnapshot()
            return
        }
        takeSnapshot(force: false, forgetUnseen: false)
    }

    /// Slow periodic pass: re-syncs observers (apps that dropped events, apps
    /// that were not ready when they launched) and scans once as a safety net.
    private func safetyTick() {
        guard AX.isTrusted() else { return }
        observer.sync()
        guard let layoutID = currentLayout?.id, autosaveDelay(for: layoutID) == nil else { return }
        takeSnapshot(force: false, forgetUnseen: false)
    }

    /// Scans, merges the scan into the layout's living record set, and stores
    /// the result. A scan only ever updates what it can see; records for
    /// windows on hidden desktops keep their last known frame.
    private func takeSnapshot(force: Bool, forgetUnseen: Bool) {
        guard let before = LayoutIdentity.current() else { return }
        guard before.id == currentLayout?.id else {
            // A screen change notification has not arrived yet; wait for it.
            return
        }

        let live = WindowScanner.scan(layout: before)

        guard let after = LayoutIdentity.current(), after == before else {
            log.notice("Layout changed during scan, snapshot discarded")
            return
        }

        let now = Date()
        let existing = store.latest(layoutID: before.id)?.windows ?? []
        let running = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleIdentifier })
        let merge = SnapshotMerger.merge(
            existing: existing, scanned: live, runningBundleIDs: running, now: now, forgetUnseen: forgetUnseen
        )
        lastScanSeen = merge.seen
        lastScanKnown = merge.records.count

        guard !merge.records.isEmpty else {
            if force { log.notice("No windows found, nothing saved") }
            return
        }

        if !force, before.displayCount > 1, let builtIn = before.builtInDisplay,
           merge.looksLikePileUp(builtInUUID: builtIn.uuid) {
            log.notice("Autosave refused: most windows seen in this scan that belong on external displays are on the built-in display. Use Save Layout Now if this is intended")
            return
        }

        guard let outcome = store.persist(records: merge.records, layout: before, now: now) else { return }
        lastSavedAt = now

        let kind = force ? (forgetUnseen ? "Forget unseen" : "Manual save") : "Autosave"
        let detail = "saw \(merge.seen), matched \(merge.matched), added \(merge.added), dropped \(merge.dropped), known \(merge.records.count)"
        switch outcome {
        case .updatedLatest:
            if merge.added > 0 || merge.dropped > 0 || force {
                log.notice("\(kind, privacy: .public): \(detail, privacy: .public); refreshed current entry")
            } else {
                log.info("\(kind, privacy: .public): \(detail, privacy: .public); refreshed current entry")
            }
        case .promoted(let from):
            log.notice("\(kind, privacy: .public): \(detail, privacy: .public); arrangement matches entry from \(Self.historyFormatter.string(from: from), privacy: .public), promoted to current")
        case .newEntry(let total):
            log.notice("\(kind, privacy: .public): \(detail, privacy: .public); new arrangement, history now \(total, privacy: .public) of \(SnapshotStore.historyLimit, privacy: .public)")
        }
        for (bundleID, count) in merge.droppedByBundle.sorted(by: { $0.key < $1.key }) {
            log.notice("  dropped \(count, privacy: .public): \(bundleID, privacy: .public)")
        }

        if force {
            clearProtection(reason: forgetUnseen ? "forget unseen" : "manual save")
        }
    }
}
