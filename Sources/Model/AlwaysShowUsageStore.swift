import Foundation

/// User preference for keeping the core usage metrics visible at rest,
/// without requiring a hover.
///
/// Default on: persistent usage is the product's primary glanceable value;
/// click remains the path to the detailed panel. Users can still opt into the
/// smaller logo-only rest state from Settings.
@MainActor
final class AlwaysShowUsageStore: ObservableObject {
    static let shared = AlwaysShowUsageStore()

    private static let key = "MacIsland.alwaysShowUsage"

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key) }
    }

    private init() {
        self.enabled = Pref.seededBool(key: Self.key, default: true)
    }
}
