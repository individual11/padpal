import Foundation

/// One of the pad's layers as stored on the pad: 16 keys and the four encoder directions.
struct PadLayer: Equatable {
    var keys: [UInt16]      // matrix order; index 15 is the pad's own layer key
    var turns: [UInt16]     // roller ccw, roller cw, knob ccw, knob cw

    /// The 19 slots PadPal uses, in `PadInput.all` order.
    var slots: [UInt16] { Array(keys.prefix(PadInput.keys.count)) + turns }

    /// True when every slot carries PadPal's code.
    var isPadPal: Bool { slots == PadInput.codes }

    /// Slots that do something (not empty and not "same as the layer below").
    var inUse: Int { slots.filter { $0 > 1 }.count }

    /// Layer the pad's layer key jumps to from here, when it is a plain "go to layer" key.
    var layerKeyTarget: Int? {
        guard keys.count > 15, (0x5200...0x521F).contains(keys[15]) else { return nil }
        return Int(keys[15] & 0x1F)
    }

    var summary: String {
        if isPadPal { return "PadPal" }
        return inUse == 0 ? "empty" : "\(inUse) key\(inUse == 1 ? "" : "s") in use"
    }
}

/// What a key press from the pad looked like to the computer.
struct PadUsage: Hashable {
    var page: Int
    var usage: Int
}

extension PadBackup {
    var layers: [PadLayer] {
        keymap.enumerated().map { i, keys in
            PadLayer(keys: keys, turns: i < encoders.count ? encoders[i].flatMap { $0 } : [])
        }
    }
}

/// Turns the pad's own key codes (QMK, as VIA reports them) into PadPal actions.
enum PadTranslate {
    /// USB keyboard usage -> the key names PadPal's shortcuts use.
    static let keyNames: [Int: String] = {
        var m: [Int: String] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { m[0x04 + i] = String(c) }
        for (i, c) in "1234567890".enumerated() { m[0x1E + i] = String(c) }
        for (i, n) in ["return", "escape", "delete", "tab", "space", "-", "=", "[", "]", "\\"].enumerated() { m[0x28 + i] = n }
        for (i, n) in [";", "'", "`", ",", ".", "/"].enumerated() { m[0x33 + i] = n }
        for i in 0..<12 { m[0x3A + i] = "f\(i + 1)" }
        for (i, n) in ["home", "pageup", "forwarddelete", "end", "pagedown", "right", "left", "down", "up"].enumerated() { m[0x4A + i] = n }
        return m
    }()

    /// QMK media key -> PadPal media name, its label, and the consumer-page usage it sends.
    static let media: [UInt16: (name: String, label: String, usage: Int)] = [
        0xA8: ("mute", "Mute", 0xE2), 0xA9: ("volup", "Volume up", 0xE9), 0xAA: ("voldown", "Volume down", 0xEA),
        0xAB: ("next", "Next track", 0xB5), 0xAC: ("prev", "Previous track", 0xB6), 0xAE: ("playpause", "Play / pause", 0xCD),
    ]
    /// Consumer usages of media keys PadPal has no action for; only used to recognize a layer.
    static let otherMedia: [UInt16: Int] = [0xAD: 0xB7, 0xBB: 0xB3, 0xBC: 0xB4, 0xBD: 0x6F, 0xBE: 0x70]

    static func modifierNames(_ bits: Int) -> [String] {
        var parts: [String] = []
        if bits & 0x08 != 0 { parts.append("cmd") }
        if bits & 0x01 != 0 { parts.append("ctrl") }
        if bits & 0x04 != 0 { parts.append("alt") }
        if bits & 0x02 != 0 { parts.append("shift") }
        return parts
    }

    /// First macro key code. It moved between versions of the VIA protocol.
    static func macroBase(_ proto: Int) -> UInt16 { proto >= 12 ? 0x7700 : 0x7702 }

