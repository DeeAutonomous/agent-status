# Per-session menu-bar item redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace today's single-line `[icon] cwd-basename` per-session menu-bar item with a two-line, 180pt-wide layout showing `aiTitle` on top and a state-driven suffix (`idle` / `Bash npm test · 1m` / `3 tools · 2m` / `approve Bash · xcodebuild test`) below, plus a red pip overlay on the icon when any of the last 5 completed tools had `is_error`.

**Architecture:** A pure static builder `PerSessionStatusItem.rowData(from: snap, now:)` returns a small `Equatable` `RowData` value. `update(with:)` calls it on every snapshot ingest; the existing `RowData == lastRowData` short-circuit replaces the current per-field comparison, so redraws still fire only on meaningful state transitions. No new timer — sub-60s elapsed is suppressed and minute-bucketed text only changes at 60s boundaries, which the 1.3 Hz file-driven ingest lands within ~1s.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, AppKit (NSStatusItem), XCTest, XcodeGen.

**Spec:** [`docs/superpowers/specs/2026-05-11-per-session-menu-bar-item-redesign-design.md`](../specs/2026-05-11-per-session-menu-bar-item-redesign-design.md)

---

## File Structure

**Modify:**
- `AgentStatus/UI/PerSession/PerSessionStatusItem.swift` — main file. Add `RowData` private struct + `rowData(from:now:)` static builder; replace the `lastStatus/lastTitle/lastDim` triple with `lastRowData`; rewrite `update(with:)`; bump `itemWidth: 102 → 180`; replace `PerSessionLabel` body with two-line VStack + red pip overlay; drop the now-unused `shortTitle(for:)` helper.
- `README.md` — features bullet (small touch).

**Create:**
- `AgentStatusTests/PerSessionRowDataTests.swift` — pure-builder tests for every case in the spec's Testing table.

**Test command pattern (used in every task):**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/<TestClass> 2>&1 | tail -20
```

**XcodeGen note:** Whenever a task creates a new `.swift` file, run `xcodegen generate` before running the test command so the .xcodeproj picks it up. The `.xcodeproj` itself is gitignored — do NOT `git add AgentStatus.xcodeproj`.

---

### Task 1: Add `RowData` struct + `rowData(from:now:)` builder (failing tests first)

**Files:**
- Create: `AgentStatusTests/PerSessionRowDataTests.swift`
- Modify: `AgentStatus/UI/PerSession/PerSessionStatusItem.swift`

- [ ] **Step 1: Write the failing test file**

Create `AgentStatusTests/PerSessionRowDataTests.swift`:

```swift
import XCTest
@testable import AgentStatus

