# Concurrency-aware tool tracking + waiting-question display

**Status:** Approved (brainstorm 2026-05-08), pending implementation plan.
**Scope:** `SessionDetailView` (popover content) + `PerSessionStatusItem` tooltip + `TranscriptTailer` data model. Inline `SessionRow` and the 60-second sparkline are explicitly **out of scope** for this round.
**Top constraint:** performance. The new build must be indistinguishable from today's in Activity Monitor (~15 MB RAM, ~0% CPU idle).

---

## Why

Today's per-session detail view answers "what is the agent doing?" with a single `currentTool` field that is wrong under parallelism: `TranscriptTailer.recomputeCurrentTool()` arbitrarily picks the most-recently-started entry from `toolStarts` and discards the rest. With `run_in_background: true` Bash and parallel `Agent` calls, sessions routinely have 2–5 active tools at once — invisible today.

Separately, when status is `waiting` (permission gate, AskUserQuestion, etc.) the UI shows the raw `waitingFor` string ("approve Bash") but not what the agent is actually waiting *for* — the command being approved, the question being asked. The data is in the transcript; the UI just doesn't surface it.

This spec replaces the status-only sparkline-as-primary-signal with a structured "Running now / Recent / Waiting" view that uses data already captured.

---

## Performance commitments (top-priority constraint)

The redesign adds state and one new live UI surface. Each commitment below is a guard against regressing the README's "~15 MB RAM, ~0% CPU idle" baseline.

1. **Polling cadence unchanged.** 1 Hz `tick()` per session, status-independent. Considered adaptive intervals (slower on idle) — rejected: an idle `tick()` is one `stat()` syscall (~µs on APFS), well under 0.01% CPU even at 10 sessions. Adaptive trades real UX (5 s lag on busy↔idle transitions) for nothing measurable.
2. **Popover-gated `TimelineView`.** The "Running now" elapsed timer (`t+12s`) lives inside one shared `TimelineView(.periodic(from: .now, by: 1))` wrapping the section. The view is instantiated only when the popover is open (existing pattern in `PerSessionStatusItem.popoverDidClose`) and is omitted entirely when `activeTools.isEmpty`. Steady state with popover closed: zero ticking work.
3. **Split snapshot stream.** `SessionStore` exposes two channels: a *core* channel (status, waitingFor, currentModel) that drives menu-bar row redraws, and a *rich* channel (active/recent/usage/tokens) consumed only by the open detail view. Mutations to `recentTools` never wake the row.
4. **Allocation discipline at the hot path.** `tick()` on an idle file remains zero-allocation (early-return when `size ≤ offset` is preserved). New work piggybacks on ticks already doing parsing: `recentTools` appended only on `tool_result` arrival; `activeTools` snapshot recomputed only when `toolStarts` mutates (dirty-bit gate); completion timestamps use `Date()` at processing time, skipping the `ISO8601DateFormatter` allocation that `parseTimestamp` requires under Swift 6 strict concurrency.
5. **Bounded initial-read chunk.** `tick()` currently does `readData(ofLength: Int(size - offset))` — for a resumed 50 MB transcript that's one 50 MB allocation. Cap at 1 MB and loop within the same tick. Latent issue, fixed here.
6. **Debug `PerfStats` actor.** New ~30 LOC actor counting ticks/sec, bytes/sec, lines/sec, snapshot yields/sec. Surfaced in a hidden gear-menu pane (debug builds only). Lets us prove parity with hard numbers instead of guessing.

---

## Data model

### `EnrichedSession` additions

```swift
/// All in-flight top-level tool calls, ordered by startedAt ascending.
var activeTools: [ActiveTool] = []

/// Recently-completed top-level tool calls, newest-first, cap = 10.
var recentTools: [CompletedTool] = []

// `currentTool: ActiveTool?` is kept on the struct for one release as nil
// (deprecated). Removal scheduled for the follow-up PR after consumers migrate.
```

### New type

```swift
struct CompletedTool: Hashable, Sendable {
    let id: String                // Anthropic tool_use_id
    let name: String              // "Bash", "Edit", "Agent", ...
    let preview: String           // ActiveTool.preview output, computed at start
    let startedAt: Date
    let endedAt: Date
    let isError: Bool             // from tool_result.is_error
    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}
```

### `WaitingDisplay`

```swift
enum WaitingDisplay: Equatable, Sendable {
    case tool(name: String, preview: String)
    case askUserQuestion(text: String, options: [String])
    case subagent(description: String, prompt: String)
    case unknown(rawWaitingFor: String)
}
```

---

## `TranscriptTailer` changes

### Pure helpers (testable, follow `aiTitle(fromEvent:)` precedent)

```swift
static func isSidechain(_ assistantJSON: [String: Any]) -> Bool
static func completion(from start: ActiveTool, isError: Bool, at: Date) -> CompletedTool
static func waitingDisplay(for waitingFor: String?,
                           pending: ActiveTool?,
                           pendingInput: [String: Any]?) -> WaitingDisplay?
```

