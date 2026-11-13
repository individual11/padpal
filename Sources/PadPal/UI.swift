import SwiftUI

struct PadView: View {
    @ObservedObject var state: AppState

    private var tint: Color {
        guard let h = state.profile.hue else { return .accentColor }
        return Color(hue: Double(h) / 255, saturation: Double(state.profile.sat ?? 255) / 255 * 0.8, brightness: 0.95)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !state.connected { notFound }
            if state.connected && !state.installed && state.padRead == .ok { chooseLayer }
            if state.connected && state.padRead == .failed {
                note("Couldn't read the pad's layers.", "Try again") { state.reload() }
            }
            if state.connected && state.installed && state.offLayer { offLayer }
            if !state.inputAccess {
                note("Allow PadPal under Input Monitoring to read the pad, then reopen the app.", "Open Settings") {
                    PadListener.requestAccess()
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
                }
            }
            if !state.accessibility {
                note("Allow PadPal under Accessibility to send shortcuts.", "Open Settings") {
                    Actions.requestAccessibility()
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                }
            }
            if let e = state.configError { note(e, nil, nil) }
            Group {
                grid
                turns
            }
            .opacity(state.connected ? 1 : 0.45)
            if let m = state.message {
                Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            settings
            Divider()
            HStack {
                Button("Edit layouts") { state.openEditor() }
                Button("Reload") { state.reload() }
                if let n = state.reloadNote {
                    Label(n, systemImage: state.configError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(state.configError == nil ? Color.green : Color.orange)
                        .transition(.opacity)
                }
                Spacer()
                Button { state.showAbout() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .help("About PadPal")
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in WindowFitter(height: g.size.height) })
        .animation(.easeInOut(duration: 0.25), value: state.reloadNote)
        .animation(.easeInOut(duration: 0.25), value: state.message)
        .animation(.easeInOut(duration: 0.25), value: state.connected)
        .animation(.easeInOut(duration: 0.25), value: state.installed)
        .animation(.easeInOut(duration: 0.25), value: state.offLayer)
        .onAppear { state.refreshPermissions() }
    }

    /// Shown while no Creator Micro is plugged in.
    private var notFound: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cable.connector.slash").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No Creator Micro found").font(.callout.weight(.semibold))
                Text("Plug the pad in and PadPal picks it up by itself. You can still edit layouts in the meantime.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.1)))
    }

    /// Layer names for the menus: "Layer 1 · 12 keys in use", "Layer 2 · PadPal ✓", "Layer 3 · empty".
    private var layerItems: some View {
        ForEach(0..<max(state.layers.count, 4), id: \.self) { i in
            if i < state.layers.count {
                Text("Layer \(i + 1) · \(state.layers[i].summary)\(state.layers[i].isPadPal ? " ✓" : "")").tag(i)
            } else {
                Text("Layer \(i + 1)").tag(i)
            }
        }
    }

    /// Shown when none of the pad's layers has PadPal's keys yet.
    private var chooseLayer: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose a layer for PadPal").font(.callout.weight(.semibold))
                Text("PadPal takes over one of the pad's four layers. The other three keep working as they do now.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Picker("", selection: SwiftUI.Binding<Int>(
                    get: { state.config.layer }, set: { state.pickLayer($0) }
                )) { layerItems }
                .labelsHidden().frame(maxWidth: 220)
                Spacer()
                Button("Set up pad") { state.setUp(layer: state.config.layer) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.1)))
    }

    /// Shown after a key arrives from the pad that PadPal's layer can't send.
    private var offLayer: some View {
        let layer = state.config.layer + 1
        let how: String
        switch state.offLayerPresses {
        case 1?: how = "Press the layer key on the pad once"
        case 2?: how = "Press the layer key on the pad twice"
        case let n?: how = "Press the layer key on the pad \(n) times"
        case nil: how = "Press the layer key on the pad"
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square.stack.3d.up").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pad seems to be on another layer").font(.callout.weight(.semibold))
                Text("\(how) to come back to layer \(layer).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.1)))
    }

    private var header: some View {
        HStack {
            Circle().fill(!state.connected ? Color.gray : (state.offLayer ? Color.orange : Color.green)).frame(width: 8, height: 8)
            Text(state.profile.name).font(.headline)
            Spacer()
            Picker("", selection: SwiftUI.Binding<String>(
                get: { state.pinned ?? "auto" },
                set: { state.switchProfile($0) }
            )) {
                Text("Follow front app").tag("auto")
                ForEach(state.config.profiles, id: \.name) { Text($0.name).tag($0.name) }
            }
            .labelsHidden()
            .frame(width: 170)
        }
    }

    private var settings: some View {
        VStack(spacing: 6) {
            if state.connected && state.installed && state.padRead == .ok {
                HStack {
                    Text("Pad layer").font(.caption)
                    Spacer()
                    Picker("", selection: SwiftUI.Binding<Int>(
                        get: { state.config.layer }, set: { state.chooseLayer($0) }
                    )) { layerItems }
                    .labelsHidden().frame(width: 190).controlSize(.small)
                }
            }
            HStack {
                Text("Rim on app switch").font(.caption)
                Spacer()
                Picker("", selection: SwiftUI.Binding<String>(
                    get: { state.config.rimStyle }, set: { state.setRimStyle($0) }
                )) {
                    Text("Off").tag("off")
                    Text("Instant").tag("instant")
                    Text("Fade").tag("fade")
                    Text("Rotate").tag("rotate")
                    Text("Sweep").tag("sweep")
                }
                .labelsHidden().frame(width: 110).controlSize(.small)
            }
            HStack {
                Text("Hold for Default layout").font(.caption)
                Spacer()
                Picker("", selection: SwiftUI.Binding<String>(
                    get: { state.config.overrideKey }, set: { state.setOverrideKey($0) }
                )) {
                    Text("Command").tag("cmd")
                    Text("Option").tag("alt")
                    Text("Control").tag("ctrl")
                    Text("Shift").tag("shift")
                    Text("Nothing").tag("none")
                }
                .labelsHidden().frame(width: 110).controlSize(.small)
            }
        }
    }

    private var grid: some View {
        let rows: [[String?]] = [
            ["roller.click", "top1", "top2", "knob.click"],
            ["a1", "a2", "a3", "a4"],
            ["b1", "b2", "b3", "b4"],
            ["corner.left", "bot1", "bot2", nil],
        ]
        return VStack(spacing: 6) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { c in cell(rows[r][c]) }
                }
            }
        }
    }

    private func cell(_ input: String?) -> some View {
        let label = input.flatMap { state.config.binding($0, in: state.profile)?.label }
        let pressed = input != nil && state.flash == input
        let isEncoder = input == "roller.click" || input == "knob.click"
        return Text(input == nil ? "Pad layer" : (label ?? ""))
            .font(.system(size: 11, weight: .medium))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .padding(4)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(input == nil ? .secondary : .primary)
            .background(
                RoundedRectangle(cornerRadius: isEncoder ? 26 : 9)
                    .fill(pressed ? tint : tint.opacity(label == nil ? 0.06 : 0.22))
            )
            .overlay(RoundedRectangle(cornerRadius: isEncoder ? 26 : 9).strokeBorder(tint.opacity(0.35)))
    }

    private var turns: some View {
        VStack(alignment: .leading, spacing: 3) {
            turnLine("Roller", "roller.ccw", "roller.cw")
            turnLine("Knob", "knob.ccw", "knob.cw")
        }
        .font(.caption)
    }

    private func turnLine(_ name: String, _ ccw: String, _ cw: String) -> some View {
        let l = state.config.binding(ccw, in: state.profile)?.label ?? "nothing"
        let r = state.config.binding(cw, in: state.profile)?.label ?? "nothing"
        let on = state.flash == ccw || state.flash == cw
        return Text("\(name) turn: \(l) / \(r)").foregroundStyle(on ? tint : .secondary)
    }

    private func note(_ text: String, _ button: String?, _ action: (() -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let button, let action { Button(button, action: action).controlSize(.small) }
        }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

/// Keeps the menu-bar panel's window exactly as tall as its content. Without this the window
/// stays at its old height when a notice disappears, leaving an empty strip at the bottom.
private struct WindowFitter: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        DispatchQueue.main.async {
            guard let w = view.window, height > 0 else { return }
            let content = w.contentRect(forFrameRect: w.frame)
            guard abs(content.height - height) > 0.5 else { return }
            var frame = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: content.width, height: height))
            frame.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - frame.height)   // keep the top edge in place
            w.setFrame(frame, display: true)
        }
    }
}

