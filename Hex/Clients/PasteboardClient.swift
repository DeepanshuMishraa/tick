//
//  PasteboardClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import Sauce
import SwiftUI
import AppKit

private let pasteboardLogger = HexLog.pasteboard

enum PasteboardPasteResult: Equatable, Sendable {
    case pasted(beforeText: String?, afterText: String?)
    case noFocusedInput
    case failed
}

@DependencyClient
struct PasteboardClient {
    var paste: @Sendable (String) async -> PasteboardPasteResult = { _ in .failed }
    var copy: @Sendable (String) async -> Void
    var focusedText: @Sendable () async -> String? = { nil }
    var focusedInputAvailable: @Sendable () async -> Bool = { false }
    var sendKeyboardCommand: @Sendable (KeyboardCommand) async -> Void
}

extension PasteboardClient: DependencyKey {
    static var liveValue: Self {
        let live = PasteboardClientLive()
        return .init(
            paste: { text in
                await live.paste(text: text)
            },
            copy: { text in
                await live.copy(text: text)
            },
            focusedText: {
                await PasteboardClientLive.focusedText()
            },
            focusedInputAvailable: {
                await PasteboardClientLive.focusedInputAvailable()
            },
            sendKeyboardCommand: { command in
                await live.sendKeyboardCommand(command)
            }
        )
    }
}

extension DependencyValues {
    var pasteboard: PasteboardClient {
        get { self[PasteboardClient.self] }
        set { self[PasteboardClient.self] = newValue }
    }
}

struct PasteboardClientLive {
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init(_ pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
        }

        @MainActor
        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restoredItems = items.map { savedItem in
                let item = NSPasteboardItem()
                for (type, data) in savedItem {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
    }

    @MainActor
    func paste(text: String) async -> PasteboardPasteResult {
        // A freshly launched process's first Accessibility queries can
        // transiently fail while its HIServices/AX connection warms up, and
        // target apps occasionally answer `.cannotComplete` while they're busy.
        // Poll briefly before concluding that nothing is focused, otherwise the
        // very first transcription after launch would always end up in the
        // "Couldn't paste" pill.
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            pasteboardLogger.notice("Paste: frontmost=\(frontmost.bundleIdentifier ?? "unknown", privacy: .public)")
        } else {
            pasteboardLogger.notice("Paste: no frontmost application")
        }

        let foundFocus = await waitUntilFocusedInputAvailable(timeout: 0.08)

        if !foundFocus {
            // Some apps (notably Chromium/Electron UIs — Helium, Slack, web
            // chat editors) never expose an AX-focused element even when a
            // text field genuinely holds keyboard focus. Rather than silently
            // dropping the transcript, park it on the clipboard (restored
            // immediately afterwards) and post a synthetic Cmd+V so the
            // focused view receives it regardless of its AX support.
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.bundleIdentifier != Bundle.main.bundleIdentifier,
               frontmost.bundleIdentifier != "com.apple.finder" {
                pasteboardLogger.notice("No AX focus reported; falling back to blind clipboard paste")
                return await pasteWithRestoredClipboard(text, beforeText: nil)
            }
            pasteboardLogger.notice("Paste skipped because no focused text input was found (after 0.08s of retries)")
            return .noFocusedInput
        }
        let beforeText = Self.focusedText()

        // Ghostty can report a successful AX write while its terminal buffer
        // ignores the mutation. Use its native clipboard paste path directly;
        // the clipboard must remain populated long enough for Ghostty's async
        // event handling to consume it.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.mitchellh.ghostty" {
            pasteboardLogger.notice("Using Ghostty clipboard paste transport")
            return await pasteWithRestoredClipboard(text, beforeText: beforeText)
        }

