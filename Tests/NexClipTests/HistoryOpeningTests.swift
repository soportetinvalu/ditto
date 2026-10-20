// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import AppKit
@testable import NexClip

final class HistoryOpeningTests: XCTestCase {
    private func withHistory(_ body: (HistoryController, NSPasteboard) throws -> Void) throws {
        _ = NSApplication.shared
        let suite = "NexClipOpening." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let board = NSPasteboard(name: NSPasteboard.Name(suite))
        defer { defaults.removePersistentDomain(forName: suite); board.releaseGlobally() }
        let preferences = Preferences(defaults)
        let store = try ClipStore(path: ":memory:")
        let monitor = ClipboardMonitor(store: store, preferences: preferences, pasteboard: board)
        let controller = HistoryController(store: store, preferences: preferences, monitor: monitor,
                                           paste: PasteCoordinator(monitor: monitor, preferences: preferences))
        defer { controller.hide(); controller.panel.close() }
        try body(controller, board)
    }
    private func pump(_ duration: TimeInterval) {
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            // RunLoop alone does not dispatch the AppKit activation/window events
            // that NSApplication.run normally consumes in a real application.
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
    }
    private func wait(_ condition: () -> Bool, seconds: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { pump(0.01) }
        return condition()
    }
    func testMetadataIsBoundedAndDoesNotExportHistoryOrSearch() throws {
        try withHistory { controller, board in
            let sentinel = "PRIVATE-SENTINEL-DO-NOT-EXPORT"
            try controller.store.capture([Representation(item: 0, type: "public.utf8-plain-text", data: Data(sentinel.utf8))],
                                         title: sentinel, text: sentinel, source: sentinel)
            let changeCount = board.changeCount
            for _ in 0..<12 { controller.open(source: .menu) }
            controller.search.stringValue = sentinel
            pump(0.4)
            let report = controller.openingDiagnostic
            let rows = report.split(separator: "\n").filter { $0.hasPrefix("attempt=") }
            XCTAssertEqual(rows.count, 48)
            XCTAssertFalse(report.contains(sentinel))
            XCTAssertTrue(report.contains("source=menu"))
            XCTAssertTrue(report.contains("phase=groupsLoaded"))
            XCTAssertTrue(report.contains("phase=historyLoaded"))
            XCTAssertTrue(report.contains("phase=settled"))
            XCTAssertEqual(board.changeCount, changeCount)
        }
    }
    func testDelayedSnapshotsNeverReopenExplicitlyHiddenPanel() throws {
        try withHistory { controller, _ in
            controller.open(source: .statusClick)
            controller.hideForPermission()
            pump(0.4)
            XCTAssertFalse(controller.panel.isVisible)
            XCTAssertEqual(controller.panel.level, .normal)
            let report = controller.openingDiagnostic
            XCTAssertTrue(report.contains("phase=permissionHidden"))
            XCTAssertTrue(report.contains("phase=settled"))
            XCTAssertTrue(report.split(separator: "\n").last?.contains("visible=false") == true)
        }
    }
    func testSamplingCannotOverwriteANewerAttempt() throws {
        try withHistory { controller, _ in
            controller.open(source: .shortcut)
            controller.open(source: .menu)
            pump(0.4)
            let samples = controller.openingDiagnostic.split(separator: "\n").filter {
                $0.contains("phase=nextTurn") || $0.contains("phase=settled")
            }
            XCTAssertEqual(samples.count, 2)
            XCTAssertTrue(samples.allSatisfy { $0.hasPrefix("attempt=2 source=menu ") })
        }
    }
    // Requires an explicitly opted-in, unlocked interactive Mac. No synthetic event
    // or activation notification is injected. A separate regular AppKit process owns focus.
    func testRealExternalFocusOpeningPersistenceAndDeactivation() throws {
        guard ProcessInfo.processInfo.environment["NEXCLIP_RUN_FOCUS_TESTS"] == "1" else {
            throw XCTSkip("Requires NEXCLIP_RUN_FOCUS_TESTS=1 and an interactive macOS session")
        }
        _ = NSApplication.shared
        // swift test is a command-line XCTest host, not an NSApplication.run host.
        // Complete AppKit launch before evaluating real inter-process activation.
        NSApp.finishLaunching()
        let previousPolicy = NSApp.activationPolicy()
        XCTAssertTrue(NSApp.setActivationPolicy(.accessory))
        defer { _ = NSApp.setActivationPolicy(previousPolicy) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexClipFocus-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("FocusFixture.app/Contents")
        let executable = bundle.appendingPathComponent("MacOS/FocusFixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleExecutable": "FocusFixture", "CFBundleIdentifier": "test.nexclip.focusfixture",
                                    "CFBundlePackageType": "APPL", "CFBundleName": "NexClip Focus Fixture"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Info.plist"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/ExternalFocus.swift")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", fixture.path, "-o", executable.path]
        try compiler.run(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        guard compiler.terminationStatus == 0 else { return }
        for mode in ["text", "secure"] {
            let ready = root.appendingPathComponent("ready-" + mode)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = [mode, ready.path]
            configuration.createsNewApplicationInstance = true
            configuration.activates = true
            var launched: NSRunningApplication?
            var launchError: Error?
            // Launch the bundle through LaunchServices as macOS launches real apps,
            // rather than spawning its executable as an unregistered command child.
            NSWorkspace.shared.openApplication(at: bundle.deletingLastPathComponent(), configuration: configuration) {
                launched = $0; launchError = $1
            }
            XCTAssertTrue(wait { launched != nil || launchError != nil })
            if let launchError { throw launchError }
            let external = try XCTUnwrap(launched)
            defer {
                external.terminate()
                XCTAssertTrue(wait { external.isTerminated }, "Fixture cleanup")
            }
            let fixtureReady = wait { FileManager.default.fileExists(atPath: ready.path) &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier == external.processIdentifier && !NSApp.isActive }
            print("FOCUS fixture mode=\(mode) ready=\(fixtureReady) hostActive=\(NSApp.isActive)")
            guard fixtureReady else {
                throw XCTSkip("Infrastructure: external AppKit fixture did not acquire focus; presenter not evaluated")
            }
            // Capability control independent of HistoryController: the XCTest host
            // must be able to activate an ordinary NSWindow before its presenter
            // can be judged. A CI host failing this control is not a product red.
            let control = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 240, height: 100),
                                   styleMask: [.titled], backing: .buffered, defer: false)
            control.isReleasedWhenClosed = false
            defer { control.close() }
            NSApp.activate(ignoringOtherApps: true)
            control.makeKeyAndOrderFront(nil)
            let controlReady = wait { NSApp.isActive && control.isKeyWindow &&
                control.occlusionState.contains(.visible) }
            print("FOCUS hostControl mode=\(mode) active=\(NSApp.isActive) key=\(control.isKeyWindow) visible=\(control.isVisible) occluded=\(!control.occlusionState.contains(.visible))")
            control.orderOut(nil)
            guard controlReady else {
                throw XCTSkip("Infrastructure: command-line XCTest host cannot activate an independent AppKit control window; presenter not evaluated")
            }
            XCTAssertTrue(external.activate(options: [.activateIgnoringOtherApps]))
            XCTAssertTrue(wait { !NSApp.isActive &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier == external.processIdentifier })
            try withHistory { controller, board in
                let changeCount = board.changeCount
                controller.open(source: .menu) // Real shared presenter; NOT a physical shortcut/menu E2E.
                let opened = wait { external.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == external.processIdentifier && controller.panel.isVisible && controller.panel.isKeyWindow &&
                    controller.panel.occlusionState.contains(.visible) && controller.panel.isOnActiveSpace }
                print("FOCUS presenter mode=\(mode) opened=\(opened)\n\(controller.openingDiagnostic)")
                XCTAssertTrue(opened, mode)
                // No transient flash counted as success. Observe through several run-loop turns.
                let end = Date().addingTimeInterval(0.6)
                repeat {
                    XCTAssertTrue(external.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == external.processIdentifier && controller.panel.isVisible && controller.panel.isKeyWindow &&
                        controller.panel.occlusionState.contains(.visible) && controller.panel.isOnActiveSpace, mode)
                    pump(0.02)
                } while Date() < end
                XCTAssertEqual(controller.paste.destination?.processIdentifier, external.processIdentifier)
                XCTAssertEqual(board.changeCount, changeCount)
                let nextConfiguration = NSWorkspace.OpenConfiguration()
                nextConfiguration.arguments = [mode, root.appendingPathComponent("next-ready-" + mode).path]
                nextConfiguration.createsNewApplicationInstance = true
                nextConfiguration.activates = true
                var next: NSRunningApplication?
                NSWorkspace.shared.openApplication(at: bundle.deletingLastPathComponent(), configuration: nextConfiguration) { application, _ in next = application }
                XCTAssertTrue(wait { next != nil })
                let nextApp = try XCTUnwrap(next)
                defer { nextApp.terminate(); XCTAssertTrue(wait { nextApp.isTerminated }) }
                XCTAssertTrue(wait { NSWorkspace.shared.frontmostApplication?.processIdentifier == nextApp.processIdentifier && !controller.panel.isKeyWindow &&
                    !controller.panel.occlusionState.contains(.visible) })
                pump(0.4)
                XCTAssertFalse(NSApp.isActive)
                XCTAssertFalse(controller.panel.occlusionState.contains(.visible))
                // Explicit permission hiding must remain hidden even on a later activation.
                controller.hideForPermission()
                NSApp.activate(ignoringOtherApps: true)
                XCTAssertTrue(wait { NSApp.isActive })
                pump(0.4)
                XCTAssertFalse(controller.panel.isVisible)
            }
        }
        // NSSecureTextField is a controlled external focus case, not proof of browser Secure Input.
    }
}
