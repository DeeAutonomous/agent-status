# Concurrency-aware tools + waiting question — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `EnrichedSession.currentTool` (singular) with `activeTools[]` + `recentTools[]` so the popover honestly shows parallel work, add a tool-aware "Waiting" section, and enrich the per-session status-item tooltip — without regressing today's "~15 MB RAM, ~0% CPU idle" baseline.

**Architecture:** New types (`CompletedTool`, `WaitingDisplay`) plus three pure static helpers on `TranscriptTailer` (`isSidechain`, the `CompletedTool` constructor, and `waitingDisplay`) drive the data model. `TranscriptTailer.process(line:)` filters sidechain assistant messages, maintains a 10-entry recent-tools ring, and recomputes `activeTools` only behind a dirty bit. Initial-read is bounded to 1 MB chunks. `SessionStore.uiEqual` narrows its `enriched` comparison to a `coreEqual` that ignores `activeTools`/`recentTools`, so detail-only fields don't trigger menu-bar redraws. `SessionDetailView` gains three conditional sections (Waiting / Running now / Recent) wrapped in one popover-gated `TimelineView` for live elapsed timers. `PerSessionStatusItem` enriches its tooltip on every `update(with:)` call (no view-tree mutation).

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, AppKit (NSStatusItem/NSPopover), XCTest, XcodeGen, `xcodebuild` for test runs.

**Spec:** [`docs/superpowers/specs/2026-05-08-concurrency-aware-tools-design.md`](../specs/2026-05-08-concurrency-aware-tools-design.md)

---

## File Structure

**Modify:**
- `AgentStatus/Model/EnrichedSession.swift` — add `activeTools`, `recentTools` properties; add `CompletedTool` struct; add `coreEqual(_:)` method.
- `AgentStatus/Watching/TranscriptTailer.swift` — three new pure static helpers; sidechain filter; recent-tools ring; dirty-bit recompute; chunked initial read; replace `recomputeCurrentTool()`.
- `AgentStatus/Store/SessionStore.swift` — narrow `uiEqual`'s enriched comparison to `coreEqual`.
- `AgentStatus/UI/PerSession/SessionDetailView.swift` — replace the `currentTool(_:)` rendering with `WaitingSection` + `RunningNowSection` + `RecentToolsSection`.
- `AgentStatus/UI/PerSession/PerSessionStatusItem.swift` — enrich tooltip with pending-tool preview / concurrency count.
- `AgentStatusTests/TranscriptTailerTests.swift` — add helper tests.
- `AgentStatusTests/TranscriptParsingTests.swift` — add integration tests using a real temp file fixture.
- `README.md` — features bullet, project layout, test count.

**Create:**
- `AgentStatus/Model/WaitingDisplay.swift` — the `WaitingDisplay` enum.
- `AgentStatus/Watching/PerfStats.swift` — debug counters actor.
- `AgentStatusTests/WaitingDisplayTests.swift` — enum-rendering tests.
- `AgentStatusTests/CompletedToolTests.swift` — duration computation tests.
- `AgentStatusTests/EnrichedSessionCoreEqualTests.swift` — pin the perf invariant in a test.
- `AgentStatusTests/PerfStatsTests.swift` — counter-monotonicity tests.
- `AgentStatusTests/Fixtures/concurrent-tools.jsonl` — sanitized real transcript with parallel tool_uses.
- `scripts/perf-check.sh` — replays a synthetic transcript through `TranscriptTailer.process(line:)` and prints lines/sec, ms/tick, peak RSS.
- `scripts/perf-baseline.txt` — checked-in baseline numbers.

**Test command (used in every task):**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/<TestClass> 2>&1 | tail -20
```

**XcodeGen note:** Whenever a task creates a *new* `.swift` file (test or production), run `xcodegen generate` after the file is created and before running the test command. The README states `brew install xcodegen` is the install path.

---

### Task 1: Add `CompletedTool` to `EnrichedSession.swift`

**Files:**
- Modify: `AgentStatus/Model/EnrichedSession.swift`
- Create: `AgentStatusTests/CompletedToolTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AgentStatusTests/CompletedToolTests.swift`:

```swift
import XCTest
@testable import AgentStatus

final class CompletedToolTests: XCTestCase {
    func testInitFromActiveToolCopiesIdentityFields() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let active = ActiveTool(id: "toolu_1", name: "Bash", preview: "npm test",
                                startedAt: start, rawInputJSON: nil)
        let end = start.addingTimeInterval(2.5)

        let done = CompletedTool(completing: active, isError: false, at: end)

        XCTAssertEqual(done.id, "toolu_1")
        XCTAssertEqual(done.name, "Bash")
        XCTAssertEqual(done.preview, "npm test")
        XCTAssertEqual(done.startedAt, start)
        XCTAssertEqual(done.endedAt, end)
        XCTAssertFalse(done.isError)
        XCTAssertEqual(done.duration, 2.5, accuracy: 0.0001)
    }

    func testIsErrorIsCarriedThrough() {
        let active = ActiveTool(id: "x", name: "Bash", preview: "",
                                startedAt: .now, rawInputJSON: nil)
        let done = CompletedTool(completing: active, isError: true, at: .now)
        XCTAssertTrue(done.isError)
    }
}
```

- [ ] **Step 2: Verify it fails**

```bash
xcodegen generate
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/CompletedToolTests 2>&1 | tail -20
```

Expected: build error, "type 'CompletedTool' not in scope" or similar.

- [ ] **Step 3: Extend `ActiveTool` and add `CompletedTool` in `EnrichedSession.swift`**

In `AgentStatus/Model/EnrichedSession.swift`, modify the `ActiveTool` struct (≈ lines 40-45) to add a `rawInputJSON` field used by `SessionDetailView` to render `AskUserQuestion` / subagent waiting templates:

```swift
/// One in-flight tool call.
struct ActiveTool: Hashable, Sendable {
    let id: String              // Anthropic tool_use_id
    let name: String            // "Bash", "Edit", "Write", "Read", etc.
    let preview: String         // one-line summary of the tool's input
    let startedAt: Date
    /// JSON-encoded copy of the tool's `input` dict, if any. Stored as `Data`
    /// so the struct stays `Hashable, Sendable` under Swift 6 strict concurrency.
    /// Decoded at render time by callers that need question text / options /
    /// subagent prompt fields. Nil when input was empty or un-encodable.
    /// Defaulted so call sites that don't yet thread input through compile cleanly
    /// during the multi-task migration.
    let rawInputJSON: Data?

    init(id: String, name: String, preview: String, startedAt: Date, rawInputJSON: Data? = nil) {
        self.id = id
        self.name = name
        self.preview = preview
        self.startedAt = startedAt
        self.rawInputJSON = rawInputJSON
    }
}
```

Append after the `ActiveTool` extension (after the closing `}` near line 76):

```swift
/// One completed top-level tool call — pushed into `EnrichedSession.recentTools`
/// when its `tool_result` arrives. Sidechain (subagent-internal) tool calls do
/// not enter this list.
struct CompletedTool: Hashable, Sendable {
    let id: String              // Anthropic tool_use_id
    let name: String            // "Bash", "Edit", "Agent", ...
    let preview: String         // Reuses ActiveTool.preview at start time
    let startedAt: Date
    let endedAt: Date
    let isError: Bool           // From the tool_result.is_error block

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    init(completing active: ActiveTool, isError: Bool, at end: Date) {
        self.id = active.id
        self.name = active.name
        self.preview = active.preview
        self.startedAt = active.startedAt
        self.endedAt = end
        self.isError = isError
    }
}
```

- [ ] **Step 4: Verify it passes**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/CompletedToolTests 2>&1 | tail -10
```

Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add AgentStatus/Model/EnrichedSession.swift \
        AgentStatusTests/CompletedToolTests.swift \
        AgentStatus.xcodeproj
git commit -m "feat(model): add CompletedTool"
```

---

### Task 2: Create `WaitingDisplay` enum

**Files:**
- Create: `AgentStatus/Model/WaitingDisplay.swift`
- Create: `AgentStatusTests/WaitingDisplayTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AgentStatusTests/WaitingDisplayTests.swift`:

```swift
import XCTest
@testable import AgentStatus

final class WaitingDisplayTests: XCTestCase {
    func testToolCaseEquality() {
        let a = WaitingDisplay.tool(name: "Bash", preview: "npm test")
        let b = WaitingDisplay.tool(name: "Bash", preview: "npm test")
        XCTAssertEqual(a, b)
    }

    func testAskUserQuestionCarriesOptions() {
        let d = WaitingDisplay.askUserQuestion(
            text: "Which DB?", options: ["Postgres", "SQLite"]
        )
        if case let .askUserQuestion(text, options) = d {
            XCTAssertEqual(text, "Which DB?")
            XCTAssertEqual(options, ["Postgres", "SQLite"])
        } else {
            XCTFail("expected .askUserQuestion case")
        }
    }

