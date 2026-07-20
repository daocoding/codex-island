import Darwin
import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("PASS: \(message)")
    } else {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func writeFixture(_ json: String, to url: URL, permissions: Int = 0o600) throws {
    try Data(json.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}

@main
struct ClaudeDesktopUsageBridgeTestRunner {
    static func main() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshotURL = directory.appendingPathComponent("snapshot.json")
        let valid = """
        {
          "schema_version": 1,
          "provider": "claude",
          "source": "claude_code_desktop",
          "generated_at": 1800000000,
          "plan": "max",
          "windows": {
            "five_hour": {"used_percent": 12.5, "resets_at": 1800000600},
            "seven_day": {"used_percent": 41, "resets_at": 1800345600},
            "scoped_weekly": {"used_percent": 72, "resets_at": 1800345600, "label": "Fable"}
          }
        }
        """
        try writeFixture(valid, to: snapshotURL)
        let reading = try ClaudeDesktopUsageBridge.load(now: now, from: snapshotURL)
        expect(abs(reading.usage.fiveHour.usedPercent - 0.125) < 0.0001,
               "valid bridge 5h percent normalizes")
        expect(reading.usage.weekly.percentInt == 41, "valid bridge weekly percent loads")
        expect(reading.usage.scopedLabel == "Fable", "valid bridge scoped label loads")
        expect(reading.observedAt == now, "generated_at becomes observation time")

        let afterFiveHourReset = try ClaudeDesktopUsageBridge.load(
            now: now.addingTimeInterval(601),
            from: snapshotURL
        )
        expect(!afterFiveHourReset.usage.fiveHour.hasKnownValue,
               "elapsed 5h window is dropped independently")
        expect(afterFiveHourReset.usage.weekly.hasKnownValue,
               "weekly window survives a 5h reset")

        do {
            _ = try ClaudeDesktopUsageBridge.load(
                now: now.addingTimeInterval(ClaudeDesktopUsageBridge.maximumSnapshotAge + 1),
                from: snapshotURL
            )
            expect(false, "stale snapshot is rejected")
        } catch ClaudeDesktopUsageBridge.ReadError.staleSnapshot {
            expect(true, "stale snapshot is rejected")
        }

        let impossibleURL = directory.appendingPathComponent("impossible.json")
        let impossible = valid.replacingOccurrences(
            of: "1800000600",
            with: "1800030000"
        )
        try writeFixture(impossible, to: impossibleURL)
        do {
            _ = try ClaudeDesktopUsageBridge.load(now: now, from: impossibleURL)
            expect(false, "impossible reset distance is rejected")
        } catch ClaudeDesktopUsageBridge.ReadError.invalidWindow {
            expect(true, "impossible reset distance is rejected")
        }

        let permissiveURL = directory.appendingPathComponent("permissive.json")
        try writeFixture(valid, to: permissiveURL, permissions: 0o644)
        do {
            _ = try ClaudeDesktopUsageBridge.load(now: now, from: permissiveURL)
            expect(false, "group-readable snapshot is rejected")
        } catch ClaudeDesktopUsageBridge.ReadError.insecureFile {
            expect(true, "group-readable snapshot is rejected")
        }

        let symlinkURL = directory.appendingPathComponent("snapshot-link.json")
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: snapshotURL)
        do {
            _ = try ClaudeDesktopUsageBridge.load(now: now, from: symlinkURL)
            expect(false, "snapshot symlink is rejected")
        } catch ClaudeDesktopUsageBridge.ReadError.insecureFile {
            expect(true, "snapshot symlink is rejected")
        }

        if failures > 0 {
            print("\(failures) CCD usage bridge test(s) failed")
            exit(1)
        }
        print("All CCD usage bridge tests passed")
    }
}
