# Repose

A small macOS menu bar app that remembers where your windows are for each
set of monitors and moves them back when those monitors reconnect.

Typical case: a MacBook with two external displays. When you unplug, macOS
piles every window onto the laptop screen. When you plug back in, the external
desktops come back empty and you drag everything back by hand. Repose does the
dragging for you.

## What it does

- Watches for display changes (connect, disconnect, resolution change).
- Identifies a *layout* by the set of connected display UUIDs. Laptop only,
  laptop plus the two work monitors, and laptop plus a home monitor are three
  different layouts, each with its own saved history. How macOS happens to
  arrange the same monitors this time does not matter: window positions are
  stored relative to the display they are on, not as absolute coordinates.
- Listens for window events (moved, resized, created, title changed, focus
  changed) from every regular (Dock-visible) app through Accessibility
  observers. About a second after the last event, if autosave is allowed (see
  below), it scans all windows and merges the result into the layout's
  living record set (see "Why scans merge"). The last 5 meaningfully
  different arrangements per layout are kept.
- A safety scan runs every 60 seconds as well, in case an app drops events.
- When a layout with a saved snapshot appears and Auto-restore is on, waits
  2 seconds for macOS to finish its own shuffling, waits until apps actually
  report their windows, then moves each window back and reads the frame back
  to verify it. Up to three passes run, about 3 and 8 seconds apart, until
  everything verifies.

Fullscreen windows (the macOS kind that get their own Space) are never moved.
macOS already restores those on its own.

### Menu

- **Save Layout Now**: scans and merges immediately, no matter what the
  guards below say, and resumes autosave. Like every scan it only updates
  the windows it can see.
- **Forget Unseen Windows**: scans, merges, and drops every remembered
  window the scan could not see. Use it after you have deliberately closed
  windows and want them gone from the layout. Make sure the desktops you
  care about are visible on each display first, otherwise their windows are
  forgotten too.
- **Restore Layout Now**: runs the restore sequence against the newest
  entry for the current layout.
- **Restore Previous Snapshot**: submenu with up to 5 entries, each labelled
  with date, time to the second, and a per-display window count such as
  "13 windows: 7 laptop, 1 left, 5 right". Choosing one restores it and
  makes it the newest entry, so it becomes the state that future reconnects
  go back to.
- **Auto-restore**: toggle, on by default. Only affects restoring.
- **Open Accessibility Settings**, **Quit Repose**.

The top four lines show the display count and entry count, the Accessibility
state and how many apps are observed, whether autosave is active, paused
while locked, or paused to guard the last good snapshot, and how many of the
known windows the last scan actually saw. When that last line says something
like "Last scan saw 8 of 14 known windows", the other 6 are on desktops that
are not currently visible and keep their last known frames.

### Why scans merge instead of replace

With "Displays have separate Spaces" on, the Accessibility window list of an
app only contains windows on desktops that are currently visible on some
display. Swipe the right monitor to a fullscreen desktop and every window on
that monitor's normal desktop vanishes from the scan, even though it is still
open. An early version of Repose replaced the snapshot on every scan, so a
scan taken at that moment silently forgot Slack, Outlook and the terminals,
and a later reconnect had nothing to put back.

Scans therefore merge. Each layout has one living record set:

- A scanned window is matched to an existing record by bundle id plus full
  title hash, then bundle id plus stable title hash, then bundle id plus index
  among the records not yet matched in this scan. The index fallback only
  pairs a record and a window on the same display, so a record that belongs
  on an external display is never reassigned to a laptop window during a
  pile-up.
- Matched records get the window's current frame, display, title hashes and
  index, a new `lastSeen` time and a higher `seenCount`. New windows are
  appended. Records the scan did not see are left exactly as they were.
- A record is dropped only when its app is no longer running, when it has
  not been seen for 7 days, or when the app is clearly visible (a title
  matched) with fewer windows than records and the record has not been seen
  for 24 hours. Forget Unseen Windows drops every unseen record at once.

