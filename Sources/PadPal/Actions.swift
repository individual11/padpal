import AppKit
import ApplicationServices

enum Actions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39,
        "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48,
        "space": 49, "`": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    private static let arrows: Set<String> = ["left", "right", "up", "down"]

    /// Turns a pressed key and its modifiers into shortcut text such as "cmd+shift+n".
    static func shortcutText(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        let aliases: Set<String> = ["enter", "backspace", "esc"]
        guard let key = keyCodes.first(where: { $0.value == keyCode && !aliases.contains($0.key) })?.key else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    /// Parses "cmd+shift+n" into a key code and modifier flags.
    static func parse(_ shortcut: String) -> (CGKeyCode, CGEventFlags)? {
        var flags: CGEventFlags = []
        var key: String?
        for part in shortcut.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: key = part
            }
        }
        guard let key, let code = keyCodes[key] else { return nil }
        if arrows.contains(key) { flags.insert([.maskSecondaryFn, .maskNumericPad]) }
        return (code, flags)
    }

    /// True while the named modifier is physically held on any keyboard.
    static func isHolding(_ name: String) -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        switch name {
        case "cmd": return flags.contains(.maskCommand)
        case "alt": return flags.contains(.maskAlternate)
        case "ctrl": return flags.contains(.maskControl)
        case "shift": return flags.contains(.maskShift)
        default: return false
        }
    }

    /// Macros run here one after another, so a second press queues behind the first instead of interleaving.
    private static let macroQueue = DispatchQueue(label: "padpal.macro")
    /// Pause between macro steps, so the front app can keep up.
    private static let stepGap = 0.04

    static func runMacro(_ steps: [Step]) {
        macroQueue.async {
            for step in steps {
                if let ms = step.wait { Thread.sleep(forTimeInterval: Double(min(max(ms, 0), 10_000)) / 1000); continue }
                if let keys = step.keys { pressKeys(keys) }
                else if let text = step.text { type(text) }
                else if let media = step.media { mediaKey(media) }
                else if let target = step.open { open(target) }
                else if let cmd = step.shell { run("/bin/zsh", ["-lc", cmd]) }
                else if let lines = step.scroll { scroll(lines) }
                Thread.sleep(forTimeInterval: stepGap)
            }
        }
    }

    static func perform(_ b: Binding) {
        if let steps = b.steps { runMacro(steps) }
        else if let keys = b.keys { pressKeys(keys) }
        else if let media = b.media { mediaKey(media) }
        else if let target = b.open { open(target) }
        else if let cmd = b.shell { run("/bin/zsh", ["-lc", cmd]) }
        else if let text = b.text { type(text) }
        else if let lines = b.scroll { scroll(lines) }
    }

    static func pressKeys(_ shortcut: String) {
        guard let (code, flags) = parse(shortcut) else { NSLog("PadPal: can't parse shortcut \(shortcut)"); return }
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    static func type(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        // One key event carries about 20 UTF-16 units at most, so longer text goes out in pieces.
        var pieces: [[UInt16]] = [[]]
        for ch in text {
            let units = Array(String(ch).utf16)
            if pieces[pieces.count - 1].count + units.count > 20 { pieces.append([]) }
            pieces[pieces.count - 1] += units
        }
        for chars in pieces where !chars.isEmpty {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.flags = []
                e?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
                e?.post(tap: .cghidEventTap)
            }
            if pieces.count > 1 { usleep(4000) }
        }
    }

    static func scroll(_ lines: Int) {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(lines), wheel2: 0, wheel3: 0)
        e?.flags = []   // ignore modifiers held on the main keyboard, so Command + scroll doesn't zoom
        e?.post(tap: .cghidEventTap)
    }

    static func mediaKey(_ name: String) {
        let codes: [String: Int] = ["volup": 0, "voldown": 1, "mute": 7, "playpause": 16, "next": 17, "prev": 18]
        guard let key = codes[name] else { return }
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let e = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                       modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                       timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                       data1: (key << 16) | (state << 8), data2: -1)
            e?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static func open(_ target: String) {
        if target.contains("://") || target.hasPrefix("/") || target.hasPrefix("~") {
            run("/usr/bin/open", [(target as NSString).expandingTildeInPath])
        } else {
            run("/usr/bin/open", ["-a", target])
        }
    }

    private static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
    }
}
