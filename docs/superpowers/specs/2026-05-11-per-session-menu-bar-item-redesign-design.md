# Per-session menu-bar item redesign

**Status:** Approved (brainstorm 2026-05-11), pending implementation plan.
**Scope:** `PerSessionStatusItem` + its embedded `PerSessionLabel` SwiftUI view. No changes to `SessionRow`, the dashboard, the popover, or the transcript tailer.
**Top constraint:** performance. Redraw discipline matches today's: every change goes through a `RowData` equality gate so 1.3 Hz snapshot ingest never thrashes the menu bar layout.

---

## Why

Today's per-session menu-bar item shows `[status-icon] cwd-basename` in a fixed 102pt width. Two problems:

1. **Identity is weak.** Multiple sessions in the same project (open terminals, scratch directories) look identical because they share a cwd. The cwd answers *where*, not *what*.
2. **Status is binary.** The icon conveys idle/busy/waiting/error, but says nothing about *what* the session is doing, *how long* it's been doing it, or *whether it just hit errors*. The user pinned this session because they care about it — but to learn anything beyond a color, they have to click.

The popover (rich detail) and the tooltip (enriched in v0.1.0) both exist. The menu-bar item itself remains the bottleneck for at-a-glance answers.

---

## Design

### Layout — two-line, 180pt wide, 22pt tall

```
Width 180pt, height 22pt (NSStatusBar.system.thickness — unchanged).

╔════════════════════════════════════════════╗
║ [icon]   {aiTitle, 12pt medium}            ║  ← top: ~26 chars before tail-truncation
║          {suffix, 9pt regular, secondary}  ║  ← bottom: ~34 chars before tail-truncation
╚════════════════════════════════════════════╝
```

Both rows live inside the existing `NSHostingView<PerSessionLabel>` that's already mounted in the `NSStatusItem.button`. The status item itself is reconfigured from `withLength: 102` to `withLength: 180`.

### Identity (top row)

- Source: `EnrichedSession.aiTitle` when present.
- Fallback: `SessionSnapshot.cwdBasename` when aiTitle is nil or empty (covers the first ~10 s of a session before Claude emits the `ai-title` event).
- No git branch. No cwd suffix. Tooltip still carries the full path (already enriched in v0.1.0).
- Tail-truncated at the rendered width (~26 chars at 12pt medium).

### Status icon (left)

The existing `StaticStatusIcon` is preserved unchanged. One adornment is added: a small red dot overlay (10% of icon size, bottom-right) when `hasRecentError == true` (see below). The base SF Symbol + color logic per status stays identical.

### Suffix (bottom row)

State-driven content. Elapsed is minute-precision and shown only when `≥ 60 s` (no per-second churn).

**Elapsed anchor:** when there's exactly one active tool, the anchor is that tool's `startedAt`. When there are multiple, the anchor is the *earliest* `activeTools` entry's `startedAt` — i.e., "how long has this session been continuously doing parallel work?" Falling back to the latest tool would jitter on every new tool start; falling back to the session's `startedAt` would tell you uptime instead of busy-time. Earliest active gives the answer that most aligns with "is this stuck."

| State | Bottom row |
|---|---|
| `.idle` | `idle` |
| `.busy`, 1 active tool, < 60 s | `{Name} {preview}` (e.g., `Bash xcodebuild test`) |
| `.busy`, 1 active tool, ≥ 60 s | `{Name} {preview} · {N}m` |
| `.busy`, ≥ 2 active tools, < 60 s | `{N} tools` |
| `.busy`, ≥ 2 active tools, ≥ 60 s | `{N} tools · {M}m` |
| `.waiting`, preview non-empty | `approve {Name} · {preview}` |
| `.waiting`, preview empty / unknown | `approve {Name}` |
| `.stopped` / `.paused` / `.error` / `.running` | status displayName lowercased |

Tail-truncated at the rendered width (~34 chars at 9pt regular). When the bottom row's *computed* text is the empty string (transient edge cases — see below), the row renders as `""` (zero-width, no glyph placeholder).

### Real examples at native size

```
[●]  Configure terminal input position
     idle

[●]  Investigate flake
     Bash xcodebuild -scheme Ag… · 1m

[●]  Build menu bar dashboard
     3 tools · 2m

[⚠]  Review git authors
     approve Bash · xcodebuild test

[●●] Run release pipeline                ← red pip on icon (icon-only)
     idle
```

---

## Data flow

No changes to provider, tailer, or store layers. `PerSessionStatusItem.update(with:)` (called per snapshot ingest, ~1.3 Hz today) gains one responsibility: derive a small `RowData` and only mutate the SwiftUI view tree when it changes from the cached value.

### `RowData` (private struct, Equatable)

```swift
private struct RowData: Equatable {
    let status: SessionStatus
    let title: String           // aiTitle ?? cwdBasename, tail-truncate at render
    let bottom: String          // suffix-grammar output, tail-truncate at render
    let dim: Bool               // !isAlive
    let hasRecentError: Bool    // recentTools.prefix(5).contains { $0.isError }
}
```

`PerSessionStatusItem.update(with:)` flow:

1. Compute `RowData` from the incoming `SessionSnapshot`.
2. Always refresh the tooltip (cheap — no view-tree mutation, behavior preserved from v0.1.0).
3. If `RowData == lastRowData`, return early.
4. Otherwise, swap the `hostingView.rootView` to a fresh `PerSessionLabel` built from the new `RowData`, and cache it.

### Pure builder (testable)

```swift
extension PerSessionStatusItem {
    /// Pure: snapshot + now → RowData. Drives the redraw gate. Lives on
    /// the type so XCTest can pin every state's expected output.
    static func rowData(from snap: SessionSnapshot, now: Date) -> RowData
}
```