    func testSubagentTruncatesIsCallerSide() {
        // The enum stores the prompt verbatim; truncation happens at render time.
        let d = WaitingDisplay.subagent(description: "do thing", prompt: String(repeating: "x", count: 500))
        if case let .subagent(_, prompt) = d {
            XCTAssertEqual(prompt.count, 500)
        } else {
            XCTFail("expected .subagent case")
        }
    }

    func testUnknownPreservesRawString() {
        let d = WaitingDisplay.unknown(rawWaitingFor: "approve Foo")
        XCTAssertEqual(d, .unknown(rawWaitingFor: "approve Foo"))
    }
}
```

- [ ] **Step 2: Verify it fails**

```bash
xcodegen generate
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/WaitingDisplayTests 2>&1 | tail -20
```

Expected: build error, "type 'WaitingDisplay' not in scope".

- [ ] **Step 3: Create `WaitingDisplay.swift`**

Create `AgentStatus/Model/WaitingDisplay.swift`:

```swift
import Foundation

/// What the agent is waiting on, in a shape `SessionDetailView` can render.
/// Built by `TranscriptTailer.waitingDisplay(for:pending:pendingInput:)` from
/// the session's `waitingFor` string plus the most recent in-flight tool_use.
///
/// All cases are pure data — no SwiftUI imports here. Truncation, formatting,
/// and option-count limits live at the render site.
enum WaitingDisplay: Hashable, Sendable {
    /// Permission gate for a regular tool. preview is `ActiveTool.preview` output.
    case tool(name: String, preview: String)

    /// Permission gate for `AskUserQuestion`. options are option labels only —
    /// option-level descriptions are intentionally dropped for compactness.
    case askUserQuestion(text: String, options: [String])

    /// Permission gate for a `Task` (sub-agent) invocation.
    case subagent(description: String, prompt: String)

    /// Anything else — fall back to the raw waitingFor string.
    case unknown(rawWaitingFor: String)
}
```

- [ ] **Step 4: Verify it passes**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/WaitingDisplayTests 2>&1 | tail -10
```

Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add AgentStatus/Model/WaitingDisplay.swift \
        AgentStatusTests/WaitingDisplayTests.swift \
        AgentStatus.xcodeproj
git commit -m "feat(model): add WaitingDisplay enum"
```

---

### Task 3: Add `activeTools` + `recentTools` to `EnrichedSession`

**Files:**
- Modify: `AgentStatus/Model/EnrichedSession.swift`
- Modify: `AgentStatusTests/TranscriptParsingTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `AgentStatusTests/TranscriptParsingTests.swift` inside the existing class:

```swift
    func testEnrichedSessionEmptyHasNoActiveOrRecentTools() {
        let e = EnrichedSession.empty
        XCTAssertEqual(e.activeTools, [])
        XCTAssertEqual(e.recentTools, [])
    }
```

- [ ] **Step 2: Verify it fails**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/TranscriptParsingTests/testEnrichedSessionEmptyHasNoActiveOrRecentTools 2>&1 | tail -20
```

Expected: build error, "value of type 'EnrichedSession' has no member 'activeTools'".

- [ ] **Step 3: Add the fields to `EnrichedSession`**

In `AgentStatus/Model/EnrichedSession.swift`, after the existing `var toolCalls: Int = 0` line (≈ line 34), insert:

```swift
    /// All in-flight top-level tool calls, ordered by `startedAt` ascending.
    /// Sidechain (sub-agent internal) tool calls are filtered out at ingestion.
    var activeTools: [ActiveTool] = []

    /// Recently-completed top-level tool calls, newest-first, capped at 10.
    /// Sidechain tool calls are filtered out at ingestion.
    var recentTools: [CompletedTool] = []
```

- [ ] **Step 4: Verify it passes**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/TranscriptParsingTests 2>&1 | tail -10
```

Expected: `Executed 5 tests, with 0 failures` (4 existing + 1 new).

- [ ] **Step 5: Commit**

```bash
git add AgentStatus/Model/EnrichedSession.swift \
        AgentStatusTests/TranscriptParsingTests.swift
git commit -m "feat(model): add activeTools and recentTools to EnrichedSession"
```

---

### Task 4: `EnrichedSession.coreEqual(_:)` — perf invariant

**Files:**
- Modify: `AgentStatus/Model/EnrichedSession.swift`
- Create: `AgentStatusTests/EnrichedSessionCoreEqualTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AgentStatusTests/EnrichedSessionCoreEqualTests.swift`:

```swift
import XCTest
@testable import AgentStatus

/// Pins the perf invariant: mutating activeTools / recentTools must not
/// flip coreEqual (which gates SessionStore @Published updates).
final class EnrichedSessionCoreEqualTests: XCTestCase {
    func testCoreEqualIgnoresActiveTools() {
        var a = EnrichedSession.empty
        var b = EnrichedSession.empty
        b.activeTools = [ActiveTool(id: "x", name: "Bash", preview: "npm",
                                    startedAt: .now, rawInputJSON: nil)]
        XCTAssertTrue(a.coreEqual(b))
    }

    func testCoreEqualIgnoresRecentTools() {
        var a = EnrichedSession.empty
        var b = EnrichedSession.empty
        let active = ActiveTool(id: "x", name: "Bash", preview: "npm",
                                startedAt: .now, rawInputJSON: nil)
        b.recentTools = [CompletedTool(completing: active, isError: false, at: .now)]
        XCTAssertTrue(a.coreEqual(b))
    }

    func testCoreEqualNoticesCurrentModelChange() {
        var a = EnrichedSession.empty
        var b = EnrichedSession.empty
        b.currentModel = "claude-opus-4-7"
        XCTAssertFalse(a.coreEqual(b))
    }

    func testCoreEqualNoticesAITitleChange() {
        var a = EnrichedSession.empty
        var b = EnrichedSession.empty
        b.aiTitle = "Investigate flake"
        XCTAssertFalse(a.coreEqual(b))
    }

    func testCoreEqualNoticesPermissionMode() {
        var a = EnrichedSession.empty
        var b = EnrichedSession.empty
        b.permissionMode = "plan"
        XCTAssertFalse(a.coreEqual(b))
    }
}
```

- [ ] **Step 2: Verify it fails**

```bash
xcodegen generate
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/EnrichedSessionCoreEqualTests 2>&1 | tail -20
```

Expected: build error, "value of type 'EnrichedSession' has no member 'coreEqual'".

- [ ] **Step 3: Add `coreEqual` to `EnrichedSession`**

In `AgentStatus/Model/EnrichedSession.swift`, before the `static let empty = EnrichedSession()` line (≈ line 36), insert:

```swift
    /// Equality view used by `SessionStore.uiEqual` to gate UI republish events.
    /// Excludes `activeTools` and `recentTools` so detail-only churn doesn't
    /// thrash the menu bar. Keep this in sync with the row's actual visual
    /// dependencies — anything the menu-bar row reads must compare here.
    func coreEqual(_ other: EnrichedSession) -> Bool {
        currentModel == other.currentModel
            && lastStopReason == other.lastStopReason
            && permissionMode == other.permissionMode
            && aiTitle == other.aiTitle
            && lastUserPrompt == other.lastUserPrompt
            && lastAssistantText == other.lastAssistantText
            && subagentName == other.subagentName
            && tokens == other.tokens
            && estimatedCost == other.estimatedCost
            && errorCount == other.errorCount
            && assistantTurns == other.assistantTurns
            && toolCalls == other.toolCalls
            && currentTool == other.currentTool
    }
```

- [ ] **Step 4: Verify it passes**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/EnrichedSessionCoreEqualTests 2>&1 | tail -10
```

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add AgentStatus/Model/EnrichedSession.swift \
        AgentStatusTests/EnrichedSessionCoreEqualTests.swift \
        AgentStatus.xcodeproj
git commit -m "feat(model): add EnrichedSession.coreEqual for perf-gating"
```

---

### Task 5: `TranscriptTailer.isSidechain(_:)` helper

**Files:**
- Modify: `AgentStatus/Watching/TranscriptTailer.swift`
- Modify: `AgentStatusTests/TranscriptTailerTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `AgentStatusTests/TranscriptTailerTests.swift` (before the closing `}`):

```swift
    // MARK: - isSidechain

    func testIsSidechainTrueWhenFlagPresent() {
        XCTAssertTrue(TranscriptTailer.isSidechain(["isSidechain": true]))
    }

    func testIsSidechainFalseWhenFlagAbsent() {
        XCTAssertFalse(TranscriptTailer.isSidechain([:]))
    }

    func testIsSidechainFalseWhenFlagFalse() {
        XCTAssertFalse(TranscriptTailer.isSidechain(["isSidechain": false]))
    }

    func testIsSidechainFalseWhenFlagWrongType() {
        // Bool-only — string "true" must not count as truthy.
        XCTAssertFalse(TranscriptTailer.isSidechain(["isSidechain": "true"]))
    }
