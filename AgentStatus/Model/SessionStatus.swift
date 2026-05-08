import SwiftUI

/// Unified status taxonomy across providers. `.unknown(raw)` is a forward-compat escape
/// hatch so a new Claude Code release can ship a new status string without us crashing.
enum SessionStatus: Hashable, Sendable {
    case idle
    case busy
    case waiting
    case running
    case paused
    case stopped
    case error
    case unknown(String)

    init(raw: String) {
        switch raw.lowercased() {
        case "idle":     self = .idle
        case "busy":     self = .busy
        case "waiting":  self = .waiting
        case "running":  self = .running
        case "paused":   self = .paused
        case "stopped":  self = .stopped
        case "error":    self = .error
        default:         self = .unknown(raw)
        }
    }

    var rawValue: String {
        switch self {
        case .idle: "idle"
        case .busy: "busy"
        case .waiting: "waiting"
        case .running: "running"
        case .paused: "paused"
        case .stopped: "stopped"
        case .error: "error"
        case .unknown(let s): s
        }
    }

    /// Aggregate precedence: the menu-bar icon adopts the highest-precedence status across all sessions.
    /// error > waiting > busy > running > idle > paused/stopped/unknown.
    var precedence: Int {
        switch self {
        case .error:   5
        case .waiting: 4
        case .busy:    3
        case .running: 2
        case .idle:    1
        case .paused, .stopped, .unknown: 0
        }
    }

    var color: Color {
        switch self {
        case .idle:    .green
        case .busy:    .blue
        case .running: .blue
        case .waiting: .orange
        case .error:   .red
        case .paused, .stopped: .secondary
        case .unknown: .secondary
        }
    }

    var sfSymbol: String {
        switch self {
        case .idle:    "circle.fill"
        case .busy:    "arrow.triangle.2.circlepath"
        case .running: "arrow.triangle.2.circlepath"
        case .waiting: "hand.raised.fill"
        case .error:   "exclamationmark.triangle.fill"
        case .stopped: "stop.fill"
        case .paused:  "pause.fill"
        case .unknown: "questionmark.circle.dashed"
        }
    }

    var displayName: String {
        switch self {
        case .unknown(let s): s
        default: rawValue.capitalized
        }
    }
}
