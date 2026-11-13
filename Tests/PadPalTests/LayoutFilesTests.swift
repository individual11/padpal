import Foundation
import Testing
@testable import PadPal

/// Every layout shipped in the layouts folder must import cleanly and only use keys PadPal can press.
@Suite struct LayoutFilesTests {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("layouts")

    static var files: [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.hasSuffix(".padpal.json") }.sorted { $0.path < $1.path }
    }

    @Test func thereAreLayoutsToCheck() {
        #expect(!Self.files.isEmpty)
    }

    @Test func noTwoLayoutsClaimTheSameApp() throws {
        var owner: [String: String] = [:]
        for url in Self.files {
            for p in try #require(readLayouts(try Data(contentsOf: url))) {
                for app in p.apps ?? [] {
                    #expect(owner[app] == nil, "\(app) is in both \(owner[app] ?? "") and \(url.lastPathComponent)")
                    owner[app] = url.lastPathComponent
                }
            }
        }
    }

    @Test(arguments: files.map(\.lastPathComponent))
    func layoutFileIsValid(_ name: String) throws {
        let data = try Data(contentsOf: Self.folder.appendingPathComponent(name))
        let layouts = try #require(readLayouts(data), "\(name) is not a layout file")
        #expect(layouts.count == 1)
        for p in layouts {
            #expect(!p.name.isEmpty)
            #expect(!(p.apps ?? []).isEmpty, "\(name) names no apps")
            #expect(!p.bindings.isEmpty)
            #expect(p.riskLines.isEmpty, "\(name) has shell commands, things to open or macros")
            for (slot, b) in p.bindings {
                #expect(PadInput.all.contains(slot), "\(name): unknown slot \(slot)")
                #expect(!b.label.isEmpty, "\(name): \(slot) has no label")
                let actions = [b.keys != nil, b.media != nil, b.text != nil, b.scroll != nil, b.profile != nil].filter { $0 }.count
                #expect(actions == 1, "\(name): \(slot) should have exactly one action")
                if let k = b.keys { #expect(Actions.parse(k) != nil, "\(name): \(slot) has a shortcut PadPal can't press: \(k)") }
                if let m = b.media { #expect(["playpause", "next", "prev", "volup", "voldown", "mute"].contains(m), "\(name): \(slot)") }
            }
        }
    }
}