```

- [ ] **Step 2: Verify it fails**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/TranscriptTailerTests 2>&1 | tail -20
```

Expected: build error, "type 'TranscriptTailer' has no member 'isSidechain'".

- [ ] **Step 3: Add the helper**

In `AgentStatus/Watching/TranscriptTailer.swift`, after the `aiTitle(fromEvent:)` static helper (around line 70), insert:

```swift
    /// True when an `assistant` JSON record is part of a sub-agent's sidechain.
    /// Top-level assistant messages omit this key or set it to `false`.
    static func isSidechain(_ json: [String: Any]) -> Bool {
        (json["isSidechain"] as? Bool) == true
    }
```

- [ ] **Step 4: Verify it passes**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/TranscriptTailerTests 2>&1 | tail -10
```

Expected: 4 new tests pass alongside existing ones.

- [ ] **Step 5: Commit**

```bash
git add AgentStatus/Watching/TranscriptTailer.swift \
        AgentStatusTests/TranscriptTailerTests.swift
git commit -m "feat(tailer): add isSidechain pure helper"
```

---

### Task 6: `TranscriptTailer.waitingDisplay` helper

**Files:**
- Modify: `AgentStatus/Watching/TranscriptTailer.swift`
- Modify: `AgentStatusTests/TranscriptTailerTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `AgentStatusTests/TranscriptTailerTests.swift`:

```swift
    // MARK: - waitingDisplay

    private func makeActive(name: String, preview: String) -> ActiveTool {
        ActiveTool(id: "id", name: name, preview: preview, startedAt: .now, rawInputJSON: nil)
    }

    func testWaitingDisplayNilWhenNotWaiting() {
        XCTAssertNil(TranscriptTailer.waitingDisplay(for: nil, pending: nil, pendingInput: nil))
    }

    func testWaitingDisplayToolCase() {
        let pending = makeActive(name: "Bash", preview: "npm test")
        let d = TranscriptTailer.waitingDisplay(
            for: "approve Bash", pending: pending, pendingInput: nil
        )
        XCTAssertEqual(d, .tool(name: "Bash", preview: "npm test"))
    }

    func testWaitingDisplayAskUserQuestion() {
        let pending = makeActive(name: "AskUserQuestion", preview: "")
        let input: [String: Any] = [
            "questions": [[
                "question": "Which DB?",
                "options": [
                    ["label": "Postgres"],
                    ["label": "SQLite"],
                ],
            ]],
        ]
        let d = TranscriptTailer.waitingDisplay(
            for: "approve AskUserQuestion", pending: pending, pendingInput: input
        )
        XCTAssertEqual(d, .askUserQuestion(text: "Which DB?", options: ["Postgres", "SQLite"]))
    }

    func testWaitingDisplayAskUserQuestionEmptyOptions() {
        let pending = makeActive(name: "AskUserQuestion", preview: "")
        let input: [String: Any] = [
            "questions": [["question": "Proceed?", "options": [[String: Any]]()]],
        ]
        let d = TranscriptTailer.waitingDisplay(
            for: "approve AskUserQuestion", pending: pending, pendingInput: input
        )
        XCTAssertEqual(d, .askUserQuestion(text: "Proceed?", options: []))
    }

    func testWaitingDisplaySubagent() {
        let pending = makeActive(name: "Task", preview: "research-foo")
        let input: [String: Any] = [
            "description": "research-foo",
            "prompt": "Find all references to toolStarts and report them.",
        ]
        let d = TranscriptTailer.waitingDisplay(
            for: "approve Task", pending: pending, pendingInput: input
        )
        XCTAssertEqual(d, .subagent(
            description: "research-foo",
            prompt: "Find all references to toolStarts and report them."
        ))
    }

    func testWaitingDisplaySubagentMissingPromptDefaultsToEmpty() {
        let pending = makeActive(name: "Task", preview: "do thing")
        let input: [String: Any] = ["description": "do thing"]
        let d = TranscriptTailer.waitingDisplay(
            for: "approve Task", pending: pending, pendingInput: input
        )
        XCTAssertEqual(d, .subagent(description: "do thing", prompt: ""))
    }

    func testWaitingDisplayUnknownFallback() {
        // No pending tool we recognize → fall back to raw string verbatim.
        let d = TranscriptTailer.waitingDisplay(
            for: "approve Foo", pending: nil, pendingInput: nil
        )
        XCTAssertEqual(d, .unknown(rawWaitingFor: "approve Foo"))
    }
```

- [ ] **Step 2: Verify it fails**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/TranscriptTailerTests 2>&1 | tail -20
```

Expected: build error, "type 'TranscriptTailer' has no member 'waitingDisplay'".

- [ ] **Step 3: Add the helper**

In `AgentStatus/Watching/TranscriptTailer.swift`, after `isSidechain(_:)` (the helper added in Task 5), insert:

```swift
    /// Build a `WaitingDisplay` from the raw `waitingFor` string and the most
    /// recent in-flight tool_use (if any). Pure — no I/O, no state.
    /// Returns nil when not waiting (`waitingFor == nil`).
    ///
    /// Routing rules:
    ///   - `pending.name == "AskUserQuestion"` → `.askUserQuestion(text, options)`
    ///     using `pendingInput["questions"][0]`.
    ///   - `pending.name == "Task"` → `.subagent(description, prompt)` from `pendingInput`.
    ///   - any other `pending` → `.tool(name, preview)`.
    ///   - no `pending` → `.unknown(rawWaitingFor)`.
    static func waitingDisplay(
        for waitingFor: String?,
        pending: ActiveTool?,
        pendingInput: [String: Any]?
    ) -> WaitingDisplay? {
        guard let raw = waitingFor else { return nil }

        guard let p = pending else {
            return .unknown(rawWaitingFor: raw)
        }

        switch p.name {
        case "AskUserQuestion":
            let questions = (pendingInput?["questions"] as? [[String: Any]]) ?? []
            let first = questions.first ?? [:]
            let text = (first["question"] as? String) ?? ""
            let options = ((first["options"] as? [[String: Any]]) ?? []).compactMap {
                $0["label"] as? String
            }
            return .askUserQuestion(text: text, options: options)

        case "Task":
            let description = (pendingInput?["description"] as? String) ?? ""
            let prompt = (pendingInput?["prompt"] as? String) ?? ""
            return .subagent(description: description, prompt: prompt)

        default:
            return .tool(name: p.name, preview: p.preview)
        }
    }
```

- [ ] **Step 4: Verify it passes**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/TranscriptTailerTests 2>&1 | tail -10
```

Expected: 7 new tests pass.

- [ ] **Step 5: Commit**

```bash
git add AgentStatus/Watching/TranscriptTailer.swift \
        AgentStatusTests/TranscriptTailerTests.swift
git commit -m "feat(tailer): add waitingDisplay pure helper"
```

---

### Task 7: Sidechain filter in `handleAssistantMessage`

**Files:**
- Modify: `AgentStatus/Watching/TranscriptTailer.swift`
- Modify: `AgentStatusTests/TranscriptParsingTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `AgentStatusTests/TranscriptParsingTests.swift` (before the closing `}`):

```swift
    // MARK: - Sidechain filter
    //
    // Top-level assistant messages bump toolCalls; sidechain ones must not.

    func testSidechainAssistantMessageDoesNotIncrementToolCalls() async {
        let tailer = TranscriptTailer(sessionId: "sc-test", cwd: URL(fileURLWithPath: "/tmp"))
        let json = makeAssistantToolUseJSON(toolUseId: "x", name: "Bash", isSidechain: true)
        await tailer._test_processLine(jsonString(json))
        let snap = await tailer._test_state
        XCTAssertEqual(snap.toolCalls, 0, "sidechain tool_use must not bump counter")
        XCTAssertTrue(snap.activeTools.isEmpty)
    }

    func testTopLevelAssistantMessageIncrementsToolCalls() async {
        let tailer = TranscriptTailer(sessionId: "tl-test", cwd: URL(fileURLWithPath: "/tmp"))
        let json = makeAssistantToolUseJSON(toolUseId: "x", name: "Bash", isSidechain: false)
        await tailer._test_processLine(jsonString(json))
        let snap = await tailer._test_state
        XCTAssertEqual(snap.toolCalls, 1)
        XCTAssertEqual(snap.activeTools.count, 1)
        XCTAssertEqual(snap.activeTools.first?.name, "Bash")
    }

    // MARK: - Test helpers

    private func makeAssistantToolUseJSON(toolUseId: String, name: String, isSidechain: Bool) -> [String: Any] {
        var top: [String: Any] = [
            "type": "assistant",
            "message": [
                "model": "claude-opus-4-7",
                "stop_reason": "tool_use",
                "content": [
                    [
                        "type": "tool_use",
                        "id": toolUseId,
                        "name": name,
                        "input": ["command": "echo hi"],
                    ],
                ],
            ],
        ]
        if isSidechain { top["isSidechain"] = true }
        return top
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }
```

- [ ] **Step 2: Verify it fails**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/TranscriptParsingTests 2>&1 | tail -20
```

