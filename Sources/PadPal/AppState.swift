import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

let statusNotification = Notification.Name("local.padpal.status")

@MainActor
final class AppState: ObservableObject {
    @Published var config: Config
    @Published var configError: String?
    @Published var connected = false
    @Published var installed = false
    @Published var inputAccess = false
    @Published var accessibility = false
    @Published var pinned: String?            // profile name pinned by hand; nil = follow the front app
    @Published var frontApp: String?
    @Published var flash: String?             // input pressed most recently
    /// A passing notice under the pad picture; clears itself after a few seconds.
    @Published var message: String? {
        didSet {
            messageToken += 1
            guard message != nil else { return }
            let token = messageToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.messageToken == token { self?.message = nil }
            }
        }
    }
    private var messageToken = 0
    /// Shown beside the Reload button for a moment after a reload.
    @Published var reloadNote: String?

    private let pad = PadLink()
    private let listener = PadListener()
    private let io = DispatchQueue(label: "padpal.io")
    private var originalKeys: Light?
    private var originalGlow: Light?
    private var timer: Timer?
    private var termSource: DispatchSourceSignal?
    @Published var editorInput = "top1"      // slot selected in the layout editor
    @Published var editorProfile = ""        // profile shown in the layout editor
    private var editorWindow: NSWindow?
    @Published var recording = false         // the editor is waiting for a shortcut to be pressed
    var recordMonitor: Any?
    private var status: String?               // Claude status shown on the rim, if any
    private let rimGen = Counter()            // bumped to cancel a rim animation in flight
    private let rim = RimState()

    var profile: Profile {
        if let name = pinned, let p = config.profiles.first(where: { $0.name == name }) { return p }
        return config.profile(forApp: frontApp)
    }

    init() {
        (config, configError) = Config.load()
        frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        pad.onConnection = { [weak self] up in
            DispatchQueue.main.async { self?.connectionChanged(up) }
        }
        pad.start()

        listener.onInput = { [weak self] name in
            DispatchQueue.main.async { self?.handle(name) }
        }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in
                guard let self, id != Bundle.main.bundleIdentifier else { return }
                self.frontApp = id
                self.applyLight()
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: statusNotification, object: nil, queue: .main) { [weak self] note in
            let state = note.object as? String ?? "clear"
            Task { @MainActor in self?.showStatus(state) }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.padpal.edit"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openEditor() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreLightsNow() }
        }

        // Restore the pad's own lighting when the app is terminated, not only when it is quit from the menu.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.restoreLightsNow() }
            exit(0)
        }
        term.resume()
        termSource = term

        if !PadListener.accessGranted { PadListener.requestAccess() }
        refreshPermissions()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    func refreshPermissions() {
        accessibility = Actions.accessibilityGranted
        if PadListener.accessGranted && !listener.isRunning { _ = listener.start() }
        inputAccess = listener.isRunning
        let report = """
        time: \(Date())
        inputMonitoring: \(PadListener.accessState)
        listenerRunning: \(listener.isRunning)
        lastOpenResult: 0x\(String(UInt32(bitPattern: listener.lastOpenResult), radix: 16))
        accessibility: \(accessibility)
        padConnected: \(connected)
        layerInstalled: \(installed)
        executable: \(Bundle.main.executablePath ?? "?")
        """
        try? report.write(to: Config.dir.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
    }

    private func connectionChanged(_ up: Bool) {
        connected = up
        guard up else { installed = false; return }
        let layer = config.layer
        io.async { [pad, rim] in
            var keys = pad.light(.keys), glow = pad.light(.glow)
            if let saved = SavedLights.load() {
                // The app last exited without restoring the pad, so what the pad shows now is ours, not its own.
                keys = saved.keys; glow = saved.glow
                rim.full = saved.brightness; rim.level = saved.brightness
                pad.setBrightness(.glow, UInt8(saved.brightness))
            } else if let k = keys, let g = glow {
                if let b = pad.brightness(.glow), b > 0 { rim.full = Int(b); rim.level = Int(b) }
                SavedLights(keys: k, glow: g, brightness: rim.full).save()
            }
            let ok = pad.isInstalled(layer: layer)
            DispatchQueue.main.async {
                self.originalKeys = keys
                self.originalGlow = glow
                self.installed = ok
                self.applyLight()
            }
        }
    }

    // MARK: Input

    private func handle(_ input: String) {
        flash = input
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if self?.flash == input { self?.flash = nil }
        }
        if editorWindow?.isVisible == true && NSApp.isActive {
            editorInput = input      // while editing, a pad press picks the slot instead of acting
            return
        }
        let active = Actions.isHolding(config.overrideKey) ? config.profiles[0] : profile
        guard let b = config.binding(input, in: active) else { return }
        if let target = b.profile { switchProfile(target); return }
        if !accessibility && (b.keys != nil || b.text != nil || b.scroll != nil || b.media != nil) {
            Actions.requestAccessibility()
            message = "Allow PadPal under Accessibility so it can send shortcuts."
            return
        }
        Actions.perform(b)
    }

    func switchProfile(_ target: String) {
        switch target {
        case "auto": pinned = nil
        case "next":
            let names = config.profiles.map(\.name)
            let i = names.firstIndex(of: profile.name) ?? 0
            pinned = names[(i + 1) % names.count]
        default: if config.profiles.contains(where: { $0.name == target }) { pinned = target }
        }
        applyLight()
    }

    // MARK: Lighting

    func applyLight() {
        guard connected, let original = originalKeys else { return }
        let p = profile
        let want = p.hue.map { Light(effect: 1, hue: $0, sat: p.sat ?? 255) } ?? original
        io.async { [pad] in pad.setLight(.keys, want) }
        applyRim()
    }

    /// Moves the rim to the current profile's colour, using the chosen transition.
    private func applyRim() {
        guard connected, status == nil, let original = originalGlow else { return }
        let style = config.rimStyle
        let p = profile
        let target = style == "off" ? original : (p.hue.map { Light(effect: 1, hue: $0, sat: p.sat ?? 255) } ?? original)
        let gen = rimGen.next()
        io.async { [pad, rim, rimGen] in
            guard rimGen.value == gen, rim.shown != target else { return }
            let from = rim.shown ?? original
            let full = Int(rim.full)
            if style != "fade" && rim.level != full {
                pad.setBrightness(.glow, UInt8(full)); rim.level = full
            }
            if style == "fade" {
                // Dim to off, change colour while dark, then come back up. No in-between colours.
                rim.shown = nil
                let steps = 9, startLevel = rim.level
                for i in 1...steps {
                    guard rimGen.value == gen else { return }
                    rim.level = startLevel * (steps - i) / steps
                    pad.setBrightness(.glow, UInt8(rim.level))
                    usleep(22_000)
                }
                pad.setLight(.glow, target)
                for i in 1...steps {
                    guard rimGen.value == gen else { return }
                    rim.level = full * i / steps
                    pad.setBrightness(.glow, UInt8(rim.level))
                    usleep(22_000)
                }
            } else if style == "sweep" {
                // Blend straight from the old colour to the new one (a linear mix of red, green and
                // blue), so the rim never shows the rainbow colours that lie between two hues.
                rim.shown = nil
                let a = Self.rgb(hue: from.hue, sat: from.sat), b = Self.rgb(hue: target.hue, sat: target.sat)
                if from.effect != 1 { pad.setLight(.glow, Light(effect: 1, hue: from.hue, sat: from.sat)) }
                let steps = 16
                for i in 1...steps {
                    guard rimGen.value == gen else { return }
                    let t = Double(i) / Double(steps)
                    let mix = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
                    let (h, sat, v) = Self.hsv(mix)
                    pad.setColor(.glow, hue: h, sat: sat)
                    rim.level = Int((Double(full) * v).rounded())
                    pad.setBrightness(.glow, UInt8(rim.level))
                    usleep(24_000)
                }
                pad.setLight(.glow, target)
                pad.setBrightness(.glow, UInt8(full)); rim.level = full
            } else if target.effect == 1 && style == "rotate" {
                // The firmware's "snake" effect chases the new colour around the rim, then it settles.
                pad.setLight(.glow, Light(effect: 17, hue: target.hue, sat: target.sat))
                for _ in 0..<16 { guard rimGen.value == gen else { return }; usleep(50_000) }
                pad.setLight(.glow, target)
            } else {
                pad.setLight(.glow, target)
            }
            rim.shown = target
        }
    }

    /// Shows a Claude status on the rim: working, waiting, done or clear.
    func showStatus(_ state: String) {
        guard connected else { return }
        let want: Light?
        switch state {
        case "working": want = Light(effect: 3, hue: 11, sat: 255)    // breathing orange
        case "waiting": want = Light(effect: 1, hue: 40, sat: 255)    // solid amber
        case "done": want = Light(effect: 1, hue: 85, sat: 255)       // solid green
        default: want = nil
        }
        guard let want else { status = nil; applyRim(); return }
        status = state
        _ = rimGen.next()
        io.async { [pad, rim] in
            if rim.level != rim.full { pad.setBrightness(.glow, UInt8(rim.full)); rim.level = rim.full }
            pad.setLight(.glow, want); rim.shown = want
        }
        if state == "done" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.status == "done" else { return }
                self.status = nil
                self.applyRim()
            }
        }
    }

    /// Signed hue distance the short way round the colour wheel.
    nonisolated static func hueStep(_ from: UInt8, _ to: UInt8) -> Int {
        var d = Int(to) - Int(from)
        if d > 128 { d -= 256 } else if d < -128 { d += 256 }
        return d
    }

    /// Pad colour (hue and saturation 0-255, full brightness) as red, green, blue in 0...1.
    nonisolated static func rgb(hue: UInt8, sat: UInt8) -> (Double, Double, Double) {
        let h = Double(hue) / 255 * 6, s = Double(sat) / 255
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let (r, g, b): (Double, Double, Double)
        switch Int(h) % 6 {
        case 0: (r, g, b) = (1, x, 0)
        case 1: (r, g, b) = (x, 1, 0)
        case 2: (r, g, b) = (0, 1, x)
        case 3: (r, g, b) = (0, x, 1)
        case 4: (r, g, b) = (x, 0, 1)
        default: (r, g, b) = (1, 0, x)
        }
        return (1 - s + s * r, 1 - s + s * g, 1 - s + s * b)
    }

    /// Red, green, blue in 0...1 as pad hue and saturation (0-255) plus brightness (0...1).
    nonisolated static func hsv(_ c: (Double, Double, Double)) -> (UInt8, UInt8, Double) {
        let mx = max(c.0, c.1, c.2), mn = min(c.0, c.1, c.2), d = mx - mn
        var h = 0.0
        if d > 0.0001 {
            if mx == c.0 { h = ((c.1 - c.2) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.1 { h = (c.2 - c.0) / d + 2 }
            else { h = (c.0 - c.1) / d + 4 }
            if h < 0 { h += 6 }
        }
        let sat = mx > 0 ? d / mx : 0
        return (UInt8(min(255, (h / 6 * 255).rounded())), UInt8(min(255, (sat * 255).rounded())), mx)
    }

    func setRimStyle(_ style: String) {
        config.rim = style
        config.save()
        applyRim()
    }

    func setOverrideKey(_ key: String) {
        config.defaultWhileHolding = key
        config.save()
    }

    private func restoreLightsNow() {
        let keys = originalKeys, glow = originalGlow
        io.sync { [pad, rim] in
            pad.setBrightness(.glow, UInt8(rim.full))
            if let keys { pad.setLight(.keys, keys) }
            if let glow { pad.setLight(.glow, glow) }
        }
        if keys != nil && glow != nil { SavedLights.clear() }
    }

    // MARK: Config and pad setup

    func reload() {
        (config, configError) = Config.load()
        if let p = pinned, !config.profiles.contains(where: { $0.name == p }) { pinned = nil }
        connectionChanged(connected)
        reloadNote = configError == nil ? "Reloaded" : "Couldn't read config"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.reloadNote = nil }
    }

    func showAbout() {
        let credits = NSAttributedString(
            string: "Per-app layouts and colours for the Work Louder Creator Micro.\nAn independent project, not affiliated with Work Louder.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    func openEditor() {
        if editorWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "PadPal Layouts"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: EditorView(state: self))
            w.center()
            editorWindow = w
            // Back to a menu-bar-only app once the editor closes.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
            }
        }
        if !config.profiles.contains(where: { $0.name == editorProfile }) { editorProfile = profile.name }
        // While the editor is open, behave like a normal app: Dock icon and Command-Tab entry.
        NSApp.setActivationPolicy(.regular)
        editorWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Don't start with the cursor in the Label field, where stray typing would rename a key.
        DispatchQueue.main.async { [weak self] in self?.editorWindow?.makeFirstResponder(nil) }
    }

    /// Call after the editor changes the config: saves it and refreshes the pad's colours.
    func configEdited() {
        config.save()
        if let p = pinned, !config.profiles.contains(where: { $0.name == p }) { pinned = nil }
        applyLight()
    }

    // MARK: Import and export

    /// Saves the given layouts to a file the user picks.
    func exportLayouts(_ profiles: [Profile], suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName + ".padpal.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try enc.encode(LayoutFile(padpalLayouts: 1, profiles: profiles)).write(to: url)
            message = "Exported \(profiles.count) layout\(profiles.count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Adds layouts from a file. Existing layouts are never replaced: clashing names get a number,
    /// and an app already claimed by one of your layouts stays with it.
    func importLayouts() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        let incoming: [Profile]
        if let f = try? dec.decode(LayoutFile.self, from: data) { incoming = f.profiles }
        else if let c = try? dec.decode(Config.self, from: data) { incoming = c.profiles }
        else if let p = try? dec.decode(Profile.self, from: data) { incoming = [p] }
        else { message = "\(url.lastPathComponent) isn't a PadPal layout file."; return }
        guard !incoming.isEmpty else { message = "\(url.lastPathComponent) has no layouts in it."; return }

        var claimed = Set(config.profiles.flatMap { $0.apps ?? [] })
        var last = ""
        for var p in incoming {
            let base = p.name.isEmpty ? "Layout" : p.name
            var name = base, n = 2
            while config.profiles.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
            p.name = name
            p.apps = (p.apps ?? []).filter { !claimed.contains($0) }
            claimed.formUnion(p.apps ?? [])
            p.bindings = p.bindings.filter { PadInput.all.contains($0.key) }
            config.profiles.append(p)
            last = name
        }
        editorProfile = last
        configEdited()
        message = "Imported \(incoming.count) layout\(incoming.count == 1 ? "" : "s") from \(url.lastPathComponent)."
    }

    func openConfig() { NSWorkspace.shared.open(Config.file) }

    func installOnPad() {
        let layer = config.layer
        io.async { [pad] in
            let text = PadSetup.install(pad, layer: layer)
            let ok = pad.isInstalled(layer: layer)
            DispatchQueue.main.async { self.message = text; self.installed = ok }
        }
    }
}

