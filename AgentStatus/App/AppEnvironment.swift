import Foundation

/// DI container constructed once at app launch, held by AgentStatusApp as @StateObject.
/// All dependents read these via .environmentObject in SwiftUI or by direct injection in
/// imperative AppKit controllers.
@MainActor
final class AppEnvironment: ObservableObject {
    let registry: ProviderRegistry
    let store: SessionStore
    let settings: Settings
    let perSessionItems: PerSessionItemController
    let notifications: NotificationManager

    init() {
        let registry = ProviderRegistry()
        registry.register(ClaudeCodeProvider())
        registry.register(CodexProvider())
        self.registry = registry
        let store = SessionStore(registry: registry)
        let settings = Settings()
        self.store = store
        self.settings = settings
        self.perSessionItems = PerSessionItemController(store: store, settings: settings)
        self.notifications = NotificationManager(store: store, settings: settings)
    }

    func boot() async {
        await store.start()
        notifications.start()
    }
}
