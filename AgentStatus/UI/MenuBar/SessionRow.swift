import SwiftUI

/// One row in the dashboard list. Static-only icon; rich enriched fields are
/// gated by Settings toggles so users can pare back what they see.
struct SessionRow: View {
    let snapshot: SessionSnapshot
    let buckets: [SessionStatus?]
    @EnvironmentObject var settings: Settings

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StaticStatusIcon(status: snapshot.status, size: 22, dim: !snapshot.isAlive)
                .frame(width: 24)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                titleRow
                statusLine
                metaChips
                SparklineView(buckets: buckets, height: 12)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                TimelineView(.everyMinute) { ctx in
                    Text(ElapsedFormatter.short(from: snapshot.startedAt, to: ctx.date))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text("pid \(snapshot.pid)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .opacity(snapshot.isAlive ? 1.0 : 0.45)
        .help(tooltip)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(displayTitle)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if showTitleSubtext {
                Text(snapshot.cwdBasename)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if snapshot.providerId != "claude-code" {
                Text(snapshot.providerId)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.secondary.opacity(0.18), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayTitle: String {
        if settings.showAITitleAndLastPrompt, let t = snapshot.enriched?.aiTitle, !t.isEmpty {
            return t
        }
        return snapshot.cwdBasename
    }

    /// Show the cwd as a small subtext only when we have an AI title (so the
    /// path isn't lost), and only if titles are enabled.
    private var showTitleSubtext: Bool {
        settings.showAITitleAndLastPrompt
            && snapshot.enriched?.aiTitle?.isEmpty == false
    }

    private var statusLine: some View {
        Text(secondaryLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var secondaryLine: String {
        if let w = snapshot.waitingFor, !w.isEmpty {
            return "\(snapshot.status.displayName) — \(w)"
        }
        return snapshot.status.displayName
    }

    private func currentToolLine(_ tool: ActiveTool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(.system(size: 9))
                .foregroundStyle(.tint)
            Text(tool.name)
                .font(.system(size: 11, weight: .semibold))
            if !tool.preview.isEmpty {
                Text(tool.preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TimelineView(.periodic(from: tool.startedAt, by: 1)) { ctx in
                Text("(\(ElapsedFormatter.short(from: tool.startedAt, to: ctx.date)))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var metaChips: some View {
        let chips = computedChips()
        if !chips.isEmpty {
            HStack(spacing: 4) {
                ForEach(chips, id: \.self) { chip in
                    Text(chip.text)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(chip.color.opacity(0.18), in: Capsule())
                        .foregroundStyle(chip.color)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private struct Chip: Hashable { let text: String; let color: Color }

    private func computedChips() -> [Chip] {
        var out: [Chip] = []
        guard let e = snapshot.enriched else { return out }
        if settings.showPermissionMode, let mode = e.permissionMode {
            out.append(Chip(text: shortMode(mode), color: modeColor(mode)))
        }
        if settings.showTokensAndCost, e.tokens.grandTotal > 0 {
            out.append(Chip(text: "\(e.tokens.compactTotal) · \(e.estimatedCost.asUSD)", color: .secondary))
        }
        if settings.showAITitleAndLastPrompt, let model = e.currentModel {
            out.append(Chip(text: shortModel(model), color: .purple))
        }
        return out
    }

    private func shortMode(_ mode: String) -> String {
        switch mode {
        case "bypassPermissions": "bypass"
        case "auto":              "auto"
        case "plan":              "plan"
        case "default":           "default"
        default: mode
        }
    }
    private func modeColor(_ mode: String) -> Color {
        switch mode {
        case "bypassPermissions": .red
        case "auto":              .orange
        case "plan":              .blue
        default:                  .secondary
        }
    }
    private func shortModel(_ model: String) -> String {
        let m = model.lowercased()
        if m.contains("opus")   { return "opus" }
        if m.contains("sonnet") { return "sonnet" }
        if m.contains("haiku")  { return "haiku" }
        return model
    }

    private var tooltip: String {
        var parts: [String] = []
        parts.append(snapshot.cwd.path)
        if let v = snapshot.version { parts.append("v\(v)") }
        if let k = snapshot.kind { parts.append(k) }
        if let w = snapshot.waitingFor { parts.append("waiting for: \(w)") }
        if let e = snapshot.enriched {
            if let p = e.lastUserPrompt { parts.append("last prompt: \(p.prefix(120))") }
            if let t = e.lastAssistantText { parts.append("last reply: \(t.prefix(120))") }
        }
        return parts.joined(separator: "\n")
    }
}