### Ingestion

- `handleAssistantMessage` gains a sidechain check at entry: if `Self.isSidechain(json)`, return early. Subagent activity still reaches us via the transcript stream but never enters `toolStarts`, `activeTools`, `recentTools`, or `state.toolCalls`.
- `handleUserMessage`'s `tool_result` branch, when removing from `toolStarts`, now also pushes a `CompletedTool` onto a private `recentToolsRing` (cap = 10), and yields the snapshot.
- `recomputeCurrentTool()` is replaced by `recomputeActiveAndRecent()`:
  - Sets `state.activeTools = toolStarts.values.sorted { $0.at < $1.at }.map { ActiveTool(...) }`
  - Sets `state.recentTools = recentToolsRing.snapshot()` (newest-first)
  - Gated on a `dirty: Bool` flag set by ingestion writes.
- `state.currentTool` always set to nil. (Deprecated; consumer cleanup in follow-up.)

### `tick()` chunked read

```swift
let toRead = min(size - offset, 1_048_576)   // 1 MB chunk
let data = handle.readData(ofLength: Int(toRead))
offset += toRead
// existing line-split + dispatch
// loop continues into the next tick — no need to drain in one go
```

This is bounded regardless of transcript size and preserves the early-return on `size ≤ offset`.

---

## `SessionStore` core/rich split

Today `SessionStore` re-emits when *any* field on `EnrichedSession` differs (`SessionStore.swift:73-80`). Split into:

- `coreSnapshot` — `(id, status, waitingFor, currentModel, isAlive, cwd)`. Subscribed by menu-bar row, dashboard list, `PerSessionStatusItem.update`.
- `richSnapshot` — full `EnrichedSession`. Subscribed only by `SessionDetailView` (lazily, when popover open).

Equality on `coreSnapshot` is unchanged in semantics — just narrowed in scope. A test pins the invariant: mutating `recentTools` does not produce a `coreSnapshot` change event.

---

## `SessionDetailView` layout

Vertical stack of conditional sections. Each hidden when its data is empty, so a brand-new session renders identically to today minus the (still-present) facts/sparkline/prompts.

```
┌───────────────────────────────────────────────┐
│ Header  (unchanged)                           │
│   {ai-title}                                  │
│   {model} · {turns} turns · ${cost}           │
├───────────────────────────────────────────────┤
│ Waiting   (only if status == .waiting)        │
│   ⚠ Waiting · approve Bash                    │
│      $ xcodebuild -scheme AgentStatus \       │
│          test -destination 'platform=macOS'   │
├───────────────────────────────────────────────┤
│ Running now (3)   (hidden if empty)           │
│   ⚡ Bash xcodebuild ...        t+12s         │
│   ⚡ Bash npm test              t+09s         │
│   ⚡ Agent research-foo         t+04s         │
├───────────────────────────────────────────────┤
│ Recent (5)   (hidden if empty)                │
│   ✓ Read SessionRow.swift       0.4s          │
│   ✗ Bash flaky-test             2.1s          │
│   ✓ Edit SessionRow.swift       0.3s          │
│   ✓ Grep "toolStarts"           0.2s          │
│   ✓ Read EnrichedSession.swift  0.1s          │
├───────────────────────────────────────────────┤
│ Facts grid  (model/mode/permissions/tokens)   │   unchanged
├───────────────────────────────────────────────┤
│ Sparkline (22 px)                             │   unchanged
├───────────────────────────────────────────────┤
│ Last prompt + Last assistant text             │   unchanged
└───────────────────────────────────────────────┘
```

### Waiting templates (driven by `WaitingDisplay`)