/// What an exported layout file holds.
struct LayoutFile: Codable {
    var padpalLayouts: Int      // file format version
    var profiles: [Profile]
}

/// The pad's own lighting, kept on disk while the app is showing its colours, so an unclean exit can't lose it.
struct SavedLights: Codable {
    var keys: Light
    var glow: Light
    var brightness: Int
    static let file = Config.dir.appendingPathComponent("original-lights.json")
    static func load() -> SavedLights? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SavedLights.self, from: $0) }
    }
    func save() { try? JSONEncoder().encode(self).write(to: SavedLights.file) }
    static func clear() { try? FileManager.default.removeItem(at: file) }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

/// What the rim currently shows; only touched on the pad I/O queue.
final class RimState: @unchecked Sendable {
    var shown: Light?
    var full = 255      // the rim's normal brightness, read from the pad
    var level = 255     // brightness right now (lower only part-way through a fade)
}

/// Backup, install and restore steps shared by the app and the command line.
enum PadSetup {
    static func saveBackup(_ pad: PadLink, to url: URL? = nil) -> URL? {
        guard let b = pad.backup() else { return nil }
        try? FileManager.default.createDirectory(at: Config.backups, withIntermediateDirectories: true)
        let stamp = b.date.replacingOccurrences(of: ":", with: "-")
        let dest = url ?? Config.backups.appendingPathComponent("pad-\(stamp).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(b), (try? data.write(to: dest)) != nil else { return nil }
        return dest
    }

    static func install(_ pad: PadLink, layer: Int) -> String {
        guard let saved = saveBackup(pad) else { return "Couldn't back up the pad, so nothing was written." }
        guard let n = pad.install(layer: layer) else { return "Writing to the pad failed. Backup: \(saved.path)" }
        return "Pad layer \(layer) ready (\(n) slots changed). Backup: \(saved.lastPathComponent)"
    }

    static func restore(_ pad: PadLink, from url: URL) -> String {
        guard let data = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(PadBackup.self, from: data) else {
            return "Couldn't read backup \(url.path)"
        }
        guard let n = pad.restore(b) else { return "Restore failed part-way; run it again." }
        return "Restored \(n) slots from \(url.lastPathComponent)"
    }
}
