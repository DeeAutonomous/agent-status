import AppKit
import Combine
import SwiftUI

/// Diffs SessionStore.snapshots into a map of NSStatusItems — adding new ones,
/// removing dead ones, updating existing ones — gated by the per-session toggle.
/// Lives for the app's lifetime, owned by AppEnvironment.
@MainActor
final class PerSessionItemController: ObservableObject {
    private let store: SessionStore
    private let settings: Settings
    private var items: [String: PerSessionStatusItem] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(store: SessionStore, settings: Settings) {
        self.store = store
        self.settings = settings

        // Recompute on either snapshot change or settings toggle.
        Publishers.CombineLatest(
            store.$snapshots,
            settings.$perSessionMenuBarItemsEnabled
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] snapshots, enabled in
            self?.sync(snapshots: snapshots, enabled: enabled)
        }
        .store(in: &cancellables)
    }

    private func sync(snapshots: [SessionSnapshot], enabled: Bool) {
        // Disabled → tear down everything.
        guard enabled else {
            for (_, item) in items { item.remove() }
            items.removeAll()
            return
        }

        let target = snapshots.filter { $0.deservesPerSessionItem }
        let targetIDs = Set(target.map(\.id))

        // Remove stale.
        for (id, item) in items where !targetIDs.contains(id) {
            item.remove()
            items.removeValue(forKey: id)
        }

        // Add or update.
        for snap in target {
            if let existing = items[snap.id] {
                existing.update(with: snap)
            } else {
                let new = PerSessionStatusItem(
                    snapshotId: snap.id,
                    initialSnapshot: snap,
                    store: store,
                    settings: settings
                )
                items[snap.id] = new
            }
        }
    }
}

// Settings needs to publish its @AppStorage value via a $-prefixed projected value
// for CombineLatest. @AppStorage already participates in objectWillChange via
// ObservableObject, but to use it as a Publisher we re-expose it through @Published.
// We handle that in Settings.swift by switching to @Published mirror values where needed.