        do {
            // Prefer direct Accessibility insertion. It preserves the user's
            // clipboard and replaces the current selection atomically.
            try Self.insertTextAtCursor(text)
            // AX writes are synchronous. Capture the baseline immediately so
            // background formatting can safely replace this exact insertion.
            let afterText = Self.focusedText()
            return .pasted(beforeText: beforeText, afterText: afterText)
        } catch {
            // Web views and several Electron editors expose focus through AX
            // but reject direct value mutation. Use the system paste command
            // as a final transport, then restore the user's clipboard in all
            // cases so the transcription never remains there.
            pasteboardLogger.debug("Accessibility insertion unavailable; using restored paste fallback")
        }
        return await pasteWithRestoredClipboard(text, beforeText: beforeText)
    }

    /// Polls until a focused text input becomes visible via Accessibility, or
    /// the timeout elapses. See `paste(text:)` for why the first query can miss.
    @MainActor
    private func waitUntilFocusedInputAvailable(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var iterations = 0
        while true {
            if Self.focusedInputAvailable() {
                if iterations > 0 {
                    pasteboardLogger.notice("Focused text input appeared after \(iterations, privacy: .public) AX retry/retries")
                }
                return true
            }
            guard Date() < deadline else { return false }
            iterations += 1
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    @MainActor
    func copy(text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    @MainActor
    func sendKeyboardCommand(_ command: KeyboardCommand) async {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Convert modifiers to CGEventFlags and key codes for modifier keys
        var modifierKeyCodes: [CGKeyCode] = []
        var flags = CGEventFlags()

        for modifier in command.modifiers.sorted {
            switch modifier.kind {
            case .command:
                flags.insert(.maskCommand)
                modifierKeyCodes.append(55) // Left Cmd
            case .shift:
                flags.insert(.maskShift)
                modifierKeyCodes.append(56) // Left Shift
            case .option:
                flags.insert(.maskAlternate)
                modifierKeyCodes.append(58) // Left Option
            case .control:
                flags.insert(.maskControl)
                modifierKeyCodes.append(59) // Left Control
            case .fn:
                flags.insert(.maskSecondaryFn)
                // Fn key doesn't need explicit key down/up
            }
        }

        // Press modifiers down
        for keyCode in modifierKeyCodes {
            let modDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            modDown?.post(tap: .cghidEventTap)
        }
        
        // Press main key if present
        if let key = command.key {
            let keyCode = Sauce.shared.keyCode(for: key)
            
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            keyDown?.flags = flags
            keyDown?.post(tap: .cghidEventTap)
            
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            keyUp?.flags = flags
            keyUp?.post(tap: .cghidEventTap)
        }
        
        // Release modifiers in reverse order
        for keyCode in modifierKeyCodes.reversed() {
            let modUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            modUp?.post(tap: .cghidEventTap)
        }
        
        pasteboardLogger.debug("Sent keyboard command: \(command.displayName)")
    }

    // MARK: - Helpers

    enum PasteError: Error {
        case focusedElementNotFound
        case elementDoesNotSupportTextEditing
        case failedToInsertText
    }

    static func insertTextAtCursor(_ text: String) throws {
        // Get the system-wide accessibility element
        let systemWideElement = AXUIElementCreateSystemWide()

        // Get the focused element
        var focusedElementRef: CFTypeRef?
        let axError = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)

        guard axError == .success, let focusedElementRef = focusedElementRef else {
            pasteboardLogger.error("Focused element lookup failed; AXError.rawValue=\(axError.rawValue, privacy: .public)")
            throw PasteError.focusedElementNotFound
        }

        let focusedElement = focusedElementRef as! AXUIElement

        var value: CFTypeRef?
        let hasValue = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &value
        ) == .success

        if hasValue, let currentText = value as? String,
           let selectedRange = selectedRange(of: focusedElement) {
            let currentValue = currentText as NSString
            let range = NSRange(
                location: Int(selectedRange.location),
                length: Int(selectedRange.length)
            )

            guard range.location >= 0,
                  range.length >= 0,
                  NSMaxRange(range) <= currentValue.length else {
                throw PasteError.failedToInsertText
            }

            let updatedText = currentValue.replacingCharacters(in: range, with: text)
            if AXUIElementSetAttributeValue(
                focusedElement,
                kAXValueAttribute as CFString,
                updatedText as CFTypeRef
            ) == .success {
                // Keep the caret immediately after the inserted text.
                var caretRange = CFRange(
                    location: selectedRange.location + text.utf16.count,
                    length: 0
                )
                if let axCaretRange = AXValueCreate(.cfRange, &caretRange) {
                    _ = AXUIElementSetAttributeValue(
                        focusedElement,
                        kAXSelectedTextRangeAttribute as CFString,
                        axCaretRange
                    )
                }
                return
            }
        }

        // A number of editors support setting selected text even though they
        // do not expose a writable value/range pair.
        var selectedText: CFTypeRef?
        let supportsSelectedText = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        ) == .success

        if !supportsSelectedText {
            throw PasteError.elementDoesNotSupportTextEditing
        }

        let insertResult = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if insertResult != .success {
            throw PasteError.failedToInsertText
        }
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
        let rangeValue,
        CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    @MainActor
    private func pasteWithRestoredClipboard(
        _ text: String,
        beforeText: String?
    ) async -> PasteboardPasteResult {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(to: pasteboard)
            return .failed
        }

        // Let the pasteboard server commit the temporary item before posting
        // Cmd-V. Do not wait for an Accessibility read-back; web editors often
        // do not expose one and the correction monitor can observe it later.
        let isGhostty = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.mitchellh.ghostty"
        try? await Task.sleep(for: .milliseconds(20))
        let didPostPaste = postCommandV()

        // Ghostty handles Cmd-V on its event loop and reads the pasteboard
        // after the key event arrives. Restoring immediately after posting
        // races that read and makes Ghostty paste the user's old clipboard
        // (or nothing). Give it a short, app-specific consumption window;
        // other applications already snapshot the pasteboard synchronously.
        if isGhostty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        snapshot.restore(to: pasteboard)

        guard didPostPaste else { return .failed }
        pasteboardLogger.notice(
            "Clipboard paste command posted app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown", privacy: .public) restoreDelayMs=\(isGhostty ? 250 : 0, privacy: .public)"
        )
        return .pasted(beforeText: beforeText, afterText: nil)
    }

    @MainActor
    private func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let commandKey: CGKeyCode = 55
        let vKey = Sauce.shared.keyCode(for: .v)
        guard let commandDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: commandKey,
            keyDown: true
        ), let vDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: vKey,
            keyDown: true
        ), let vUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: vKey,
            keyDown: false
        ), let commandUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: commandKey,
            keyDown: false
        ) else {
            return false
        }

        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
        return true
    }

    /// Reads the focused accessibility value without touching the clipboard.
    /// An empty string is a valid value for a focused, empty text field.
    @MainActor
    static func focusedText() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        let axError = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard axError == .success, let focusedElementRef else { return nil }
        let focusedElement = focusedElementRef as! AXUIElement

        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &value) == .success,
           let text = value as? String {
            return text
        }

        // Selected text is only a fragment, not the complete field value. It
        // cannot be used as a dictionary baseline because an unrelated
        // selection can look like a one-word correction.
        return nil
    }

    @MainActor
    static func focusedInputAvailable() -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        let axError = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard axError == .success, let focusedElementRef else { return false }
        let focusedElement = focusedElementRef as! AXUIElement
        var value: CFTypeRef?
        let supportsText = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &value
        ) == .success
        let supportsSelectedText = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success
        return supportsText || supportsSelectedText
    }

}