History is deduplicated by arrangement. Two entries count as different only
if the multiset of (bundle id, display, size rounded to 10 points, offset
rounded to 10 points) differs. Title, index, `lastSeen` and `seenCount`
changes refresh the newest entry in place. Returning to an arrangement that
matches an older entry promotes that entry to newest instead of adding one.


## Why only Accessibility is needed

With "Displays have separate Spaces" on, the desktop that is active on each
display after a reconnect is the one your windows belong to. Setting a
window's position through the Accessibility API is therefore enough to put it
back on the right display and the right desktop. No private Spaces APIs,
no Screen Recording, no Automation, no helper processes.

Be aware of what the Accessibility permission allows *in general*: an app
holding it can read the UI tree of any other app (window titles, text fields,
buttons), move and resize windows, press buttons and synthesize input. It is a
powerful grant. Repose uses a deliberately tiny slice of it, listed below, and
you can audit that in `Sources/Repose/Accessibility.swift`,
`Sources/Repose/WindowScanner.swift` and `Sources/Repose/WindowObserver.swift`.

## Exactly what Repose reads, stores, and never does

**Accessibility attributes read**, and nothing else:

| Attribute | Used for |
|---|---|
| `AXWindows` | listing an app's windows |
| `AXRole` | keeping only real windows (`AXWindow`) |
| `AXTitle` | hashed immediately, plain text discarded |
| `AXPosition`, `AXSize` | the frame to save, the attributes written on restore, and read back to verify |
| `AXFullScreen` | skipping fullscreen windows |

**Accessibility notifications observed**, per app, and nothing else:
`AXWindowMoved`, `AXWindowResized`, `AXWindowCreated`, `AXTitleChanged`,
`AXFocusedWindowChanged`. A notification only tells Repose "something
changed"; it then runs the same scan described above. No data about the
window travels with the event.

**System notifications observed**: screen parameters changed, screen locked
and unlocked, session became active and resigned active, did wake.

**Stored on disk**, under
`~/Library/Application Support/Repose/layouts/<layout id>/<timestamp>.json`,
newest 5 files per layout:

- A format version (currently 3).
- The layout: each display's UUID, frame, and whether it is the built-in one.
- The time the entry was created and the time it was last refreshed.
- Per window: bundle id, index within the app's window list, the UUID of the
  display it was on, its offset from that display's top-left corner, width,
  height, the absolute origin when last seen (informational), whether it was
  fullscreen, two SHA-256 hashes of the title, when a scan last saw it, and
  how many scans have seen it.

The layout id in the folder name is the SHA-256 of the sorted display UUIDs.
Format 2 entries (same folder layout, no `lastSeen`) are read as is; their
records are treated as last seen at the entry's save time. Files from the
first version of Repose (one flat file per layout, absolute coordinates,
frame-sensitive ids) are moved into `layouts/legacy/` on first launch and
not used; the move is logged. Delete that folder whenever you like.

**Title hashing.** Plain window titles are never written to disk or to the
log. For each window two hashes are kept, computed with CryptoKit SHA-256:

1. The full title.
2. The *stable part* of the title: the text after the last separator, where a
   separator is a hyphen or an em dash (U+2014) surrounded by spaces. For
   `main.swift - repose - Visual Studio Code` that is `Visual Studio Code`;
   for `Inbox - Google Chrome` it is `Google Chrome`. Terminal uses the em
   dash form. This survives tab switches and file changes.

An empty title produces no hashes, so empty-titled windows only match by index.

**Never done:**

- No networking code of any kind. The binary contains no URLSession, no
  sockets, nothing that opens a connection. The only URL in the source is the
  `x-apple.systempreferences:` link that opens System Settings.
- No analytics, no crash reporting, no telemetry.
- No reading of any Accessibility attribute other than the six in the table.
- No reading of window contents, text fields, or anything inside a window.

**Logged** (to the unified log, visible in Console.app): counts of windows
saved, moved, verified, wrong size, refused and unmatched, with app names
only, plus the display arrangement as UUID prefixes and frames. Example:
`Restore (layout appeared) pass 1: moved 6, verified 5, in place 9, wrong size 1, refused 0, unmatched 0, fullscreen skipped 2`.

