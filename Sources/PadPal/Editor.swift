import SwiftUI
import AppKit

enum ActionKind: String, CaseIterable, Identifiable {
    case inherit, keys, media, open, shell, text, scroll, profile, macro
    var id: String { rawValue }

    func title(isDefault: Bool) -> String {
        switch self {
        case .inherit: return isDefault ? "Nothing" : "Same as Default"
        case .keys: return "Keyboard shortcut"
        case .media: return "Media key"
        case .open: return "Open app, file or link"
        case .shell: return "Run shell command"
        case .text: return "Type text"
        case .scroll: return "Scroll"
        case .profile: return "Switch layout"
        case .macro: return "Macro (several steps)"
        }
    }
}

enum StepKind: String, CaseIterable, Identifiable {
    case keys, text, wait, media, open, shell, scroll
    var id: String { rawValue }

    var title: String {
        switch self {
        case .keys: return "Shortcut"
        case .text: return "Type text"
        case .wait: return "Wait"
        case .media: return "Media key"
        case .open: return "Open"
        case .shell: return "Shell command"
        case .scroll: return "Scroll"
        }
    }

    var icon: String {
        switch self {
        case .keys: return "command"
        case .text: return "character.cursor.ibeam"
        case .wait: return "clock"
        case .media: return "playpause"
        case .open: return "arrow.up.forward.app"
        case .shell: return "terminal"
        case .scroll: return "arrow.up.arrow.down"
        }
    }

    var blank: Step {
        switch self {
        case .keys: return Step(keys: "")
        case .text: return Step(text: "")
        case .wait: return Step(wait: 200)
        case .media: return Step(media: "playpause")
        case .open: return Step(open: "")
        case .shell: return Step(shell: "")
        case .scroll: return Step(scroll: 3)
        }
    }
}

extension Step {
    var kind: StepKind {
        if text != nil { return .text }
        if wait != nil { return .wait }
        if media != nil { return .media }
        if open != nil { return .open }
        if shell != nil { return .shell }
        if scroll != nil { return .scroll }
        return .keys
    }
}

extension PadBinding {
    var kind: ActionKind {
        if steps != nil { return .macro }
        if keys != nil { return .keys }
        if media != nil { return .media }
        if open != nil { return .open }
        if shell != nil { return .shell }
        if text != nil { return .text }
        if scroll != nil { return .scroll }
        if profile != nil { return .profile }
        return .inherit
    }

    static func blank(_ kind: ActionKind, label: String) -> PadBinding? {
        switch kind {
        case .inherit: return nil
        case .keys: return PadBinding(label: label, keys: "")
        case .media: return PadBinding(label: label, media: "playpause")
        case .open: return PadBinding(label: label, open: "")
        case .shell: return PadBinding(label: label, shell: "")
        case .text: return PadBinding(label: label, text: "")
        case .scroll: return PadBinding(label: label, scroll: 3)
        case .profile: return PadBinding(label: label, profile: "next")
        case .macro: return PadBinding(label: label, steps: [])
        }
    }
}

private let slotNames: [String: String] = [
    "roller.click": "Roller click", "roller.ccw": "Roller turn left", "roller.cw": "Roller turn right",
    "knob.click": "Knob click", "knob.ccw": "Knob turn left", "knob.cw": "Knob turn right",
    "top1": "Top row, key 1", "top2": "Top row, key 2",
    "a1": "Second row, key 1", "a2": "Second row, key 2", "a3": "Second row, key 3", "a4": "Second row, key 4",
    "b1": "Third row, key 1", "b2": "Third row, key 2", "b3": "Third row, key 3", "b4": "Third row, key 4",
    "corner.left": "Bottom-left corner", "bot1": "Bottom row, key 1", "bot2": "Bottom row, key 2",
]

struct EditorView: View {
    @ObservedObject var state: AppState
    private var recording: Bool { state.recording }

    private var idx: Int { state.config.profiles.firstIndex { $0.name == state.editorProfile } ?? 0 }
    private var profile: Profile { state.config.profiles[idx] }
    private var isDefault: Bool { idx == 0 }
    private var input: String { state.editorInput }

