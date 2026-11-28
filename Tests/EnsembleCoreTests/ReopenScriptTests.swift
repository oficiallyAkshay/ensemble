#if os(macOS)
import Foundation
import Testing

/// The scripts that open Ensemble again after Restart Ensemble and after an update live in the app target, which no
/// test target links, so this suite reads their text from the source files and runs it the way `DetachedShell.run`
/// does: the reopen definition, a newline and the script, under `/bin/sh -c` with the five standard arguments.
/// The absolute paths of open, launchctl and pgrep are pointed at stand-ins that record what they were given, and a
/// `sleep` stand-in on the search path skips the pauses.
@Suite struct ReopenScriptTests {
    static let bundle = "/Applications/Ensemble Test.app"
    static let uid = "501"
    static let job = "com.example.ensemble.test"

    enum Script: CaseIterable {
        case restart, updateSafetyNet

        var file: String { self == .restart ? "Permissions.swift" : "UpdateController.swift" }
        var marker: String { self == .restart ? "static func reopenAfterExit()" : "static func reopenIfRelaunchMissing()" }
    }

    @Test(arguments: Script.allCases)
    func loginOffOpensTheBundle(_ script: Script) throws {
        let calls = try run(script, atLogin: false, kickstartWorks: true)
        #expect(!calls.isEmpty)
        #expect(calls.allSatisfy { $0 == "open \(Self.bundle)" })
    }

    @Test(arguments: Script.allCases)
    func loginOnKickstartsTheLoginJob(_ script: Script) throws {
        let calls = try run(script, atLogin: true, kickstartWorks: true)
        #expect(!calls.isEmpty)
        #expect(calls.allSatisfy { $0 == "launchctl kickstart gui/\(Self.uid)/\(Self.job)" })
    }

    @Test(arguments: Script.allCases)
    func loginOnWithFailedKickstartOpensTheBundle(_ script: Script) throws {
        let calls = try run(script, atLogin: true, kickstartWorks: false)
        #expect(calls.first == "launchctl kickstart gui/\(Self.uid)/\(Self.job)")
        #expect(calls.contains("open \(Self.bundle)"))
        #expect(calls.allSatisfy { $0.hasPrefix("launchctl kickstart ") || $0 == "open \(Self.bundle)" })
    }

    // MARK: - Running a script as the app does

    static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Ensemble/App")

    /// The text of the first Swift multi-line string literal after `marker`, with the closing delimiter's
    /// indentation removed, as Swift does.
    static func literal(after marker: String, in file: String) throws -> String {
        let source = try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.contains(marker) })
        let open = try #require(lines[start...].firstIndex { $0.hasSuffix("\"\"\"") })
        let close = try #require(lines[(open + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\"\"\"") })
        let indent = lines[close].prefix { $0 == " " }.count
        return lines[(open + 1)..<close].map { String($0.dropFirst(indent)) }.joined(separator: "\n")
    }

    /// Returns the calls the stand-ins recorded, one line each.
    func run(_ script: Script, atLogin: Bool, kickstartWorks: Bool) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("calls.log").path
        func stub(_ name: String, _ body: String) throws -> String {
            let path = dir.appendingPathComponent(name).path
            try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
        let open = try stub("open", "echo \"open $*\" >> '\(log)'")
        let launchctl = try stub("launchctl", "echo \"launchctl $*\" >> '\(log)'; exit \(kickstartWorks ? 0 : 1)")
        let pgrep = try stub("pgrep", "exit 1")
        _ = try stub("sleep", "exit 0")

        var text = try Self.literal(after: "static let reopen", in: "DetachedShell.swift") + "\n"
            + Self.literal(after: script.marker, in: script.file)
        for (real, standIn) in [("/usr/bin/open", open), ("/bin/launchctl", launchctl), ("/usr/bin/pgrep", pgrep)] {
            text = text.replacingOccurrences(of: real, with: standIn)
        }
        #expect(!text.contains("/usr/bin/open") && !text.contains("/bin/launchctl"))

        // A process that has already exited, so the wait for this copy to quit ends at once.
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", text, "sh", String(gone.processIdentifier), Self.bundle, atLogin ? "1" : "0", Self.uid, Self.job]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = dir.path + ":/usr/bin:/bin"
        shell.environment = environment
        try shell.run()
        // A script that never returns fails the check instead of stalling the suite.
        let guardTimer = DispatchWorkItem { if shell.isRunning { shell.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: guardTimer)
        shell.waitUntilExit()
        guardTimer.cancel()
        #expect(shell.terminationReason == .exit)

        let recorded = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return recorded.split(separator: "\n").map(String.init)
    }
}
#endif