/// Pure-builder tests for PerSessionStatusItem.rowData(from:now:).
/// All cases use a pinned date so elapsed math is deterministic.
@MainActor
final class PerSessionRowDataTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 100_000)

    // MARK: - Title source

    func testTitleUsesAITitleWhenPresent() {
        var e = EnrichedSession.empty
        e.aiTitle = "Investigate flake"
        let snap = makeSnap(enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.title, "Investigate flake")
    }

    func testTitleFallsBackToCwdBasenameWhenAITitleNil() {
        let snap = makeSnap(cwd: URL(fileURLWithPath: "/Users/dee/repos/agent-status"))
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.title, "agent-status")
    }

    func testTitleFallsBackToCwdBasenameWhenAITitleEmpty() {
        var e = EnrichedSession.empty
        e.aiTitle = ""
        let snap = makeSnap(cwd: URL(fileURLWithPath: "/tmp/foo"), enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.title, "foo")
    }

    // MARK: - Bottom suffix grammar

    func testIdleBottomIsIdle() {
        let snap = makeSnap(status: .idle)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "idle")
    }

    func testSingleToolUnderOneMinuteShowsNameAndPreview() {
        var e = EnrichedSession.empty
        e.activeTools = [active(id: "1", name: "Bash", preview: "npm test", startedAt: t0.addingTimeInterval(-30))]
        let snap = makeSnap(status: .busy, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "Bash npm test")
    }

    func testSingleToolOverOneMinuteAppendsMinutes() {
        var e = EnrichedSession.empty
        e.activeTools = [active(id: "1", name: "Bash", preview: "npm test", startedAt: t0.addingTimeInterval(-90))]
        let snap = makeSnap(status: .busy, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "Bash npm test · 1m")
    }

    func testSingleToolEmptyPreviewShowsNameOnly() {
        var e = EnrichedSession.empty
        e.activeTools = [active(id: "1", name: "Bash", preview: "", startedAt: t0.addingTimeInterval(-30))]
        let snap = makeSnap(status: .busy, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "Bash")
    }

    func testThreeToolsUnderOneMinuteShowsCountOnly() {
        var e = EnrichedSession.empty
        e.activeTools = [
            active(id: "a", name: "Bash", preview: "one", startedAt: t0.addingTimeInterval(-35)),
            active(id: "b", name: "Bash", preview: "two", startedAt: t0.addingTimeInterval(-20)),
            active(id: "c", name: "Read", preview: "x",   startedAt: t0.addingTimeInterval(-10)),
        ]
        let snap = makeSnap(status: .busy, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "3 tools")
    }

    func testThreeToolsOverOneMinuteAppendsMinutesUsingEarliestStart() {
        // Earliest tool started 130s ago → bottom uses 2m.
        var e = EnrichedSession.empty
        e.activeTools = [
            active(id: "a", name: "Bash", preview: "one", startedAt: t0.addingTimeInterval(-130)),
            active(id: "b", name: "Bash", preview: "two", startedAt: t0.addingTimeInterval(-60)),
            active(id: "c", name: "Read", preview: "x",   startedAt: t0.addingTimeInterval(-10)),
        ]
        let snap = makeSnap(status: .busy, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "3 tools · 2m")
    }

    func testWaitingWithPendingPreviewIncludesPreview() {
        var e = EnrichedSession.empty
        e.activeTools = [active(id: "1", name: "Bash", preview: "xcodebuild test", startedAt: t0.addingTimeInterval(-5))]
        let snap = makeSnap(status: .waiting, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "approve Bash · xcodebuild test")
    }

    func testWaitingWithEmptyPreviewShowsApproveNameOnly() {
        var e = EnrichedSession.empty
        e.activeTools = [active(id: "1", name: "AskUserQuestion", preview: "", startedAt: t0.addingTimeInterval(-2))]
        let snap = makeSnap(status: .waiting, enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "approve AskUserQuestion")
    }

    func testWaitingWithNoPendingToolFallsBackToStatusName() {
        // Transient: status .waiting but activeTools empty.
        let snap = makeSnap(status: .waiting)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "waiting")
    }

    func testStoppedShowsLowercasedDisplayName() {
        let snap = makeSnap(status: .stopped)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "stopped")
    }

    func testPausedShowsLowercasedDisplayName() {
        let snap = makeSnap(status: .paused)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertEqual(r.bottom, "paused")
    }

    // MARK: - Error pip window

    func testHasRecentErrorFalseWhenAllCleanInLastFive() {
        var e = EnrichedSession.empty
        e.recentTools = (0..<3).map { _ in completion(isError: false) }
        let snap = makeSnap(enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertFalse(r.hasRecentError)
    }

    func testHasRecentErrorTrueWhenMostRecentErrored() {
        var e = EnrichedSession.empty
        e.recentTools = [completion(isError: true), completion(isError: false)]
        let snap = makeSnap(enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertTrue(r.hasRecentError)
    }

    func testHasRecentErrorTrueWhenErrorInLastFiveButNotMostRecent() {
        var e = EnrichedSession.empty
        e.recentTools = [
            completion(isError: false),   // newest
            completion(isError: false),
            completion(isError: true),    // mid window
            completion(isError: false),
            completion(isError: false),
        ]
        let snap = makeSnap(enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertTrue(r.hasRecentError)
    }

    func testHasRecentErrorFalseWhenErrorOutsideLastFive() {
        var e = EnrichedSession.empty
        e.recentTools = [
            completion(isError: false),
            completion(isError: false),
            completion(isError: false),
            completion(isError: false),
            completion(isError: false),
            completion(isError: true),    // 6th — outside the prefix-5 window
        ]
        let snap = makeSnap(enriched: e)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertFalse(r.hasRecentError)
    }

    func testHasRecentErrorFalseWhenRecentToolsEmpty() {
        let snap = makeSnap()
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertFalse(r.hasRecentError)
    }

    // MARK: - dim from isAlive

    func testDimTrueWhenSessionNotAlive() {
        let snap = makeSnap(isAlive: false)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertTrue(r.dim)
    }

    func testDimFalseWhenSessionAlive() {
        let snap = makeSnap(isAlive: true)
        let r = PerSessionStatusItem.rowData(from: snap, now: t0)
        XCTAssertFalse(r.dim)
    }

    // MARK: - Redraw gate invariant

    func testIdenticalContentDifferentUpdatedAtProducesEqualRowData() {
        // The whole point of the gate: a snapshot pair that differs only in
        // updatedAt must produce identical RowData so update(with:) short-circuits.
        let a = makeSnap(updatedAt: t0)
        let b = makeSnap(updatedAt: t0.addingTimeInterval(0.7))
        let ra = PerSessionStatusItem.rowData(from: a, now: t0)
        let rb = PerSessionStatusItem.rowData(from: b, now: t0)
        XCTAssertEqual(ra, rb)
    }

    // MARK: - Helpers

    private func active(id: String, name: String, preview: String, startedAt: Date) -> ActiveTool {
        ActiveTool(id: id, name: name, preview: preview, startedAt: startedAt, rawInputJSON: nil)
    }

    private func completion(isError: Bool) -> CompletedTool {
        let a = ActiveTool(id: UUID().uuidString, name: "Bash", preview: "x",
                           startedAt: t0.addingTimeInterval(-1), rawInputJSON: nil)
        return CompletedTool(completing: a, isError: isError, at: t0)
    }

    private func makeSnap(
        status: SessionStatus = .idle,
        cwd: URL = URL(fileURLWithPath: "/tmp/sample"),
        updatedAt: Date? = nil,
        isAlive: Bool = true,
        enriched: EnrichedSession? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: "p:s",
            providerId: "p",
            pid: 1,
            sessionId: "s",
            cwd: cwd,
            startedAt: t0.addingTimeInterval(-200),
            updatedAt: updatedAt ?? t0,
            status: status,
            waitingFor: nil,
            version: nil,
            kind: nil,
            entrypoint: nil,
            isAlive: isAlive,
            enriched: enriched ?? EnrichedSession.empty
        )
    }
}
```

- [ ] **Step 2: Verify it fails to compile**

```bash
xcodegen generate
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/PerSessionRowDataTests 2>&1 | tail -20
```

Expected: build error — `rowData` static method does not exist on `PerSessionStatusItem`.

- [ ] **Step 3: Add `RowData` and `rowData(from:now:)` to `PerSessionStatusItem`**

In `AgentStatus/UI/PerSession/PerSessionStatusItem.swift`, append before the closing `}` of the `PerSessionStatusItem` class (i.e., after the `tooltip(for:)` method, before line 152):

```swift
    /// Equatable snapshot of every menu-bar-row-relevant field. Used as the
    /// sole redraw gate in `update(with:)` so 1.3 Hz file-driven snapshot
    /// ingest can't thrash the menu bar layout — only meaningful state
    /// transitions produce a new `RowData` and therefore a new SwiftUI tree.
    struct RowData: Equatable {
        let status: SessionStatus
        let title: String
        let bottom: String
        let dim: Bool
        let hasRecentError: Bool
    }

    /// Pure: snapshot + now → RowData. The `now: Date` parameter is the
    /// elapsed-time anchor (production passes `Date()`; tests pass a pinned
    /// date). All formatting decisions live here so the redraw gate can
    /// short-circuit on equality alone.
    static func rowData(from snap: SessionSnapshot, now: Date) -> RowData {
        let title = (snap.enriched?.aiTitle?.isEmpty == false ? snap.enriched?.aiTitle : nil)
            ?? snap.cwdBasename

        let bottom = bottomText(for: snap, now: now)

        let recent = snap.enriched?.recentTools ?? []
        let hasRecentError = recent.prefix(5).contains { $0.isError }

        return RowData(
            status: snap.status,
            title: title,
            bottom: bottom,
            dim: !snap.isAlive,
            hasRecentError: hasRecentError
        )
    }

    /// Compute the bottom-row suffix from session state. Private — split out
    /// so the main `rowData` builder stays small and the suffix grammar is
    /// readable as a single function. Returns the literal text including any
    /// `· {N}m` elapsed-time tail; truncation happens at render time.
    private static func bottomText(for snap: SessionSnapshot, now: Date) -> String {
        // Waiting overrides everything except .error — most action-required.
        if snap.status == .waiting {
            if let pending = snap.enriched?.activeTools.last {
                let trimmed = pending.preview.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    return "approve \(pending.name)"
                }
                return "approve \(pending.name) · \(trimmed)"
            }
            return snap.status.displayName.lowercased()
        }

        let active = snap.enriched?.activeTools ?? []

        if snap.status == .busy && !active.isEmpty {
            // Elapsed anchor: earliest active tool's startedAt. activeTools
            // is already sorted ascending by startedAt (see TranscriptTailer.
            // recomputeActiveAndRecent), so `.first` is the earliest.
            let elapsedSeconds = max(0, now.timeIntervalSince(active.first!.startedAt))
            let minutesSuffix = elapsedSeconds >= 60 ? " · \(Int(elapsedSeconds) / 60)m" : ""

            if active.count == 1 {
                let tool = active[0]
                let trimmed = tool.preview.trimmingCharacters(in: .whitespaces)
                let head = trimmed.isEmpty ? tool.name : "\(tool.name) \(trimmed)"
                return head + minutesSuffix
            }
            return "\(active.count) tools\(minutesSuffix)"
        }

        // All other states (idle, busy-without-active, stopped, paused,
        // error, running, unknown) → status displayName lowercased.
        return snap.status.displayName.lowercased()
    }
