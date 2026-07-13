import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginStore: ObservableObject {
    static let shared = LaunchAtLoginStore()

    private static let registrationFingerprintKey =
        "MacIsland.launchAtLoginRegistrationFingerprint"

    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    private init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    /// Refresh an enabled login item after the installed app binary changes.
    /// `SMAppService` records the app bundle it was registered from; local
    /// development builds are replaced wholesale, so running from `build/`
    /// must never become the durable login target. Once the maintained build
    /// is installed under Applications, re-register it once per binary
    /// fingerprint so the next login resolves the current executable.
    func reconcileRegistrationIfNeeded() {
        refresh()
        guard isEnabled,
              isDurableApplicationInstall,
              let fingerprint = registrationFingerprint,
              UserDefaults.standard.string(
                forKey: Self.registrationFingerprintKey
              ) != fingerprint else { return }

        do {
            try? SMAppService.mainApp.unregister()
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(
                fingerprint,
                forKey: Self.registrationFingerprintKey
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    private func setEnabled(_ enabled: Bool) {
        if enabled && !isDurableApplicationInstall {
            errorMessage = "Install CodexIsland in Applications before enabling Launch at Login."
            refresh()
            return
        }

        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled {
                    try? SMAppService.mainApp.unregister()
                }
                try SMAppService.mainApp.register()
                if let fingerprint = registrationFingerprint {
                    UserDefaults.standard.set(
                        fingerprint,
                        forKey: Self.registrationFingerprintKey
                    )
                }
            } else {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.removeObject(
                    forKey: Self.registrationFingerprintKey
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    private var isDurableApplicationInstall: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix("\(NSHomeDirectory())/Applications/")
    }

    /// Path + version + executable metadata is deliberately cheap. We only
    /// need to notice a replaced local build, not establish cryptographic
    /// identity (codesigning owns that job).
    private var registrationFingerprint: String? {
        guard let executableURL = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(
                atPath: executableURL.path
              ),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        return [
            Bundle.main.bundleURL.standardizedFileURL.path,
            version,
            size.stringValue,
            String(modified.timeIntervalSince1970),
        ].joined(separator: "|")
    }
}