Field-level rules:
- `.askUserQuestion` — render `questions[0].question` as the headline; render `options[].label` as numbered list (option-level `description` omitted for compactness; max 4 options shown — Claude Code's tool schema caps at 4 anyway).
- `.subagent` — `description` as the headline; `prompt` truncated to the first 100 characters with a tail ellipsis.
- `.tool` — `name` is the tool name; `preview` reuses `ActiveTool.preview(toolName:input:)` so output is consistent with Running rows.


```
⚠ Waiting · approve Bash                    ← .tool
   $ xcodebuild -scheme AgentStatus test ...

⚠ Waiting · approve Edit                    ← .tool
   SessionRow.swift

⚠ Waiting · approve AskUserQuestion         ← .askUserQuestion
   "Which DB driver should we use?"
     1. Postgres (Recommended)
     2. SQLite
     3. MySQL

⚠ Waiting · approve Task                    ← .subagent
   research-foo
   "Find all references to toolStarts and ..."

⚠ Waiting · approve Foo                     ← .unknown (fallback: renders rawWaitingFor verbatim, no second line)
```

### Row mechanics

- **Running** — `bolt.fill` glyph (orange when also waiting, blue otherwise). Monospaced name + preview, tail-truncated to row width. Right-aligned `t+12s` (under 60 s) or `t+1m23s` (over). Cap 5 visible; if `activeTools.count > 5` the section appends one extra text-only row reading `+N more…` (no glyph, no timer).
- **Recent** — `checkmark` (subtle green) or `xmark` (subtle red), name + one-line preview, right-aligned duration. Cap 10. Newest first.
- **Empty states** — a section with zero rows renders nothing — no header, no whitespace.
- **Concurrent waiting + running** — both sections render independently; possible when a backgrounded Bash continues while the agent hits another permission gate.

### SF Symbols only (no new bundle assets)

`bell.badge.fill` (existing waiting icon), `bolt.fill` (active), `checkmark`, `xmark`.

---

## `PerSessionStatusItem` tooltip enrichment

The status item visual (icon + 12-char title) is **unchanged**. Tooltip-only enrichment, computed in the existing `update(with:)` path that already refreshes the tooltip every snapshot ("Always refresh tooltip — cheap, no view-tree mutation"):

```
~/repos/agent-status — waiting — approve Bash
  $ xcodebuild -scheme AgentStatus test ...

~/repos/agent-status — busy — 3 tools running
  Bash, Bash, Agent

~/repos/agent-status — busy — Agent research-foo
```

Cost: a longer string on hover-tick; no relayout.

---

## Testing

### Pure-helper unit tests
- `isSidechain`: top-level (false), `isSidechain: true` (true), missing key (false)
- `completion(from:isError:at:)`: clean result, `is_error: true`, zero-duration
- `waitingDisplay`: each enum case incl. `.unknown` fallback, empty options array, missing `prompt` field

### `TranscriptTailer` integration tests (extend `TranscriptParsingTests.swift`)
- Single tool: start → end → `recentTools.count == 1`, `activeTools.isEmpty`
- Three concurrent tool_uses in one assistant message → `activeTools.count == 3`, ordered by `startedAt`
- Sidechain assistant message containing tool_uses → all three collections unchanged
- File rotation mid-session → `activeTools` and `recentTools` reset along with existing state
- Synthetic > 1 MB transcript → completes without OOM, parses all lines across multiple ticks

A fixture file at `AgentStatusTests/Fixtures/concurrent-tools.jsonl` derived from a sanitized real transcript.

### Snapshot diff invariant test (new)
- Mutating `recentTools` only produces no `coreSnapshot` change event
- Mutating `status` produces exactly one `coreSnapshot` change event

This locks the perf invariant as a test, not a comment.

### UI
SwiftUI previews for: empty · 1 active · 3 active · each `WaitingDisplay` case · 10 recent with one error. No snapshot-image tests in this scope.

### `PerfStats` sanity
Counters monotonic, `ticks/sec` clamps non-negative, reset clears.

### Perf regression gate
`scripts/perf-check.sh` — replays a 30-second fixture transcript against an instrumented `TranscriptTailer`, prints ticks/sec, lines/sec, peak RSS via `/usr/bin/time -l`. Baseline numbers committed at `scripts/perf-baseline.txt`. PR body must include before/after numbers from this script. Manual gate; reproducible.

---

## Rollout

**One PR, one branch** (`feat/concurrency-aware-tools`). No feature flag — new sections render conditionally on data presence; brand-new sessions are pixel-identical to today.

**Suggested commit sequence:**
1. Data model (`EnrichedSession`, `CompletedTool`, `WaitingDisplay`) + pure helpers + helper tests.
2. `TranscriptTailer` ingestion changes (sidechain filter, `recentToolsRing`, dirty-bit recompute, chunked read) + integration tests + fixture.
3. `SessionStore` core/rich split + diff invariant test.
4. `SessionDetailView` Running / Recent / Waiting sections + previews.
5. `PerSessionStatusItem` tooltip enrichment.
6. `PerfStats` actor + dev-only gear-menu pane.
7. `scripts/perf-check.sh` + baseline; paste numbers in PR.
8. README: features bullet, project-layout file names, test count.

---

## Out of scope (deferred follow-ups)

These came up during brainstorming and are deliberately not included here:

- **Inline `SessionRow` concurrency badge** — analogous to the per-session item; same redraw-thrashing concern. Revisit with the sparkline rework.
- **Sparkline → "concurrency over time"** — repurpose the strip's y-axis from status to `activeTools.count`, with red tips for error buckets. Strictly more informative but visually a bigger change.
- **Subagent expansion** — drill into a sidechain on click. Needs parent-attribution plumbing.
- **Persisted Recent** — survives app restart (today's design is live-only, rebuilt by transcript replay).
- **Multi-tool pip on per-session icon** — bool-gated overlay when `activeTools.count > 1`. Belongs with the inline-row redesign.
- **Deletion of the deprecated `currentTool` field** — kept as nil for one release; remove in the consumer-migration PR.