```

- [ ] **Step 4: Verify all tests pass**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/PerSessionRowDataTests 2>&1 | tail -10
```

Expected: `Executed 21 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add AgentStatus/UI/PerSession/PerSessionStatusItem.swift \
        AgentStatusTests/PerSessionRowDataTests.swift
git commit -m "feat(per-session): add RowData builder for the redesigned menu-bar item"
```

---

### Task 2: Rewrite `PerSessionLabel`, wire `RowData`, bump width — one coordinated commit

This task is the UI surgery: replace `PerSessionLabel` with the two-line version, swap the cache fields, rewrite the constructor + updater, bump the width constant, and delete the now-unused `shortTitle` helper. All in one commit so every commit on the branch stays green.

**Files:**
- Modify: `AgentStatus/UI/PerSession/PerSessionStatusItem.swift`

- [ ] **Step 1: Replace `PerSessionLabel`**

In `AgentStatus/UI/PerSession/PerSessionStatusItem.swift`, find the existing `PerSessionLabel` (≈ lines 154-173) and replace it with:

```swift
/// SwiftUI content of a per-session NSStatusItem button. Two rows inside the
/// fixed 22pt menu bar height: aiTitle (or cwd fallback) at 12pt medium on top,
/// a state-driven suffix at 9pt regular below. Static — no animations.
///
/// The red pip overlay on the status icon is bool-gated (`hasRecentError`) so
/// only the bool-transition crosses a redraw boundary.
struct PerSessionLabel: View {
    let row: PerSessionStatusItem.RowData

    var body: some View {
        HStack(spacing: 6) {
            iconWithPip
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(row.dim ? .secondary : .primary)
                Text(row.bottom)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: 180, height: NSStatusBar.system.thickness, alignment: .leading)
    }

    /// Icon stack: base StaticStatusIcon with an optional red pip overlay in
    /// the bottom-right corner. The pip is a small filled circle ~4pt across,
    /// drawn with a thin background-color ring so it stays visible against
    /// any menu bar tint.
    private var iconWithPip: some View {
        StaticStatusIcon(status: row.status, size: 14, dim: row.dim)
            .overlay(alignment: .bottomTrailing) {
                if row.hasRecentError {
                    Circle()
                        .fill(.red)
                        .frame(width: 4, height: 4)
                        .overlay(Circle().stroke(Color(NSColor.controlBackgroundColor), lineWidth: 0.5))
                        .offset(x: 1, y: 1)
                }
            }
            .frame(width: 14, height: 14, alignment: .center)
    }
}
```

