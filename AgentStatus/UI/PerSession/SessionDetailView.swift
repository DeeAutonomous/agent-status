import SwiftUI
import AppKit

/// Per-session popover content. Built lazily by PerSessionStatusItem so its
/// timers and animations only run while the popover is on-screen.
struct SessionDetailView: View {
    let snapshotId: String
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var settings: Settings

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            content(now: ctx.date)
        }
    }

    private func content(now: Date) -> some View {
        let snap = store.snapshots.first { $0.id == snapshotId }
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let s = snap {
                    header(for: s, now: now)
                    Divider()
                    if s.status == .waiting {
                        waitingSection(for: s)
                        Divider()
                    }
                    runningNowSection(for: s)
                    sparkline(for: s)
                    Divider()
                    if settings.showTokensAndCost, let tokens = s.enriched?.tokens, tokens.grandTotal > 0 {
                        tokensSection(s.enriched!)
                        Divider()
                    }
                    if settings.showAITitleAndLastPrompt {
                        promptsSection(s.enriched)
                    }
                    metadata(for: s)
                    Divider()
                    actions(for: s)
                } else {
                    Text("Session is no longer running.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .padding(14)
        }
        .frame(width: 360, height: 420)
    }

    private func header(for s: SessionSnapshot, now: Date) -> some View {
        HStack(spacing: 10) {
            StatusRingIcon(status: s.status, size: 28, dim: !s.isAlive)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle(for: s))
                    .font(.system(.body).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(s.cwdBasename)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(s.status.displayName)
                    .font(.caption)
                    .foregroundStyle(s.status.color)
                Text(ElapsedFormatter.short(from: s.startedAt, to: now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func displayTitle(for s: SessionSnapshot) -> String {
        if settings.showAITitleAndLastPrompt, let t = s.enriched?.aiTitle, !t.isEmpty {
            return t
        }
        return s.cwdBasename
    }

    private func currentTool(_ tool: ActiveTool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").foregroundStyle(.tint)
                Text("Running \(tool.name)").font(.subheadline.weight(.semibold))
                Spacer()
                TimelineView(.periodic(from: tool.startedAt, by: 1)) { ctx in
                    Text(ElapsedFormatter.short(from: tool.startedAt, to: ctx.date))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if !tool.preview.isEmpty {
                Text(tool.preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

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
                    Text("\u{201C}\(text)\u{201D}")     // "…"
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

    private func sparkline(for s: SessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last 60s").font(.caption2).foregroundStyle(.tertiary)
            SparklineView(buckets: store.history(for: s.id).bucket(into: 60, span: 60), height: 22)
        }
    }

    private func tokensSection(_ e: EnrichedSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tokens & cost").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if let m = e.currentModel { Text(m).font(.caption2.monospaced()).foregroundStyle(.secondary) }
            }
            HStack(spacing: 10) {
                tokenStat("in",       e.tokens.input)
                tokenStat("out",      e.tokens.output)
                tokenStat("c-read",   e.tokens.cacheRead)
                tokenStat("c-write",  e.tokens.cacheCreation)
                Spacer()
                Text(e.estimatedCost.asUSD)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            }
        }
    }

    private func tokenStat(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
            Text(TokenUsage.compact(n)).font(.system(size: 11, design: .monospaced)).monospacedDigit()
        }
    }

    private func promptsSection(_ e: EnrichedSession?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = e?.lastUserPrompt, !p.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last prompt").font(.caption2).foregroundStyle(.tertiary)
                    Text(p).font(.caption).lineLimit(3).truncationMode(.tail).textSelection(.enabled)
                }
            }
            if let r = e?.lastAssistantText, !r.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last reply").font(.caption2).foregroundStyle(.tertiary)
                    Text(r).font(.caption).lineLimit(3).truncationMode(.tail).textSelection(.enabled)
                }
            }
        }
    }

    private func metadata(for s: SessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row("path", s.cwd.path, monospaced: true)
            if let w = s.waitingFor { row("waiting", w) }
            if settings.showPermissionMode, let m = s.enriched?.permissionMode { row("mode", m) }
            if let n = s.enriched?.subagentName { row("agent", n) }
            if let v = s.version { row("version", v) }
            if let k = s.kind    { row("kind", k) }
            if let e = s.enriched, e.toolCalls > 0 {
                row("tools", "\(e.toolCalls) calls\(e.errorCount > 0 ? " · \(e.errorCount) errors" : "")")
            }
            row("pid", "\(s.pid)", monospaced: true)
        }
    }

    private func row(_ key: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .trailing)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func actions(for s: SessionSnapshot) -> some View {
        HStack(spacing: 8) {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([s.cwd])
            }
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(s.pid)", forType: .string)
            }
        }
        .controlSize(.small)
        .font(.caption)
    }
}
