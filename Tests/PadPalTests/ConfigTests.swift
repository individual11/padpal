import CoreGraphics
import Foundation
import Testing
@testable import PadPal

/// Shortcut text, the config file, and the checks made on layouts from someone else.
@Suite struct ConfigTests {
    @Test func parsesShortcuts() throws {
        let (code, flags) = try #require(Actions.parse("cmd+shift+n"))
        #expect(code == 45)
        #expect(flags.contains(.maskCommand) && flags.contains(.maskShift))
        #expect(!flags.contains(.maskAlternate) && !flags.contains(.maskControl))
        #expect(Actions.parse("Command+Option+T")?.0 == 17)
        #expect(Actions.parse("return")?.0 == 36)
        #expect(Actions.parse("cmd+nosuchkey") == nil)
        #expect(Actions.parse("cmd+shift") == nil)
    }

    @Test func arrowKeysCarryTheFunctionFlag() throws {
        let (_, flags) = try #require(Actions.parse("alt+left"))
        #expect(flags.contains(.maskSecondaryFn))
    }

    @Test func starterConfigIsUsable() {
        let c = Config.starter
        #expect(c.profiles.first?.name == "Default")
        for p in c.profiles {
            for (slot, b) in p.bindings {
                #expect(PadInput.all.contains(slot), "\(p.name) uses unknown slot \(slot)")
                if let k = b.keys { #expect(Actions.parse(k) != nil, "\(p.name) \(slot): \(k)") }
            }
        }
    }

    @Test func readsAMinimalConfig() throws {
        let json = #"{"layer": 2, "profiles": [{"name": "Default", "bindings": {"b1": {"label": "Undo", "keys": "cmd+z"}}}]}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.layer == 2)
        #expect(c.rimStyle == "fade")
        #expect(c.overrideKey == "cmd")
    }

    @Test func profileForAppAndFallbackToDefault() {
        let c = Config.starter
        #expect(c.profile(forApp: "com.apple.Safari").name == "Browser")
        #expect(c.profile(forApp: "com.example.unknown").name == "Default")
        #expect(c.profile(forApp: nil).name == "Default")
        let browser = c.profile(forApp: "com.apple.Safari")
        #expect(c.binding("top1", in: browser)?.label == "New tab")
        #expect(c.binding("bot1", in: browser)?.label == "Copy")     // not in Browser, so the Default's
    }

    @Test func flagsActionsThatCanRunThings() {
        #expect(Binding(label: "x", shell: "rm -rf ~").riskText != nil)
        #expect(Binding(label: "x", open: "https://example.com").riskText != nil)
        #expect(Binding(label: "x", steps: [Step(keys: "cmd+a")]).riskText != nil)
        #expect(Binding(label: "x", keys: "cmd+c").riskText == nil)
        #expect(Binding(label: "x", media: "mute").riskText == nil)
        #expect(Binding(label: "x", text: "hello").riskText == nil)
        #expect(Binding(label: "x", steps: []).riskText == nil)
    }

    @Test func importWithoutRisksKeepsOnlySafeKeys() {
        let p = Profile(name: "Theirs", apps: nil, hue: nil, sat: nil, bindings: [
            "a1": Binding(label: "Copy", keys: "cmd+c"),
            "a2": Binding(label: "Wipe", shell: "rm -rf ~"),
            "a3": Binding(label: "Site", open: "https://example.com"),
            "a4": Binding(label: "Macro", steps: [Step(text: "hi")]),
        ])
        #expect(p.riskLines.count == 3)
        #expect(p.riskLines.contains { $0.contains("rm -rf ~") })
        #expect(p.withoutRisks.bindings.keys.sorted() == ["a1"])
    }

    @Test func readsLayoutsInAllThreeShapes() throws {
        let profile = #"{"name": "One", "bindings": {}}"#
        #expect(readLayouts(Data(profile.utf8))?.map(\.name) == ["One"])
        let file = #"{"padpalLayouts": 1, "profiles": [\#(profile)]}"#
        #expect(readLayouts(Data(file.utf8))?.map(\.name) == ["One"])
        let config = #"{"layer": 1, "profiles": [\#(profile)]}"#
        #expect(readLayouts(Data(config.utf8))?.map(\.name) == ["One"])
        #expect(readLayouts(Data("not json".utf8)) == nil)
        #expect(readLayouts(Data(#"{"something": "else"}"#.utf8)) == nil)
    }
}