- [ ] **Step 2: Replace the cache field triple**

In the same file, find the cache field triple (lines 22-24):

```swift
    private var lastStatus: SessionStatus
    private var lastTitle: String
    private var lastDim: Bool
```

Replace with a single field:

```swift
    private var lastRowData: RowData
```

- [ ] **Step 3: Bump the width constant + refresh the comment above it**

Replace the comment + constant block (lines 26-28):

```swift
    /// Width budget: ~14pt icon + 5pt spacing + ~70pt text + 12pt padding ≈ 102pt.
    /// Fixed length avoids Auto Layout cycles between the button and hosting view.
    private static let itemWidth: CGFloat = 102
```

with:

```swift
    /// Width budget: 14pt icon + 6pt spacing + ~154pt two-line text area + 6pt padding ≈ 180pt.
    /// Fixed length avoids Auto Layout cycles between the button and hosting view.
    private static let itemWidth: CGFloat = 180
```

- [ ] **Step 4: Rewrite the constructor**

Replace the constructor (lines 31-64) with:

```swift
    init(snapshotId: String, initialSnapshot: SessionSnapshot, store: SessionStore, settings: Settings) {
        self.snapshotId = snapshotId
        self.store = store
        self.settings = settings
        self.item = NSStatusBar.system.statusItem(withLength: Self.itemWidth)
        self.popover = NSPopover()
        self.popover.behavior = .transient
        self.popover.contentSize = NSSize(width: 320, height: 260)
        // contentViewController stays nil until popover opens — see togglePopover().

        self.lastRowData = Self.rowData(from: initialSnapshot, now: Date())

        super.init()

        self.popover.delegate = self

        let host = NSHostingView(rootView: PerSessionLabel(row: lastRowData))
        host.frame = NSRect(x: 0, y: 0, width: Self.itemWidth, height: Self.itemHeight)

        if let button = item.button {
            button.image = nil
            button.title = ""
            button.subviews.forEach { $0.removeFromSuperview() }
            button.addSubview(host)
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = Self.tooltip(for: initialSnapshot)
        }
        hostingView = host
    }
```

