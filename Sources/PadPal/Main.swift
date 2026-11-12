import Foundation

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first, !cmd.hasPrefix("-") else { PadPalApp.main(); return }
        exit(runCommand(cmd, Array(args.dropFirst())))
    }

    /// Command-line tools: status, edit, inspect, backup, setup, restore, dump.
    static func runCommand(_ cmd: String, _ args: [String]) -> Int32 {
        if cmd == "status" {
            DistributedNotificationCenter.default().postNotificationName(
                statusNotification, object: args.first ?? "clear", userInfo: nil, deliverImmediately: true)
            return 0
        }
        if cmd == "edit" {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("local.padpal.edit"), object: nil, userInfo: nil, deliverImmediately: true)
            return 0
        }
        if cmd == "inspect" {
            guard let path = args.first, let data = FileManager.default.contents(atPath: path), let layouts = readLayouts(data) else {
                print("inspect needs a PadPal layout file"); return 2
            }
            let risks = layouts.flatMap(\.riskLines)
            print("\(layouts.count) layout\(layouts.count == 1 ? "" : "s"): \(layouts.map(\.name).joined(separator: ", "))")
            print(risks.isEmpty ? "No shell commands, things to open, or macros." : "\(risks.count) action\(risks.count == 1 ? "" : "s") to read before importing:\n\n" + risks.joined(separator: "\n\n"))
            return 0
        }
        guard ["backup", "setup", "restore", "dump"].contains(cmd) else {
            print("usage: PadPal [edit | inspect <file> | status working|waiting|done|clear | backup [file] | setup [layer] | restore <file> | dump]")
            return 2
        }
        let pad = PadLink()
        _ = Unmanaged.passRetained(pad)   // an active HID manager must never be released
        pad.start()
        guard pad.waitConnected() else { print("Pad not found."); return 1 }
        switch cmd {
        case "backup":
            guard let url = PadSetup.saveBackup(pad, to: args.first.map { URL(fileURLWithPath: $0) }) else { print("Backup failed."); return 1 }
            print("Saved \(url.path)")
        case "setup":
            let layer = args.first.flatMap(Int.init) ?? Config.load().0.layer
            print(PadSetup.install(pad, layer: layer))
        case "restore":
            guard let path = args.first else { print("restore needs a backup file"); return 2 }
            print(PadSetup.restore(pad, from: URL(fileURLWithPath: path)))
        default:
            guard let b = pad.backup() else { print("Read failed."); return 1 }
            for (i, layer) in b.keymap.enumerated() {
                print("layer \(i):", layer.map { String(format: "%04x", $0) }.joined(separator: " "),
                      "| encoders:", b.encoders[i].map { $0.map { String(format: "%04x", $0) }.joined(separator: "/") }.joined(separator: " "))
            }
            print("key light:", b.keyLight.map { "\($0)" } ?? "?", "| underglow:", b.glowLight.map { "\($0)" } ?? "?")
        }
        return 0
    }
}
