import os

enum Log {
    static let subsystem = "ai.autonomous.AgentStatus"

    static let watcher  = Logger(subsystem: subsystem, category: "watcher")
    static let provider = Logger(subsystem: subsystem, category: "provider")
    static let store    = Logger(subsystem: subsystem, category: "store")
    static let ui       = Logger(subsystem: subsystem, category: "ui")
    static let launch   = Logger(subsystem: subsystem, category: "launch")
}