- [ ] **Step 5: Rewrite `update(with:)`**

Replace `update(with:)` (lines 66-85) with:

```swift
    /// Snapshot ingest hook. Tooltip refreshes every time (cheap — no
    /// view-tree mutation). The SwiftUI tree is rebuilt only when the
    /// derived `RowData` differs from the cached one, so the 1.3 Hz
    /// file-driven ingest doesn't thrash the menu bar layout.
    func update(with snapshot: SessionSnapshot) {
        guard let host = hostingView else { return }

        // Always refresh tooltip — cheap, no view-tree mutation.
        item.button?.toolTip = Self.tooltip(for: snapshot)

        let next = Self.rowData(from: snapshot, now: Date())
        if next == lastRowData { return }

        lastRowData = next
        host.rootView = PerSessionLabel(row: next)
    }
```

- [ ] **Step 6: Delete the now-unused `shortTitle(for:)` helper**

Remove the entire `shortTitle(for:)` function (lines 87-92 in the pre-edit file):

```swift
    private static func shortTitle(for snapshot: SessionSnapshot) -> String {
        let base = snapshot.cwdBasename
        let max = 12
        if base.count <= max { return base }
        return String(base.prefix(max - 1)) + "…"
    }
```

The aiTitle / cwd-basename fallback now lives inside `rowData(from:now:)`.

