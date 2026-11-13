import Testing
@testable import PadPal

/// Turning the pad's own key codes into PadPal actions.
@Suite struct TranslateTests {
    private func action(_ code: UInt16, proto: Int = 11, macros: [[UInt8]] = []) -> PadTranslate.Result {
        PadTranslate.binding(code, proto: proto, macros: macros)
    }

    @Test func emptyAndTransparentKeysAreEmpty() {
        #expect(action(0x0000) == .empty)
        #expect(action(0x0001) == .empty)
    }

    @Test func plainKeysAndModifiers() {
        #expect(action(0x081D) == .action(Binding(label: "⌘Z", keys: "cmd+z")))
        #expect(action(0x0A1D) == .action(Binding(label: "⌘⇧Z", keys: "cmd+shift+z")))
        #expect(action(0x0450) == .action(Binding(label: "⌥←", keys: "alt+left")))
        #expect(action(0x0C51) == .action(Binding(label: "⌘⌥↓", keys: "cmd+alt+down")))
        #expect(action(0x0028) == .action(Binding(label: "Return", keys: "return")))
    }

    @Test func mediaKeys() {
        #expect(action(0x00A8) == .action(Binding(label: "Mute", media: "mute")))
        #expect(action(0x00A9) == .action(Binding(label: "Volume up", media: "volup")))
        #expect(action(0x00AE) == .action(Binding(label: "Play / pause", media: "playpause")))
    }

    @Test func keysWithNoEquivalentAreLeftOut() {
        #expect(action(0x7820) == .skipped)     // lighting toggle
        #expect(action(0x5201) == .skipped)     // go to layer 1
        #expect(action(0x7F00) == .skipped)     // vendor key
        #expect(action(0x00E3) == .skipped)     // a modifier by itself
    }

    @Test func macroKeyBaseDependsOnProtocol() {
        #expect(PadTranslate.macroIndex(0x7702, proto: 11) == 0)
        #expect(PadTranslate.macroIndex(0x770B, proto: 11) == 9)
        #expect(PadTranslate.macroIndex(0x7700, proto: 11) == nil)
        #expect(PadTranslate.macroIndex(0x7700, proto: 12) == 0)
    }

    @Test func splitsMacroMemoryOnZeroBytes() {
        #expect(PadTranslate.splitMacros([0, 0, 65, 66, 0, 67, 0]) == [[], [], [65, 66], [67]])
    }

    @Test func macroWithHeldModifierAndTap() {
        // hold Command, "a", release Command, tap forward delete
        let made = PadTranslate.steps([1, 2, 227, 97, 1, 3, 227, 1, 1, 76])
        #expect(made.steps == [Step(keys: "cmd+a"), Step(keys: "forwarddelete")])
        #expect(made.dropped == 0)
    }

    @Test func macroTextDelayAndReturn() {
        let bytes: [UInt8] = [1, 4, 0x32, 0x35, 0x30, 0x7C] + Array("ok".utf8) + [1, 1, 0x28]
        #expect(PadTranslate.steps(bytes).steps == [Step(wait: 250), Step(text: "ok"), Step(keys: "return")])
    }

    @Test func overLongDelayIsCappedInsteadOfOverflowing() {
        let bytes: [UInt8] = [1, 4] + [UInt8](repeating: 0x39, count: 40) + [0x7C]
        #expect(PadTranslate.steps(bytes).steps == [Step(wait: 10_000)])
    }

    @Test func mediaTapInsideMacroIsKept() {
        #expect(PadTranslate.steps([1, 1, 0xA8]).steps == [Step(media: "mute")])
        #expect(action(0x7702, macros: [[1, 1, 0xA8]]) == .action(Binding(label: "Mute", media: "mute")))
    }

    @Test func macroWithUnsupportedKeyIsLeftOutWhole() {
        let macro: [UInt8] = [1, 1, 0x04, 1, 1, 0x65]      // tap "a", then tap a key PadPal can't press
        #expect(PadTranslate.steps(macro).dropped == 1)
        #expect(action(0x7702, macros: [macro]) == .skipped)
    }

