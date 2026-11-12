import Foundation

/// What one pad input does. Exactly one of the action fields should be set.
struct Binding: Codable, Equatable {
    var label: String
    var keys: String?      // shortcut, e.g. "cmd+shift+n"
    var media: String?     // playpause | next | prev | volup | voldown | mute
    var open: String?      // app name, file path or URL
    var shell: String?     // command run with /bin/zsh -lc
    var text: String?      // text to type
    var scroll: Int?       // lines; positive scrolls up
    var profile: String?   // "next", "auto" or a profile name
}

typealias PadBinding = Binding

struct Profile: Codable, Equatable {
    var name: String
    var apps: [String]?    // bundle identifiers that activate this profile
    var hue: UInt8?        // key colour, 0-255 around the colour wheel
    var sat: UInt8?        // 0 = white, 255 = full colour
    var bindings: [String: Binding]
}

struct Config: Codable, Equatable {
    /// Pad layer that carries the app's codes (0-based; layer 1 is one press of the pad's layer key).
    var layer: Int
    /// The first profile is the fallback: inputs a profile leaves out use its binding.
    var profiles: [Profile]
    /// How the outer rim changes to the app colour on an app switch: off, instant, fade, rotate or sweep.
    var rim: String?
    /// Runs the sweep the other way round the rim.
    var sweepReverse: Bool?
    /// Holding this key on the main keyboard makes the pad use the first profile: cmd, alt, ctrl, shift or none.
    var defaultWhileHolding: String?

    var rimStyle: String { rim ?? "fade" }
    var overrideKey: String { defaultWhileHolding ?? "cmd" }

    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PadPal")
    static let file = dir.appendingPathComponent("config.json")
    static let backups = dir.appendingPathComponent("backups")

    static func load() -> (Config, String?) {
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: file) else {
            let c = Config.starter
            c.save()
            return (c, nil)
        }
        do { return (try JSONDecoder().decode(Config.self, from: data), nil) }
        catch { return (Config.starter, "config.json has an error, using the starter layout: \(error.localizedDescription)") }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        try? enc.encode(self).write(to: Config.file)
    }

    func profile(forApp bundleID: String?) -> Profile {
        if let id = bundleID, let p = profiles.first(where: { $0.apps?.contains(id) == true }) { return p }
        return profiles[0]
    }

    func binding(_ input: String, in p: Profile) -> Binding? {
        p.bindings[input] ?? profiles[0].bindings[input]
    }

    static let starter = Config(layer: 1, profiles: [
        Profile(name: "Default", apps: nil, hue: nil, sat: nil, bindings: [
            "roller.click": Binding(label: "Mission Control", keys: "ctrl+up"),
            "roller.ccw": Binding(label: "Space left", keys: "ctrl+left"),
            "roller.cw": Binding(label: "Space right", keys: "ctrl+right"),
            "knob.click": Binding(label: "Mute", media: "mute"),
            "knob.ccw": Binding(label: "Volume down", media: "voldown"),
            "knob.cw": Binding(label: "Volume up", media: "volup"),
            "top1": Binding(label: "Previous track", media: "prev"),
            "top2": Binding(label: "Next track", media: "next"),
            "a1": Binding(label: "Open Claude", open: "Claude"),
            "a2": Binding(label: "Play / pause", media: "playpause"),
            "b1": Binding(label: "Undo", keys: "cmd+z"),
            "b2": Binding(label: "Redo", keys: "cmd+shift+z"),
            "b3": Binding(label: "Word left", keys: "alt+left"),
            "b4": Binding(label: "Word right", keys: "alt+right"),
            "bot1": Binding(label: "Copy", keys: "cmd+c"),
            "bot2": Binding(label: "Paste", keys: "cmd+v"),
            "corner.left": Binding(label: "Next profile", profile: "next"),
        ]),
        Profile(name: "Claude", apps: ["com.anthropic.claudefordesktop"], hue: 11, sat: 230, bindings: [
            "top1": Binding(label: "New session", keys: "cmd+n"),
            "top2": Binding(label: "Command palette", keys: "cmd+k"),
            "a1": Binding(label: "Sidebar", keys: "cmd+b"),
            "a2": Binding(label: "Files", keys: "cmd+shift+f"),
            "a3": Binding(label: "Changes", keys: "cmd+shift+d"),
            "a4": Binding(label: "Find", keys: "cmd+f"),
            "b1": Binding(label: "Stop", keys: "escape"),
            "b2": Binding(label: "Reopen closed", keys: "cmd+shift+t"),
            "b3": Binding(label: "Open folder", keys: "cmd+shift+o"),
            "b4": Binding(label: "Send", keys: "return"),
            "knob.ccw": Binding(label: "Scroll down", scroll: -3),
            "knob.cw": Binding(label: "Scroll up", scroll: 3),
        ]),
        Profile(name: "Browser", apps: ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser"], hue: 150, sat: 230, bindings: [
            "top1": Binding(label: "New tab", keys: "cmd+t"),
            "top2": Binding(label: "Close tab", keys: "cmd+w"),
            "a1": Binding(label: "Back", keys: "cmd+["),
            "a2": Binding(label: "Forward", keys: "cmd+]"),
            "a3": Binding(label: "Reload", keys: "cmd+r"),
            "a4": Binding(label: "Reopen tab", keys: "cmd+shift+t"),
            "roller.ccw": Binding(label: "Previous tab", keys: "ctrl+shift+tab"),
            "roller.cw": Binding(label: "Next tab", keys: "ctrl+tab"),
            "knob.ccw": Binding(label: "Scroll down", scroll: -3),
            "knob.cw": Binding(label: "Scroll up", scroll: 3),
        ]),
    ])
}