Preferences: a single boolean, `autoRestoreEnabled`, in the app's defaults
domain `com.repose.app`.

## Build and run

Requirements: macOS 13 or later, Swift 5.9 or later (Xcode 15+ or the
Command Line Tools).

### From the command line (recommended)

```bash
./Scripts/build-app.sh
```

This runs `swift build -c release`, wraps the binary in `dist/Repose.app`
with an `Info.plist` that sets `LSUIElement` (no Dock icon), and ad-hoc signs
the bundle so macOS can attach the Accessibility grant to it. Then:

```bash
open dist/Repose.app
```

Running the bare executable with `swift run` also works for a quick test. The
app hides its Dock icon in code as well, so it behaves the same, but macOS
ties the Accessibility grant to that binary path, so prefer the bundle for
daily use.

### From Xcode

1. Open `Package.swift` in Xcode (File > Open, or `xed .` in the project
   folder). Xcode treats the package as a project with a `Repose` scheme.
2. Select the `Repose` scheme and My Mac, then Product > Run.
3. The first run triggers the Accessibility prompt (see below). Grant it, then
   stop and run again. Xcode-built binaries live in DerivedData and change on
   each build; if the grant stops working after a rebuild, remove Repose from
   the Accessibility list and add it again, or use the bundle script above.

Xcode is not required: the Command Line Tools are enough for the script.

### Replacing a running copy

1. Quit Repose from its menu bar icon.
2. Copy the new bundle over the old one, for example:
   ```bash
   rm -rf /Applications/Repose.app && cp -R dist/Repose.app /Applications/
   ```
3. Launch it and open the menu. If the second line says "not granted" even
   though the toggle in System Settings is on, the ad-hoc signature changed:
   remove Repose from Privacy & Security > Accessibility with the minus
   button and add it again with plus. The menu updates within 2 seconds.

## Grant Accessibility

On first launch Repose calls `AXIsProcessTrustedWithOptions` with the prompt
option, so macOS shows a dialog pointing at System Settings. If you dismissed
it:

1. Click the Repose menu bar icon and choose **Open Accessibility Settings**,
   or go to System Settings > Privacy & Security > Accessibility.
2. Click **+**, pick `Repose.app` wherever you placed it, and make sure its
   toggle is on.
3. Open the Repose menu again; the second line should read
   "Accessibility: granted". No restart is needed.


## Add to Login Items

1. Build the bundle with `./Scripts/build-app.sh` and move `dist/Repose.app`
   somewhere permanent, for example `/Applications/Repose.app`. (Moving the
   app after granting Accessibility requires granting it again.)
2. System Settings > General > Login Items & Extensions.
3. Under "Open at Login" click **+** and pick `Repose.app`.

Repose does not auto-restore at launch, only when a layout change is
detected while it is running. After logging in, use **Restore Layout Now** if
you need it.

## Project layout

```
Package.swift                      Swift Package manifest (executable target)
Sources/Repose/main.swift          App entry, sets accessory activation policy
Sources/Repose/AppController.swift Menu, timers, lock handling, autosave guard, restore sequence
Sources/Repose/Models.swift        LayoutIdentity (UUID set id), WindowRecord (relative frames), LayoutSnapshot
Sources/Repose/Hashing.swift       SHA-256 helpers and the stable-part rule
Sources/Repose/Accessibility.swift The six AX attributes the app touches
Sources/Repose/WindowScanner.swift Enumerates windows of regular apps and maps them to displays
Sources/Repose/WindowObserver.swift Per-app AX observers that trigger a save
Sources/Repose/Restorer.swift      Matching, target frame mapping, verified moves, readiness check
Sources/Repose/SnapshotMerger.swift Merges a scan into the living record set, pile-up check
Sources/Repose/SnapshotStore.swift Deduplicated snapshot history on disk, legacy migration
Resources/Info.plist               Bundle plist with LSUIElement
Scripts/build-app.sh               Release build plus .app bundle plus ad-hoc sign
```