    private var tint: Color {
        guard let h = profile.hue else { return .accentColor }
        return Color(hue: Double(h) / 255, saturation: Double(profile.sat ?? 255) / 255 * 0.8, brightness: 0.95)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 180)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    profileHeader
                    padGrid
                    Divider()
                    inspector
                }
                .padding(20)
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .onDisappear { stopRecording() }
        .sheet(isPresented: SwiftUI.Binding(get: { state.macroSheet }, set: { state.macroSheet = $0 })) {
            MacroSheet(state: state)
        }
    }

    // MARK: Layout list

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Layouts").font(.headline).padding(12)
            ForEach(state.config.profiles, id: \.name) { p in
                HStack {
                    Circle()
                        .fill(p.hue.map { Color(hue: Double($0) / 255, saturation: 0.8, brightness: 0.95) } ?? Color.gray.opacity(0.4))
                        .frame(width: 10, height: 10)
                    Text(p.name)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(p.name == profile.name ? Color.accentColor.opacity(0.2) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { stopRecording(); state.editorProfile = p.name }
            }
            Spacer()
            if let m = state.message {
                Text(m).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button { addProfile() } label: { Image(systemName: "plus") }
                Button { deleteProfile() } label: { Image(systemName: "minus") }.disabled(isDefault)
                Spacer()
                Menu("More") {
                    Button("Import layouts…") { state.importLayouts() }
                    Button("Export “\(profile.name)”…") { state.exportLayouts([profile], suggestedName: profile.name) }
                    Button("Export all layouts…") { state.exportLayouts(state.config.profiles, suggestedName: "PadPal layouts") }
                    Divider()
                    Button("Open config file") { state.openConfig() }
                }
                .controlSize(.small).frame(width: 78)
            }
            .padding(10)
        }
    }

    private func addProfile() {
        var n = 1
        while state.config.profiles.contains(where: { $0.name == "Layout \(n)" }) { n += 1 }
        state.config.profiles.append(Profile(name: "Layout \(n)", apps: [], hue: 170, sat: 230, bindings: [:]))
        state.editorProfile = "Layout \(n)"
        state.configEdited()
    }

    private func deleteProfile() {
        guard !isDefault else { return }
        state.config.profiles.remove(at: idx)
        state.editorProfile = state.config.profiles[0].name
        state.configEdited()
    }

    // MARK: Layout details

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if isDefault {
                    Text(profile.name).font(.title2.bold())
                    Text("Used when no other layout matches the front app.").foregroundStyle(.secondary)
                } else {
                    TextField("Name", text: SwiftUI.Binding(
                        get: { profile.name },
                        set: { new in
                            guard !new.isEmpty, !state.config.profiles.contains(where: { $0.name == new }) else { return }
                            if state.pinned == profile.name { state.pinned = new }
                            state.config.profiles[idx].name = new
                            state.editorProfile = new
                            state.configEdited()
                        }))
                        .textFieldStyle(.roundedBorder).font(.title3).frame(width: 220)
                }
                Spacer()
                Toggle("Color", isOn: SwiftUI.Binding(
                    get: { profile.hue != nil },
                    set: { on in
                        state.config.profiles[idx].hue = on ? 170 : nil
                        state.config.profiles[idx].sat = on ? 230 : nil
                        state.configEdited()
                    }))
                if profile.hue != nil {
                    ColorPicker("", selection: SwiftUI.Binding(
                        get: { Color(hue: Double(profile.hue ?? 0) / 255, saturation: Double(profile.sat ?? 255) / 255, brightness: 1) },
                        set: { c in
                            guard let ns = NSColor(c).usingColorSpace(.deviceRGB) else { return }
                            state.config.profiles[idx].hue = UInt8(max(0, min(255, (ns.hueComponent * 255).rounded())))
                            state.config.profiles[idx].sat = UInt8(max(0, min(255, (ns.saturationComponent * 255).rounded())))
                            state.configEdited()
                        }), supportsOpacity: false)
                        .labelsHidden()
                }
            }
            if !isDefault { appsRow }
        }
    }

    private var appsRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Active in").foregroundStyle(.secondary)
            ForEach(profile.apps ?? [], id: \.self) { id in
                HStack(spacing: 4) {
                    Text(appName(id))
                    Button { removeApp(id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.gray.opacity(0.18)))
            }
            Menu("Add app") {
                ForEach(runningApps(), id: \.id) { app in
                    Button(app.name) { addApp(app.id) }
                }
                Divider()
                Button("Choose…") { chooseApp() }
            }
            .frame(width: 100)
            Spacer()
        }
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func runningApps() -> [(id: String, name: String)] {
        let taken = Set(state.config.profiles.flatMap { $0.apps ?? [] })
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, !taken.contains(id), id != Bundle.main.bundleIdentifier else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addApp(_ id: String) {
        for i in state.config.profiles.indices { state.config.profiles[i].apps?.removeAll { $0 == id } }
        state.config.profiles[idx].apps = (state.config.profiles[idx].apps ?? []) + [id]
        state.configEdited()
    }

    private func removeApp(_ id: String) {
        state.config.profiles[idx].apps?.removeAll { $0 == id }
        state.configEdited()
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        addApp(id)
    }

    // MARK: Pad

    private var padGrid: some View {
        let rows: [[String?]] = [
            ["roller.click", "top1", "top2", "knob.click"],
            ["a1", "a2", "a3", "a4"],
            ["b1", "b2", "b3", "b4"],
            ["corner.left", "bot1", "bot2", nil],
        ]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Click a slot, or press it on the pad, to edit it.").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    ForEach(0..<rows.count, id: \.self) { r in
                        HStack(spacing: 8) {
                            ForEach(0..<4, id: \.self) { c in slot(rows[r][c], round: (r == 0 && (c == 0 || c == 3))) }
                        }
                    }
                }
                .frame(width: 380)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Roller turn").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) { slot("roller.ccw", round: false, prefix: "Left: "); slot("roller.cw", round: false, prefix: "Right: ") }
                    Text("Knob turn").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    HStack(spacing: 8) { slot("knob.ccw", round: false, prefix: "Left: "); slot("knob.cw", round: false, prefix: "Right: ") }
                }
                .frame(width: 220)
            }
        }
    }

    private func slot(_ name: String?, round: Bool, prefix: String = "") -> some View {
        let own = name.flatMap { profile.bindings[$0] }
        let inherited = name.flatMap { own == nil ? state.config.profiles[0].bindings[$0] : nil }
        let label = own?.label ?? inherited?.label
        let selected = name != nil && name == input
        let shape = RoundedRectangle(cornerRadius: round ? 30 : 10)
        return Text(name == nil ? "Pad layer key" : prefix + (label ?? "—"))
            .font(.system(size: 11, weight: own != nil ? .semibold : .regular))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(4)
            .frame(maxWidth: .infinity, minHeight: 60)
            .foregroundStyle(name == nil || own == nil ? .secondary : .primary)
            .background(shape.fill(tint.opacity(own != nil ? 0.28 : 0.07)))
            .overlay(shape.strokeBorder(selected ? Color.accentColor : tint.opacity(0.35), lineWidth: selected ? 2.5 : 1))
            .contentShape(Rectangle())
            .onTapGesture { if let name { stopRecording(); state.editorInput = name } }
    }

    // MARK: Slot inspector

    private var current: PadBinding? { profile.bindings[input] }

    private func set(_ b: PadBinding?) {
        state.config.profiles[idx].bindings[input] = b
        state.configEdited()
    }

    private func edit(_ change: (inout PadBinding) -> Void) {
        guard var b = current else { return }
        change(&b)
        set(b)
    }

    /// Opens the step sheet. `original` is what Cancel puts back.
    private func openSteps(original: PadBinding?) {
        stopRecording()
        state.macroOriginal = original
        state.macroSelection = nil
        state.macroSheet = true
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(slotNames[input] ?? input).font(.headline)
            HStack {
                Text("Action").frame(width: 70, alignment: .leading)
                Picker("", selection: SwiftUI.Binding(
                    get: { current?.kind ?? .inherit },
                    set: { kind in
                        stopRecording()
                        let before = current
                        set(PadBinding.blank(kind, label: current?.label ?? ""))
                        if kind == .macro { openSteps(original: before) }
                    }
                )) {
                    ForEach(ActionKind.allCases) { Text($0.title(isDefault: isDefault)).tag($0) }
                }
                .labelsHidden().frame(width: 240)
            }
            if let b = current {
                HStack {
                    Text("Label").frame(width: 70, alignment: .leading)
                    TextField("Shown on the key", text: SwiftUI.Binding(get: { b.label }, set: { v in edit { $0.label = v } }))
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                }
                if b.kind == .macro {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Steps").frame(width: 70, alignment: .leading)
                        Text(macroSummary(b.steps ?? []))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        Button("Edit Steps…") { openSteps(original: b) }
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(valueTitle(b.kind)).frame(width: 70, alignment: .leading)
                        valueEditor(b)
                    }
                }
            } else if !isDefault, let d = state.config.profiles[0].bindings[input] {
                Text("Uses the Default layout's action: \(d.label).").foregroundStyle(.secondary)
            } else {
                Text("This slot does nothing.").foregroundStyle(.secondary)
            }
        }
    }

    private func valueTitle(_ kind: ActionKind) -> String {
        switch kind {
        case .keys: return "Shortcut"
        case .media: return "Key"
        case .open: return "Target"
        case .shell: return "Command"
        case .text: return "Text"
        case .scroll: return "Lines"
        case .profile: return "Layout"
        case .macro: return "Steps"
        case .inherit: return ""
        }
    }

    @ViewBuilder
    private func valueEditor(_ b: PadBinding) -> some View {
        switch b.kind {
        case .keys:
            TextField("cmd+shift+n", text: SwiftUI.Binding(get: { b.keys ?? "" }, set: { v in edit { $0.keys = v } }))
                .textFieldStyle(.roundedBorder).frame(width: 160)
            let mine = recording && state.recordingStep == nil
            Button(mine ? "Press keys…" : "Record") { mine ? stopRecording() : startRecording() }
            if !(b.keys ?? "").isEmpty && Actions.parse(b.keys ?? "") == nil {
                Text("Not a shortcut PadPal can send.").font(.caption).foregroundStyle(.orange)
            }
        case .media:
            Picker("", selection: SwiftUI.Binding(get: { b.media ?? "playpause" }, set: { v in edit { $0.media = v } })) {
                Text("Play / pause").tag("playpause")
                Text("Next track").tag("next")
                Text("Previous track").tag("prev")
                Text("Volume up").tag("volup")
                Text("Volume down").tag("voldown")
                Text("Mute").tag("mute")
            }
            .labelsHidden().frame(width: 240)
        case .open:
            TextField("App name, path or https://…", text: SwiftUI.Binding(get: { b.open ?? "" }, set: { v in edit { $0.open = v } }))
                .textFieldStyle(.roundedBorder).frame(width: 320)
            Button("Choose app…") {
                let panel = NSOpenPanel()
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                panel.allowedContentTypes = [.application]
                if panel.runModal() == .OK, let url = panel.url { edit { $0.open = url.path } }
            }
        case .shell:
            TextField("Runs in zsh", text: SwiftUI.Binding(get: { b.shell ?? "" }, set: { v in edit { $0.shell = v } }))
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).frame(width: 440)
        case .text:
            TextField("Text to type", text: SwiftUI.Binding(get: { b.text ?? "" }, set: { v in edit { $0.text = v } }))
                .textFieldStyle(.roundedBorder).frame(width: 440)
        case .scroll:
            Stepper(value: SwiftUI.Binding(get: { b.scroll ?? 3 }, set: { v in edit { $0.scroll = v } }), in: -20...20) {
                let n = b.scroll ?? 3
                Text(n >= 0 ? "\(n) up" : "\(-n) down")
            }
            .frame(width: 140, alignment: .leading)
        case .profile:
            Picker("", selection: SwiftUI.Binding(get: { b.profile ?? "next" }, set: { v in edit { $0.profile = v } })) {
                Text("Next layout").tag("next")
                Text("Follow front app").tag("auto")
                ForEach(state.config.profiles, id: \.name) { Text($0.name).tag($0.name) }
            }
            .labelsHidden().frame(width: 240)
        case .inherit, .macro:
            EmptyView()
        }
    }

    // MARK: Shortcut recording

    private func startRecording() {
        stopRecording()
        state.recording = true
        state.recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let text = Actions.shortcutText(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                edit { b in
                    b.keys = text
                    if b.label.isEmpty { b.label = text }
                }
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        state.recording = false
        state.recordingStep = nil
        if let m = state.recordMonitor { NSEvent.removeMonitor(m) }
        state.recordMonitor = nil
    }
}