Expected: build error — `_test_processLine` and `_test_state` don't exist.

- [ ] **Step 3: Add test hooks to `TranscriptTailer`**

At the bottom of `AgentStatus/Watching/TranscriptTailer.swift`, before the closing `}` of the actor, add:

```swift
    // MARK: - Test-only hooks
    //
    // Bypass file I/O so unit tests can drive the actor directly. Underscored
    // names mark them as not part of the production surface.
    func _test_processLine(_ line: String) {
        process(line: line)
    }

    var _test_state: EnrichedSession { state }
```

Then in `process(line:)`, in the `case "assistant":` branch, replace the existing call:

```swift
        case "assistant":
            handleAssistantMessage(json)
```

with:

```swift
        case "assistant":
            if Self.isSidechain(json) { return }
            handleAssistantMessage(json)
```

- [ ] **Step 4: Verify it passes**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/TranscriptParsingTests 2>&1 | tail -10
```

Expected: both new tests pass.

- [ ] **Step 5: Commit**

```bash
git add AgentStatus/Watching/TranscriptTailer.swift \
        AgentStatusTests/TranscriptParsingTests.swift
git commit -m "feat(tailer): filter sidechain assistant messages from tool tracking"
```

---

### Task 8: Track concurrent active tools in `state.activeTools`

**Files:**
- Modify: `AgentStatus/Watching/TranscriptTailer.swift`
- Modify: `AgentStatusTests/TranscriptParsingTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `AgentStatusTests/TranscriptParsingTests.swift`:

```swift
    func testThreeConcurrentToolUsesProduceThreeActiveTools() async {
        let tailer = TranscriptTailer(sessionId: "para", cwd: URL(fileURLWithPath: "/tmp"))
        let json: [String: Any] = [
            "type": "assistant",
            "message": [
                "model": "claude-opus-4-7",
                "content": [
                    ["type": "tool_use", "id": "a", "name": "Bash", "input": ["command": "one"]],
                    ["type": "tool_use", "id": "b", "name": "Bash", "input": ["command": "two"]],
                    ["type": "tool_use", "id": "c", "name": "Read", "input": ["file_path": "/tmp/x"]],
                ],
            ],
        ]
        await tailer._test_processLine(jsonString(json))
        let snap = await tailer._test_state
        XCTAssertEqual(snap.activeTools.count, 3)
        // Active tools are sorted by startedAt ascending — all three started
        // from the same assistant message timestamp, so ordering by id is
        // implementation-defined; just check the set.
        XCTAssertEqual(Set(snap.activeTools.map(\.id)), ["a", "b", "c"])
    }
```

- [ ] **Step 2: Verify it fails**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/TranscriptParsingTests/testThreeConcurrentToolUsesProduceThreeActiveTools 2>&1 | tail -20
```

Expected: assertion failure — `snap.activeTools` is empty (the existing code only sets `currentTool`).

- [ ] **Step 3: Replace `recomputeCurrentTool` with `recomputeActiveAndRecent`**

In `AgentStatus/Watching/TranscriptTailer.swift`, first widen the `toolStarts` tuple type from `(name: String, preview: String, at: Date)` to also carry the encoded input dict. Find the existing declaration (≈ line 29):

```swift
    private var toolStarts: [String: (name: String, preview: String, at: Date)] = [:]
```

Replace with:

```swift
    private var toolStarts: [String: (name: String, preview: String, at: Date, inputJSON: Data?)] = [:]
```

Locate the existing `recomputeCurrentTool()` (≈ line 246-258) and replace the entire function with:

```swift
    /// Snapshot `toolStarts` into `state.activeTools` (sorted by startedAt asc)
    /// and `recentToolsRing` into `state.recentTools` (newest-first).
    /// Called only when `toolStarts` or `recentToolsRing` mutates; the
    /// `activeAndRecentDirty` flag prevents redundant recomputes per tick.
    private func recomputeActiveAndRecent() {
        guard activeAndRecentDirty else { return }
        activeAndRecentDirty = false

        state.activeTools = toolStarts
            .map {
                ActiveTool(
                    id: $0.key,
                    name: $0.value.name,
                    preview: $0.value.preview,
                    startedAt: $0.value.at,
                    rawInputJSON: $0.value.inputJSON
                )
            }
            .sorted { $0.startedAt < $1.startedAt }

        state.recentTools = Array(recentToolsRing.reversed())   // newest-first
        // currentTool kept nil — deprecated; UI consumers migrate next.
        state.currentTool = nil
    }
```

Add the supporting state above the `init` (where `state` lives, around line 28-29):

```swift
    private var recentToolsRing: [CompletedTool] = []
    private static let recentToolsCap = 10
    private var activeAndRecentDirty = false
```

In `handleAssistantMessage(_:)`, in the `tool_use` block (around line 232-238), capture and encode the input, then set the dirty flag:

```swift
            case "tool_use":
                state.toolCalls += 1
                if let id = block["id"] as? String,
                   let name = block["name"] as? String {
                    let input = block["input"] as? [String: Any] ?? [:]
                    let preview = ActiveTool.preview(toolName: name, input: input)
                    let inputJSON = input.isEmpty ? nil
                        : (try? JSONSerialization.data(withJSONObject: input))
                    toolStarts[id] = (name: name, preview: preview, at: now, inputJSON: inputJSON)
                    activeAndRecentDirty = true
                }
```

At the very bottom of `handleAssistantMessage(_:)`, replace `recomputeCurrentTool()` with `recomputeActiveAndRecent()`.

In `handleUserMessage(_:)`, the `tool_result` branch currently calls `recomputeCurrentTool()`. Replace those calls with `recomputeActiveAndRecent()` and set the dirty flag. The relevant block (≈ line 181-191):

```swift
            for block in blocks {
                if (block["type"] as? String) == "tool_result" {
                    if let id = block["tool_use_id"] as? String, let starting = toolStarts[id] {
                        let active = ActiveTool(
                            id: id,
                            name: starting.name,
                            preview: starting.preview,
                            startedAt: starting.at,
                            rawInputJSON: starting.inputJSON
                        )
                        let isError = (block["is_error"] as? Bool) == true
                        let completion = CompletedTool(completing: active, isError: isError, at: Date())
                        recentToolsRing.append(completion)
                        if recentToolsRing.count > Self.recentToolsCap {
                            recentToolsRing.removeFirst(recentToolsRing.count - Self.recentToolsCap)
                        }
                        toolStarts.removeValue(forKey: id)
                        activeAndRecentDirty = true
                        recomputeActiveAndRecent()
                    }
                    if (block["is_error"] as? Bool) == true {
                        state.errorCount += 1
                    }
                }
            }
```

(Remove the now-unused `recomputeCurrentTool()` function — it's been replaced.)

- [ ] **Step 4: Verify it passes**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/TranscriptParsingTests 2>&1 | tail -10
```

Expected: all tests pass including the new one.

- [ ] **Step 5: Commit**

```bash
git add AgentStatus/Watching/TranscriptTailer.swift \
        AgentStatusTests/TranscriptParsingTests.swift
git commit -m "feat(tailer): track concurrent activeTools and recentTools ring"
```

---

### Task 9: Tool completion populates `recentTools`

