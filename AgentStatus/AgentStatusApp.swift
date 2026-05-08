import SwiftUI

@main
struct AgentStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environmentObject(env.store)
                .environmentObject(env.settings)
                .task { await env.boot() }
        } label: {
            // Wrap in a small observable view so the label re-renders when
            // store.aggregate publishes. Reading env.store.aggregate inline
            // would capture a stale snapshot — App's body only re-evaluates
            // on env's own objectWillChange, not the nested store's.
            MenuBarLabelView(store: env.store)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabelView: View {
    @ObservedObject var store: SessionStore
    var body: some View {
        AggregateMenuBarLabel(aggregate: store.aggregate)
    }
}
