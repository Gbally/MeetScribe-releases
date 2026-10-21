// Global keyboard shortcut (e.g. ⌃⌥R) to start/stop recording from any app.
// Uses Carbon's RegisterEventHotKey, which needs no Accessibility permission.

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon flags: cmdKey, shiftKey, optionKey, controlKey
    var display: String     // e.g. "⌃⌥R"

    static let defaultShortcut = Hotkey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥R")

    /// From a key press; nil unless it has ⌘, ⌃ or ⌥ (plain keys would break typing everywhere).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var carbon = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { carbon |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { carbon |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { carbon |= cmdKey; symbols += "⌘" }
        keyCode = UInt32(event.keyCode)
        modifiers = UInt32(carbon)
        display = symbols + Self.keyName(event)
    }

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    private static func keyName(_ e: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let s = special[Int(e.keyCode)] { return s }
        return (e.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// Registers the shortcut and calls `action` when it's pressed.
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    func register(_ hotkey: Hotkey?) {
        unregister()
        guard let hotkey else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x4D534352), id: 1) // 'MSCR'
        RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotkeyCenter.shared.action?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// "⌃⌥R  [Change] [Remove]" — click Change, then press the new combination.
struct HotkeyField: View {
    @Binding var hotkey: Hotkey?
    @State private var capturing = false
    @State private var monitor: Any?
    @State private var hint = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(capturing ? tr("Press the keys…") : (hotkey?.display ?? tr("None")))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(capturing ? Color.accentColor : Color.secondary.opacity(0.4)))
                Button(capturing ? tr("Cancel") : tr("Change…")) { capturing ? stop() : startCapture() }
                if hotkey != nil && !capturing { Button("Remove") { hotkey = nil } }
            }
            .controlSize(.small)
            if !hint.isEmpty { Text(hint).font(.caption).foregroundColor(.orange) }
        }
        .onDisappear { stop() }
    }

    private func startCapture() {
        NSApp.activate(ignoringOtherApps: true)
        HotkeyCenter.shared.unregister() // so pressing the current shortcut can be captured
        capturing = true
        hint = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if let hk = Hotkey(event: event) {
                hotkey = hk
                stop()
            } else {
                hint = tr("Use at least ⌃, ⌥ or ⌘ together with a key.")
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if capturing { capturing = false; HotkeyCenter.shared.register(hotkey) }
    }
}