**Files:**
- Modify: `AgentStatusTests/TranscriptParsingTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `AgentStatusTests/TranscriptParsingTests.swift`:

```swift
    func testToolStartThenResultMovesToRecentTools() async {
        let tailer = TranscriptTailer(sessionId: "rt", cwd: URL(fileURLWithPath: "/tmp"))

        let start: [String: Any] = [
            "type": "assistant",
            "message": [
                "model": "claude-opus-4-7",
                "content": [
                    ["type": "tool_use", "id": "u1", "name": "Bash",
                     "input": ["command": "ls"]],
                ],
            ],
        ]
        await tailer._test_processLine(jsonString(start))

        let result: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    ["type": "tool_result", "tool_use_id": "u1",
                     "is_error": false],
                ],
            ],
        ]
        await tailer._test_processLine(jsonString(result))

        let snap = await tailer._test_state
        XCTAssertTrue(snap.activeTools.isEmpty, "completed tool should leave activeTools")
        XCTAssertEqual(snap.recentTools.count, 1)
        XCTAssertEqual(snap.recentTools.first?.id, "u1")
        XCTAssertEqual(snap.recentTools.first?.name, "Bash")
        XCTAssertFalse(snap.recentTools.first?.isError ?? true)
    }

    func testRecentToolsRingCapsAt10() async {
        let tailer = TranscriptTailer(sessionId: "ring", cwd: URL(fileURLWithPath: "/tmp"))
        // 12 start+result pairs → only the last 10 should remain.
        for i in 0..<12 {
            let id = "u\(i)"
            await tailer._test_processLine(jsonString([
                "type": "assistant",
                "message": [
                    "content": [
                        ["type": "tool_use", "id": id, "name": "Bash",
                         "input": ["command": "echo \(i)"]],
                    ],
                ],
            ]))
            await tailer._test_processLine(jsonString([
                "type": "user",
                "message": [
                    "content": [
                        ["type": "tool_result", "tool_use_id": id, "is_error": false],
                    ],
                ],
            ]))
        }
        let snap = await tailer._test_state
        XCTAssertEqual(snap.recentTools.count, 10)
        // Newest first: the last completion (u11) should be at index 0.
        XCTAssertEqual(snap.recentTools.first?.id, "u11")
        // u0 and u1 should be gone.
        XCTAssertFalse(snap.recentTools.contains { $0.id == "u0" })
        XCTAssertFalse(snap.recentTools.contains { $0.id == "u1" })
    }

    func testToolErrorIsCarriedIntoRecent() async {
        let tailer = TranscriptTailer(sessionId: "err", cwd: URL(fileURLWithPath: "/tmp"))
        await tailer._test_processLine(jsonString([
            "type": "assistant",
            "message": [
                "content": [
                    ["type": "tool_use", "id": "x", "name": "Bash",
                     "input": ["command": "false"]],
                ],
            ],
        ]))
        await tailer._test_processLine(jsonString([
            "type": "user",
            "message": [
                "content": [
                    ["type": "tool_result", "tool_use_id": "x", "is_error": true],
                ],
            ],
        ]))
        let snap = await tailer._test_state
        XCTAssertEqual(snap.recentTools.first?.isError, true)
    }
```

- [ ] **Step 2: Verify it passes**

The implementation from Task 8 already handles this. Run:

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/TranscriptParsingTests 2>&1 | tail -10
```

Expected: all tests pass — these new ones validate Task 8's implementation.

- [ ] **Step 3: Commit**

```bash
git add AgentStatusTests/TranscriptParsingTests.swift
git commit -m "test(tailer): pin recentTools ring + error carry-through"
```

---

### Task 10: Bound initial-read to 1 MB chunks

**Files:**
- Modify: `AgentStatus/Watching/TranscriptTailer.swift`
- Modify: `AgentStatusTests/TranscriptParsingTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `AgentStatusTests/TranscriptParsingTests.swift`:

```swift
    func testChunkedReadParsesLargeTranscriptInOneTick() async throws {
        // Build a 2 MB synthetic transcript and feed it via the real file-based
        // tick path. The tailer must parse it without OOM and produce expected
        // state, regardless of total file size.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-status-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Encode the cwd as Claude does: replace "/" with "-".
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let encoded = dir.path.replacingOccurrences(of: "/", with: "-")
        let projDir = projects.appendingPathComponent(encoded, isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projDir) }

        let sessionId = "chunk-\(UUID().uuidString)"
        let file = projDir.appendingPathComponent("\(sessionId).jsonl")

        // ~2 MB of assistant tool_use lines (each ~200 bytes → ~10 000 lines).
        let oneLine = """
        {"type":"assistant","message":{"model":"claude-opus-4-7","content":[{"type":"tool_use","id":"id-XXXX","name":"Bash","input":{"command":"echo XXXX"}}]}}
        """
        var blob = ""
        for i in 0..<10_000 {
            blob += oneLine.replacingOccurrences(of: "XXXX", with: String(i)) + "\n"
        }
        try blob.write(to: file, atomically: true, encoding: .utf8)

        let tailer = TranscriptTailer(sessionId: sessionId, cwd: dir, pollInterval: 0.05)
        await tailer.start()
        defer { Task { await tailer.stop() } }

        // Drain a few ticks until the file is fully read. Cap so the test
        // can't hang.
        var snap = EnrichedSession.empty
        for await s in tailer.snapshots.prefix(40) {
            snap = s
            if snap.toolCalls >= 10_000 { break }
        }
        XCTAssertEqual(snap.toolCalls, 10_000, "all lines should be parsed across multiple chunks")
    }
```

- [ ] **Step 2: Verify it fails OR slow**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/TranscriptParsingTests/testChunkedReadParsesLargeTranscriptInOneTick 2>&1 | tail -20
```

Expected: test passes today (single read works for 2 MB) — but we need the chunking to bound *worst-case* memory. Continue to Step 3 to add the chunking and confirm parity.

- [ ] **Step 3: Implement chunked read**

In `AgentStatus/Watching/TranscriptTailer.swift`, in `tick()` (≈ lines 68-106), replace this block:

```swift
            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: offset)
            let data = handle.readData(ofLength: Int(size - offset))
            try handle.close()
            offset = size
```

with:

```swift
            // Chunked read: bound peak memory regardless of file size. A resumed
            // multi-MB transcript drains across multiple ticks instead of a
            // single jumbo allocation.
            let chunkCap: UInt64 = 1_048_576    // 1 MB
            let toRead = min(size - offset, chunkCap)
            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: offset)
            let data = handle.readData(ofLength: Int(toRead))
            try handle.close()
            offset += toRead
```

(Note: `offset = size` becomes `offset += toRead`. The next tick reads the next chunk.)

- [ ] **Step 4: Verify it passes**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/TranscriptParsingTests 2>&1 | tail -10
```

Expected: all tests pass; the large-transcript test draining across multiple ticks confirms the loop works.

- [ ] **Step 5: Commit**

```bash
git add AgentStatus/Watching/TranscriptTailer.swift \
        AgentStatusTests/TranscriptParsingTests.swift
git commit -m "perf(tailer): chunk initial read at 1 MB to bound peak memory"
```

---

### Task 11: Wire `coreEqual` into `SessionStore.uiEqual`

**Files:**
- Modify: `AgentStatus/Store/SessionStore.swift`
- Create: `AgentStatusTests/SessionStoreCoreEqualTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AgentStatusTests/SessionStoreCoreEqualTests.swift`:

```swift
import XCTest
@testable import AgentStatus

/// Pins the perf invariant at the store layer: a snapshot diff that differs
/// only in `enriched.activeTools` / `enriched.recentTools` does NOT count as
/// "ui-equal-changed" — i.e. menu-bar consumers don't get woken up.
@MainActor
final class SessionStoreCoreEqualTests: XCTestCase {
    func testActiveToolsChangeIsUIEqual() {
        let a = makeSnapshot(activeCount: 0)
        let b = makeSnapshot(activeCount: 3)
        XCTAssertTrue(SessionStore._test_uiEqual([a], [b]))
    }

    func testRecentToolsChangeIsUIEqual() {
        let a = makeSnapshot(recentCount: 0)
        let b = makeSnapshot(recentCount: 5)
        XCTAssertTrue(SessionStore._test_uiEqual([a], [b]))
    }

    func testStatusChangeIsNotUIEqual() {
        let a = makeSnapshot(status: .busy)
        let b = makeSnapshot(status: .waiting)
        XCTAssertFalse(SessionStore._test_uiEqual([a], [b]))
    }

    func testCurrentModelChangeIsNotUIEqual() {
        var ea = EnrichedSession.empty; ea.currentModel = "x"
        var eb = EnrichedSession.empty; eb.currentModel = "y"
        let a = makeSnapshot(enriched: ea)
        let b = makeSnapshot(enriched: eb)
        XCTAssertFalse(SessionStore._test_uiEqual([a], [b]))
    }

    private func makeSnapshot(
        status: SessionStatus = .busy,
        activeCount: Int = 0,
        recentCount: Int = 0,
        enriched: EnrichedSession? = nil
    ) -> SessionSnapshot {
        var e = enriched ?? EnrichedSession.empty
        e.activeTools = (0..<activeCount).map {
            ActiveTool(id: "a\($0)", name: "Bash", preview: "x",
                       startedAt: .now, rawInputJSON: nil)
        }
        let active0 = ActiveTool(id: "x", name: "Bash", preview: "x",
                                 startedAt: .now, rawInputJSON: nil)
        e.recentTools = (0..<recentCount).map { _ in
            CompletedTool(completing: active0, isError: false, at: .now)
        }
        return SessionSnapshot(
            id: "p:s",
            providerId: "p",
            pid: 1,
            sessionId: "s",
            cwd: URL(fileURLWithPath: "/tmp"),
            startedAt: .now,
            updatedAt: .now,
            status: status,
            waitingFor: nil,
            version: nil,
            kind: nil,
            entrypoint: nil,
            isAlive: true,
            enriched: e
        )
    }
}
```

- [ ] **Step 2: Verify it fails**

```bash
xcodegen generate
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/SessionStoreCoreEqualTests 2>&1 | tail -20
```

Expected: build error — `_test_uiEqual` does not exist.

- [ ] **Step 3: Narrow `uiEqual`'s enriched comparison and expose a test hook**

In `AgentStatus/Store/SessionStore.swift`, find the `uiEqual` function (≈ line 75-88). Replace the line:

```swift
                || x.enriched != y.enriched