// MARK: - Macro steps

private let mediaTitles: [(String, String)] = [
    ("playpause", "Play / pause"), ("next", "Next track"), ("prev", "Previous track"),
    ("volup", "Volume up"), ("voldown", "Volume down"), ("mute", "Mute"),
]

/// "cmd+shift+k" as the glyphs a Mac menu would show: ⌘⇧K.
func prettyShortcut(_ shortcut: String) -> String {
    let glyphs = ["cmd": "⌘", "command": "⌘", "shift": "⇧", "alt": "⌥", "opt": "⌥", "option": "⌥", "ctrl": "⌃", "control": "⌃",
                  "return": "↩", "enter": "↩", "escape": "⎋", "esc": "⎋", "tab": "⇥", "space": "Space", "delete": "⌫",
                  "backspace": "⌫", "left": "←", "right": "→", "up": "↑", "down": "↓"]
    return shortcut.lowercased().split(separator: "+").map { glyphs[String($0)] ?? $0.uppercased() }.joined()
}

func waitText(_ ms: Int) -> String {
    ms >= 1000 ? String(format: "%g s", Double(ms) / 1000) : "\(ms) ms"
}

/// One line describing a macro, e.g. ⌘K › “deploy” › 200 ms › ↩
func macroSummary(_ steps: [Step]) -> String {
    if steps.isEmpty { return "No steps yet" }
    return steps.map { s -> String in
        switch s.kind {
        case .keys: return (s.keys ?? "").isEmpty ? "?" : prettyShortcut(s.keys ?? "")
        case .text: return "“\(s.text ?? "")”"
        case .wait: return waitText(s.wait ?? 0)
        case .media: return mediaTitles.first { $0.0 == s.media }?.1 ?? "Media"
        case .open: return "Open \(((s.open ?? "") as NSString).lastPathComponent)"
        case .shell: return "Shell"
        case .scroll: return (s.scroll ?? 0) >= 0 ? "Scroll ↑\(s.scroll ?? 0)" : "Scroll ↓\(-(s.scroll ?? 0))"
        }
    }.joined(separator: " › ")
}

