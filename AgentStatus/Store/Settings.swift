import Foundation
import SwiftUI
import Combine

/// User-facing preferences. Uses `@Published` (not `@AppStorage`) so dependents can
/// subscribe via Combine; `didSet` blocks persist to UserDefaults.
@MainActor
final class Settings: ObservableObject {
    // Menu bar UX
    @Published var perSessionMenuBarItemsEnabled: Bool {
        didSet { defaults.set(perSessionMenuBarItemsEnabled, forKey: Keys.perSessionMenuBarItems) }
    }
    @Published var launchAgentInstalled: Bool {
        didSet { defaults.set(launchAgentInstalled, forKey: Keys.launchAgentInstalled) }
    }

    // Rich signals (toggle each one on/off)
    @Published var showCurrentTool: Bool {
        didSet { defaults.set(showCurrentTool, forKey: Keys.showCurrentTool) }
    }
    @Published var showPermissionMode: Bool {
        didSet { defaults.set(showPermissionMode, forKey: Keys.showPermissionMode) }
    }
    @Published var showTokensAndCost: Bool {
        didSet { defaults.set(showTokensAndCost, forKey: Keys.showTokensAndCost) }
    }
    @Published var showAITitleAndLastPrompt: Bool {
        didSet { defaults.set(showAITitleAndLastPrompt, forKey: Keys.showAITitleAndLastPrompt) }
    }

    // Notifications (each toggle independently)
    @Published var notifyWaiting: Bool {
        didSet { defaults.set(notifyWaiting, forKey: Keys.notifyWaiting) }
    }
    @Published var notifyToolError: Bool {
        didSet { defaults.set(notifyToolError, forKey: Keys.notifyToolError) }
    }
    @Published var notifyCompletion: Bool {
        didSet { defaults.set(notifyCompletion, forKey: Keys.notifyCompletion) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.perSessionMenuBarItems:    true,
            Keys.launchAgentInstalled:      false,
            Keys.showCurrentTool:           true,
            Keys.showPermissionMode:        true,
            Keys.showTokensAndCost:         true,
            Keys.showAITitleAndLastPrompt:  true,
            Keys.notifyWaiting:             true,
            Keys.notifyToolError:           true,
            Keys.notifyCompletion:          false  // off by default — chatty
        ])
        self.perSessionMenuBarItemsEnabled = defaults.bool(forKey: Keys.perSessionMenuBarItems)
        self.launchAgentInstalled          = defaults.bool(forKey: Keys.launchAgentInstalled)
        self.showCurrentTool               = defaults.bool(forKey: Keys.showCurrentTool)
        self.showPermissionMode            = defaults.bool(forKey: Keys.showPermissionMode)
        self.showTokensAndCost             = defaults.bool(forKey: Keys.showTokensAndCost)
        self.showAITitleAndLastPrompt      = defaults.bool(forKey: Keys.showAITitleAndLastPrompt)
        self.notifyWaiting                 = defaults.bool(forKey: Keys.notifyWaiting)
        self.notifyToolError               = defaults.bool(forKey: Keys.notifyToolError)
        self.notifyCompletion              = defaults.bool(forKey: Keys.notifyCompletion)
    }

    private enum Keys {
        static let perSessionMenuBarItems    = "perSessionMenuBarItemsEnabled"
        static let launchAgentInstalled      = "launchAgentInstalled"
        static let showCurrentTool           = "showCurrentTool"
        static let showPermissionMode        = "showPermissionMode"
        static let showTokensAndCost         = "showTokensAndCost"
        static let showAITitleAndLastPrompt  = "showAITitleAndLastPrompt"
        static let notifyWaiting             = "notifyWaiting"
        static let notifyToolError           = "notifyToolError"
        static let notifyCompletion          = "notifyCompletion"
    }
}