```

with:

```swift
                || !enrichedCoreEqual(x.enriched, y.enriched)
```

Add this helper just below `uiEqual`:

```swift
    /// True when the menu-bar-row-relevant subset of the two enriched values
    /// match. Detail-only fields (`activeTools`, `recentTools`) are excluded
    /// so churn there doesn't trigger a row redraw.
    private static func enrichedCoreEqual(_ a: EnrichedSession?, _ b: EnrichedSession?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.coreEqual(y)
        default: return false
        }
    }

    /// Test-only hook so XCTest can pin the perf invariant.
    static func _test_uiEqual(_ a: [SessionSnapshot], _ b: [SessionSnapshot]) -> Bool {
        uiEqual(a, b)
    }
```

- [ ] **Step 4: Verify it passes**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/SessionStoreCoreEqualTests 2>&1 | tail -10
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add AgentStatus/Store/SessionStore.swift \
        AgentStatusTests/SessionStoreCoreEqualTests.swift \
        AgentStatus.xcodeproj
git commit -m "perf(store): exclude detail-only fields from uiEqual"
```

---

### Task 12: SessionDetailView — Waiting section

**Files:**
- Modify: `AgentStatus/UI/PerSession/SessionDetailView.swift`

- [ ] **Step 1: Add a `waitingSection(for:)` helper**

In `AgentStatus/UI/PerSession/SessionDetailView.swift`, add this private method anywhere among the other section helpers (e.g. after `currentTool(_:)` ≈ line 105):

```swift
    @ViewBuilder
    private func waitingSection(for s: SessionSnapshot) -> some View {
        let pending = s.enriched?.activeTools.last
        let pendingInput: [String: Any]? = pending?.rawInputJSON.flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
        if let display = TranscriptTailer.waitingDisplay(
            for: s.waitingFor, pending: pending, pendingInput: pendingInput
        ) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge.fill").foregroundStyle(.orange)
                    Text("Waiting · \(headlineLabel(for: display))")
                        .font(.subheadline.weight(.semibold))
                }
                detailLines(for: display)
            }
        }
    }

    private func headlineLabel(for d: WaitingDisplay) -> String {
        switch d {
        case .tool(let name, _):              return "approve \(name)"
        case .askUserQuestion:                 return "approve AskUserQuestion"
        case .subagent:                        return "approve Task"
        case .unknown(let raw):                return raw
        }
    }

    @ViewBuilder
    private func detailLines(for d: WaitingDisplay) -> some View {
        switch d {
        case .tool(_, let preview):
            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }

        case .askUserQuestion(let text, let options):
            VStack(alignment: .leading, spacing: 2) {
                if !text.isEmpty {
                    Text("\u{201C}\(text)\u{201D}")     // “…”
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                ForEach(Array(options.prefix(4).enumerated()), id: \.offset) { idx, label in
                    Text("  \(idx + 1). \(label)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

        case .subagent(let description, let prompt):
            VStack(alignment: .leading, spacing: 2) {
                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !prompt.isEmpty {
                    Text(prompt.count > 100 ? String(prompt.prefix(100)) + "\u{2026}" : prompt)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }

        case .unknown:
            EmptyView()
        }
    }
```

In `content(now:)`, locate the existing currentTool block (≈ lines 24-27):

```swift
                    if settings.showCurrentTool, let tool = s.enriched?.currentTool {
                        currentTool(tool)
                        Divider()
                    }
```

Replace it with:

```swift
                    if s.status == .waiting {
                        waitingSection(for: s)
                        Divider()
                    }
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' build 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual eyeball check via SwiftUI preview**

(Optional but recommended — open the file in Xcode and verify the preview canvas renders.)

- [ ] **Step 4: Run the full test suite**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add AgentStatus/UI/PerSession/SessionDetailView.swift
git commit -m "feat(ui): waiting section with tool-aware templates"
```

---

### Task 13: SessionDetailView — Running now section

**Files:**
- Modify: `AgentStatus/UI/PerSession/SessionDetailView.swift`

- [ ] **Step 1: Add the section helper**

In `AgentStatus/UI/PerSession/SessionDetailView.swift`, add after `waitingSection(for:)`:

```swift
    @ViewBuilder
    private func runningNowSection(for s: SessionSnapshot) -> some View {
        let active = s.enriched?.activeTools ?? []
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Running now (\(active.count))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                // ONE shared TimelineView wraps all rows — single 1 Hz tick
                // for the whole section instead of one per tool. Lives only
                // while the popover is on screen.
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let visible = Array(active.prefix(5))
                    let overflow = active.count - visible.count
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(visible, id: \.id) { tool in
                            runningRow(for: tool, now: ctx.date,
                                       isWaitingChild: s.status == .waiting)
                        }
                        if overflow > 0 {
                            Text("+\(overflow) more\u{2026}")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func runningRow(for tool: ActiveTool, now: Date, isWaitingChild: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10))
                .foregroundStyle(isWaitingChild ? .orange : .blue)
            Text(tool.name)
                .font(.system(size: 11, weight: .medium))
            if !tool.preview.isEmpty {
                Text(tool.preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Text(formatElapsed(from: tool.startedAt, to: now))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func formatElapsed(from start: Date, to now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(start)))
        if secs < 60 { return "t+\(secs)s" }
        let m = secs / 60, s = secs % 60
        return "t+\(m)m\(s)s"
    }
```

In `content(now:)`, after the waiting block, add:

```swift
                    runningNowSection(for: s)
```

(No `Divider()` after — `runningNowSection` is conditional so adding a divider would leave a stray separator when empty. The spec calls for empty sections to render nothing.)