The `now: Date` parameter is the elapsed-time anchor. Inside the builder it's used to compute minutes-since-`startedAt` for the dominant active tool (or session-busy start; details in the suffix-grammar implementation). Production code passes `Date()`; tests pass a pinned date for determinism.

---

## Performance & redraw triggers

The existing rule (comment in `PerSessionStatusItem.update(with:)`):

> *"Critical: the file's `updatedAt` ticks every Claude write, so naive update-on-every poll thrashes the menu bar layout."*

is preserved verbatim. `RowData` equality is the sole gate.

**No new timer.** Sub-60 s elapsed is suppressed; minute-bucketed text only differs at 60 s boundaries. Between minute boundaries, every snapshot ingest produces an identical `RowData` and short-circuits at step 3 above. The ~1.3 Hz file-driven ingest cadence is enough to land minute transitions within ~1 s of accuracy without dedicated timers.

**Redraw transitions, in expected frequency order:**

| Trigger | Approx. frequency in a busy session |
|---|---|
| `bottom` text changes at a minute boundary | once per minute |
| `bottom` text changes on tool start / end | a few per minute |
| `title` changes (aiTitle arrives or refines) | 1–2 per session |
| `status` changes | rare |
| `hasRecentError` bool flips | rare |
| `dim` flips (process death) | once per session |

**Width change:** `withLength: 102` → `withLength: 180` is a one-time configuration change at item construction. Auto Layout cycles are avoided by keeping the hosting view's frame fixed (matches today's pattern).

---

## Edge cases

- **aiTitle nil** → cwd basename. The existing single-line fallback path (today's behavior) is narrowed to this case.
- **cwd basename longer than 26 chars** → tail-truncated by SwiftUI at the rendered width.
- **busy + `activeTools.isEmpty`** (transient inconsistency between status update and transcript replay) → bottom shows status displayName lowercased (`busy`). No special-case logic.
- **recentTools empty AND errorCount > 0** → no red pip. The pip is window-based (`recentTools.prefix(5)`), not session-cumulative, so old errors from way back don't strand the pip on forever.
- **Task (subagent) as the sole active tool** → falls through to single-tool case: `Task research-foo · 1m`.
- **Preview empty** (AskUserQuestion, unknown tool, empty input dict) → just the name: `Bash`, not `Bash ` with trailing space.
- **Multiple Bash entries in activeTools** (3 concurrent shell commands) → `3 tools`. No same-name aggregation.

---

## Testing

### Pure-builder tests (XCTest, fast, deterministic)

One new test class, `PerSessionStatusItemRowDataTests`. All cases call `PerSessionStatusItem.rowData(from: snap, now: pinnedDate)`.

| Case | Expected |
|---|---|
| `aiTitle == "Investigate flake"` | `title == "Investigate flake"` |
| `aiTitle == nil`, cwd `"/tmp/agent-status"` | `title == "agent-status"` |
| `.idle` | `bottom == "idle"` |
| 1 tool `Bash` preview `"npm test"`, 30 s elapsed | `bottom == "Bash npm test"` |
| 1 tool `Bash` preview `"npm test"`, 90 s elapsed | `bottom == "Bash npm test · 1m"` |
| 3 tools, 35 s elapsed | `bottom == "3 tools"` |
| 3 tools, 130 s elapsed | `bottom == "3 tools · 2m"` |
| `.waiting`, pending `Bash` preview `"xcodebuild test"` | `bottom == "approve Bash · xcodebuild test"` |
| `.waiting`, pending `AskUserQuestion` preview `""` | `bottom == "approve AskUserQuestion"` |
| `.stopped` | `bottom == "stopped"` |
| `recentTools` all clean | `hasRecentError == false` |
| Most recent of last 5 is error | `hasRecentError == true` |
| Errors in last 5 but NOT in last 1 | `hasRecentError == true` |
| `isAlive == false` | `dim == true` |

### Redraw-gating invariant test

Two `SessionSnapshot` values that differ ONLY in `updatedAt` must produce **identical** `RowData` (so `update(with:)` short-circuits before mutating the view tree).

### No SwiftUI snapshot tests

Visual layout sits in a single small SwiftUI view; previews + manual eyeball check are sufficient. Snapshot-image testing isn't worth the harness cost for this scope.

---

## Rollout

**One PR, one branch** (`feat/per-session-redesign`).

**Suggested commit sequence:**

1. Add `RowData` + `PerSessionStatusItem.rowData(from:now:)` builder + tests.
2. Wire the builder into `update(with:)`; replace `PerSessionLabel` with the two-line version reading from `RowData`.
3. Change `withLength: 102` → `withLength: 180` at item construction.
4. Add the red-pip overlay to `PerSessionLabel`'s icon when `hasRecentError`.
5. Update README screenshot / feature bullet if applicable.

**No feature flag.** A brand-new session before aiTitle arrives still renders cleanly (cwd basename fallback). Existing pinned sessions get the new layout immediately on next launch.

**README updates:** features bullet describing the new identity / status density; test count.

---

## Out of scope (deferred follow-ups)

- **Variable-width items** based on aiTitle length — fixed 180pt is simpler and avoids layout cycle risk with other menu bar items.
- **Animated badges or progress rings** — spec's no-animation rule still applies.
- **Custom user labels** per session — useful, but adds settings UI surface area. Belongs in a separate PR.
- **Watching `.git/HEAD`** — branch was dropped from the visible label, so this is moot for now.
- **Showing tokens / cost in the suffix** — popover already does this; menu bar's job is urgency, not biography.
- **Same redesign applied to inline `SessionRow`** — `SessionRow` is dropdown content (clicked, not glanced), with different size constraints. Out of scope.