/// The sheet where a macro's steps are listed, reordered, recorded and tested.
struct MacroSheet: View {
    @ObservedObject var state: AppState

    private var idx: Int { state.config.profiles.firstIndex { $0.name == state.editorProfile } ?? 0 }
    private var input: String { state.editorInput }
    private var binding: PadBinding? { state.config.profiles[idx].bindings[input] }
    private var steps: [Step] { binding?.steps ?? [] }
    private var recordingAll: Bool { state.recording && state.recordingStep == -1 }

    private func setSteps(_ change: (inout [Step]) -> Void) {
        guard var b = binding else { return }
        var s = b.steps ?? []
        change(&s)
        b.steps = s
        state.config.profiles[idx].bindings[input] = b
        state.configEdited()
    }

    private func editStep(_ i: Int, _ change: (inout Step) -> Void) {
        setSteps { if $0.indices.contains(i) { change(&$0[i]) } }
    }

    /// Rows are identified by position, so a field being edited must let go before rows move.
    private func settle() {
        stopRecording()
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func remove(_ i: Int) {
        settle()
        setSteps { if $0.indices.contains(i) { $0.remove(at: i) } }
        state.macroSelection = nil
    }

    private func move(_ i: Int, by d: Int) {
        settle()
        setSteps { if $0.indices.contains(i) && $0.indices.contains(i + d) { $0.swapAt(i, i + d) } }
        state.macroSelection = i + d
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((binding?.label ?? "").isEmpty ? "Macro steps" : "Steps for “\(binding?.label ?? "")”").font(.headline)
                Spacer()
                Text("Runs top to bottom, 40 ms between steps").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if steps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "list.bullet.indent").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No steps yet").font(.headline)
                    Text("Record keys or add a step.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: SwiftUI.Binding<Int?>(get: { state.macroSelection }, set: { state.macroSelection = $0 })) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        row(i, step).tag(i)
                    }
                    .onMove { from, to in
                        settle()
                        setSteps { $0.move(fromOffsets: from, toOffset: to) }
                        state.macroSelection = nil
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onDeleteCommand { if let i = state.macroSelection { remove(i) } }
            }
            Divider()
            footer
        }
        .frame(minWidth: 580, idealWidth: 600, minHeight: 380, idealHeight: 420)
        .onDisappear { stopRecording() }
    }

    private func row(_ i: Int, _ step: Step) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Drag to reorder")
            Menu {
                ForEach(StepKind.allCases) { kind in
                    Button { settle(); editStep(i) { $0 = kind.blank } } label: { Label(kind.title, systemImage: kind.icon) }
                }
            } label: {
                Label(step.kind.title, systemImage: step.kind.icon)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 140, alignment: .leading)
            stepValue(i, step)
        }
        .controlSize(.small)
        .padding(.vertical, 2)
        .foregroundStyle(step.kind == .wait ? .secondary : .primary)
        .contextMenu {
            Button("Move Up") { move(i, by: -1) }.disabled(i == 0)
            Button("Move Down") { move(i, by: 1) }.disabled(i == steps.count - 1)
            Button("Duplicate") { settle(); setSteps { $0.insert(step, at: i + 1) } }
            Divider()
            Button("Delete") { remove(i) }
        }
    }

    @ViewBuilder
    private func stepValue(_ i: Int, _ step: Step) -> some View {
        switch step.kind {
        case .keys:
            TextField("cmd+shift+n", text: SwiftUI.Binding(get: { step.keys ?? "" }, set: { v in editStep(i) { $0.keys = v } }))
                .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
            if !(step.keys ?? "").isEmpty {
                if Actions.parse(step.keys ?? "") == nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Not a shortcut PadPal can send.")
                } else {
                    Text(prettyShortcut(step.keys ?? "")).foregroundStyle(.secondary).lineLimit(1).frame(width: 56, alignment: .leading)
                }
            }
            let mine = state.recording && state.recordingStep == i
            Button { mine ? stopRecording() : startRecording(step: i) } label: {
                Image(systemName: mine ? "stop.circle.fill" : "record.circle").foregroundStyle(mine ? Color.red : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(mine ? "Stop" : "Record this shortcut")
        case .text:
            TextField("Text to type", text: SwiftUI.Binding(get: { step.text ?? "" }, set: { v in editStep(i) { $0.text = v } }))
                .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
        case .wait:
            Stepper(value: SwiftUI.Binding(get: { step.wait ?? 200 }, set: { v in editStep(i) { $0.wait = v } }), in: 0...10_000, step: 50) {
                Text(waitText(step.wait ?? 200)).monospacedDigit()
            }
            Spacer()
        case .media:
            Picker("", selection: SwiftUI.Binding(get: { step.media ?? "playpause" }, set: { v in editStep(i) { $0.media = v } })) {
                ForEach(mediaTitles, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden().frame(width: 170)
            Spacer()
        case .open:
            TextField("App name, path or https://…", text: SwiftUI.Binding(get: { step.open ?? "" }, set: { v in editStep(i) { $0.open = v } }))
                .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
        case .shell:
            TextField("Runs in zsh", text: SwiftUI.Binding(get: { step.shell ?? "" }, set: { v in editStep(i) { $0.shell = v } }))
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity)
        case .scroll:
            Stepper(value: SwiftUI.Binding(get: { step.scroll ?? 3 }, set: { v in editStep(i) { $0.scroll = v } }), in: -20...20) {
                let n = step.scroll ?? 3
                Text(n >= 0 ? "\(n) up" : "\(-n) down")
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(StepKind.allCases) { kind in
                    Button { settle(); setSteps { $0.append(kind.blank) } } label: { Label(kind.title, systemImage: kind.icon) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .frame(width: 48)
            .help("Add a step")
            Button { if let i = state.macroSelection { remove(i) } } label: { Image(systemName: "minus") }
                .disabled(state.macroSelection == nil)
                .help("Remove the selected step")
            Button(recordingAll ? "Stop Recording" : "Record Keys") { recordingAll ? stopRecording() : startRecording(step: nil) }
                .tint(recordingAll ? .red : nil)
            if recordingAll {
                Text("Each shortcut you press becomes a step.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(state.testCountdown.map { "Runs in \($0)…" } ?? "Test") { settle(); state.testMacro(steps) }
                .disabled(steps.isEmpty || state.testCountdown != nil)
                .help("Runs the macro after 3 seconds, so you can switch to the app it is for")
            Button("Cancel") {
                settle()
                state.config.profiles[idx].bindings[input] = state.macroOriginal
                state.configEdited()
                state.macroSheet = false
            }
            .keyboardShortcut(.cancelAction)
            .help("Close without keeping the changes made here")
            Button("Done") { settle(); state.macroSheet = false }
        }
        .padding(12)
    }

    // MARK: Recording

    /// Records into one step, or with `step` nil appends a step for every shortcut pressed until stopped.
    private func startRecording(step: Int?) {
        settle()
        state.recording = true
        state.recordingStep = step ?? -1
        state.recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let text = Actions.shortcutText(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return nil }
            if let step {
                editStep(step) { $0 = Step(keys: text) }
                stopRecording()
            } else {
                setSteps { $0.append(Step(keys: text)) }
            }
            return nil
        }
    }

    private func stopRecording() {
        state.recording = false
        state.recordingStep = nil
        if let m = state.recordMonitor { NSEvent.removeMonitor(m) }
        state.recordMonitor = nil
    }
}
