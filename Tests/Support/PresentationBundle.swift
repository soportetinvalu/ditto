// SPDX-License-Identifier: GPL-3.0-only
// Standalone test application compiled with the unchanged production sources,
// except App.swift (no production startup, capture, TCC or migration).
import AppKit
import Carbon

final class PresentationDelegate: NSObject, NSApplicationDelegate {
    var external: NSRunningApplication?
    var secondExternal: NSRunningApplication?
    var checks = [[String: Any]]()
    let result = URL(fileURLWithPath: CommandLine.arguments[1])
    let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
    let mode = CommandLine.arguments[3]
    func check(_ name: String, _ passed: Bool) {
        checks.append(["name": name, "passed": passed])
        print("BUNDLE \(mode) \(name)=\(passed)")
    }
    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            NSApp.updateWindows()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
    }
    func wait(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(3)
        while !condition() && Date() < end { pump(0.01) }
        return condition()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run after the LaunchServices launch has finished, not inside its callback.
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in self.run() }
    }
    func run() {
        var diagnostic = ""
        do {
            let ready = result.appendingPathExtension("ready")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = [mode, ready.path]
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            var launchError: Error?
            NSWorkspace.shared.openApplication(at: fixture, configuration: configuration) { self.external = $0; launchError = $1 }
            check("launchCompleted", wait { self.external != nil || launchError != nil })
            if let launchError { throw launchError }
            guard let external else { throw LocalError("Fixture launch failed") }
            let externalReady = wait { FileManager.default.fileExists(atPath: ready.path) && NSWorkspace.shared.frontmostApplication?.processIdentifier == external.processIdentifier && !NSApp.isActive }
            check("externalOwnsFocus", externalReady)
            guard externalReady else { throw LocalError("External focus precondition failed") }
            let secureInputBefore = IsSecureEventInputEnabled()
            // Independent control, recorded but never used to skip the product.
            let control = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 240, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            control.isReleasedWhenClosed = false
            NSApp.activate(ignoringOtherApps: true); control.makeKeyAndOrderFront(nil)
            let controlReady = wait { NSApp.isActive && control.isKeyWindow && control.occlusionState.contains(.visible) }
            let controlState: [String: Any] = ["active": NSApp.isActive, "key": control.isKeyWindow, "visible": control.isVisible, "unoccluded": control.occlusionState.contains(.visible)]
            control.orderOut(nil); control.close()
            _ = external.activate(options: [.activateIgnoringOtherApps])
            check("externalFocusRestored", wait { !NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == external.processIdentifier })
            let suite = "NexClipBundleTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            let board = NSPasteboard(name: NSPasteboard.Name(suite))
            defer { defaults.removePersistentDomain(forName: suite); board.releaseGlobally() }
            let preferences = Preferences(defaults)
            // Copy-only exercises the real paste destination without AX or event injection.
            defaults.set(false, forKey: "autoPaste")
            let store = try ClipStore(path: ":memory:")
            try store.capture([Representation(item: 0, type: "public.utf8-plain-text", data: Data("fixture".utf8))], title: "fixture", text: "fixture", source: "test")
            let monitor = ClipboardMonitor(store: store, preferences: preferences, pasteboard: board)
            let paste = PasteCoordinator(monitor: monitor, preferences: preferences)
            let history = HistoryController(store: store, preferences: preferences, monitor: monitor, paste: paste)
            defer { history.hide(); history.panel.close() }
            let count = board.changeCount
            let nonactivating = history.panel.styleMask.contains(.nonactivatingPanel)
            let correctlyPresented: () -> Bool = {
                history.panel.isKeyWindow && history.panel.isVisible && history.panel.occlusionState.contains(.visible) && history.panel.isOnActiveSpace &&
                (nonactivating ? external.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == external.processIdentifier : NSApp.isActive)
            }
            history.open(source: .menu)
            let opened = wait(correctlyPresented)
            let presentationState: [String: Any] = ["appKitActive": NSApp.isActive, "runningApplicationActive": NSRunningApplication.current.isActive,
                "externalActive": external.isActive, "externalFrontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == external.processIdentifier,
                "key": history.panel.isKeyWindow, "unoccluded": history.panel.occlusionState.contains(.visible)]
            check("presentedKeyVisibleWithCorrectActivation", opened)
            if !opened {
                finish(["mode": mode, "nonactivating": nonactivating, "presentationState": presentationState, "secureInputBefore": secureInputBefore, "controlReady": controlReady, "controlState": controlState, "bundleID": Bundle.main.bundleIdentifier ?? "", "policy": NSApp.activationPolicy().rawValue], history.openingDiagnostic)
                return
            }
            var persistent = opened
            let end = Date().addingTimeInterval(0.6)
            while Date() < end {
                persistent = persistent && correctlyPresented()
                pump(0.02)
            }
            check("persistent600ms", persistent)
            check("destinationPreserved", paste.destination?.processIdentifier == external.processIdentifier)
            check("openingDoesNotWriteClipboard", board.changeCount == count)
            check("initialSelectionResponder", history.panel.firstResponder === history.table)
            // Local responder events, not OS input injection or a physical keyboard E2E.
            history.panel.makeFirstResponder(history.search)
            check("searchEditorReceivesFocus", history.search.currentEditor() != nil)
            if let editor = history.search.currentEditor() {
                editor.insertText("fixture")
                history.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            }
            check("searchFiltersRealStore", history.search.stringValue == "fixture" && history.clips.count == 1)
            history.panel.makeFirstResponder(history.table)
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: history.panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            history.table.keyDown(with: escape)
            pump(0.4)
            check("escapeStaysClosed", !history.panel.isVisible)
            _ = external.activate(options: [.activateIgnoringOtherApps])
            check("focusBeforeReopen", wait { !history.panel.isKeyWindow && external.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == external.processIdentifier })
            history.open(source: .statusClick)
            check("reopenedBySharedPresenter", wait(correctlyPresented))
            history.pasteSelection()
            check("copyOnlyWritesNamedBoard", board.string(forType: .string) == "fixture")
            check("copyOnlyReturnsToDestination", wait { !history.panel.isVisible && NSWorkspace.shared.frontmostApplication?.processIdentifier == external.processIdentifier })
            history.open(source: .shortcut)
            check("thirdOpen", wait(correctlyPresented))
            // Switch to another real GUI process. Re-keying a window in the
            // already-frontmost app is not proof that borrowed key focus ended.
            let secondReady = result.appendingPathExtension("second-ready")
            let secondConfiguration = NSWorkspace.OpenConfiguration()
            secondConfiguration.arguments = [mode, secondReady.path]
            secondConfiguration.activates = true
            secondConfiguration.createsNewApplicationInstance = true
            var secondError: Error?
            NSWorkspace.shared.openApplication(at: fixture, configuration: secondConfiguration) { self.secondExternal = $0; secondError = $1 }
            check("secondExternalLaunched", wait { self.secondExternal != nil || secondError != nil })
            if let secondError { throw secondError }
            guard let secondExternal else { throw LocalError("Second fixture launch failed") }
            check("secondExternalOwnsFocus", wait { FileManager.default.fileExists(atPath: secondReady.path) && NSWorkspace.shared.frontmostApplication?.processIdentifier == secondExternal.processIdentifier })
            check("externalKeyFocusHides", wait { !history.panel.isKeyWindow && !history.panel.occlusionState.contains(.visible) })
            pump(0.4)
            check("noDelayedFocusTheft", NSWorkspace.shared.frontmostApplication?.processIdentifier == secondExternal.processIdentifier && !history.panel.occlusionState.contains(.visible))
            history.open(source: .menu)
            history.hideForPermission()
            _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            pump(0.4)
            check("permissionHideStaysHidden", !history.panel.isVisible && history.panel.level == .normal)
            diagnostic = history.openingDiagnostic
            let metadata: [String: Any] = ["mode": mode, "nonactivating": nonactivating, "presentationState": presentationState, "secureInputBefore": secureInputBefore, "controlReady": controlReady, "controlState": controlState, "bundleID": Bundle.main.bundleIdentifier ?? "", "policy": NSApp.activationPolicy().rawValue]
            finish(metadata, diagnostic)
        } catch {
            check("harnessError", false)
            finish(["mode": mode, "error": String(describing: error)], diagnostic)
        }
    }
    func finish(_ metadata: [String: Any], _ diagnostic: String) {
        if let secondExternal { secondExternal.terminate(); check("secondFixtureCleaned", wait { secondExternal.isTerminated }) }
        if let external { external.terminate(); check("fixtureCleaned", wait { external.isTerminated }) }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": checks, "metadata": metadata, "diagnostic": diagnostic]
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: result, options: .atomic)
        NSApp.terminate(nil)
    }
}
@main struct PresentationMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = PresentationDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