    static func macroIndex(_ code: UInt16, proto: Int) -> Int? {
        let base = macroBase(proto)
        return code >= base && code < base + 16 ? Int(code - base) : nil
    }

    /// Splits the pad's macro memory into one byte list per macro.
    static func splitMacros(_ bytes: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = [], cur: [UInt8] = []
        for b in bytes {
            if b == 0 { out.append(cur); cur = [] } else { cur.append(b) }
        }
        return out
    }

    /// A stored macro as PadPal steps. Text is typed, key taps become shortcuts or media keys, delays
    /// become waits. `dropped` counts key presses that have no PadPal equivalent.
    static func steps(_ macro: [UInt8]) -> (steps: [Step], dropped: Int) {
        var steps: [Step] = [], held = 0, text = "", i = 0, dropped = 0
        func flush() { if !text.isEmpty { steps.append(Step(text: text)); text = "" } }
        func press(_ usage: Int) {
            if let m = media[UInt16(usage)] { flush(); steps.append(Step(media: m.name)); return }
            guard let name = keyNames[usage] else { dropped += 1; return }
            flush()
            steps.append(Step(keys: (modifierNames(held) + [name]).joined(separator: "+")))
        }
        while i < macro.count {
            let b = macro[i]
            guard b == 1, i + 1 < macro.count else {
                // An ordinary character: typed, or pressed with whatever modifiers are being held.
                let ch = String(UnicodeScalar(b)).lowercased()
                if held != 0, Actions.keyCodes[ch] != nil {
                    flush(); steps.append(Step(keys: (modifierNames(held) + [ch]).joined(separator: "+")))
                } else if b >= 0x20 {
                    text.append(Character(UnicodeScalar(b)))
                } else if b == 0x0A || b == 0x0D {
                    flush(); steps.append(Step(keys: "return"))
                }
                i += 1
                continue
            }
            let action = macro[i + 1]
            if action == 4 {
                // A delay: digits up to a "|".
                var ms = 0
                i += 2
                while i < macro.count, macro[i] != 0x7C {
                    // Stop adding digits once past the longest wait PadPal allows, so a huge number can't overflow.
                    if (0x30...0x39).contains(macro[i]), ms <= 10_000 { ms = ms * 10 + Int(macro[i]) - 0x30 }
                    i += 1
                }
                i += 1
                flush()
                if ms > 0 { steps.append(Step(wait: min(ms, 10_000))) }
                continue
            }
            guard i + 2 < macro.count else { break }
            let code = Int(macro[i + 2])
            let mod = (0xE0...0xE7).contains(code) ? 1 << ((code - 0xE0) % 4) : 0
            switch action {
            case 1: if mod == 0 { press(code) }
            case 2: if mod != 0 { held |= mod } else { press(code) }
            case 3: if mod != 0 { held &= ~mod }
            default: break
            }
            i += 3
        }
        flush()
        return (steps, dropped)
    }

    enum Result: Equatable { case empty, skipped, action(Binding) }

    /// One pad key code as a PadPal action.
    static func binding(_ code: UInt16, proto: Int, macros: [[UInt8]]) -> Result {
        if code <= 1 { return .empty }
        if let m = media[code] { return .action(Binding(label: m.label, media: m.name)) }
        let wheel: [UInt16: Int] = proto >= 12 ? [0xD9: 3, 0xDA: -3] : [0xF9: 3, 0xFA: -3]
        if let lines = wheel[code] { return .action(Binding(label: lines > 0 ? "Scroll up" : "Scroll down", scroll: lines)) }
        if code < 0x2000 {
            // A plain key, possibly with modifiers held.
            guard let name = keyNames[Int(code & 0xFF)] else { return .skipped }
            let keys = (modifierNames(Int(code >> 8)) + [name]).joined(separator: "+")
            return .action(Binding(label: label(forKeys: keys), keys: keys))
        }
        if let n = macroIndex(code, proto: proto) {
            // A macro the reading doesn't include (the read was cut short) is unknown, not empty.
            guard n < macros.count else { return .skipped }
            let made = steps(macros[n])
            let s = made.steps
            // A macro with a key PadPal can't press is left out whole: running the rest of it
            // without that key would do something other than what the pad did.
            if made.dropped > 0 { return .skipped }
            if s.isEmpty { return .empty }
            if s.count == 1, let k = s[0].keys { return .action(Binding(label: label(forKeys: k), keys: k)) }
            if s.count == 1, let name = s[0].media, let m = media.values.first(where: { $0.name == name }) {
                return .action(Binding(label: m.label, media: name))
            }
            if s.count == 1, let t = s[0].text { return .action(Binding(label: "Type “\(t.prefix(12))”", text: t)) }
            return .action(Binding(label: "Macro \(n + 1)", steps: s))
        }
        return .skipped
    }

