// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct AccessibilityResetResult {
    let exitCode: Int32
    let output: String
    var succeeded: Bool { exitCode == 0 }
    var summary: String { "tccutil reset Accessibility: exit=\(exitCode); \(output)" }
}

/// Apple documents a per-user, per-bundle reset without sudo. Never grants access.
/// No shell, user-supplied arguments, other services, or privilege escalation.
enum AccessibilityReset {
    static let executable = URL(fileURLWithPath: "/usr/bin/tccutil")
    static let arguments = ["reset", "Accessibility", "com.nexclip.app"]
    static func run(completion: @escaping (AccessibilityResetResult) -> Void) {
        let process = Process(); let output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        do { try process.run(); output.fileHandleForWriting.closeFile() }
        catch { completion(AccessibilityResetResult(exitCode: -1, output: error.localizedDescription)); return }
        // Never block AppKit. tccutil has small fixed output; drain while it runs.
        DispatchQueue.global(qos: .utility).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = AccessibilityResetResult(exitCode: process.terminationStatus,
                output: String(decoding: data.prefix(8192), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            DispatchQueue.main.async { completion(result) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if process.isRunning { process.terminate() }
        }
    }
}