- [ ] **Step 7: Verify it builds**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Run the full test suite**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`. Full suite includes the ~175 s chunked-read test from v0.1.0; total test count is previous total + 21 new `PerSessionRowDataTests` tests.

- [ ] **Step 9: Commit**

```bash
git add AgentStatus/UI/PerSession/PerSessionStatusItem.swift
git commit -m "feat(per-session): two-line label, RowData gate, 180pt width"
```

---

### Task 3: Manual visual QA against a running app

**Files:** none (verification only)

- [ ] **Step 1: Build and run the Debug app**

```bash
cd /Users/dee/repos/agent-status
pgrep -lf "build/Build/Products/Debug/AgentStatus" | awk '{print $1}' | xargs -r kill 2>&1
sleep 1
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus -configuration Debug \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -3
APP="build/Build/Products/Debug/AgentStatus.app"
codesign --force --deep --sign - "$APP" 2>&1 | tail -1
open "$APP"
```

Expected: app launches; menu bar shows the existing dropdown plus any pinned per-session items at the new 180pt width.

- [ ] **Step 2: Eyeball each state across pinned sessions**

If you have ≥1 pinned per-session item visible:

- **Idle state:** top row shows aiTitle (or cwd basename if a brand-new session); bottom row reads `idle` in small grey text.
- **Busy with one tool:** bottom reads `{Name} {preview}` for the first ~60s, then transitions to `{Name} {preview} · 1m` after a minute boundary.
- **Busy with multiple tools:** bottom reads `3 tools` (or whatever count); after 60s, appends ` · 1m`, etc.
- **Waiting state:** orange-tinted icon; bottom reads `approve {Name} · {preview}` (or just `approve {Name}` for AskUserQuestion).
- **Recent errors:** red pip overlay on the bottom-right of the status icon when any of the last 5 completions had `is_error`.

If you have no pinned items, pin one via the gear menu / settings (existing behavior) to verify.

- [ ] **Step 3: Confirm no per-second flicker**

Watch a pinned item during a busy session for 30 seconds. The bottom row text must not change every second — the only mid-session transitions should be at tool start/end and at minute boundaries while busy. If you see per-second jitter, the redraw gate is broken; investigate before moving on.

- [ ] **Step 4: (No commit — verification only.)**

If anything looks wrong, fix it as a follow-up edit in this task before moving to Task 5.

---

### Task 4: README features bullet update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Locate the features bullet list**

In `README.md`, find the features bullet list (the one that contains "Live menu-bar dashboard", "Per-session detail popover", etc.). The "Concurrency-aware" bullet was added in v0.1.0.

- [ ] **Step 2: Update or replace the existing per-session bullet**

Find the existing bullet that describes the per-session menu bar item. (Today it likely says something like "*Per-session menu-bar items* — pin specific sessions to the menu bar with status icon and cwd label.") Replace it with:

```
- **Per-session menu-bar items** — pin specific sessions to the menu bar with an informative two-line label: aiTitle on top, state-driven suffix (`idle` / `Bash xcodebuild test · 1m` / `3 tools · 2m` / `approve Bash · xcodebuild test`) below, plus a red pip overlay on the icon when recent tool calls have errored. Designed to answer "do I need to look at this session" without a click.
```

If the existing bullet has a different exact wording, preserve the bullet's position in the list and just update the description text. Keep the indentation and Markdown formatting consistent with the surrounding bullets.

- [ ] **Step 3: Sanity check the build is still clean**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`. (README changes don't compile, but this confirms nothing else regressed since Task 2.)

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README — per-session item two-line layout"
```

---

### Task 5: Push branch + open PR

**Files:** none (PR creation only)

- [ ] **Step 1: Run the full test suite once more for the PR body**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -2
```

Capture the test count line for the PR body (e.g., `Executed 99 tests, with 0 failures`).

- [ ] **Step 2: Push the branch and open the PR**

```bash
git push -u origin feat/per-session-redesign
gh pr create --base main \
  --title "feat: per-session menu-bar item — two-line, 180pt, aiTitle + state suffix" \
  --body "$(cat <<'EOF'
## Summary

Replaces the single-line, 102pt `[icon] cwd-basename` per-session menu-bar item with a two-line, 180pt layout designed to answer "do I need to look at this session" without a click.

- **Top row** (12pt medium): aiTitle when present, cwd basename as fallback for the first ~10s before Claude emits the title event.
- **Bottom row** (9pt secondary): state-driven suffix — `idle` / `Bash xcodebuild test · 1m` / `3 tools · 2m` / `approve Bash · xcodebuild test` / `stopped` / etc.
- **Red pip overlay** on the status icon when any of the last 5 completed tools had `is_error` — auto-decays as successful tools push errored ones out of the window.

## Performance

The new `PerSessionStatusItem.rowData(from:now:)` builder produces an `Equatable` `RowData` value; `update(with:)` re-renders the SwiftUI tree only when it changes from the cached value. No new timer — sub-60s elapsed is suppressed and minute-bucketed text only differs at 60s boundaries, which the existing 1.3 Hz file-driven ingest lands within ~1s. Redraw budget is unchanged in spirit from the existing comment ("naive update-on-every poll thrashes the menu bar layout").

## Verification

```
$ xcodebuild ... test
** TEST SUCCEEDED **
Executed <PASTE FROM STEP 1> tests, with 0 failures
```

21 new `PerSessionRowDataTests` cover every suffix-grammar branch, aiTitle/cwd fallback, the `hasRecentError` window semantics, the `dim` flag, and the redraw-gate invariant (snapshots differing only in `updatedAt` produce identical `RowData`).

## Spec & Plan

- [Spec](docs/superpowers/specs/2026-05-11-per-session-menu-bar-item-redesign-design.md)
- [Plan](docs/superpowers/plans/2026-05-11-per-session-redesign.md)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Paste the actual test count from Step 1 into the PR body before submitting.

---

## Self-review notes

- **Spec coverage** — every section of the spec maps to a task:
  - Layout & identity (Section 1 of spec) → Task 2 (PerSessionLabel, width bump, all wiring in one commit)
  - Suffix grammar (Section 2) → Task 1 (`bottomText(for:now:)` builder) + tests in Task 1
  - Data flow / `RowData` (Section 3) → Task 1 (struct + builder) + Task 2 (wiring)
  - Performance & redraw triggers (Section 4) → Task 1 (gate construction) + Task 2 (gate wiring) + Task 3 (visual confirmation)
  - Edge cases (Section 5) → Task 1 tests for `aiTitle == ""`, transient waiting w/o pending, empty preview, etc.
  - Testing (Section 6) → Task 1 tests cover every table row + the redraw-gate invariant
  - Rollout (Section 7) → Task 4 (README) + Task 5 (PR)
  - Out of scope (Section 8) — preserved unchanged; nothing in this plan exceeds spec scope
- **No placeholders** — every step contains complete code or a concrete shell command. The `<PASTE FROM STEP 1>` marker in the PR body is an intentional fill-in from observed numbers, not unfinished spec content.
- **Type consistency** — `RowData` defined once in Task 1, used by name throughout Task 2. The static `rowData(from:now:)` signature is identical at every reference site. The `PerSessionLabel` initializer becomes `init(row: RowData)` in Task 2 and is called with `row:` consistently in the same task.
- **TDD discipline** — Task 1 begins with the failing test file before the production builder exists. Task 2 is one coordinated edit so every commit on the branch is buildable. Task 3 is a manual visual QA gate before docs / PR.