- [ ] **Step 2: Verify it builds**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' build 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run full tests**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add AgentStatus/UI/PerSession/SessionDetailView.swift
git commit -m "feat(ui): running-now section with shared 1 Hz timeline"
```

---

### Task 14: SessionDetailView — Recent section

**Files:**
- Modify: `AgentStatus/UI/PerSession/SessionDetailView.swift`

- [ ] **Step 1: Add the section helper**

In `AgentStatus/UI/PerSession/SessionDetailView.swift`, add after `runningNowSection(for:)`:

```swift
    @ViewBuilder
    private func recentToolsSection(for s: SessionSnapshot) -> some View {
        let recent = s.enriched?.recentTools ?? []
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent (\(recent.count))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recent, id: \.id) { tool in
                        recentRow(for: tool)
                    }
                }
            }
        }
    }

    private func recentRow(for tool: CompletedTool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: tool.isError ? "xmark" : "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tool.isError ? .red : .green)
            Text(tool.name)
                .font(.system(size: 11, weight: .medium))
            if !tool.preview.isEmpty {
                Text(tool.preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Text(formatDuration(tool.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tool.isError ? .red.opacity(0.8) : .secondary)
                .monospacedDigit()
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        if d < 1 { return String(format: "%.1fs", d) }
        if d < 60 { return String(format: "%.1fs", d) }
        let m = Int(d) / 60, s = Int(d) % 60
        return "\(m)m\(s)s"
    }
```

In `content(now:)`, after `runningNowSection(for: s)`, add:

```swift
                    recentToolsSection(for: s)
```

- [ ] **Step 2: Verify it builds**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' build 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run full tests**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add AgentStatus/UI/PerSession/SessionDetailView.swift
git commit -m "feat(ui): recent tools section with duration + error pip"
```

---

### Task 15: Remove the now-dead `currentTool(_:)` rendering

**Files:**
- Modify: `AgentStatus/UI/PerSession/SessionDetailView.swift`

- [ ] **Step 1: Delete the `currentTool(_:)` helper**

In `AgentStatus/UI/PerSession/SessionDetailView.swift`, remove the `private func currentTool(_ tool: ActiveTool) -> some View` function in its entirety (the version that lives ≈ lines 83-105 in the pre-task file). The Waiting section replaces its visible role.

(`Settings.showCurrentTool` may now be unused. Leave it in place for one release per the spec's deprecation note.)

- [ ] **Step 2: Verify it builds**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' build 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`. Any "unused function" warnings are not allowed; if Xcode complains, you missed a call site — re-grep for `currentTool(`.

- [ ] **Step 3: Run full tests**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add AgentStatus/UI/PerSession/SessionDetailView.swift
git commit -m "refactor(ui): drop legacy currentTool rendering"
```

---

### Task 16: Enrich `PerSessionStatusItem` tooltip

**Files:**
- Modify: `AgentStatus/UI/PerSession/PerSessionStatusItem.swift`

- [ ] **Step 1: Replace the tooltip-build line**

In `AgentStatus/UI/PerSession/PerSessionStatusItem.swift`, find the existing tooltip refresh (≈ line 75):

```swift
        item.button?.toolTip = "\(snapshot.cwd.path) — \(snapshot.status.displayName)\(snapshot.waitingFor.map { " — \($0)" } ?? "")"
```

Replace with:

```swift
        item.button?.toolTip = Self.tooltip(for: snapshot)
```

Add this static helper at the bottom of the class, before the closing brace:

```swift
    /// Build a multi-line tooltip from a snapshot. Pure — no side effects.
    /// Free to call on every poll: the tooltip is hover-only and never causes
    /// a layout pass.
    static func tooltip(for snap: SessionSnapshot) -> String {
        var lines: [String] = []
        var headline = "\(snap.cwd.path) \u{2014} \(snap.status.displayName)"
        if let w = snap.waitingFor { headline += " \u{2014} \(w)" }

        let active = snap.enriched?.activeTools ?? []
        if active.count > 1 {
            headline += " \u{2014} \(active.count) tools running"
        } else if active.count == 1, let one = active.first {
            headline += " \u{2014} \(one.name) \(one.preview)".trimmingCharacters(in: .whitespaces)
        }
        lines.append(headline)

        // Second line: pending tool preview when waiting, or active list when running ≥ 2.
        if snap.status == .waiting, let pending = active.last, !pending.preview.isEmpty {
            lines.append("  \(pending.preview)")
        } else if active.count > 1 {
            let names = active.map(\.name).joined(separator: ", ")
            lines.append("  \(names)")
        }

        return lines.joined(separator: "\n")
    }
```

- [ ] **Step 2: Verify it builds**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' build 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Add a tooltip test**

Append to `AgentStatusTests/SessionStoreCoreEqualTests.swift` (or create a `PerSessionStatusItemTests.swift` if you prefer — the tooltip is a pure static function, easy to test):

Create `AgentStatusTests/PerSessionStatusItemTests.swift`:

```swift
import XCTest
@testable import AgentStatus

@MainActor
final class PerSessionStatusItemTests: XCTestCase {
    func testTooltipBaseLine() {
        let snap = makeSnap(status: .busy)
        XCTAssertEqual(PerSessionStatusItem.tooltip(for: snap),
                       "/tmp/x \u{2014} busy")
    }

    func testTooltipIncludesWaitingFor() {
        let snap = makeSnap(status: .waiting, waitingFor: "approve Bash")
        XCTAssertTrue(PerSessionStatusItem.tooltip(for: snap)
            .contains("approve Bash"))
    }

    func testTooltipShowsConcurrencyCount() {
        let snap = makeSnap(status: .busy, activeNames: ["Bash", "Bash", "Agent"])
        let tip = PerSessionStatusItem.tooltip(for: snap)
        XCTAssertTrue(tip.contains("3 tools running"))
        XCTAssertTrue(tip.contains("Bash, Bash, Agent"))
    }

    func testTooltipShowsSinglePendingPreviewWhenWaiting() {
        let snap = makeSnap(status: .waiting,
                            waitingFor: "approve Bash",
                            activeNames: ["Bash"],
                            previews: ["xcodebuild test"])
        let tip = PerSessionStatusItem.tooltip(for: snap)
        XCTAssertTrue(tip.contains("xcodebuild test"))
    }

    private func makeSnap(
        status: SessionStatus,
        waitingFor: String? = nil,
        activeNames: [String] = [],
        previews: [String] = []
    ) -> SessionSnapshot {
        var e = EnrichedSession.empty
        e.activeTools = zip(activeNames, previews + Array(repeating: "", count: max(0, activeNames.count - previews.count)))
            .enumerated()
            .map { i, pair in
                ActiveTool(id: "id\(i)", name: pair.0, preview: pair.1,
                           startedAt: .now, rawInputJSON: nil)
            }
        return SessionSnapshot(
            id: "p:s",
            providerId: "p",
            pid: 1,
            sessionId: "s",
            cwd: URL(fileURLWithPath: "/tmp/x"),
            startedAt: .now,
            updatedAt: .now,
            status: status,
            waitingFor: waitingFor,
            version: nil,
            kind: nil,
            entrypoint: nil,
            isAlive: true,
            enriched: e
        )
    }
}
```

- [ ] **Step 4: Run the new tests**

```bash
xcodegen generate
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/PerSessionStatusItemTests 2>&1 | tail -10
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add AgentStatus/UI/PerSession/PerSessionStatusItem.swift \
        AgentStatusTests/PerSessionStatusItemTests.swift \
        AgentStatus.xcodeproj
git commit -m "feat(per-session): enrich tooltip with concurrency and pending tool"
```

---

### Task 17: `PerfStats` actor + tests

**Files:**
- Create: `AgentStatus/Watching/PerfStats.swift`
- Create: `AgentStatusTests/PerfStatsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AgentStatusTests/PerfStatsTests.swift`:

```swift
import XCTest
@testable import AgentStatus

final class PerfStatsTests: XCTestCase {
    func testCountersStartAtZero() async {
        let stats = PerfStats()
        let s = await stats.snapshot()
        XCTAssertEqual(s.ticks, 0)
        XCTAssertEqual(s.bytes, 0)
        XCTAssertEqual(s.lines, 0)
        XCTAssertEqual(s.yields, 0)
    }

    func testCountersAreMonotonic() async {
        let stats = PerfStats()
        await stats.observe(tick: 1)
        await stats.observe(bytes: 100)
        await stats.observe(lines: 10)
        await stats.observe(yield: 1)
        await stats.observe(tick: 1)
        let s = await stats.snapshot()
        XCTAssertEqual(s.ticks, 2)
        XCTAssertEqual(s.bytes, 100)
        XCTAssertEqual(s.lines, 10)
        XCTAssertEqual(s.yields, 1)
    }

    func testResetClearsCounters() async {
        let stats = PerfStats()
        await stats.observe(tick: 5)
        await stats.observe(bytes: 999)
        await stats.reset()
        let s = await stats.snapshot()
        XCTAssertEqual(s.ticks, 0)
        XCTAssertEqual(s.bytes, 0)
    }
}
```

- [ ] **Step 2: Verify it fails**

```bash
xcodegen generate
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/PerfStatsTests 2>&1 | tail -20
```

Expected: build error — `PerfStats` not in scope.

- [ ] **Step 3: Implement `PerfStats`**

Create `AgentStatus/Watching/PerfStats.swift`:

```swift
import Foundation

/// Debug-only telemetry collector for `TranscriptTailer` perf claims.
/// Counters are monotonic until `reset()`. The actor isolates writes so we
/// don't pay for synchronization in the production path — call sites are
/// fire-and-forget `Task { await stats.observe(...) }`.
///
/// Surfaced in a hidden gear-menu pane (debug builds only) — see
/// `Settings.showPerfStats` or the wiring in `MenuBarController`.
actor PerfStats {
    struct Snapshot: Equatable, Sendable {
        var ticks: UInt64 = 0
        var bytes: UInt64 = 0
        var lines: UInt64 = 0
        var yields: UInt64 = 0
    }

    private var counters = Snapshot()

    func observe(tick n: UInt64 = 1)  { counters.ticks  &+= n }
    func observe(bytes n: UInt64)     { counters.bytes  &+= n }
    func observe(lines n: UInt64)     { counters.lines  &+= n }
    func observe(yield n: UInt64 = 1) { counters.yields &+= n }

    func snapshot() -> Snapshot { counters }
    func reset() { counters = Snapshot() }
}
```

- [ ] **Step 4: Verify it passes**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/PerfStatsTests 2>&1 | tail -10
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add AgentStatus/Watching/PerfStats.swift \
        AgentStatusTests/PerfStatsTests.swift \
        AgentStatus.xcodeproj
git commit -m "feat(perf): add PerfStats actor for tailer telemetry"
```

---

### Task 18: Wire `PerfStats` into `TranscriptTailer`

**Files:**
- Modify: `AgentStatus/Watching/TranscriptTailer.swift`

- [ ] **Step 1: Add an optional `PerfStats` reference and observe**

In `AgentStatus/Watching/TranscriptTailer.swift`, near the actor's other private fields (≈ line 22-29), add:

```swift
    private let perf: PerfStats?
```

Update the `init` to accept it (default nil — production code won't supply one):

```swift
    init(sessionId: String, cwd: URL, pollInterval: TimeInterval = 1.0, perf: PerfStats? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.pollInterval = pollInterval
        self.perf = perf

        var cont: AsyncStream<EnrichedSession>.Continuation!
        self.snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in cont = c }
        self.continuation = cont
    }
```

In `tick()`, fire telemetry at the relevant points. Right after `let toRead = ...` (the new chunked-read line), record the bytes:

```swift
            let toRead = min(size - offset, chunkCap)
            if let perf = perf { Task { await perf.observe(bytes: toRead); await perf.observe(tick: 1) } }
```

(That fire-and-forget Task is intentional — the tick must not await on telemetry.)

After the parsing loop, before `continuation.yield(state)`, count lines:

```swift
            for line in lines where !line.isEmpty {
                process(line: String(line))
            }
            if let perf = perf {
                let lineCount = UInt64(lines.filter { !$0.isEmpty }.count)
                Task { await perf.observe(lines: lineCount); await perf.observe(yield: 1) }
            }
            continuation.yield(state)
```

- [ ] **Step 2: Verify it builds**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' build 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run full tests**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: all tests pass (production code passes nil for `perf`, so behavior is unchanged).

- [ ] **Step 4: Commit**

```bash
git add AgentStatus/Watching/TranscriptTailer.swift
git commit -m "feat(perf): observe ticks/bytes/lines/yields when PerfStats wired"
```

---

### Task 19: `scripts/perf-check.sh` + baseline

**Files:**
- Create: `scripts/perf-check.sh`
- Create: `scripts/perf-baseline.txt`
- Create: `AgentStatusTests/PerfBenchmarks.swift`

- [ ] **Step 1: Add a benchmark XCTest**

Create `AgentStatusTests/PerfBenchmarks.swift`:

```swift
import XCTest
@testable import AgentStatus

/// Reproducible synthetic load: feed N JSONL lines through the tailer's
/// per-line dispatch and measure wall-clock parse cost.
///
/// Not a correctness test — included so `scripts/perf-check.sh` has a
/// deterministic timing target. CI does not run this; the script does.
final class PerfBenchmarks: XCTestCase {
    func testParseTenThousandToolUseLinesUnderOneSecond() async {
        let tailer = TranscriptTailer(sessionId: "bench", cwd: URL(fileURLWithPath: "/tmp"))
        let template = """
        {"type":"assistant","message":{"model":"claude-opus-4-7","content":[{"type":"tool_use","id":"u-XXXX","name":"Bash","input":{"command":"echo XXXX"}}]}}
        """
        let lines = (0..<10_000).map { template.replacingOccurrences(of: "XXXX", with: String($0)) }

        let start = Date()
        for line in lines { await tailer._test_processLine(line) }
        let elapsed = Date().timeIntervalSince(start)

        // Generous bound so the test isn't flaky — the bench script reads the
        // exact number from stdout and compares against the checked-in baseline.
        XCTAssertLessThan(elapsed, 2.0, "10K tool_use lines took \(elapsed)s — slow path regression?")
        print("PERF: lines=10000 elapsed=\(elapsed)")
    }
}
```

- [ ] **Step 2: Add the shell driver**

Create `scripts/perf-check.sh`:

```bash
#!/usr/bin/env bash
# Reproducible perf gate. Runs PerfBenchmarks, extracts the elapsed-time line,
# and compares against scripts/perf-baseline.txt.
#
# Usage:
#   scripts/perf-check.sh
#
# Exit 0 when within 2x baseline. Prints both numbers.
set -euo pipefail

cd "$(dirname "$0")/.."

OUTPUT=$(xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test \
  -only-testing:AgentStatusTests/PerfBenchmarks 2>&1)

ELAPSED=$(echo "$OUTPUT" | grep -E '^PERF: lines=10000 elapsed=' \
  | tail -1 | sed -E 's/.*elapsed=//')

if [[ -z "$ELAPSED" ]]; then
  echo "perf-check: could not extract elapsed time from xcodebuild output" >&2
  echo "$OUTPUT" | tail -30 >&2
  exit 1
fi

BASELINE=$(cat scripts/perf-baseline.txt 2>/dev/null || echo "0.5")

echo "perf-check: elapsed=${ELAPSED}s  baseline=${BASELINE}s"

# Threshold: 2x baseline → flag regression.
awk -v e="$ELAPSED" -v b="$BASELINE" 'BEGIN {
  if (b > 0 && e > b * 2.0) {
    printf "perf-check: REGRESSION (%.3fs > 2x baseline %.3fs)\n", e, b
    exit 1
  }
  printf "perf-check: OK\n"
  exit 0
}'
```

- [ ] **Step 3: Add the baseline placeholder**

Create `scripts/perf-baseline.txt` with a single line — the *measured* baseline from your machine. After implementing, run the script once and update this file with the observed value:

```
0.5
```

(0.5s is a conservative initial guess for 10 000 small JSONL lines on Apple Silicon. Replace after first successful run.)

- [ ] **Step 4: Make it executable and run it**

```bash
chmod +x scripts/perf-check.sh
xcodegen generate
scripts/perf-check.sh
```

Expected: `perf-check: OK` with the actual measured time. If the time is much faster than 0.5s (likely), update `scripts/perf-baseline.txt` to that observed value.

- [ ] **Step 5: Commit**

```bash
git add scripts/perf-check.sh scripts/perf-baseline.txt \
        AgentStatusTests/PerfBenchmarks.swift \
        AgentStatus.xcodeproj
git commit -m "perf: add reproducible perf-check script + benchmark"
```

---

### Task 20: README updates

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Refresh test count and feature bullet**

In `README.md`:

1. Find the line in the project-layout block that reads `AgentStatusTests/           # XCTest target — 27 tests` (≈ line 122) and update the count to match the actual passing count after this PR (run `xcodebuild ... test 2>&1 | grep -E 'Executed [0-9]+ tests'` to read the number).

2. Add a feature bullet near the others (≈ line 18-19), e.g. after "Always-on":

```
- **Concurrency-aware** — the per-session popover lists every in-flight tool with live elapsed timers, recent completions with durations, and tool-aware "waiting for approval" detail when blocked on a permission gate.
```

- [ ] **Step 2: Run full tests one more time**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README — concurrency feature + test count"
```

---

### Task 21: Final perf verification + PR

**Files:** none (verification + PR creation only)

- [ ] **Step 1: Run the perf gate one more time and record numbers**

```bash
scripts/perf-check.sh
```

Capture the line beginning `perf-check: elapsed=...` for the PR body.

- [ ] **Step 2: Run the full test suite**

```bash
xcodebuild -project AgentStatus.xcodeproj -scheme AgentStatus \
  -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`. Note the total test count.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin feat/concurrency-aware-tools
gh pr create --base main \
  --title "feat: concurrency-aware tools + waiting question display" \
  --body "$(cat <<'EOF'
## Summary

Replaces `EnrichedSession.currentTool` (singular) with `activeTools[]` and `recentTools[]` so the per-session popover honestly shows parallel work — and adds a tool-aware "Waiting" section that surfaces the actual command/question being approved. Per-session menu-bar tooltip enriched at zero layout cost.

## Verification

```
$ scripts/perf-check.sh
perf-check: elapsed=<paste>s  baseline=<paste>s
perf-check: OK

$ xcodebuild ... test
** TEST SUCCEEDED **
Executed <N> tests, with 0 failures
```

## Spec & Plan

- [Spec](docs/superpowers/specs/2026-05-08-concurrency-aware-tools-design.md)
- [Plan](docs/superpowers/plans/2026-05-08-concurrency-aware-tools-plan.md)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

(Paste the actual numbers from steps 1 and 2 into the PR body before submitting.)

---

## Self-review notes

- **Spec coverage** — every section of the spec maps to at least one task: data model (T1, T3), pure helpers (T5, T6 + the `CompletedTool` initializer in T1), tailer ingestion (T7, T8, T9, T10), store split (T4, T11), UI sections (T12–T15), tooltip (T16), `PerfStats` (T17, T18), perf gate (T19), README (T20). The spec's `currentTool` deprecation note is honored: T8 sets it to nil; T15 deletes its rendering; full removal scheduled for the next PR.
- **No placeholders** — every step contains complete code or a concrete shell command. The `<N>` and `<paste>` markers in the final PR-body template are intentional fill-ins from observed numbers, not unfinished spec content.
- **Type consistency** — `CompletedTool.init(completing:isError:at:)` is used identically in T1, T4, T8, T9, T11, and T16. `EnrichedSession.coreEqual(_:)` defined in T4 and consumed in T11. `WaitingDisplay` defined in T2 and consumed in T6, T12. `TranscriptTailer.waitingDisplay(for:pending:pendingInput:)` signature matches across T6 and T12.
- **TDD discipline** — every task that adds production code starts with a failing test (`Step 1`) and verifies failure (`Step 2`) before implementing.
