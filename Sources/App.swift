import SwiftUI
import AppKit

@main
struct CodexIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        // Placeholder scene — `App` requires at least one `Scene`. We never
        // trigger the system Settings menu (we're a `.accessory` app with
        // no menu bar), so this stays inert. Settings is shown via our own
        // SettingsWindowController.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var island: IslandWindowController?
    private var settingsShortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Keep an enabled login item attached to the durable Applications
        // install after a local build replaces that bundle. Development
        // binaries under build/ intentionally never become login targets.
        LaunchAtLoginStore.shared.reconcileRegistrationIfNeeded()

        island = IslandWindowController()
        island?.show()

        // Route Cmd+, to our hand-rolled Settings window. Without this, the
        // inert `Settings { EmptyView() }` scene below claims the shortcut and
        // opens a blank window. Consuming the event (returning nil) keeps that
        // empty scene from ever surfacing.
        settingsShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "," {
                SettingsWindowController.shared.show()
                return nil
            }
            return event
        }

        // Start fetching at app launch — NOT on view appear — so the panel
        // already has cached values the first time the user hovers, instead
        // of flashing "0%" while the first request lands.
        UsageStore.shared.startAutoRefresh()
        CostStore.shared.startAutoRefresh()

        // Wire the alert engine after the usage store so its initial
        // recompute sees whatever values the first refresh has produced.
        AlertEngine.shared.start()

        // Apex Learn fork addition: relay each usage refresh to our aiOS
        // sidecar (POST /api/quota/ingest) so its agent-avatar quota rings
        // stay live across hosts. See Sources/Broadcast/AiosBroadcaster.swift.
        AiosBroadcaster.shared.start()

        // Touch the shared updater so Sparkle starts its background scheduler.
        _ = UpdaterController.shared
    }

    /// Pin the app to the run loop until the user explicitly quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
