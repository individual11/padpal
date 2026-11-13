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
    /// The pad's four layers as last read from it; empty until the pad has been read.
    @Published var layers: [PadLayer] = []
    /// A key arrived from the pad that isn't PadPal's, so the pad is probably on another layer.
    @Published var offLayer = false
    /// Presses of the pad's layer key that lead back, when that is certain.
    @Published var offLayerPresses: Int?
    private var snapshot: PadBackup?
    /// Whether the pad's layers have been read since it was plugged in. Nothing is written to the pad until they have.
    enum PadRead { case pending, ok, failed }
    @Published var padRead = PadRead.pending
    /// Bumped whenever the pad connects or disconnects, so a reading from an earlier connection is thrown away.
    private var padGen = 0
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
    @Published var recordingStep: Int?       // macro step the shortcut is for; -1 appends each press; nil is the slot's own
    @Published var macroSheet = false        // the macro step sheet is open
    var macroOriginal: PadBinding?           // the slot's binding when the sheet opened, for Cancel (nil = it had none)
    @Published var macroSelection: Int?      // selected row in the step sheet
    @Published var testCountdown: Int?       // seconds left before a test run of a macro
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
        listener.onForeign = { [weak self] usage in
            DispatchQueue.main.async { self?.foreign(usage) }
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
        padPalLayer: \(config.layer + 1)
        layers: \(layers.map(\.summary).joined(separator: " | "))
        onAnotherLayer: \(offLayer)
        executable: \(Bundle.main.executablePath ?? "?")
        """
        try? report.write(to: Config.dir.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
    }

    private func connectionChanged(_ up: Bool) {
        connected = up
        padGen += 1
        let gen = padGen
        guard up else { installed = false; layers = []; snapshot = nil; padRead = .pending; setOffLayer(false); return }
        padRead = .pending
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
            // One failed request spoils a whole reading, so try twice before giving up.
            let snap = pad.backup() ?? pad.backup()
            let fallback = snap == nil ? pad.isInstalled(layer: layer) : false
            DispatchQueue.main.async {
                guard gen == self.padGen else { return }
                self.originalKeys = keys
                self.originalGlow = glow
                self.setOffLayer(false)
                self.take(snap, installedIfUnread: fallback)
                self.applyLight()
            }
        }
    }

    /// Takes in a fresh reading of the pad's layers and works out whether PadPal's layer is set up.
    /// A failed reading (nil) is not proof that setup is needed: the last reading is kept, and
    /// `installedIfUnread` says whether PadPal's layer is known to be set up some other way.
    private func take(_ snap: PadBackup?, installedIfUnread: Bool = false) {
        guard let snap else {
            padRead = .failed
            if installedIfUnread { installed = true }
            return
        }
        padRead = .ok
        snapshot = snap
        layers = snap.layers
        func holds(_ n: Int) -> Bool { layers.indices.contains(n) && layers[n].isPadPal }
        // The config names a layer without PadPal's keys, but another layer has them: use that one.
        if !holds(config.layer), let other = layers.firstIndex(where: \.isPadPal) {
            config.layer = other
            config.save()
            message = "Using layer \(other + 1), where PadPal is already set up."
        }
        installed = holds(config.layer)
    }

    // MARK: Other layers

    /// A key press from the pad that PadPal's layer can't send.
    private func foreign(_ usage: PadUsage) {
        guard installed else { return }
        var presses: Int?
        if let snap = snapshot {
            let macros = PadTranslate.splitMacros(snap.macros)
            let from = layers.indices.filter {
                !layers[$0].isPadPal && PadTranslate.usages(of: layers[$0], proto: snap.protocolVersion, macros: macros).contains(usage)
            }
            if from.count == 1 { presses = PadTranslate.presses(from: from[0], to: config.layer, layers: layers) }
        }
        offLayerPresses = presses
        setOffLayer(true)
    }

    /// While the pad is on another layer it shows its own lighting, so a colored rim means PadPal is live.
    private func setOffLayer(_ off: Bool) {
        guard offLayer != off else { return }
        offLayer = off
        if !off { offLayerPresses = nil }
        if off { status = nil }     // the pad's own lighting wins over a status color
        applyLight()
    }

    // MARK: Input

    private func handle(_ input: String) {
        setOffLayer(false)
        flash = input
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if self?.flash == input { self?.flash = nil }
        }
        if editorWindow?.isVisible == true && NSApp.isActive {
            if !macroSheet { editorInput = input }      // while editing, a pad press picks the slot instead of acting
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
        let want = offLayer ? original : (p.hue.map { Light(effect: 1, hue: $0, sat: p.sat ?? 255) } ?? original)
        io.async { [pad] in pad.setLight(.keys, want) }
        applyRim()
    }

    /// Moves the rim to the current profile's color, using the chosen transition.
    private func applyRim() {
        guard connected, status == nil, let original = originalGlow else { return }
        let style = config.rimStyle
        let p = profile
        let target = style == "off" || offLayer ? original : (p.hue.map { Light(effect: 1, hue: $0, sat: p.sat ?? 255) } ?? original)
        let gen = rimGen.next()
        io.async { [pad, rim, rimGen] in
            guard rimGen.value == gen, rim.shown != target else { return }
            let from = rim.shown ?? original
            let full = Int(rim.full)
            if style != "fade" && rim.level != full {
                pad.setBrightness(.glow, UInt8(full)); rim.level = full
            }
            if style == "fade" {
                // Dim to off, change color while dark, then come back up. No in-between colors.
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
                // Blend straight from the old color to the new one (a linear mix of red, green and
                // blue), so the rim never shows the rainbow colors that lie between two hues.
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
                // The firmware's "snake" effect chases the new color around the rim, then it settles.
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
        guard connected, !offLayer else { return }
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

    /// Signed hue distance the short way round the color wheel.
    nonisolated static func hueStep(_ from: UInt8, _ to: UInt8) -> Int {
        var d = Int(to) - Int(from)
        if d > 128 { d -= 256 } else if d < -128 { d += 256 }
        return d
    }

    /// Pad color (hue and saturation 0-255, full brightness) as red, green, blue in 0...1.
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

    /// Runs a macro after a short countdown, so there is time to bring the target app to the front.
    func testMacro(_ steps: [Step]) {
        guard testCountdown == nil else { return }
        testCountdown = 3
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let n = self.testCountdown else { timer.invalidate(); return }
                if n > 1 { self.testCountdown = n - 1; return }
                timer.invalidate()
                self.testCountdown = nil
                Actions.runMacro(steps)
            }
        }
    }

    func showAbout() {
        let credits = NSAttributedString(
            string: "Per-app layouts and colors for the Work Louder Creator Micro.\nAn independent project, not affiliated with Work Louder.",
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

    /// Call after the editor changes the config: saves it and refreshes the pad's colors.
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
        guard var incoming = readLayouts(data) else { message = "\(url.lastPathComponent) isn't a PadPal layout file."; return }
        guard !incoming.isEmpty else { message = "\(url.lastPathComponent) has no layouts in it."; return }

        // Shell commands, things to open and macros can do real damage, so show them before taking them in.
        let risks = incoming.flatMap(\.riskLines)
        var left = 0
        if !risks.isEmpty {
            switch Self.confirmRisky(risks, file: url.lastPathComponent) {
            case .alertFirstButtonReturn:
                incoming = incoming.map(\.withoutRisks)
                left = risks.count
            case .alertSecondButtonReturn: break
            default: return
            }
        }

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
            + (left > 0 ? " Left out \(left) action\(left == 1 ? "" : "s")." : "")
    }

    /// Lists the risky actions in a file being imported. First button: import without them. Second: import all.
    private static func confirmRisky(_ risks: [String], file: String) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "\(file) contains \(risks.count) action\(risks.count == 1 ? "" : "s") that can run things on your Mac"
        alert.informativeText = "Shell commands, things to open, and macros run with your account's full access as soon as the key is pressed. Read each one below. Import them only if you trust where this file came from and understand what they do."
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        text.string = risks.joined(separator: "\n\n")
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.autoresizingMask = [.width]
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Import Without These")
        alert.addButton(withTitle: "Import Everything")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal()
    }

    func openConfig() { NSWorkspace.shared.open(Config.file) }

    // MARK: Choosing the pad layer

    /// First run: remembers which layer to set up, without writing anything to the pad.
    func pickLayer(_ n: Int) {
        config.layer = n
        config.save()
    }

    /// The layer menu in the panel: moves PadPal to another layer.
    func chooseLayer(_ n: Int) {
        guard layers.indices.contains(n), n != config.layer || !installed else { return }
        if layers[n].isPadPal {
            config.layer = n
            config.save()
            installed = true
            setOffLayer(false)
            message = "Using layer \(n + 1), where PadPal is already set up."
            return
        }
        setUp(layer: n)
    }

    /// Writes PadPal's keys to a layer after a backup. Asks first when the layer has keys on it.
    func setUp(layer n: Int) {
        // Without a reading of the pad there is no telling what this would overwrite.
        guard padRead == .ok, layers.indices.contains(n) else {
            message = padRead == .pending ? "Still reading the pad. Try again in a moment." : "Couldn’t read the pad’s layers. Click Reload and try again."
            return
        }
        var keep = false
        let gen = padGen
        if layers[n].inUse > 0 {
            let count = layers[n].inUse
            let alert = NSAlert()
            alert.messageText = "Set up PadPal on layer \(n + 1)?"
            alert.informativeText = "This replaces the \(count) key\(count == 1 ? "" : "s") on layer \(n + 1). PadPal saves a backup of the whole pad first, so you can restore it."
            alert.addButton(withTitle: "Set Up Layer \(n + 1)")
            alert.addButton(withTitle: "Cancel")
            let carries = snapshot.flatMap { PadTranslate.layout(from: $0, layer: n) }.map { !$0.profile.bindings.isEmpty } ?? false
            if carries {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "Keep layer \(n + 1)’s keys as a layout"
                alert.suppressionButton?.state = .on
            }
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            keep = carries && alert.suppressionButton?.state == .on
            // The question was about the pad as it was read; if it was unplugged meanwhile, ask again.
            guard gen == padGen else { message = "The pad was reconnected. Choose the layer again."; return }
        }
        let old = installed && config.layer != n ? config.layer : nil
        io.async { [pad] in
            let result = PadSetup.install(pad, layer: n)
            let after = pad.backup()
            DispatchQueue.main.async {
                guard gen == self.padGen else { self.message = "The pad was unplugged during setup. Check the Pad layer menu."; return }
                guard result.ok else { self.message = result.text; self.take(after); return }
                self.config.layer = n
                self.config.save()
                self.setOffLayer(false)
                self.take(after, installedIfUnread: true)
                var text = result.text
                if let old { text += " Layer \(old + 1) still has PadPal’s keys." }
                if keep, let before = result.before, let note = self.addLayout(from: before, layer: n) { text += " " + note }
                self.message = text
            }
        }
    }

    // MARK: Bringing a pad layer in as a layout

    /// How many of a layer's keys PadPal could bring in as actions.
    func importable(_ n: Int) -> Int {
        snapshot.flatMap { PadTranslate.layout(from: $0, layer: n) }?.profile.bindings.count ?? 0
    }

    /// Reads the pad and adds what one of its own layers does as a new layout.
    func importPadLayer(_ n: Int) {
        let gen = padGen
        io.async { [pad] in
            let snap = pad.backup()
            DispatchQueue.main.async {
                guard gen == self.padGen, let snap else { self.message = "Couldn’t read the pad."; return }
                self.take(snap)
                self.message = self.addLayout(from: snap, layer: n) ?? "Layer \(n + 1) has nothing PadPal can carry over."
            }
        }
    }

    /// Adds a layout for each layer of a saved pad backup that holds keys of its own.
    func importFromBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = Config.backups
        panel.message = "Choose a pad backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let backup = try? JSONDecoder().decode(PadBackup.self, from: data) else {
            message = "\(url.lastPathComponent) isn’t a pad backup."
            return
        }
        // A backup file can come from anyone, and its macros would run on a key press: show them first.
        let found = backup.layers.indices.filter { !backup.layers[$0].isPadPal }
            .compactMap { PadTranslate.layout(from: backup, layer: $0)?.profile }
        let risks = found.flatMap(\.riskLines)
        var strip = false
        if !risks.isEmpty {
            switch Self.confirmRisky(risks, file: url.lastPathComponent) {
            case .alertFirstButtonReturn: strip = true
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        let notes = backup.layers.indices.filter { !backup.layers[$0].isPadPal }
            .compactMap { addLayout(from: backup, layer: $0, withoutRisks: strip) }
        message = notes.isEmpty ? "\(url.lastPathComponent) has nothing PadPal can carry over."
            : notes.joined(separator: " ") + (strip ? " Left out \(risks.count) macro\(risks.count == 1 ? "" : "s")." : "")
    }

    /// Adds the layout for one layer of a backup. Returns a line saying what happened, or nil if the layer had nothing usable.
    private func addLayout(from backup: PadBackup, layer: Int, withoutRisks: Bool = false) -> String? {
        guard let made = PadTranslate.layout(from: backup, layer: layer) else { return nil }
        var p = withoutRisks ? made.profile.withoutRisks : made.profile
        guard !p.bindings.isEmpty else { return nil }
        let skipped = made.skipped
        let base = p.name
        var n = 2
        while config.profiles.contains(where: { $0.name == p.name }) { p.name = "\(base)-\(n)"; n += 1 }
        config.profiles.append(p)
        editorProfile = p.name
        configEdited()
        let count = p.bindings.count
        return "Added \(p.name) with \(count) key\(count == 1 ? "" : "s")."
            + (skipped > 0 ? " \(skipped) couldn’t be carried over (layer, lighting or special keys)." : "")
    }
}

/// What an exported layout file holds.
struct LayoutFile: Codable {
    var padpalLayouts: Int      // file format version
    var profiles: [Profile]
}

/// The pad's own lighting, kept on disk while the app is showing its colors, so an unclean exit can't lose it.
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
    static func saveBackup(_ pad: PadLink, to url: URL? = nil) -> URL? { save(pad, to: url)?.url }

    private static func save(_ pad: PadLink, to url: URL? = nil) -> (url: URL, backup: PadBackup)? {
        guard let b = pad.backup() else { return nil }
        try? FileManager.default.createDirectory(at: Config.backups, withIntermediateDirectories: true)
        let stamp = b.date.replacingOccurrences(of: ":", with: "-")
        let dest = url ?? Config.backups.appendingPathComponent("pad-\(stamp).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(b), (try? data.write(to: dest)) != nil else { return nil }
        return (dest, b)
    }

    /// Backs the pad up, then writes PadPal's codes to a layer (0-based). `before` is the pad as it was.
    static func install(_ pad: PadLink, layer: Int) -> (text: String, ok: Bool, before: PadBackup?) {
        guard let saved = save(pad) else { return ("Couldn't back up the pad, so nothing was written.", false, nil) }
        guard pad.install(layer: layer) != nil else { return ("Writing to the pad failed. Backup: \(saved.url.path)", false, saved.backup) }
        return ("Layer \(layer + 1) ready. Backup saved: \(saved.url.lastPathComponent).", true, saved.backup)
    }

    static func restore(_ pad: PadLink, from url: URL) -> String {
        guard let data = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(PadBackup.self, from: data) else {
            return "Couldn't read backup \(url.path)"
        }
        guard let n = pad.restore(b) else { return "Restore failed part-way; run it again." }
        return "Restored \(n) slots from \(url.lastPathComponent)"
    }
}
