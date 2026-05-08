import Foundation

/// Codable mirror of one ~/.claude/sessions/<pid>.json file. Numeric timestamps are
/// Claude's convention (Unix milliseconds since 1970). All fields after `pid`/`sessionId`
/// are optional so a future Claude release can drop a field without crashing us.
struct ClaudeRawRecord: Decodable, Sendable {
    let pid: Int32
    let sessionId: String
    let cwd: String?
    let startedAt: Double?         // milliseconds
    let procStart: String?
    let version: String?
    let peerProtocol: Int?
    let kind: String?
    let entrypoint: String?
    let status: String?
    let updatedAt: Double?         // milliseconds
    let waitingFor: String?

    func toSnapshot(providerId: String, isAlive: Bool) -> SessionSnapshot {
        let cwdURL = URL(fileURLWithPath: cwd ?? "/")
        let started = Date(timeIntervalSince1970: (startedAt ?? 0) / 1000.0)
        let updated = Date(timeIntervalSince1970: (updatedAt ?? startedAt ?? 0) / 1000.0)
        let parsed  = SessionStatus(raw: status ?? "unknown")
        return SessionSnapshot(
            id: "\(providerId):\(sessionId)",
            providerId: providerId,
            pid: pid,
            sessionId: sessionId,
            cwd: cwdURL,
            startedAt: started,
            updatedAt: updated,
            status: parsed,
            waitingFor: (waitingFor?.isEmpty == false) ? waitingFor : nil,
            version: version,
            kind: kind,
            entrypoint: entrypoint,
            isAlive: isAlive
        )
    }
}
