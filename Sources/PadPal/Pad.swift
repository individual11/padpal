import Foundation
import IOKit.hid

/// The physical inputs of the Work Louder Micro Pad, in firmware matrix order,
/// followed by the four encoder directions.
enum PadInput {
    /// Names for matrix positions 0...14 (position 15, bottom-right, is left as the pad's own layer key).
    static let keys = [
        "roller.click", "top1", "top2", "knob.click",
        "a1", "a2", "a3", "a4",
        "b1", "b2", "b3", "b4",
        "corner.left", "bot1", "bot2",
    ]
    static let turns = ["roller.ccw", "roller.cw", "knob.ccw", "knob.cw"]
    static let all = keys + turns

    /// HID keyboard usages the pad sends for each input. macOS has no key mapping for
    /// these (F21-F24, International 4-9, Language 3-9, Out, Oper), so they should not
    /// type anything; only this app, reading the pad directly, sees them.
    static let codes: [UInt16] = [
        0x70, 0x71, 0x72, 0x73,
        0x8A, 0x8B, 0x8C, 0x8D,
        0x8E, 0x8F, 0x92, 0x93,
        0x94, 0x95, 0x96,
        0x97, 0x98, 0xA0, 0xA1,
    ]
    static let byCode: [Int: String] = Dictionary(uniqueKeysWithValues: zip(codes.map(Int.init), all))
}

struct Light: Codable, Equatable {
    var effect: UInt8
    var hue: UInt8
    var sat: UInt8
}

struct PadBackup: Codable {
    var date: String
    var protocolVersion: Int
    var keymap: [[UInt16]]          // [layer][16 keys]
    var encoders: [[[UInt16]]]      // [layer][encoder][ccw, cw]
    var macros: [UInt8]
    var keyLight: Light?
    var glowLight: Light?
}

/// Talks to the pad's raw HID interface using the VIA protocol.
final class PadLink: @unchecked Sendable {
    static let vendorID = 0x574C
    static let productID = 0xE6E3
    enum Channel: UInt8 { case glow = 2, keys = 3 }