    /// A short readable label for a shortcut, e.g. "⌘⇧Z".
    static func label(forKeys keys: String) -> String {
        let symbols = ["cmd": "⌘", "ctrl": "⌃", "alt": "⌥", "shift": "⇧"]
        let names = ["left": "←", "right": "→", "up": "↑", "down": "↓", "return": "Return", "escape": "Esc", "delete": "Delete",
                     "forwarddelete": "Fwd Delete", "space": "Space", "tab": "Tab", "home": "Home", "end": "End",
                     "pageup": "Page Up", "pagedown": "Page Down"]
        return keys.split(separator: "+").map(String.init).map { symbols[$0] ?? names[$0] ?? $0.uppercased() }.joined()
    }

    /// A PadPal layout holding what one of the pad's own layers did, plus how many keys could not be carried over.
    static func layout(from backup: PadBackup, layer: Int) -> (profile: Profile, skipped: Int)? {
        let layers = backup.layers
        guard layers.indices.contains(layer) else { return nil }
        let macros = splitMacros(backup.macros)
        var bindings: [String: Binding] = [:], skipped = 0
        for (slot, code) in zip(PadInput.all, layers[layer].slots) {
            switch binding(code, proto: backup.protocolVersion, macros: macros) {
            case .empty: break
            case .skipped: skipped += 1
            case .action(let b): bindings[slot] = b
            }
        }
        return (Profile(name: "layout-from-layer-\(layer + 1)", apps: nil, hue: nil, sat: nil, bindings: bindings), skipped)
    }

    /// Everything a layer could send to the computer, for working out which layer a stray key came from.
    static func usages(of layer: PadLayer, proto: Int, macros: [[UInt8]]) -> Set<PadUsage> {
        var out = Set<PadUsage>()
        func key(_ usage: Int) { if (4...0xE7).contains(usage) { out.insert(PadUsage(page: 7, usage: usage)) } }
        for code in layer.slots where code > 1 {
            if let m = media[code] { out.insert(PadUsage(page: 0x0C, usage: m.usage)); continue }
            if let u = otherMedia[code] { out.insert(PadUsage(page: 0x0C, usage: u)); continue }
            if code < 0x2000 {
                key(Int(code & 0xFF))
                let mods = Int(code >> 8), right = mods & 0x10 != 0
                for bit in 0..<4 where mods & (1 << bit) != 0 { key(0xE0 + bit + (right ? 4 : 0)) }
            } else if let n = macroIndex(code, proto: proto), n < macros.count {
                let m = macros[n]
                var i = 0
                while i + 2 < m.count {
                    if m[i] == 1, (1...3).contains(m[i + 1]) { key(Int(m[i + 2])); i += 3 } else { i += 1 }
                }
            }
        }
        return out
    }

    /// Presses of the pad's layer key that lead from one layer to another, when that can be worked out.
    static func presses(from: Int, to: Int, layers: [PadLayer]) -> Int? {
        var at = from
        for n in 1...max(1, layers.count) {
            guard layers.indices.contains(at), let next = layers[at].layerKeyTarget else { return nil }
            if next == to { return n }
            at = next
        }
        return nil
    }
}