    @Test func emptyAndMissingMacros() {
        #expect(action(0x7702, macros: [[]]) == .empty)
        #expect(action(0x7709, macros: [[]]) == .skipped)   // the reading doesn't include macro 7
    }

    @Test func multiStepMacroBecomesMacroBinding() {
        let macro: [UInt8] = [1, 1, 0x04, 1, 1, 0x05]
        #expect(action(0x7703, macros: [[], macro]) == .action(Binding(label: "Macro 2", steps: [Step(keys: "a"), Step(keys: "b")])))
    }

    @Test func layoutFromALayer() throws {
        var keys = [UInt16](repeating: 0, count: 16)
        keys[1] = 0x00AC        // top1: previous track
        keys[8] = 0x081D        // b1: Command-Z
        keys[12] = 0x7820       // corner.left: lighting, can't come across
        keys[15] = 0x5201       // the layer key is never part of a layout
        let backup = PadBackup(date: "", protocolVersion: 11, keymap: [keys],
                               encoders: [[[0x00AA, 0x00A9], [0, 0]]], macros: [])
        let made = try #require(PadTranslate.layout(from: backup, layer: 0))
        #expect(made.profile.name == "layout-from-layer-1")
        #expect(made.skipped == 1)
        #expect(made.profile.bindings.keys.sorted() == ["b1", "roller.ccw", "roller.cw", "top1"])
        #expect(made.profile.bindings["roller.cw"]?.media == "volup")
        #expect(PadTranslate.layout(from: backup, layer: 3) == nil)
    }
}

/// What PadPal knows about the pad's layers.
@Suite struct LayerTests {
    private func layer(key15: UInt16 = 0, fill: UInt16 = 0) -> PadLayer {
        var keys = [UInt16](repeating: fill, count: 16)
        keys[15] = key15
        return PadLayer(keys: keys, turns: [fill, fill, fill, fill])
    }

    private var padPal: PadLayer {
        PadLayer(keys: Array(PadInput.codes.prefix(15)) + [0x5202], turns: Array(PadInput.codes.suffix(4)))
    }

    @Test func recognizesItsOwnLayer() {
        #expect(padPal.isPadPal)
        #expect(padPal.summary == "PadPal")
        #expect(!layer().isPadPal)
    }

    @Test func countsKeysInUseWithoutTheLayerKey() {
        #expect(layer(key15: 0x5201).inUse == 0)
        #expect(layer(key15: 0x5201).summary == "empty")
        #expect(layer(fill: 0x0001).inUse == 0)             // "same as the layer below" is not a key
        var one = layer()
        one.keys[3] = 0x00A8
        #expect(one.inUse == 1)
        #expect(one.summary == "1 key in use")
    }

    @Test func layerKeyTarget() {
        #expect(layer(key15: 0x5203).layerKeyTarget == 3)
        #expect(layer(key15: 0x0004).layerKeyTarget == nil)
    }

    @Test func pressesOfTheLayerKeyBackToPadPal() {
        // The layer key cycles 0 -> 1 -> 2 -> 3 -> 0.
        let layers = [layer(key15: 0x5201), layer(key15: 0x5202), layer(key15: 0x5203), layer(key15: 0x5200)]
        #expect(PadTranslate.presses(from: 0, to: 1, layers: layers) == 1)
        #expect(PadTranslate.presses(from: 2, to: 1, layers: layers) == 3)
        let broken = [layer(key15: 0x5201), layer(key15: 0x0004)]
        #expect(PadTranslate.presses(from: 1, to: 0, layers: broken) == nil)
    }

    @Test func whatALayerCanSend() {
        var l = layer()
        l.keys[0] = 0x081D          // Command-Z
        l.turns[0] = 0x00AA         // volume down
        let sent = PadTranslate.usages(of: l, proto: 11, macros: [])
        #expect(sent == [PadUsage(page: 7, usage: 0x1D), PadUsage(page: 7, usage: 0xE3), PadUsage(page: 0x0C, usage: 0xEA)])
    }

    @Test func everyInputHasItsOwnCode() {
        #expect(PadInput.all.count == 19)
        #expect(PadInput.codes.count == PadInput.all.count)
        #expect(Set(PadInput.codes).count == PadInput.codes.count)
    }
}