    private let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let hidQueue = DispatchQueue(label: "padpal.raw")
    private let sendQueue = DispatchQueue(label: "padpal.send")
    private let lock = NSLock()
    private let sem = DispatchSemaphore(value: 0)
    private var device: IOHIDDevice?
    private var reply: [UInt8]?
    var onConnection: ((Bool) -> Void)?

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return device != nil }

    func start() {
        let match: [String: Any] = [
            kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: Self.productID,
            kIOHIDDeviceUsagePageKey: 0xFF60, kIOHIDDeviceUsageKey: 0x61,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, dev in
            let me = Unmanaged<PadLink>.fromOpaque(ctx!).takeUnretainedValue()
            me.lock.lock(); me.device = dev; me.lock.unlock()
            me.onConnection?(true)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, _ in
            let me = Unmanaged<PadLink>.fromOpaque(ctx!).takeUnretainedValue()
            me.lock.lock(); me.device = nil; me.lock.unlock()
            me.onConnection?(false)
        }, ctx)
        IOHIDManagerRegisterInputReportCallback(mgr, { ctx, _, _, _, _, report, len in
            let me = Unmanaged<PadLink>.fromOpaque(ctx!).takeUnretainedValue()
            me.lock.lock()
            me.reply = Array(UnsafeBufferPointer(start: report, count: len))
            me.lock.unlock()
            me.sem.signal()
        }, ctx)
        IOHIDManagerSetDispatchQueue(mgr, hidQueue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerActivate(mgr)
    }

    func waitConnected(_ seconds: Double = 3) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !isConnected && Date() < end { usleep(50_000) }
        return isConnected
    }

    /// Sends one 32-byte VIA command and returns the reply, or nil on failure.
    func request(_ bytes: [UInt8]) -> [UInt8]? {
        sendQueue.sync {
            lock.lock(); let dev = device; reply = nil; lock.unlock()
            guard let dev else { return nil }
            while sem.wait(timeout: .now()) == .success {}
            var out = bytes + [UInt8](repeating: 0, count: max(0, 32 - bytes.count))
            guard IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, &out, 32) == kIOReturnSuccess else { return nil }
            let end = DispatchTime.now() + 0.5
            while sem.wait(timeout: end) == .success {
                lock.lock(); let r = reply; lock.unlock()
                if let r, r.first == bytes[0] { return r }
                if let r, r.first == 0xFF { return nil }   // command not handled by firmware
            }
            return nil
        }
    }

    // MARK: Lighting (live only; nothing is saved to the pad's memory)

    func light(_ ch: Channel) -> Light? {
        guard let e = request([0x08, ch.rawValue, 2]), let c = request([0x08, ch.rawValue, 4]) else { return nil }
        return Light(effect: e[3], hue: c[3], sat: c[4])
    }

    func setLight(_ ch: Channel, _ l: Light) {
        _ = request([0x07, ch.rawValue, 2, l.effect])
        _ = request([0x07, ch.rawValue, 4, l.hue, l.sat])
    }

    func brightness(_ ch: Channel) -> UInt8? { request([0x08, ch.rawValue, 1]).map { $0[3] } }
    func setBrightness(_ ch: Channel, _ v: UInt8) { _ = request([0x07, ch.rawValue, 1, v]) }

    func setColor(_ ch: Channel, hue: UInt8, sat: UInt8) {
        _ = request([0x07, ch.rawValue, 4, hue, sat])
    }

    // MARK: Keymap

    func protocolVersion() -> Int? { request([0x01]).map { Int($0[1]) << 8 | Int($0[2]) } }
    func layerCount() -> Int? { request([0x11]).map { Int($0[1]) } }

    func key(layer: Int, index: Int) -> UInt16? {
        request([0x04, UInt8(layer), UInt8(index / 4), UInt8(index % 4)]).map { UInt16($0[4]) << 8 | UInt16($0[5]) }
    }
    func setKey(layer: Int, index: Int, _ code: UInt16) -> Bool {
        request([0x05, UInt8(layer), UInt8(index / 4), UInt8(index % 4), UInt8(code >> 8), UInt8(code & 0xFF)]) != nil
    }
    func encoder(layer: Int, encoder: Int, clockwise: Bool) -> UInt16? {
        request([0x14, UInt8(layer), UInt8(encoder), clockwise ? 1 : 0]).map { UInt16($0[4]) << 8 | UInt16($0[5]) }
    }
    func setEncoder(layer: Int, encoder: Int, clockwise: Bool, _ code: UInt16) -> Bool {
        request([0x15, UInt8(layer), UInt8(encoder), clockwise ? 1 : 0, UInt8(code >> 8), UInt8(code & 0xFF)]) != nil
    }

    func backup() -> PadBackup? {
        guard let proto = protocolVersion(), let layers = layerCount() else { return nil }
        var keymap: [[UInt16]] = [], encoders: [[[UInt16]]] = []
        for layer in 0..<layers {
            var row: [UInt16] = []
            for i in 0..<16 { guard let k = key(layer: layer, index: i) else { return nil }; row.append(k) }
            keymap.append(row)
            var encs: [[UInt16]] = []
            for e in 0..<2 {
                guard let ccw = encoder(layer: layer, encoder: e, clockwise: false),
                      let cw = encoder(layer: layer, encoder: e, clockwise: true) else { return nil }
                encs.append([ccw, cw])
            }
            encoders.append(encs)
        }
        var macros: [UInt8] = []
        if let s = request([0x0D]) {
            let size = Int(s[1]) << 8 | Int(s[2])
            var off = 0
            while off < size {
                let n = min(28, size - off)
                guard let r = request([0x0E, UInt8(off >> 8), UInt8(off & 0xFF), UInt8(n)]) else { break }
                macros += r[4..<(4 + n)]
                off += n
            }
        }
        let f = ISO8601DateFormatter()
        return PadBackup(date: f.string(from: Date()), protocolVersion: proto, keymap: keymap,
                         encoders: encoders, macros: macros, keyLight: light(.keys), glowLight: light(.glow))
    }

    /// Writes the app's codes to one layer. Returns the number of slots changed, or nil on failure.
    func install(layer: Int) -> Int? {
        var changed = 0
        for i in 0..<PadInput.keys.count {
            let want = PadInput.codes[i]
            guard let have = key(layer: layer, index: i) else { return nil }
            if have != want { guard setKey(layer: layer, index: i, want) else { return nil }; changed += 1 }
        }
        for t in 0..<4 {
            let want = PadInput.codes[PadInput.keys.count + t]
            let enc = t / 2, cw = t % 2 == 1
            guard let have = encoder(layer: layer, encoder: enc, clockwise: cw) else { return nil }
            if have != want { guard setEncoder(layer: layer, encoder: enc, clockwise: cw, want) else { return nil }; changed += 1 }
        }
        return isInstalled(layer: layer) ? changed : nil
    }

    func isInstalled(layer: Int) -> Bool {
        for i in 0..<PadInput.keys.count where key(layer: layer, index: i) != PadInput.codes[i] { return false }
        for t in 0..<4 where encoder(layer: layer, encoder: t / 2, clockwise: t % 2 == 1) != PadInput.codes[PadInput.keys.count + t] { return false }
        return true
    }

    /// Puts keys and encoders back the way a backup recorded them. Returns slots changed.
    func restore(_ b: PadBackup) -> Int? {
        var changed = 0
        for (layer, keys) in b.keymap.enumerated() {
            for (i, want) in keys.enumerated() {
                guard let have = key(layer: layer, index: i) else { return nil }
                if have != want { guard setKey(layer: layer, index: i, want) else { return nil }; changed += 1 }
            }
        }
        for (layer, encs) in b.encoders.enumerated() {
            for (e, pair) in encs.enumerated() {
                for (d, want) in pair.enumerated() {
                    guard let have = encoder(layer: layer, encoder: e, clockwise: d == 1) else { return nil }
                    if have != want { guard setEncoder(layer: layer, encoder: e, clockwise: d == 1, want) else { return nil }; changed += 1 }
                }
            }
        }
        return changed
    }
}

