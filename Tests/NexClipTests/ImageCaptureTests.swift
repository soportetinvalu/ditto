// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import AppKit
import ImageIO
import ClipCore
@testable import NexClip

final class ImageCaptureTests: XCTestCase {
    private final class Provider: NSObject, NSPasteboardItemDataProvider {
        var calls = 0
        var ready = false
        var onRead: (() -> Void)?
        let data: Data
        init(_ data: Data) { self.data = data }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            calls += 1
            onRead?()
            if ready { item.setData(data, forType: type) }
        }
    }
    private final class Fixture {
        let suite = "NexClip-image-tests-" + UUID().uuidString
        let board = NSPasteboard.withUniqueName()
        let defaults: UserDefaults
        let prefs: Preferences
        let store: ClipStore
        let monitor: ClipboardMonitor
        let history: HistoryController
        var source = "com.test.browser"
        init() throws {
            _ = NSApplication.shared
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            prefs = Preferences(defaults)
            defaults.set(true, forKey: "captureEnabled")
            defaults.set(2000, forKey: "pollMilliseconds")
            store = try ClipStore(path: ":memory:")
            var readSource: (() -> String)?
            monitor = ClipboardMonitor(store: store, preferences: prefs, pasteboard: board,
                                       frontmostSource: { readSource?() ?? "com.test.browser" })
            history = HistoryController(store: store, preferences: prefs, monitor: monitor,
                                        paste: PasteCoordinator(monitor: monitor, preferences: prefs))
            readSource = { [weak self] in self?.source ?? "" }
            monitor.onChange = { [weak history] in history?.reloadAfterCapture() }
            monitor.start()
        }
        deinit {
            monitor.stop(); history.hide(); board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
        }
        func write(_ item: NSPasteboardItem) throws {
            board.clearContents(); XCTAssertTrue(board.writeObjects([item]))
        }
        func oldImage(_ data: Data) throws -> String {
            let old = try store.capture([Representation(item: 0, type: "public.png", data: data)],
                                        title: "Anterior", text: "", source: source, now: 1)
            try store.markUsed([old.id], reorder: false, now: 2)
            return old.id
        }
    }
    private func image(_ format: NSBitmapImageRep.FileType = .png, red: UInt8 = 255) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for i in 0..<4 { pixels[i * 4] = red; pixels[i * 4 + 1] = 60; pixels[i * 4 + 2] = 80; pixels[i * 4 + 3] = 255 }
        return try XCTUnwrap(bitmap.representation(using: format, properties: [:]))
    }
    private func item(_ data: Data, type: String = "public.png") -> NSPasteboardItem {
        let item = NSPasteboardItem(); XCTAssertTrue(item.setData(data, forType: .init(type)))
        return item
    }
    func testImmediateShortcutCapturesAndSelectsNewImageBeforeTimerTick() throws {
        let f = try Fixture()
        let old = try f.oldImage(image(red: 0)); let fresh = try image()
        try f.write(item(fresh))
        // No poll/run-loop wait between Copy Image and the exact shortcut entry point.
        f.history.open(source: .shortcut)
        XCTAssertEqual(try f.store.clips().count, 2)
        let selected = try XCTUnwrap(f.history.selection.first)
        XCTAssertNotEqual(selected.id, old)
        XCTAssertEqual(try f.store.representations(selected.id), [Representation(item: 0, type: "public.png", data: fresh)])
        XCTAssertNil(selected.usedAt) // Opening is not a use/paste operation.
        XCTAssertEqual(f.board.data(forType: .png), fresh) // Opening never restores the previous copy.
        f.history.hide(); f.history.open(source: .shortcut)
        XCTAssertEqual(f.history.selection.first?.id, selected.id)
    }
    func testNativeImageFormatsPreserveBytesAndRoundTripWithoutCustomTypes() throws {
        let f = try Fixture()
        XCTAssertFalse(f.defaults.bool(forKey: "customTypes"))
        for (type, format) in [("public.png", NSBitmapImageRep.FileType.png), ("public.tiff", .tiff),
                               ("public.jpeg", .jpeg), ("com.compuserve.gif", .gif)] {
            let data = try image(format)
            XCTAssertNotNil(Preview.image(data), type)
            try f.write(item(data, type: type)); f.monitor.poll()
            let clip = try XCTUnwrap(f.store.clips().first { $0.title == "Imagen" &&
                (try? f.store.representations($0.id).contains { $0.type == type }) == true })
            let reps = try f.store.representations(clip.id)
            XCTAssertEqual(reps, [Representation(item: 0, type: type, data: data)])
            try f.monitor.write(reps)
            XCTAssertEqual(f.board.data(forType: .init(type)), data)
            let count = try f.store.clips().count
            f.monitor.poll(); XCTAssertEqual(try f.store.clips().count, count)
        }
        XCTAssertEqual(try f.store.clips().count, 4)
        XCTAssertTrue(ClipboardMonitor.isImageType("org.webmproject.webp"))
        XCTAssertTrue(ClipboardMonitor.isImageType("public.heic"))
        XCTAssertFalse(ClipboardMonitor.isImageType("public.file-url"))
        XCTAssertFalse(ClipboardMonitor.isImageType("com.test.private"))
    }
    func testWebPAndHEICImagePayloadsAreCapturedAndPreviewable() throws {
        let f = try Fixture()
        let webp = try XCTUnwrap(Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvAUAAAAdQnsIXqv+BiOh/AAA="))
        let png = try image()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let cgImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let heic = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(heic, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        for (type, data) in [("org.webmproject.webp", webp), ("public.heic", heic as Data)] {
            XCTAssertNotNil(Preview.image(data), type)
            try f.write(item(data, type: type)); f.monitor.poll()
            let clip = try XCTUnwrap(f.store.clips().first { (try? f.store.representations($0.id).first?.type) == type })
            XCTAssertEqual(clip.title, "Imagen")
            XCTAssertEqual(try f.store.representations(clip.id).first?.data, data)
            try f.monitor.write(f.store.representations(clip.id))
            XCTAssertEqual(f.board.data(forType: .init(type)), data)
        }
        XCTAssertEqual(try f.store.clips().count, 2)
    }
    func testPromisedImageIsMaterializedAndNotReplacedByURL() throws {
        let f = try Fixture(); let data = try image(); let provider = Provider(data); provider.ready = true
        let copy = NSPasteboardItem()
        copy.setString("https://example.invalid/image.png", forType: .URL)
        copy.setDataProvider(provider, forTypes: [.png])
        try f.write(copy); f.monitor.poll()
        XCTAssertGreaterThan(provider.calls, 0)
        let clip = try XCTUnwrap(f.store.clips().first)
        let reps = try f.store.representations(clip.id)
        XCTAssertEqual(reps.first { $0.type == "public.png" }?.data, data)
        XCTAssertEqual(reps.first { $0.type == "public.url" }?.data, Data("https://example.invalid/image.png".utf8))
        XCTAssertEqual(try f.store.clips().count, 1)
    }
    func testUnavailableImageRetriesSameCountWithoutSavingURLOnlyFragment() throws {
        let f = try Fixture(); let data = try image(); let provider = Provider(data)
        let copy = NSPasteboardItem(); copy.setString("https://example.invalid/deferred.png", forType: .URL)
        copy.setDataProvider(provider, forTypes: [.png])
        try f.write(copy); let count = f.board.changeCount
        f.monitor.poll()
        XCTAssertTrue(try f.store.clips().isEmpty)
        XCTAssertEqual(f.monitor.pendingReadCount, count)
        provider.ready = true; f.monitor.poll()
        XCTAssertEqual(f.board.changeCount, count)
        XCTAssertEqual(try f.store.clips().count, 1)
        let clip = try XCTUnwrap(f.store.clips().first)
        XCTAssertEqual(try f.store.representations(clip.id).first { $0.type == "public.png" }?.data, data)
        XCTAssertNil(f.monitor.pendingReadCount)
        f.monitor.poll(); XCTAssertEqual(try f.store.clips().count, 1)
    }
    func testDelayedOpeningCopyUpdatesSelectionButNotAfterUserChoosesAnotherRow() throws {
        for changeSelection in [false, true] {
            let f = try Fixture(); _ = try f.oldImage(image(red: 0))
            let other = try f.store.capture([Representation(item: 0, type: "public.utf8-plain-text", data: Data("Otro".utf8))],
                title: "Otro", text: "Otro", source: f.source, now: 0)
            let data = try image(); let provider = Provider(data); let copy = NSPasteboardItem()
            copy.setDataProvider(provider, forTypes: [.png]); try f.write(copy)
            f.history.open(source: .shortcut)
            XCTAssertNotNil(f.monitor.pendingReadCount)
            if changeSelection {
                let row = try XCTUnwrap(f.history.clips.firstIndex { $0.id == other.id })
                f.history.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            provider.ready = true; f.monitor.poll()
            let selected = try XCTUnwrap(f.history.selection.first)
            if changeSelection { XCTAssertEqual(selected.id, other.id) }
            else { XCTAssertEqual(try f.store.representations(selected.id).first?.data, data) }
            XCTAssertEqual(try f.store.clips().count, 3)
        }
    }
    func testMissingImageRetryIsBoundedAndAbandonedOnSourceChange() throws {
        for changeSource in [false, true] {
            let f = try Fixture(); let provider = Provider(try image()); let copy = NSPasteboardItem()
            copy.setDataProvider(provider, forTypes: [.png]); try f.write(copy)
            var messages = [String](); f.monitor.onMessage = { messages.append($0) }
            f.monitor.poll(); XCTAssertNotNil(f.monitor.pendingReadCount)
            let initialCalls = provider.calls
            if changeSource { f.source = "com.test.other"; provider.ready = true }
            for _ in 0..<8 { f.monitor.poll() }
            XCTAssertTrue(try f.store.clips().isEmpty); XCTAssertNil(f.monitor.pendingReadCount)
            if changeSource { XCTAssertEqual(provider.calls, initialCalls); XCTAssertTrue(messages.isEmpty) }
            else { XCTAssertEqual(provider.calls, 3); XCTAssertEqual(messages.count, 1) }
        }
    }
    func testPrivacyGuardsDoNotMaterializeImageOrRetryAfterPause() throws {
        for policy in ["disabled", "paused", "excluded", "not-allowed", "unknown", "concealed", "own"] {
            let f = try Fixture(); let provider = Provider(try image()); provider.ready = true
            let copy = NSPasteboardItem(); copy.setDataProvider(provider, forTypes: [.png])
            switch policy {
            case "disabled": f.defaults.set(false, forKey: "captureEnabled")
            case "paused": f.prefs.paused = true
            case "excluded": f.defaults.set(f.source, forKey: "excluded")
            case "not-allowed": f.defaults.set("com.test.another", forKey: "allowed")
            case "unknown": f.source = ""
            case "concealed": copy.setString("", forType: .init("org.nspasteboard.ConcealedType"))
            default: break
            }
            try f.write(copy); if policy == "own" { f.monitor.markOwnWrite() }
            f.history.open(source: .shortcut); f.monitor.poll()
            XCTAssertTrue(try f.store.clips().isEmpty, policy)
            XCTAssertEqual(provider.calls, 0, policy)
        }
        let f = try Fixture(); let provider = Provider(try image()); let copy = NSPasteboardItem()
        copy.setDataProvider(provider, forTypes: [.png]); try f.write(copy); f.monitor.poll()
        let calls = provider.calls; f.prefs.paused = true; provider.ready = true; f.monitor.poll()
        f.prefs.paused = false; f.monitor.poll()
        XCTAssertEqual(provider.calls, calls); XCTAssertTrue(try f.store.clips().isEmpty)
    }
    func testReplacementDuringMaterializationDoesNotMixCopies() throws {
        let f = try Fixture(); let provider = Provider(try image()); provider.ready = true
        let replacement = try image(red: 0)
        provider.onRead = { f.board.clearContents(); f.board.writeObjects([self.item(replacement)]) }
        let copy = NSPasteboardItem(); copy.setDataProvider(provider, forTypes: [.png])
        try f.write(copy); f.monitor.poll(); XCTAssertTrue(try f.store.clips().isEmpty)
        provider.onRead = nil; f.monitor.poll()
        let clip = try XCTUnwrap(f.store.clips().first)
        XCTAssertEqual(try f.store.representations(clip.id).first?.data, replacement)
        XCTAssertEqual(try f.store.clips().count, 1)
    }
    func testUnsupportedPrivateTypesStayOffAndImageLimitRejectsWholeCopy() throws {
        let f = try Fixture()
        try f.write(item(Data("private".utf8), type: "com.test.private")); f.monitor.poll()
        XCTAssertTrue(try f.store.clips().isEmpty)
        let copy = item(Data(repeating: 42, count: Int(CM_MAX_BYTES) + 1))
        copy.setString("Must not save fragment", forType: .string)
        var messages = [String](); f.monitor.onMessage = { messages.append($0) }
        try f.write(copy); f.monitor.poll()
        XCTAssertTrue(try f.store.clips().isEmpty); XCTAssertEqual(messages.count, 1)
        XCTAssertNil(f.monitor.pendingReadCount)
    }
}