/// The menu-bar mark: the pad's outline with its roller, knob and two keys. Drawn in code as a
/// template image, so macOS tints it for light and dark menu bars. Matches design/logos/menubar-glyph.svg.
let menuBarGlyph = makeGlyph(filled: true)
/// The same mark with empty keys, shown while no pad is connected.
let menuBarGlyphEmpty = makeGlyph(filled: false)

private func makeGlyph(filled: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        let k = 0.5   // the design is on a 36-unit grid
        NSColor.black.set()
        let outline = NSBezierPath(roundedRect: NSRect(x: 2.5 * k, y: 2.5 * k, width: 31 * k, height: 31 * k), xRadius: 8 * k, yRadius: 8 * k)
        outline.lineWidth = 3 * k
        outline.stroke()
        guard filled else { return true }
        NSBezierPath(roundedRect: NSRect(x: 8 * k, y: 10.5 * k, width: 9 * k, height: 5 * k), xRadius: 2.5 * k, yRadius: 2.5 * k).fill()
        NSBezierPath(ovalIn: NSRect(x: 19 * k, y: 8.5 * k, width: 9 * k, height: 9 * k)).fill()
        NSBezierPath(roundedRect: NSRect(x: 8 * k, y: 20 * k, width: 9 * k, height: 8 * k), xRadius: 2 * k, yRadius: 2 * k).fill()
        NSBezierPath(roundedRect: NSRect(x: 19 * k, y: 20 * k, width: 9 * k, height: 8 * k), xRadius: 2 * k, yRadius: 2 * k).fill()
        return true
    }
    image.isTemplate = true
    return image
}

struct PadPalApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            PadView(state: state)
        } label: {
            Image(nsImage: state.connected ? menuBarGlyph : menuBarGlyphEmpty)
        }
        .menuBarExtraStyle(.window)
    }
}