/// Listens to the pad's keyboard interface for the app's codes. Needs Input Monitoring.
final class PadListener: @unchecked Sendable {
    private var mgr: IOHIDManager?
    private let queue = DispatchQueue(label: "padpal.keys")
    var onInput: ((String) -> Void)?
    /// A key press from the pad that is not one of the app's codes, so it came from another layer.
    var onForeign: ((PadUsage) -> Void)?

    static var accessGranted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    static func requestAccess() { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    var isRunning: Bool { mgr != nil }
    private(set) var lastOpenResult: IOReturn = 0
    static var accessState: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "not decided"
        }
    }

    func start() -> Bool {
        guard mgr == nil else { return true }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // The pad's keyboard, and its media-key interface (only watched to notice presses from other layers).
        let match: [[String: Any]] = [(1, 6), (0x0C, 1)].map { page, usage in
            [kIOHIDVendorIDKey: PadLink.vendorID, kIOHIDProductIDKey: PadLink.productID,
             kIOHIDDeviceUsagePageKey: page, kIOHIDDeviceUsageKey: usage]
        }
        IOHIDManagerSetDeviceMatchingMultiple(m, match as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(m, { ctx, _, _, value in
            let me = Unmanaged<PadListener>.fromOpaque(ctx!).takeUnretainedValue()
            let el = IOHIDValueGetElement(value)
            let page = Int(IOHIDElementGetUsagePage(el)), usage = Int(IOHIDElementGetUsage(el))
            guard IOHIDValueGetIntegerValue(value) != 0 else { return }
            if page == 7, let name = PadInput.byCode[usage] { me.onInput?(name); return }
            // Usages below 4 are "no key" and error codes, not presses.
            if (page == 7 && (4...0xE7).contains(usage)) || (page == 0x0C && (1...0x3FF).contains(usage)) {
                me.onForeign?(PadUsage(page: page, usage: usage))
            }
        }, ctx)
        lastOpenResult = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        guard lastOpenResult == kIOReturnSuccess else { return false }
        IOHIDManagerSetDispatchQueue(m, queue)
        IOHIDManagerActivate(m)
        mgr = m
        return true
    }
}
