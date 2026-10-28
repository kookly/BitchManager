import SwiftUI
import AppKit
import CoreMIDI
import Network
import Combine
import UniformTypeIdentifiers
import Darwin
import Accessibility

func postVoiceOverAnnouncement(_ message: String) {
    if #available(macOS 14.0, *) {
        AccessibilityNotification.Announcement(message).post()
    } else if let window = NSApp.keyWindow {
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [.announcement: message])
    }
}

// ============================================================================
// 1. DATA MODELS & EXACT 69-CONTROL HARDWARE SPECIFICATION
// ============================================================================

enum ControlKind: String, Codable {
    case key      // 49 Mechanical Backlit Keys (Hardware LEDs)
    case vfader   // 8 Vertical Faders in Bottom Tier (CC 0..7)
    case hfader   // 4 Horizontal Faders in Right Tier (CC 8..11)
    case knob     // 8 Rotary Knobs in Right Tier (CC 20..27)
}

enum FeedbackMode: String, Codable, CaseIterable {
    case momentary = "MOMENTARY"
    case toggle = "TOGGLE"
    case staticLED = "STATIC"
    case customVelocity = "CUSTOM COLOR"
    case echoInbound = "ECHO VELOCITY"
    case disabled = "DISABLED"
}

enum ActionType: String, Codable, CaseIterable {
    case passthrough = "PASSTHROUGH"
    case qwerty = "QWERTY_MACRO"
    case osc = "OSC_UDP"
    case applescript = "APPLESCRIPT"
    case msc = "MSC_BROADCAST"
    case artnet = "ARTNET_DMX"
    case sacn = "SACN_E131"
}

enum LEDFXMode: String, CaseIterable, Identifiable {
    case staticFX = "STATIC (PRESET)"
    case rainbowContinuous = "RAINBOW WAVE"
    case knightRider = "CYLON SCANNER"
    case matrixRain = "DIGITAL MATRIX"
    case cyberPulse = "CYBERPUNK PULSE"
    case vuMeter = "LIVE FADER VU"
    case fireEmbers = "FIRE & EMBERS"
    case waterRipple = "CENTER RIPPLE"
    case starfield = "TWINKLE STARS"
    case audioStrobe = "STROBE FLASH"
    case heartbeat = "HEARTBEAT"
    case plasmaWave = "PLASMA FIELD"
    case spiralVortex = "SPIRAL VORTEX"
    case eqDance = "EQ DANCE"
    case colorChase = "COLOR RUNNER"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .staticFX: return "power"
        case .rainbowContinuous: return "rainbow"
        case .knightRider: return "bolt.horizontal.fill"
        case .matrixRain: return "cloud.rain.fill"
        case .cyberPulse: return "waveform.path"
        case .vuMeter: return "slider.vertical.3"
        case .fireEmbers: return "flame.fill"
        case .waterRipple: return "circle.dotted"
        case .starfield: return "sparkles"
        case .audioStrobe: return "bolt.fill"
        case .heartbeat: return "heart.fill"
        case .plasmaWave: return "wind"
        case .spiralVortex: return "circle.hexagonpath"
        case .eqDance: return "chart.bar.xaxis"
        case .colorChase: return "arrow.triangle.2.circlepath"
        }
    }
}

struct BitchBoyKeyMap {
    static let keyPositions: [(col: Int, row: Int)] = {
        var pos: [(col: Int, row: Int)] = []
        // 0..31: 8x4 Grid (Rows 0..<4, Cols 0..<8)
        for r in 0..<4 {
            for c in 0..<8 {
                pos.append((col: c, row: r))
            }
        }
        // 32..39: 1x8 Strip (Row 4, Cols 0..<8)
        for c in 0..<8 {
            pos.append((col: c, row: 4))
        }
        // 40..48: 3x3 Keypad (Rows 0..<3, Cols 8..<11)
        for r in 0..<3 {
            for c in 0..<3 {
                pos.append((col: 8 + c, row: r))
            }
        }
        return pos
    }()

    // Precomputed 49x49 key distance matrix for zero-overhead, lag-free reactive ripple & wave rendering
    static let keyDistances: [[Double]] = {
        var matrix = Array(repeating: Array(repeating: 0.0, count: 49), count: 49)
        for i in 0..<49 {
            let pi = keyPositions[i]
            for j in 0..<49 {
                let pj = keyPositions[j]
                let dx = Double(pi.col - pj.col)
                let dy = Double(pi.row - pj.row)
                matrix[i][j] = sqrt(dx * dx + dy * dy)
            }
        }
        return matrix
    }()

    // Precomputed note-to-control index lookup table (Notes 0..127) for O(1) instantaneous lookup
    static let noteToIndex: [Int] = {
        var table = Array(repeating: -1, count: 128)
        let gridNotes: [[UInt8]] = [
            [64, 65, 66, 67, 96, 97, 98, 99],
            [60, 61, 62, 63, 92, 93, 94, 95],
            [56, 57, 58, 59, 88, 89, 90, 91],
            [52, 53, 54, 55, 84, 85, 86, 87]
        ]
        var idx = 0
        for r in 0..<4 {
            for c in 0..<8 {
                table[Int(gridNotes[r][c])] = idx
                idx += 1
            }
        }
        let stripNotes: [UInt8] = [48, 49, 50, 51, 80, 81, 82, 83]
        for n in stripNotes {
            table[Int(n)] = idx
            idx += 1
        }
        let padNotes: [UInt8] = [44, 45, 46, 40, 41, 42, 36, 37, 38]
        for n in padNotes {
            table[Int(n)] = idx
            idx += 1
        }
        return table
    }()

    // Precomputed CC-to-control index lookup table (CCs 0..127) for O(1) instantaneous lookup
    static let ccToIndex: [Int] = {
        var table = Array(repeating: -1, count: 128)
        // 49..56: 8 Vertical Faders (CC 0..7)
        for i in 0..<8 {
            table[i] = 49 + i
        }
        // 57..60: 4 Horizontal Faders (CC 8..11)
        for i in 0..<4 {
            table[8 + i] = 57 + i
        }
        // 61..68: 8 Rotary Knobs (CC 20..27)
        for i in 0..<8 {
            table[20 + i] = 61 + i
        }
        return table
    }()
}

enum StudioModuleID: String, CaseIterable, Codable, Identifiable {
    case midiRouter = "MIDI ROUTER // OUT"
    case memorySlots = "MEMORY SLOTS // BANK"
    case customFXStudio = "CUSTOM FX STUDIO"
    case reactiveKeyFX = "REACTIVE KEY FX // LIVE"
    case showControl = "SHOW CONTROL // OSC STUDIO"
    case terminal = "PROTOCOL TERMINAL // MONITOR"
    case keyGrid8x4 = "8X4 KEY GRID // 32 KEYS"
    case keyStrip1x8 = "1X8 KEY STRIP // 8 KEYS"
    case keypad3x3 = "3X3 KEYPAD & MASCOT"
    case verticalFaders = "8 VERTICAL FADERS // CC 0-7"
    case horizontalFaders = "4 HORIZONTAL FADERS // CC 8-11"
    case rotaryKnobs = "2X4 ROTARY KNOBS // CC 20-27"
    case colorPickerHUD = "COLOR PICKER // LED HUD"
    case hardwareMIDIFilter = "HARDWARE MIDI & MUTE // I/O"

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        if str == "SHOW CONTROL // MSC OSC DMX" {
            self = .showControl
        } else if let val = StudioModuleID(rawValue: str) {
            self = val
        } else {
            self = .showControl
        }
    }

    var shortName: String {
        switch self {
        case .midiRouter: return "MIDI ROUTER"
        case .memorySlots: return "MEMORY SLOTS"
        case .customFXStudio: return "CUSTOM FX"
        case .reactiveKeyFX: return "REACTIVE FX"
        case .showControl: return "SHOW CTRL"
        case .terminal: return "TERMINAL"
        case .keyGrid8x4: return "KEY GRID"
        case .keyStrip1x8: return "KEY STRIP"
        case .keypad3x3: return "3X3 KEYPAD"
        case .verticalFaders: return "V-FADERS"
        case .horizontalFaders: return "H-FADERS"
        case .rotaryKnobs: return "KNOBS"
        case .colorPickerHUD: return "COLOR PICKER"
        case .hardwareMIDIFilter: return "HW MIDI"
        }
    }

    var iconName: String {
        switch self {
        case .midiRouter: return "point.3.connected.trianglepath.dotted"
        case .memorySlots: return "memorychip.fill"
        case .customFXStudio: return "wand.and.stars"
        case .reactiveKeyFX: return "waveform.circle.fill"
        case .showControl: return "dot.radiowaves.left.and.right"
        case .terminal: return "apple.terminal.fill"
        case .keyGrid8x4: return "square.grid.4x3.fill"
        case .keyStrip1x8: return "rectangle.split.3x1.fill"
        case .keypad3x3: return "circle.grid.3x3.fill"
        case .verticalFaders: return "slider.vertical.3"
        case .horizontalFaders: return "slider.horizontal.below.rectangle"
        case .rotaryKnobs: return "dial.low.fill"
        case .colorPickerHUD: return "paintpalette.fill"
        case .hardwareMIDIFilter: return "switch.2"
        }
    }

    // Ideal window content framing tailored for each module to prevent letterbox waste & clipping
    var idealWindowSize: NSSize {
        switch self {
        case .midiRouter: return NSSize(width: 375, height: 490)
        case .memorySlots: return NSSize(width: 375, height: 285)
        case .customFXStudio: return NSSize(width: 375, height: 520)
        case .reactiveKeyFX: return NSSize(width: 375, height: 265)
        case .showControl: return NSSize(width: 420, height: 560)
        case .terminal: return NSSize(width: 460, height: 430)
        case .keyGrid8x4: return NSSize(width: 460, height: 270)
        case .keyStrip1x8: return NSSize(width: 460, height: 160)
        case .keypad3x3: return NSSize(width: 280, height: 380)
        case .verticalFaders: return NSSize(width: 460, height: 260)
        case .horizontalFaders: return NSSize(width: 340, height: 220)
        case .rotaryKnobs: return NSSize(width: 280, height: 360)
        case .colorPickerHUD: return NSSize(width: 360, height: 400)
        case .hardwareMIDIFilter: return NSSize(width: 380, height: 530)
        }
    }

    var minWindowSize: NSSize {
        switch self {
        case .midiRouter: return NSSize(width: 320, height: 420)
        case .memorySlots: return NSSize(width: 320, height: 245)
        case .customFXStudio: return NSSize(width: 320, height: 450)
        case .reactiveKeyFX: return NSSize(width: 320, height: 225)
        case .showControl: return NSSize(width: 340, height: 460)
        case .terminal: return NSSize(width: 320, height: 240)
        case .keyGrid8x4: return NSSize(width: 360, height: 210)
        case .keyStrip1x8: return NSSize(width: 360, height: 120)
        case .keypad3x3: return NSSize(width: 220, height: 290)
        case .verticalFaders: return NSSize(width: 360, height: 190)
        case .horizontalFaders: return NSSize(width: 260, height: 160)
        case .rotaryKnobs: return NSSize(width: 210, height: 280)
        case .colorPickerHUD: return NSSize(width: 280, height: 300)
        case .hardwareMIDIFilter: return NSSize(width: 320, height: 430)
        }
    }

    var defaultSlotHeight: CGFloat {
        switch self {
        case .customFXStudio: return 490
        case .reactiveKeyFX: return 300
        case .midiRouter: return 440
        case .memorySlots: return 240
        case .showControl: return 480
        case .terminal: return 340
        case .keyGrid8x4: return 250
        case .keyStrip1x8: return 140
        case .keypad3x3: return 330
        case .verticalFaders: return 240
        case .horizontalFaders: return 180
        case .rotaryKnobs: return 320
        case .colorPickerHUD: return 350
        case .hardwareMIDIFilter: return 460
        }
    }

    var isHardwareModule: Bool {
        switch self {
        case .keyGrid8x4, .keyStrip1x8, .keypad3x3, .verticalFaders, .horizontalFaders, .rotaryKnobs, .colorPickerHUD:
            return true
        default:
            return false
        }
    }

    static var expansionModules: [StudioModuleID] {
        return [.showControl, .memorySlots, .midiRouter, .customFXStudio, .reactiveKeyFX, .terminal, .hardwareMIDIFilter]
    }

    static var hardwareModules: [StudioModuleID] {
        return [.keyGrid8x4, .keyStrip1x8, .keypad3x3, .verticalFaders, .horizontalFaders, .rotaryKnobs, .colorPickerHUD]
    }
}

enum ModuleZone: String, CaseIterable, Codable {
    case leftWing = "LEFT WING"
    case rightWing = "RIGHT WING"
    case bottomRack = "BOTTOM RACK"
    case floating = "FLOATING"

    var displayName: String { rawValue }
    var iconName: String {
        switch self {
        case .leftWing: return "sidebar.left"
        case .rightWing: return "sidebar.right"
        case .bottomRack: return "rectangle.bottomthird.inset.filled"
        case .floating: return "macwindow.badge.plus"
        }
    }
}

// ----------------------------------------------------------------------------
// LOCAL NETWORK INTERFACES & TERMINAL TAB NAVIGATION
// ----------------------------------------------------------------------------

struct NetworkInterfaceInfo: Identifiable {
    let id = UUID()
    let name: String
    let ip: String
    let isLoopback: Bool
}

func getLocalNetworkInterfaces() -> [NetworkInterfaceInfo] {
    var interfaces: [NetworkInterfaceInfo] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
        return [NetworkInterfaceInfo(name: "Loopback (lo0)", ip: "127.0.0.1", isLoopback: true)]
    }
    defer { freeifaddrs(ifaddr) }

    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        let addr = ptr.pointee.ifa_addr.pointee
        if (flags & (IFF_UP | IFF_RUNNING)) != 0 && addr.sa_family == UInt8(AF_INET) {
            let name = String(cString: ptr.pointee.ifa_name)
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = hostname.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress.map { String(cString: $0) } ?? ""
                }
                let isLo = (flags & IFF_LOOPBACK) != 0 || ip == "127.0.0.1"
                let friendlyName: String
                if name.hasPrefix("en0") {
                    friendlyName = "Wi-Fi (en0)"
                } else if name.hasPrefix("en") {
                    friendlyName = "Ethernet (\(name))"
                } else if isLo {
                    friendlyName = "Loopback (lo0)"
                } else {
                    friendlyName = "Interface (\(name))"
                }
                interfaces.append(NetworkInterfaceInfo(name: friendlyName, ip: ip, isLoopback: isLo))
            }
        }
    }
    if interfaces.isEmpty {
        interfaces.append(NetworkInterfaceInfo(name: "Loopback (lo0)", ip: "127.0.0.1", isLoopback: true))
    }
    return interfaces
}

enum TerminalTab: String, CaseIterable, Identifiable {
    case console = "CONSOLE"
    case network = "NETWORK"
    case settings = "SETTINGS"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .console: return "apple.terminal.fill"
        case .network: return "network"
        case .settings: return "slider.horizontal.3"
        }
    }
}

// ----------------------------------------------------------------------------
// PROTOCOL MONITOR DATA MODEL & HELPERS
// ----------------------------------------------------------------------------

func midiNoteName(_ note: UInt8) -> String {
    let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let octave = Int(note) / 12 - 1
    let name = noteNames[Int(note) % 12]
    return "\(name)\(octave)"
}

struct ProtocolEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    enum EventType: String, CaseIterable, Identifiable {
        case all = "ALL"
        case midiIn = "MIDI IN"
        case midiOut = "MIDI OUT"
        case oscIn = "OSC IN"
        case oscOut = "OSC OUT"
        case dmx = "DMX"
        case msc = "MSC"
        case sys = "SYS"

        var id: String { rawValue }

        var tagColor: Color {
            switch self {
            case .all: return .white
            case .midiIn: return Color(red: 0.2, green: 0.95, blue: 0.5)
            case .midiOut: return Color(red: 0.25, green: 0.85, blue: 0.95)
            case .oscIn: return Color(red: 1.0, green: 0.65, blue: 0.2)
            case .oscOut: return Color(red: 0.85, green: 0.45, blue: 1.0)
            case .dmx: return Color(red: 0.95, green: 0.85, blue: 0.25)
            case .msc: return Color(red: 0.45, green: 0.75, blue: 1.0)
            case .sys: return Color(white: 0.7)
            }
        }
    }
    let type: EventType
    let channelOrTarget: String
    let command: String
    let details: String
    let rawHex: String
}

enum SoundPack: String, CaseIterable, Identifiable {
    case arcade8Bit = "8-BIT ARCADE"
    case mechanicalClick = "CHERRY MX BLUE"
    case sciFiBeeps = "SCI-FI SYNTH"
    case customUser = "CUSTOM SOUNDS"
    case mute = "MUTE SOUNDS"

    var id: String { rawValue }
}

final class CustomSoundBank {
    static let shared = CustomSoundBank()
    private let storageKey = "BitchBoy_CustomSoundMap_v1"
    private(set) var soundPaths: [String: String] = [:]

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] {
            soundPaths = saved
        }
    }

    func path(for effect: SoundEffect) -> String? {
        guard let p = soundPaths[effect.rawValue], !p.isEmpty,
              FileManager.default.fileExists(atPath: p) else {
            return nil
        }
        return p
    }

    func fileName(for effect: SoundEffect) -> String? {
        guard let p = path(for: effect) else { return nil }
        return URL(fileURLWithPath: p).lastPathComponent
    }

    func setCustomSound(url: URL, for effect: SoundEffect) -> String? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let soundDir = appSupport.appendingPathComponent("BitchManager/CustomSounds", isDirectory: true)
        try? fm.createDirectory(at: soundDir, withIntermediateDirectories: true)

        let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension
        let safeKey = effect.rawValue.replacingOccurrences(of: " ", with: "_")
        let destURL = soundDir.appendingPathComponent("\(safeKey)_\(url.deletingPathExtension().lastPathComponent).\(ext)")

        try? fm.removeItem(at: destURL)
        do {
            try fm.copyItem(at: url, to: destURL)
            soundPaths[effect.rawValue] = destURL.path
            UserDefaults.standard.set(soundPaths, forKey: storageKey)
            return destURL.path
        } catch {
            // Fallback to referencing original path if copy fails
            soundPaths[effect.rawValue] = url.path
            UserDefaults.standard.set(soundPaths, forKey: storageKey)
            return url.path
        }
    }

    private var customSoundCache: [String: NSSound] = [:]

    func clearCustomSound(for effect: SoundEffect) {
        if let p = soundPaths[effect.rawValue] {
            customSoundCache.removeValue(forKey: p)
        }
        soundPaths.removeValue(forKey: effect.rawValue)
        UserDefaults.standard.set(soundPaths, forKey: storageKey)
    }

    func clearAllCustomSounds() {
        customSoundCache.removeAll()
        soundPaths.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    func playCustomIfAvailable(for effect: SoundEffect) -> Bool {
        guard let p = path(for: effect) else {
            return false
        }
        if let snd = customSoundCache[p] {
            snd.stop()
            snd.play()
            return true
        } else if let snd = NSSound(contentsOfFile: p, byReference: true) {
            customSoundCache[p] = snd
            snd.play()
            return true
        }
        return false
    }
}

enum SoundEffect: String, CaseIterable, Codable, Identifiable {
    case keyTap = "keyTap"
    case faderSlide = "faderSlide"
    case knobTick = "knobTick"
    case mascotSqueak = "mascotSqueak"
    case presetSwitch = "presetSwitch"
    case hardwareConnected = "hardwareConnected"
    case hardwareDisconnected = "hardwareDisconnected"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keyTap: return "49-KEY MECHANICAL PRESS"
        case .faderSlide: return "VERTICAL / HORIZ FADER SLIDE"
        case .knobTick: return "ROTARY KNOB DETENT TICK"
        case .mascotSqueak: return "BITCHBOY MASCOT & LOGO TAP"
        case .presetSwitch: return "MEMORY SLOT / PRESET SWITCH"
        case .hardwareConnected: return "BITCHBOY HARDWARE CONNECTED"
        case .hardwareDisconnected: return "BITCHBOY HARDWARE DISCONNECTED"
        }
    }

    var iconName: String {
        switch self {
        case .keyTap: return "keyboard.fill"
        case .faderSlide: return "slider.vertical.3"
        case .knobTick: return "dial.medium.fill"
        case .mascotSqueak: return "sparkles"
        case .presetSwitch: return "memorychip.fill"
        case .hardwareConnected: return "cable.connector"
        case .hardwareDisconnected: return "cable.connector.slash"
        }
    }

    private static var soundCache: [String: NSSound] = [:]

    private static func playCachedSound(_ name: String) {
        if let sound = soundCache[name] {
            sound.stop()
            sound.play()
        } else if let sound = NSSound(named: name) {
            soundCache[name] = sound
            sound.play()
        }
    }

    func play(with pack: SoundPack) {
        guard pack != .mute else { return }

        // If user is on CUSTOM SOUNDS pack (or has assigned a custom sound override), play their uploaded file!
        if pack == .customUser {
            if CustomSoundBank.shared.playCustomIfAvailable(for: self) {
                return
            }
            // Fallback to 8-Bit Arcade for any slot without an uploaded file yet
        }

        switch pack {
        case .arcade8Bit, .customUser:
            switch self {
            case .keyTap: Self.playCachedSound("Tink")
            case .faderSlide: Self.playCachedSound("Pop")
            case .knobTick: Self.playCachedSound("Morse")
            case .mascotSqueak: Self.playCachedSound("Purr")
            case .presetSwitch: Self.playCachedSound("Glass")
            case .hardwareConnected:
                Self.playCachedSound("Glass")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    Self.playCachedSound("Hero")
                }
            case .hardwareDisconnected:
                Self.playCachedSound("Basso")
            }
        case .mechanicalClick:
            switch self {
            case .keyTap: Self.playCachedSound("Pop")
            case .faderSlide: Self.playCachedSound("Tink")
            case .knobTick: Self.playCachedSound("Tink")
            case .mascotSqueak: Self.playCachedSound("Blow")
            case .presetSwitch: Self.playCachedSound("Ping")
            case .hardwareConnected:
                Self.playCachedSound("Ping")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    Self.playCachedSound("Glass")
                }
            case .hardwareDisconnected:
                Self.playCachedSound("Sosumi")
            }
        case .sciFiBeeps:
            switch self {
            case .keyTap: Self.playCachedSound("Morse")
            case .faderSlide: Self.playCachedSound("Purr")
            case .knobTick: Self.playCachedSound("Bottle")
            case .mascotSqueak: Self.playCachedSound("Hero")
            case .presetSwitch: Self.playCachedSound("Submarine")
            case .hardwareConnected:
                Self.playCachedSound("Submarine")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    Self.playCachedSound("Hero")
                }
            case .hardwareDisconnected:
                Self.playCachedSound("Blow")
            }
        case .mute:
            break
        }
    }
}

// ----------------------------------------------------------------------------
// HEX COLOR SUPPORT & CUSTOM GLOWING CHASSIS THEME SYSTEM
// ----------------------------------------------------------------------------
extension Color {
    init(hex: String, fallback: Color = Color(red: 0.22, green: 0.96, blue: 0.85)) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch clean.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            self = fallback
            return
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }

    func toHex() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int(round(max(0, min(1, ns.redComponent)) * 255))
        let g = Int(round(max(0, min(1, ns.greenComponent)) * 255))
        let b = Int(round(max(0, min(1, ns.blueComponent)) * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

struct CustomChassisTheme: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var pcbHex: String
    var bezelStartHex: String
    var bezelEndHex: String
    var accentGlowHex: String
    var outlineHex: String
    var headerTextHex: String

    var pcbBackground: Color { Color(hex: pcbHex, fallback: Color(red: 0.04, green: 0.24, blue: 0.21)) }
    var outerBezelColors: [Color] {
        [
            Color(hex: bezelStartHex, fallback: Color(white: 0.94)),
            Color(hex: bezelEndHex, fallback: Color(white: 0.55))
        ]
    }
    var accentPrimary: Color { Color(hex: accentGlowHex, fallback: Color(red: 0.22, green: 0.96, blue: 0.85)) }
    var sectionOutline: Color { Color(hex: outlineHex, fallback: Color(red: 0.96, green: 0.52, blue: 0.25)) }
    var headerText: Color { Color(hex: headerTextHex, fallback: Color(red: 0.98, green: 0.90, blue: 0.65)) }

    static func defaultCustom() -> CustomChassisTheme {
        CustomChassisTheme(
            name: "NEO TOKYO GLOW",
            pcbHex: "#0D0A1C",
            bezelStartHex: "#FF007F",
            bezelEndHex: "#7928CA",
            accentGlowHex: "#00F0FF",
            outlineHex: "#FF007F",
            headerTextHex: "#E0E7FF"
        )
    }

    static func starterThemes() -> [CustomChassisTheme] {
        [
            CustomChassisTheme(
                name: "NEO TOKYO GLOW",
                pcbHex: "#0D0A1C",
                bezelStartHex: "#FF007F",
                bezelEndHex: "#7928CA",
                accentGlowHex: "#00F0FF",
                outlineHex: "#FF007F",
                headerTextHex: "#E0E7FF"
            ),
            CustomChassisTheme(
                name: "ACID LIME OVERDRIVE",
                pcbHex: "#08140B",
                bezelStartHex: "#39FF14",
                bezelEndHex: "#0A4A1C",
                accentGlowHex: "#39FF14",
                outlineHex: "#CCFF00",
                headerTextHex: "#E5FFD0"
            ),
            CustomChassisTheme(
                name: "CYBER INFERNO",
                pcbHex: "#1A0505",
                bezelStartHex: "#FF3300",
                bezelEndHex: "#8B0000",
                accentGlowHex: "#FF4500",
                outlineHex: "#FF9900",
                headerTextHex: "#FFE4B5"
            ),
            CustomChassisTheme(
                name: "DEEP VOID ICE",
                pcbHex: "#040914",
                bezelStartHex: "#00D2FF",
                bezelEndHex: "#003366",
                accentGlowHex: "#38E8FF",
                outlineHex: "#0088FF",
                headerTextHex: "#D8F3FF"
            )
        ]
    }
}

enum ChassisTheme: String, CaseIterable, Identifiable {
    case petrolTeal = "PETROL TEAL"
    case retroMatrix = "RETRO MATRIX"
    case neonCyber = "NEON CYBER"
    case royalGold = "ROYAL GOLD"
    case stealthBlack = "STEALTH NOIR"
    case prismRainbow = "PRISM RAINBOW 🌈"
    case customUser = "CUSTOM THEME"

    var id: String { rawValue }

    var isRainbow: Bool {
        self == .prismRainbow
    }

    var rainbowGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 1.00, green: 0.22, blue: 0.35),
                Color(red: 1.00, green: 0.55, blue: 0.10),
                Color(red: 1.00, green: 0.88, blue: 0.15),
                Color(red: 0.20, green: 0.95, blue: 0.40),
                Color(red: 0.10, green: 0.85, blue: 1.00),
                Color(red: 0.45, green: 0.35, blue: 1.00),
                Color(red: 0.90, green: 0.25, blue: 0.95),
                Color(red: 1.00, green: 0.22, blue: 0.35)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var pcbBackground: Color {
        switch self {
        case .petrolTeal: return Color(red: 0.04, green: 0.24, blue: 0.21)
        case .retroMatrix: return Color(red: 0.02, green: 0.16, blue: 0.08)
        case .neonCyber: return Color(red: 0.08, green: 0.02, blue: 0.18)
        case .royalGold: return Color(red: 0.18, green: 0.12, blue: 0.04)
        case .stealthBlack: return Color(red: 0.06, green: 0.06, blue: 0.07)
        case .prismRainbow: return Color(red: 0.06, green: 0.03, blue: 0.12)
        case .customUser: return BitchBoyEngine.activeCustomThemeStatic.pcbBackground
        }
    }

    var outerBezelColors: [Color] {
        switch self {
        case .petrolTeal:
            return [Color(white: 0.94), Color(white: 0.75), Color(white: 0.55)]
        case .retroMatrix:
            return [Color(red: 0.15, green: 0.55, blue: 0.25), Color(red: 0.08, green: 0.30, blue: 0.12)]
        case .neonCyber:
            return [Color(red: 0.95, green: 0.22, blue: 0.85), Color(red: 0.35, green: 0.10, blue: 0.65)]
        case .royalGold:
            return [Color(red: 0.98, green: 0.85, blue: 0.45), Color(red: 0.65, green: 0.45, blue: 0.15)]
        case .stealthBlack:
            return [Color(white: 0.35), Color(white: 0.15), Color(white: 0.08)]
        case .prismRainbow:
            return [
                Color(red: 1.00, green: 0.22, blue: 0.35),
                Color(red: 1.00, green: 0.55, blue: 0.10),
                Color(red: 1.00, green: 0.88, blue: 0.15),
                Color(red: 0.20, green: 0.95, blue: 0.40),
                Color(red: 0.10, green: 0.85, blue: 1.00),
                Color(red: 0.45, green: 0.35, blue: 1.00),
                Color(red: 0.90, green: 0.25, blue: 0.95)
            ]
        case .customUser:
            return BitchBoyEngine.activeCustomThemeStatic.outerBezelColors
        }
    }

    var accentPrimary: Color {
        switch self {
        case .petrolTeal: return Color(red: 0.22, green: 0.96, blue: 0.85)
        case .retroMatrix: return Color(red: 0.18, green: 0.95, blue: 0.35)
        case .neonCyber: return Color(red: 1.0, green: 0.25, blue: 0.88)
        case .royalGold: return Color(red: 0.98, green: 0.82, blue: 0.35)
        case .stealthBlack: return Color(white: 0.85)
        case .prismRainbow: return Color(red: 1.00, green: 0.35, blue: 0.85)
        case .customUser: return BitchBoyEngine.activeCustomThemeStatic.accentPrimary
        }
    }

    var sectionOutline: Color {
        switch self {
        case .petrolTeal: return Color(red: 0.96, green: 0.52, blue: 0.25)
        case .retroMatrix: return Color(red: 0.20, green: 0.85, blue: 0.45)
        case .neonCyber: return Color(red: 0.20, green: 0.92, blue: 0.98)
        case .royalGold: return Color(red: 0.92, green: 0.75, blue: 0.25)
        case .stealthBlack: return Color(white: 0.45)
        case .prismRainbow: return Color(red: 0.25, green: 0.92, blue: 0.98)
        case .customUser: return BitchBoyEngine.activeCustomThemeStatic.sectionOutline
        }
    }

    var headerText: Color {
        switch self {
        case .petrolTeal: return Color(red: 0.98, green: 0.90, blue: 0.65)
        case .retroMatrix: return Color(red: 0.65, green: 0.98, blue: 0.65)
        case .neonCyber: return Color(red: 0.95, green: 0.75, blue: 0.98)
        case .royalGold: return Color(red: 0.98, green: 0.92, blue: 0.70)
        case .stealthBlack: return Color(white: 0.80)
        case .prismRainbow: return Color(red: 1.00, green: 0.92, blue: 0.45)
        case .customUser: return BitchBoyEngine.activeCustomThemeStatic.headerText
        }
    }
}

// ============================================================================
// BITCHBOY HARDWARE LED COLOR SYSTEM (AUTHENTIC HARDWARE VELOCITIES)
// ============================================================================

struct BitchBoyHardwareColor {
    // Exact mapping specified for BitchBoy hardware:
    // Red 72 (48 Hex), Green 87, Blue 41, Yellow 74, Cyan 78, Orange 61,
    // Purple 67, Brown 83, Off 0, White 3, Pink 57, Amber 96, Turqoise 33
    static let off       = Color(white: 0.14)
    static let white     = Color(red: 0.98, green: 0.98, blue: 1.00)
    static let turquoise = Color(red: 0.16, green: 0.90, blue: 0.78)
    static let blue      = Color(red: 0.18, green: 0.46, blue: 1.00)
    static let orange    = Color(red: 1.00, green: 0.52, blue: 0.08)
    static let purple    = Color(red: 0.68, green: 0.22, blue: 0.96)
    static let red       = Color(red: 1.00, green: 0.16, blue: 0.16)
    static let yellow    = Color(red: 1.00, green: 0.92, blue: 0.10)
    static let cyan      = Color(red: 0.10, green: 0.94, blue: 0.98)
    static let brown     = Color(red: 0.62, green: 0.38, blue: 0.18)
    static let green     = Color(red: 0.16, green: 0.92, blue: 0.32)
    static let pink      = Color(red: 1.00, green: 0.30, blue: 0.72)
    static let amber     = Color(red: 1.00, green: 0.74, blue: 0.12)

    struct Item: Identifiable, Hashable {
        let name: String
        let shortName: String
        let velocity: UInt8
        let color: Color
        var id: UInt8 { velocity }
    }

    static let allItems: [Item] = [
        Item(name: "OFF", shortName: "OFF", velocity: 0, color: off),
        Item(name: "WHITE", shortName: "WHT", velocity: 3, color: white),
        Item(name: "TURQUOISE", shortName: "TRQ", velocity: 33, color: turquoise),
        Item(name: "BLUE", shortName: "BLU", velocity: 41, color: blue),
        Item(name: "ORANGE", shortName: "ORG", velocity: 61, color: orange),
        Item(name: "PURPLE", shortName: "PRP", velocity: 67, color: purple),
        Item(name: "RED", shortName: "RED", velocity: 72, color: red),
        Item(name: "YELLOW", shortName: "YLW", velocity: 74, color: yellow),
        Item(name: "CYAN", shortName: "CYN", velocity: 78, color: cyan),
        Item(name: "BROWN", shortName: "BRN", velocity: 83, color: brown),
        Item(name: "GREEN", shortName: "GRN", velocity: 87, color: green),
        Item(name: "PINK", shortName: "PNK", velocity: 57, color: pink),
        Item(name: "AMBER", shortName: "AMB", velocity: 96, color: amber)
    ]

    static let knownVelocities: [UInt8] = [0, 3, 33, 41, 57, 61, 67, 72, 74, 78, 83, 87, 96]

    static func closestHardwareVelocity(for vel: UInt8) -> UInt8 {
        if vel == 0 { return 0 }
        return knownVelocities.min(by: { abs(Int($0) - Int(vel)) < abs(Int($1) - Int(vel)) }) ?? 0
    }

    static func color(for vel: UInt8) -> Color {
        switch vel {
        case 0:  return off
        case 3:  return white
        case 33: return turquoise
        case 41: return blue
        case 61: return orange
        case 67: return purple
        case 72: return red
        case 74: return yellow
        case 78: return cyan
        case 83: return brown
        case 87: return green
        case 57, 95: return pink
        case 96: return amber
        default:
            let nearest = knownVelocities.min(by: { abs(Int($0) - Int(vel)) < abs(Int($1) - Int(vel)) }) ?? 0
            return color(for: nearest)
        }
    }

    static func label(for vel: UInt8) -> String {
        switch vel {
        case 0:  return "OFF"
        case 3:  return "WHITE"
        case 33: return "TURQUOISE"
        case 41: return "BLUE"
        case 61: return "ORANGE"
        case 67: return "PURPLE"
        case 72: return "RED"
        case 74: return "YELLOW"
        case 78: return "CYAN"
        case 83: return "BROWN"
        case 87: return "GREEN"
        case 57, 95: return "PINK"
        case 96: return "AMBER"
        default:
            let nearest = knownVelocities.min(by: { abs(Int($0) - Int(vel)) < abs(Int($1) - Int(vel)) }) ?? 0
            return label(for: nearest)
        }
    }

    static func formattedLabel(for vel: UInt8) -> String {
        let lbl = label(for: vel)
        if vel == 0 {
            return "OFF (0)"
        }
        return "\(lbl) (\(vel))"
    }
}

enum LEDPaletteMode: String, CaseIterable, Identifiable {
    case multiVelocity = "VELOCITY MULTI-COLOR"
    case cyberCyan = "CYBER CYAN"
    case matrixGreen = "MATRIX GREEN"
    case solarAmber = "SOLAR AMBER"
    case synthMagenta = "SYNTH MAGENTA"
    case arcticWhite = "ARCTIC WHITE"

    var id: String { rawValue }
}

// ============================================================================
// GITHUB AUTO-UPDATER DATA MODELS
// ============================================================================

struct GitHubReleaseInfo: Codable, Identifiable, Equatable {
    var id: Int
    var tagName: String
    var name: String?
    var body: String?
    var htmlURL: String
    var publishedAt: String?
    var assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    var cleanVersion: String {
        tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
    }

    var bestAsset: GitHubReleaseAsset? {
        if let zip = assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) {
            return zip
        }
        if let dmg = assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) {
            return dmg
        }
        return assets.first
    }

    var formattedPublishDate: String {
        guard let publishedAt = publishedAt else { return "Recent" }
        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: publishedAt) {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return df.string(from: date)
        }
        return String(publishedAt.prefix(10))
    }
}

struct GitHubReleaseAsset: Codable, Identifiable, Equatable {
    var id: Int
    var name: String
    var browserDownloadURL: String
    var size: Int
    var contentType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case contentType = "content_type"
    }

    var formattedSize: String {
        let mb = Double(size) / (1024.0 * 1024.0)
        if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        } else {
            let kb = Double(size) / 1024.0
            return String(format: "%.0f KB", kb)
        }
    }
}

struct QwertyStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var key: String
    var cmd: Bool = false
    var shift: Bool = false
    var alt: Bool = false
    var ctrl: Bool = false
    var delayMs: Int = 10
}

// ============================================================================
// HARDWARE ARCHITECTURE SECTIONS & CONTROLS
// ============================================================================

enum HardwareSection: String, CaseIterable, Identifiable {
    case grid8x4 = "GRID"
    case strip1x8 = "STRIP"
    case keypad3x3 = "PAD"
    case verticalFaders = "VFADERS"
    case horizontalFaders = "HFADERS"
    case rotaryKnobs = "MASTER_KNOBS"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .grid8x4: return "8X4 KEY GRID (32 KEYS)"
        case .strip1x8: return "1X8 KEY STRIP (8 KEYS)"
        case .keypad3x3: return "3X3 KEYPAD (9 KEYS)"
        case .verticalFaders: return "8 VERTICAL FADERS (CC 0-7)"
        case .horizontalFaders: return "4 HORIZONTAL FADERS (CC 8-11)"
        case .rotaryKnobs: return "2X4 ROTARY KNOBS (CC 20-27)"
        }
    }

    var indexRange: Range<Int> {
        switch self {
        case .grid8x4: return 0..<32
        case .strip1x8: return 32..<40
        case .keypad3x3: return 40..<49
        case .verticalFaders: return 49..<57
        case .horizontalFaders: return 57..<61
        case .rotaryKnobs: return 61..<69
        }
    }

    static func section(for index: Int) -> HardwareSection? {
        allCases.first { $0.indexRange.contains(index) }
    }
}

// ============================================================================
// SHOW CONTROL PROTOCOL ENGINES: MSC, OSC, ART-NET 4 & sACN E1.31
// ============================================================================

enum OSCArgumentType: String, CaseIterable, Codable, Identifiable {
    case none = "NONE"
    case float = "FLOAT"
    case int = "INT"
    case string = "STRING"
    case boolean = "BOOLEAN"
    case booleanTrue = "BOOLEAN_TRUE"
    case booleanFalse = "BOOLEAN_FALSE"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "BANG / NONE"
        case .float: return "FLOAT"
        case .int: return "INT"
        case .string: return "STRING"
        case .boolean: return "BOOL"
        case .booleanTrue: return "BOOL (TRUE)"
        case .booleanFalse: return "BOOL (FALSE)"
        }
    }
}

enum MSCCommand: UInt8, CaseIterable, Identifiable, Codable {
    case go = 0x01
    case stop = 0x02
    case resume = 0x03
    case timedGo = 0x04
    case load = 0x05
    case set = 0x06
    case fire = 0x07
    case allOff = 0x08
    case restore = 0x09
    case reset = 0x0A
    case goOff = 0x0B
    case goJam = 0x11
    case standbyPlus = 0x12
    case standbyMinus = 0x13

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .go: return "GO"
        case .stop: return "STOP"
        case .resume: return "RESUME"
        case .timedGo: return "TIMED GO"
        case .load: return "LOAD"
        case .set: return "SET"
        case .fire: return "FIRE MACRO"
        case .allOff: return "ALL OFF / PANIC"
        case .restore: return "RESTORE"
        case .reset: return "RESET"
        case .goOff: return "GO OFF"
        case .goJam: return "GO JAM"
        case .standbyPlus: return "STANDBY +"
        case .standbyMinus: return "STANDBY -"
        }
    }

    var icon: String {
        switch self {
        case .go: return "play.fill"
        case .stop: return "stop.fill"
        case .resume: return "playpause.fill"
        case .timedGo: return "timer"
        case .load: return "arrow.down.doc.fill"
        case .set: return "slider.horizontal.3"
        case .fire: return "flame.fill"
        case .allOff: return "exclamationmark.octagon.fill"
        case .restore: return "arrow.uturn.backward"
        case .reset: return "arrow.clockwise"
        case .goOff: return "xmark.circle"
        case .goJam: return "bolt.horizontal.fill"
        case .standbyPlus: return "plus.circle.fill"
        case .standbyMinus: return "minus.circle.fill"
        }
    }
}

enum MSCCommandFormat: UInt8, CaseIterable, Identifiable, Codable {
    case lightingGeneral = 0x01
    case movingLights = 0x02
    case colorChangers = 0x03
    case soundGeneral = 0x10
    case soundPlayback = 0x11
    case soundEffects = 0x12
    case machinery = 0x20
    case videoGeneral = 0x30
    case projection = 0x40
    case processControl = 0x50
    case pyro = 0x60
    case allTypes = 0x7F

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .lightingGeneral: return "Lighting (General)"
        case .movingLights: return "Moving Lights"
        case .colorChangers: return "Color Changers"
        case .soundGeneral: return "Sound (General)"
        case .soundPlayback: return "Sound Playback"
        case .soundEffects: return "Sound FX"
        case .machinery: return "Machinery"
        case .videoGeneral: return "Video (General)"
        case .projection: return "Projection"
        case .processControl: return "Process Control"
        case .pyro: return "Pyrotechnics"
        case .allTypes: return "All Types (Universal Broadcast)"
        }
    }
}

protocol DMXPacketBuilder {
    static func buildDMXPacket(universe: UInt16, channels: [UInt8], sequence: UInt8) -> Data
}

struct ControlClipboardData: Codable, Equatable {
    var customName: String = ""
    var idleVelocity: UInt8 = 0
    var activeVelocity: UInt8 = 3
    var feedbackMode: FeedbackMode = .momentary
    var feedbackCustomVelocity: UInt8 = 78
    var feedbackInvert: Bool = false
    var actionType: ActionType = .passthrough
    var qwertySteps: [QwertyStep] = []
    var oscHost: String = "127.0.0.1"
    var oscPort: UInt16 = 8000
    var oscAddress: String = "/bitchboy/trigger"
    var oscArgType: String = "NONE"
    var oscArgValue: String = "1.0"
    var mscCommand: UInt8 = 1
    var mscCueNumber: String = ""
    var appleScript: String = ""
    var oscEnabled: Bool = false
    var oscMinVal: Double = 0.0
    var oscMaxVal: Double = 1.0
    var oscSendRelease: Bool = false
    var oscReleaseVal: String = "0.0"

    var typedMSCCommand: MSCCommand {
        get { MSCCommand(rawValue: mscCommand) ?? .go }
        set { mscCommand = newValue.rawValue }
    }
    var typedOSCArgType: OSCArgumentType {
        get { OSCArgumentType(rawValue: oscArgType) ?? .none }
        set { oscArgType = newValue.rawValue }
    }

    init(from item: ControlItem) {
        self.customName = item.customName
        self.idleVelocity = item.idleVelocity
        self.activeVelocity = item.activeVelocity
        self.feedbackMode = item.feedbackMode
        self.feedbackCustomVelocity = item.feedbackCustomVelocity
        self.feedbackInvert = item.feedbackInvert
        self.actionType = item.actionType
        self.qwertySteps = item.qwertySteps
        self.oscHost = item.oscHost
        self.oscPort = item.oscPort
        self.oscAddress = item.oscAddress
        self.oscArgType = item.oscArgType
        self.oscArgValue = item.oscArgValue
        self.mscCommand = item.mscCommand
        self.mscCueNumber = item.mscCueNumber
        self.appleScript = item.appleScript
        self.oscEnabled = item.oscEnabled
        self.oscMinVal = item.oscMinVal
        self.oscMaxVal = item.oscMaxVal
        self.oscSendRelease = item.oscSendRelease
        self.oscReleaseVal = item.oscReleaseVal
    }

    func apply(to item: inout ControlItem, copyName: Bool = false) {
        if copyName && !customName.isEmpty {
            item.customName = customName
        }
        item.idleVelocity = idleVelocity
        item.activeVelocity = activeVelocity
        item.feedbackMode = feedbackMode
        item.feedbackCustomVelocity = feedbackCustomVelocity
        item.feedbackInvert = feedbackInvert
        item.actionType = actionType
        item.qwertySteps = qwertySteps
        item.oscHost = oscHost
        item.oscPort = oscPort
        item.oscAddress = oscAddress
        item.oscArgType = oscArgType
        item.oscArgValue = oscArgValue
        item.mscCommand = mscCommand
        item.mscCueNumber = mscCueNumber
        item.appleScript = appleScript
        item.oscEnabled = oscEnabled
        item.oscMinVal = oscMinVal
        item.oscMaxVal = oscMaxVal
        item.oscSendRelease = oscSendRelease
        item.oscReleaseVal = oscReleaseVal
        if item.hasLED {
            item.currentLED = idleVelocity
        }
    }
}

struct UndoSnapshot {
    let description: String
    let controls: [ControlItem]
    let activeSlot: Int
    let timestamp: Date
    let customEffects: [CustomLightEffect]?
    let editingCustomFX: CustomLightEffect?
    let editingFrameIndex: Int?
}

struct ToastNotificationItem: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let icon: String
}

struct ControlItem: Identifiable, Codable {
    var id: String { "\(kind.rawValue)_\(number)" }
    var label: String
    var customName: String = ""
    var kind: ControlKind
    var number: UInt8          // MIDI Note or CC Number
    var zone: String
    var idleVelocity: UInt8 = 0
    var activeVelocity: UInt8 = 3
    var currentLED: UInt8 = 0
    var liveValue: UInt8 = 0
    var isPressed: Bool = false
    var toggleLatched: Bool = false
    var feedbackMode: FeedbackMode = .momentary
    var feedbackCustomVelocity: UInt8 = 78 // Default Cyan
    var feedbackInvert: Bool = false
    var actionType: ActionType = .passthrough
    var qwertySteps: [QwertyStep] = []
    var oscHost: String = "127.0.0.1"
    var oscPort: UInt16 = 8000
    var oscAddress: String = "/bitchboy/trigger"
    var oscArgType: String = "NONE"
    var oscArgValue: String = "1.0"
    var mscCommand: UInt8 = 1 // 1 = GO
    var mscCueNumber: String = ""
    var appleScript: String = ""
    var oscEnabled: Bool = false
    var oscMinVal: Double = 0.0
    var oscMaxVal: Double = 1.0
    var oscSendRelease: Bool = false
    var oscReleaseVal: String = "0.0"

    var typedMSCCommand: MSCCommand {
        get { MSCCommand(rawValue: mscCommand) ?? .go }
        set { mscCommand = newValue.rawValue }
    }
    var typedOSCArgType: OSCArgumentType {
        get { OSCArgumentType(rawValue: oscArgType) ?? .none }
        set { oscArgType = newValue.rawValue }
    }

    var hasLED: Bool { kind == .key }

    enum CodingKeys: String, CodingKey {
        case label, customName, kind, number, zone
        case idleVelocity, activeVelocity, currentLED, liveValue, isPressed, toggleLatched
        case feedbackMode, feedbackCustomVelocity, feedbackInvert, actionType, qwertySteps
        case oscHost, oscPort, oscAddress, oscArgType, oscArgValue
        case mscCommand, mscCueNumber, appleScript
        case oscEnabled, oscMinVal, oscMaxVal, oscSendRelease, oscReleaseVal
    }

    init(
        label: String,
        customName: String = "",
        kind: ControlKind,
        number: UInt8,
        zone: String,
        idleVelocity: UInt8 = 0,
        activeVelocity: UInt8 = 3,
        currentLED: UInt8 = 0,
        liveValue: UInt8 = 0,
        isPressed: Bool = false,
        toggleLatched: Bool = false,
        feedbackMode: FeedbackMode = .momentary,
        feedbackCustomVelocity: UInt8 = 78,
        feedbackInvert: Bool = false,
        actionType: ActionType = .passthrough,
        qwertySteps: [QwertyStep] = [],
        oscHost: String = "127.0.0.1",
        oscPort: UInt16 = 8000,
        oscAddress: String = "/bitchboy/trigger",
        oscArgType: String = "NONE",
        oscArgValue: String = "1.0",
        mscCommand: UInt8 = 1,
        mscCueNumber: String = "",
        appleScript: String = "",
        oscEnabled: Bool = false,
        oscMinVal: Double = 0.0,
        oscMaxVal: Double = 1.0,
        oscSendRelease: Bool = false,
        oscReleaseVal: String = "0.0"
    ) {
        self.label = label
        self.customName = customName
        self.kind = kind
        self.number = number
        self.zone = zone
        self.idleVelocity = idleVelocity
        self.activeVelocity = activeVelocity
        self.currentLED = currentLED
        self.liveValue = liveValue
        self.isPressed = isPressed
        self.toggleLatched = toggleLatched
        self.feedbackMode = feedbackMode
        self.feedbackCustomVelocity = feedbackCustomVelocity
        self.feedbackInvert = feedbackInvert
        self.actionType = actionType
        self.qwertySteps = qwertySteps
        self.oscHost = oscHost
        self.oscPort = oscPort
        self.oscAddress = oscAddress
        self.oscArgType = oscArgType
        self.oscArgValue = oscArgValue
        self.mscCommand = mscCommand
        self.mscCueNumber = mscCueNumber
        self.appleScript = appleScript
        self.oscEnabled = oscEnabled
        self.oscMinVal = oscMinVal
        self.oscMaxVal = oscMaxVal
        self.oscSendRelease = oscSendRelease
        self.oscReleaseVal = oscReleaseVal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        customName = (try? c.decode(String.self, forKey: .customName)) ?? ""
        kind = (try? c.decode(ControlKind.self, forKey: .kind)) ?? .key
        number = (try? c.decode(UInt8.self, forKey: .number)) ?? 0
        zone = (try? c.decode(String.self, forKey: .zone)) ?? ""
        idleVelocity = (try? c.decode(UInt8.self, forKey: .idleVelocity)) ?? 0
        activeVelocity = (try? c.decode(UInt8.self, forKey: .activeVelocity)) ?? 3
        currentLED = (try? c.decode(UInt8.self, forKey: .currentLED)) ?? 0
        liveValue = (try? c.decode(UInt8.self, forKey: .liveValue)) ?? 0
        isPressed = (try? c.decode(Bool.self, forKey: .isPressed)) ?? false
        toggleLatched = (try? c.decode(Bool.self, forKey: .toggleLatched)) ?? false
        feedbackMode = (try? c.decode(FeedbackMode.self, forKey: .feedbackMode)) ?? .momentary
        feedbackCustomVelocity = (try? c.decode(UInt8.self, forKey: .feedbackCustomVelocity)) ?? 78
        feedbackInvert = (try? c.decode(Bool.self, forKey: .feedbackInvert)) ?? false
        actionType = (try? c.decode(ActionType.self, forKey: .actionType)) ?? .passthrough
        qwertySteps = (try? c.decode([QwertyStep].self, forKey: .qwertySteps)) ?? []
        oscHost = (try? c.decode(String.self, forKey: .oscHost)) ?? "127.0.0.1"
        oscPort = (try? c.decode(UInt16.self, forKey: .oscPort)) ?? 8000
        oscAddress = (try? c.decode(String.self, forKey: .oscAddress)) ?? "/bitchboy/trigger"
        oscArgType = (try? c.decode(String.self, forKey: .oscArgType)) ?? "NONE"
        oscArgValue = (try? c.decode(String.self, forKey: .oscArgValue)) ?? "1.0"
        mscCommand = (try? c.decode(UInt8.self, forKey: .mscCommand)) ?? 1
        mscCueNumber = (try? c.decode(String.self, forKey: .mscCueNumber)) ?? ""
        appleScript = (try? c.decode(String.self, forKey: .appleScript)) ?? ""
        oscEnabled = (try? c.decode(Bool.self, forKey: .oscEnabled)) ?? false
        oscMinVal = (try? c.decode(Double.self, forKey: .oscMinVal)) ?? 0.0
        oscMaxVal = (try? c.decode(Double.self, forKey: .oscMaxVal)) ?? 1.0
        oscSendRelease = (try? c.decode(Bool.self, forKey: .oscSendRelease)) ?? false
        oscReleaseVal = (try? c.decode(String.self, forKey: .oscReleaseVal)) ?? "0.0"
    }
}

// ============================================================================
// SHOW CONTROL PROTOCOL MESSAGES & SERIALIZATION
// ============================================================================

struct MSCMessage: Identifiable {
    let id = UUID()
    let timestamp: Date = Date()
    let isOutbound: Bool
    let deviceID: UInt8
    let commandFormat: MSCCommandFormat
    let command: MSCCommand
    let cueNumber: String
    let cueList: String
    let rawBytes: [UInt8]

    var summary: String {
        let dir = isOutbound ? "TX ➡️" : "RX ⬅️"
        let cueStr = cueNumber.isEmpty ? "" : " Cue: \(cueNumber)"
        let listStr = cueList.isEmpty ? "" : " [List: \(cueList)]"
        let devStr = (deviceID == 127 || deviceID == 0x7F) ? "ALL" : "\(deviceID)"
        return "\(dir) \(command.title)\(cueStr)\(listStr) (Dev: \(devStr), \(commandFormat.label))"
    }

    var timeString: String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SS"
        return df.string(from: timestamp)
    }
}

struct ArtNetPacketBuilder: DMXPacketBuilder {
    static func buildDMXPacket(universe: UInt16, channels: [UInt8], sequence: UInt8 = 0) -> Data {
        var data = Data()
        // Header: "Art-Net\0"
        data.append(contentsOf: [0x41, 0x72, 0x74, 0x2D, 0x4E, 0x65, 0x74, 0x00])
        // OpCode: OpOutput / OpDmx (0x5000, Little Endian: 0x00, 0x50)
        data.append(contentsOf: [0x00, 0x50])
        // ProtVer: 14 (Big Endian: 0x00, 0x0E)
        data.append(contentsOf: [0x00, 0x0E])
        // Sequence & Physical
        data.append(contentsOf: [sequence, 0x00])
        // Universe (15-bit Port-Address, Little Endian)
        data.append(UInt8(universe & 0xFF))
        data.append(UInt8((universe >> 8) & 0x7F))
        // Length: 512 channels (Big Endian: 0x02, 0x00)
        data.append(contentsOf: [0x02, 0x00])
        // DMX Channel Data (padded to 512)
        var clampedChannels = channels
        if clampedChannels.count < 512 {
            clampedChannels.append(contentsOf: repeatElement(0, count: 512 - clampedChannels.count))
        } else if clampedChannels.count > 512 {
            clampedChannels = Array(clampedChannels.prefix(512))
        }
        data.append(contentsOf: clampedChannels)
        return data
    }
}

struct SACNPacketBuilder: DMXPacketBuilder {
    static let senderCID: [UInt8] = [
        0x42, 0x42, 0x4D, 0x41, 0x4E, 0x41, 0x47, 0x45,
        0x52, 0x2D, 0x53, 0x41, 0x43, 0x4E, 0x30, 0x31
    ]

    static func buildDMXPacket(universe: UInt16, channels: [UInt8], sequence: UInt8 = 0) -> Data {
        buildDMXPacket(universe: universe, priority: 100, channels: channels, sequence: sequence)
    }

    static func buildDMXPacket(universe: UInt16, priority: UInt8 = 100, channels: [UInt8], sequence: UInt8 = 0, sourceName: String = "BitchManager Pro Show Control") -> Data {
        var data = Data()
        // Root Layer (38 bytes)
        data.append(contentsOf: [0x00, 0x10]) // Preamble size (16)
        data.append(contentsOf: [0x00, 0x00]) // Postamble size (0)
        // ACN Packet Identifier: "ASC-E1.17\0\0\0"
        data.append(contentsOf: [0x41, 0x53, 0x43, 0x2D, 0x45, 0x31, 0x2E, 0x31, 0x37, 0x00, 0x00, 0x00])
        // Flags and Length: 0x7000 | (638 - 16) = 0x726E
        data.append(contentsOf: [0x72, 0x6E])
        // Root Vector: VECTOR_ROOT_E131_DATA (0x00000004)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x04])
        // CID (16 bytes)
        data.append(contentsOf: senderCID)

        // Framing Layer (77 bytes)
        // Flags and Length: 0x7000 | (638 - 38) = 0x7258
        data.append(contentsOf: [0x72, 0x58])
        // Framing Vector: VECTOR_E131_DATA_PACKET (0x00000002)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x02])
        // Source Name: 64 bytes null-padded
        var nameData = Data(sourceName.utf8.prefix(63))
        nameData.append(contentsOf: repeatElement(0, count: 64 - nameData.count))
        data.append(nameData)
        // Priority
        data.append(priority)
        // Sync Address (0)
        data.append(contentsOf: [0x00, 0x00])
        // Sequence Number
        data.append(sequence)
        // Options (0)
        data.append(0x00)
        // Universe (16-bit Big Endian)
        data.append(UInt8((universe >> 8) & 0xFF))
        data.append(UInt8(universe & 0xFF))

        // DMP Layer (523 bytes)
        // Flags and Length: 0x7000 | (638 - 115) = 0x720B
        data.append(contentsOf: [0x72, 0x0B])
        // DMP Vector: VECTOR_DMP_SET_PROPERTY (0x02)
        data.append(0x02)
        // Address Type & Data Type: 0xA1
        data.append(0xA1)
        // First Property Address: 0x0000
        data.append(contentsOf: [0x00, 0x00])
        // Address Increment: 0x0001
        data.append(contentsOf: [0x00, 0x01])
        // Property Value Count: 513 (0x0201: 1 start code + 512 DMX slots)
        data.append(contentsOf: [0x02, 0x01])
        // DMX Start Code: 0x00
        data.append(0x00)

        // 512 DMX Slots
        var clampedChannels = channels
        if clampedChannels.count < 512 {
            clampedChannels.append(contentsOf: repeatElement(0, count: 512 - clampedChannels.count))
        } else if clampedChannels.count > 512 {
            clampedChannels = Array(clampedChannels.prefix(512))
        }
        data.append(contentsOf: clampedChannels)
        return data
    }
}

struct OSCPacketBuilder {
    static func buildMessage(address: String, argType: OSCArgumentType, argValue: String) -> Data {
        buildMessage(address: address, argType: argType.rawValue, argValue: argValue)
    }

    static func buildMessage(address: String, argType: String, argValue: String) -> Data {
        var data = Data()
        // Address with 4-byte padding
        var addrData = Data(address.utf8)
        addrData.append(0) // Null terminator
        let addrPad = (4 - (addrData.count % 4)) % 4
        addrData.append(contentsOf: repeatElement(0, count: addrPad))
        data.append(addrData)

        switch argType {
        case "FLOAT":
            var tagData = Data(",f\0".utf8)
            let tagPad = (4 - (tagData.count % 4)) % 4
            tagData.append(contentsOf: repeatElement(0, count: tagPad))
            data.append(tagData)
            let fVal = Float(argValue) ?? 1.0
            var bigEndian = fVal.bitPattern.bigEndian
            data.append(Data(bytes: &bigEndian, count: 4))
        case "INT":
            var tagData = Data(",i\0".utf8)
            let tagPad = (4 - (tagData.count % 4)) % 4
            tagData.append(contentsOf: repeatElement(0, count: tagPad))
            data.append(tagData)
            let iVal = Int32(argValue) ?? 1
            var bigEndian = iVal.bigEndian
            data.append(Data(bytes: &bigEndian, count: 4))
        case "STRING":
            var tagData = Data(",s\0".utf8)
            let tagPad = (4 - (tagData.count % 4)) % 4
            tagData.append(contentsOf: repeatElement(0, count: tagPad))
            data.append(tagData)
            var strData = Data(argValue.utf8)
            strData.append(0)
            let strPad = (4 - (strData.count % 4)) % 4
            strData.append(contentsOf: repeatElement(0, count: strPad))
            data.append(strData)
        case "BOOLEAN_TRUE":
            var tagData = Data(",T\0".utf8)
            let tagPad = (4 - (tagData.count % 4)) % 4
            tagData.append(contentsOf: repeatElement(0, count: tagPad))
            data.append(tagData)
        case "BOOLEAN_FALSE":
            var tagData = Data(",F\0".utf8)
            let tagPad = (4 - (tagData.count % 4)) % 4
            tagData.append(contentsOf: repeatElement(0, count: tagPad))
            data.append(tagData)
        default: // NONE / BANG
            let tagData = Data(",\0\0\0".utf8)
            data.append(tagData)
        }
        return data
    }
}

// --- MIDI ROUTER & TRANSFORMER MODELS ---
struct MIDIOutputTarget: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let endpoint: MIDIEndpointRef
    let isHardwareBitchBoy: Bool
}

enum MIDIVelocityCurve: String, CaseIterable, Codable, Identifiable {
    case linear = "LINEAR"
    case soft = "SOFT"
    case hard = "HARD"
    case fixed127 = "MAX 127"

    var id: String { rawValue }

    func transform(_ v: UInt8) -> UInt8 {
        guard v > 0 else { return 0 }
        let norm = Double(v) / 127.0
        switch self {
        case .linear:
            return v
        case .soft:
            return UInt8(clamping: Int(round(pow(norm, 1.65) * 127.0)))
        case .hard:
            return UInt8(clamping: Int(round(pow(norm, 0.55) * 127.0)))
        case .fixed127:
            return 127
        }
    }
}

// --- GROUND-UP CUSTOM LIGHTING FX STUDIO MODELS ---
enum CustomFXLoopMode: String, CaseIterable, Codable, Identifiable {
    case loop = "LOOP"
    case pingPong = "BOUNCE"
    case oneShot = "1-SHOT"
    var id: String { rawValue }
}

enum CustomWaveShape: String, CaseIterable, Codable, Identifiable {
    case sine = "SINE WAVE"
    case sawtooth = "SAWTOOTH"
    case triangle = "TRIANGLE"
    case square = "SQUARE PULSE"
    case radial = "RADIAL RING"
    case spiral = "SPIRAL VORTEX"
    case sparkle = "NOISE SPARK"
    var id: String { rawValue }
}

enum CustomWaveDirection: String, CaseIterable, Codable, Identifiable {
    case leftToRight = "LEFT → RIGHT"
    case topToBottom = "TOP → BOTTOM"
    case diagonal = "DIAGONAL 45°"
    case centerOut = "CENTER → OUT"
    case outerIn = "OUTER → CENTER"
    var id: String { rawValue }
}

struct CustomLightEffect: Codable, Identifiable {
    var id = UUID()
    var name: String
    var isProcedural: Bool = false
    var frames: [[UInt8]] // Each frame is 49 UInt8 velocities (0..127)
    var fps: Double = 10.0
    var loopMode: CustomFXLoopMode = .loop

    // Procedural Wave Synth Parameters
    var waveShape: CustomWaveShape = .sine
    var waveDirection: CustomWaveDirection = .leftToRight
    var waveFrequency: Double = 1.0
    var minVelocity: UInt8 = 0
    var maxVelocity: UInt8 = 78

    static func emptyFrame(fill: UInt8 = 0) -> [UInt8] {
        Array(repeating: fill, count: 49)
    }

    static func buildDefaultConnectEffect() -> CustomLightEffect {
        // 10-Frame 1-Shot Hardware Connection Celebration Sweep + Checkmark Flash
        var frames: [[UInt8]] = []
        let sweepPalette: [UInt8] = [78, 87, 74, 57, 41, 67, 3]
        // Frames 0..5: Expanding neon ignition ring across all 11 columns & 3x3 keypad
        for step in 0..<6 {
            var f = emptyFrame(fill: 0)
            let targetColLeft = step * 2
            let targetColRight = 10 - step * 2
            for k in 0..<49 {
                let p = BitchBoyKeyMap.keyPositions[k]
                if abs(p.col - targetColLeft) <= 1 || abs(p.col - targetColRight) <= 1 {
                    f[k] = sweepPalette[(step + p.row) % sweepPalette.count]
                }
            }
            frames.append(f)
        }
        // Frame 6: Full green online confirmation flash
        frames.append(emptyFrame(fill: 87))
        // Frame 7: Brief blackout pulse
        frames.append(emptyFrame(fill: 0))
        // Frame 8: Cyber cyan + amber crown burst
        var burst = emptyFrame(fill: 78)
        for k in 40..<49 { burst[k] = 96 } // 3x3 keypad in amber
        frames.append(burst)
        // Frame 9: Final crisp white strobe before restoring user preset
        frames.append(emptyFrame(fill: 3))

        return CustomLightEffect(
            name: "BITCHBOY CONNECT IGNITION",
            isProcedural: false,
            frames: frames,
            fps: 14.0,
            loopMode: .oneShot
        )
    }

    static func buildStarterEffects() -> [CustomLightEffect] {
        let connectFX = buildDefaultConnectEffect()

        // 1. Neon Heart Icon Pulse (4 frames)
        var heartF1 = emptyFrame(fill: 0)
        var heartF2 = emptyFrame(fill: 0)
        let heartCoords: [(Int, Int)] = [
            (2,0), (3,0), (5,0), (6,0),
            (1,1), (2,1), (3,1), (4,1), (5,1), (6,1), (7,1),
            (2,2), (3,2), (4,2), (5,2), (6,2),
            (3,3), (4,3), (5,3),
            (4,4)
        ]
        for (k, pos) in BitchBoyKeyMap.keyPositions.enumerated() {
            if heartCoords.contains(where: { $0.0 == pos.col && $0.1 == pos.row }) {
                heartF1[k] = 57 // Pink
                heartF2[k] = 72 // Red
            }
        }
        let heartEffect = CustomLightEffect(
            name: "NEON HEART PULSE",
            isProcedural: false,
            frames: [heartF1, heartF2, heartF1, emptyFrame(fill: 0)],
            fps: 5.0,
            loopMode: .loop
        )

        // 2. X-Matrix Cross Flash (6 frames)
        var xFrames: [[UInt8]] = []
        let pal: [UInt8] = [78, 41, 67, 57, 74, 87]
        for step in 0..<6 {
            var f = emptyFrame(fill: 0)
            for k in 0..<49 {
                let p = BitchBoyKeyMap.keyPositions[k]
                if (p.col + p.row + step) % 3 == 0 || (p.col - p.row + 10 + step) % 3 == 0 {
                    f[k] = pal[(step + p.col) % pal.count]
                }
            }
            xFrames.append(f)
        }
        let xEffect = CustomLightEffect(
            name: "CYBER CROSS CHASE",
            isProcedural: false,
            frames: xFrames,
            fps: 8.0,
            loopMode: .pingPong
        )

        // 3. Scrolling Neon Bar (11 frames across all 11 columns)
        var barFrames: [[UInt8]] = []
        let barColors: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 57, 3]
        for c in 0..<11 {
            var f = emptyFrame(fill: 0)
            for k in 0..<49 {
                let col = BitchBoyKeyMap.keyPositions[k].col
                if col == c {
                    f[k] = barColors[c]
                } else if abs(col - c) == 1 {
                    f[k] = 61 // Orange ambient glow
                }
            }
            barFrames.append(f)
        }
        let barEffect = CustomLightEffect(
            name: "11-COL LASER SWEEP",
            isProcedural: false,
            frames: barFrames,
            fps: 14.0,
            loopMode: .pingPong
        )

        // 4. Procedural Radial Synth Wave
        let synthEffect = CustomLightEffect(
            name: "RADIAL HYPERSPACE",
            isProcedural: true,
            frames: [emptyFrame(fill: 78)],
            fps: 15.0,
            loopMode: .loop,
            waveShape: .radial,
            waveDirection: .centerOut,
            waveFrequency: 1.4,
            minVelocity: 0,
            maxVelocity: 78
        )

        return [connectFX, heartEffect, xEffect, barEffect, synthEffect]
    }
}

// --- REACTIVE MECHANICAL KEYBOARD INTERACTIVE FX MODELS ---
enum ReactiveKeyFXMode: String, CaseIterable, Codable, Identifiable {
    case ripple = "RIPPLE RING"
    case crossLaser = "LASER CROSS"
    case supernova = "SUPERNOVA"
    case heatTrail = "HEAT TRAIL"
    case meteorRain = "METEOR DROP"
    case arcLightning = "ARC LIGHTNING"
    case off = "OFF"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ripple: return "dot.radiowaves.left.and.right"
        case .crossLaser: return "scope"
        case .supernova: return "sun.max.fill"
        case .heatTrail: return "flame.fill"
        case .meteorRain: return "cloud.bolt.rain.fill"
        case .arcLightning: return "bolt.fill"
        case .off: return "poweroff"
        }
    }
}

struct ReactivePulseEvent: Identifiable {
    let id = UUID()
    let originKeyIndex: Int
    let originCol: Double
    let originRow: Double
    let mode: ReactiveKeyFXMode
    let baseVelocity: UInt8
    var age: Double = 0.0 // 0.0 -> 1.0+
    var lightningTargets: Set<Int> = []
}

struct PresetSlot: Codable, Identifiable {
    var id = UUID()
    var name: String
    var controls: [ControlItem]
    var globalRules: String = ""
    var iconName: String = "dial.medium.fill"
    var accentVelocity: UInt8 = 78

    init(
        id: UUID = UUID(),
        name: String,
        controls: [ControlItem],
        globalRules: String = "",
        iconName: String = "dial.medium.fill",
        accentVelocity: UInt8 = 78
    ) {
        self.id = id
        self.name = name
        self.controls = controls
        self.globalRules = globalRules
        self.iconName = iconName
        self.accentVelocity = accentVelocity
    }

    enum CodingKeys: String, CodingKey {
        case id, name, controls, globalRules, iconName, accentVelocity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        controls = try c.decode([ControlItem].self, forKey: .controls)
        globalRules = (try? c.decode(String.self, forKey: .globalRules)) ?? ""
        iconName = (try? c.decode(String.self, forKey: .iconName)) ?? "dial.medium.fill"
        accentVelocity = (try? c.decode(UInt8.self, forKey: .accentVelocity)) ?? 78
    }
}

// MARK: - CoreMIDI Background C-Callback Factories (Strictly Nonisolated)
// CoreMIDI invokes packet read and notify blocks on high-priority real-time background threads (e.g. MIDIInPortThread).
// These factory functions are declared outside @MainActor so that the C-blocks do NOT inherit @MainActor isolation,
// preventing runtime assertion failures (_dispatch_assert_queue_fail) in libdispatch when MIDI events arrive.
private func makeCoreMIDINotifyBlock(for engine: BitchBoyEngine) -> MIDINotifyBlock {
    return { [weak engine] notifyPtr in
        let msg = notifyPtr.pointee
        switch msg.messageID {
        case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged:
            Task { @MainActor [weak engine] in
                engine?.scanForBitchBoy()
            }
        default:
            break
        }
    }
}

private func makeCoreMIDIReceiveBlock(for engine: BitchBoyEngine) -> MIDIReceiveBlock {
    return { [weak engine] eventList, _ in
        let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet) ?? 8
        var curPacketPtr = UnsafeMutableRawPointer(mutating: UnsafeRawPointer(eventList)).advanced(by: packetOffset).assumingMemoryBound(to: MIDIEventPacket.self)
        for _ in 0..<eventList.pointee.numPackets {
            let curPacket = curPacketPtr.pointee
            let w0 = curPacket.words.0
            let msgType = (w0 >> 28) & 0x0F
            let statusByte = UInt8((w0 >> 16) & 0xFF)
            let data1 = UInt8((w0 >> 8) & 0xFF)
            let data2 = UInt8(w0 & 0xFF)

            if msgType == 0x3 {
                // SysEx 7-bit UMP packet
                let byteCount = min(6, Int((w0 >> 16) & 0x0F))
                let w1 = curPacket.words.1
                let rawBytes: [UInt8] = [
                    UInt8((w0 >> 8) & 0xFF),
                    UInt8(w0 & 0xFF),
                    UInt8((w1 >> 24) & 0xFF),
                    UInt8((w1 >> 16) & 0xFF),
                    UInt8((w1 >> 8) & 0xFF),
                    UInt8(w1 & 0xFF)
                ]
                let slice = Array(rawBytes.prefix(byteCount))
                Task { @MainActor [weak engine] in
                    engine?.handleIncomingSysExBytes(slice)
                }
            } else if msgType == 0x2 || statusByte >= 0x80 {
                Task { @MainActor [weak engine] in
                    engine?.handleMIDIMessage(status: statusByte, data1: data1, data2: data2)
                }
            }

            curPacketPtr = MIDIEventPacketNext(curPacketPtr)
        }
    }
}

private func makeCoreMIDIVirtualInBlock(for engine: BitchBoyEngine) -> MIDIReadBlock {
    return { [weak engine] packetList, _ in
        let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet) ?? 4
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data) ?? 12
        var curPacketPtr = UnsafeMutableRawPointer(mutating: UnsafeRawPointer(packetList)).advanced(by: packetOffset).assumingMemoryBound(to: MIDIPacket.self)
        for _ in 0..<packetList.pointee.numPackets {
            let curPacket = curPacketPtr.pointee
            let length = Int(curPacket.length)
            if length >= 3 {
                let bytesPtr = UnsafeRawPointer(curPacketPtr).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
                if bytesPtr[0] == 0xF0 {
                    let sysEx = Array(UnsafeBufferPointer(start: bytesPtr, count: length))
                    Task { @MainActor [weak engine] in
                        engine?.handleIncomingSysExBytes(sysEx)
                    }
                } else {
                    let statusByte = bytesPtr[0]
                    let data1 = bytesPtr[1]
                    let data2 = bytesPtr[2]
                    Task { @MainActor [weak engine] in
                        engine?.handleInboundExternalMIDI(status: statusByte, data1: data1, data2: data2)
                    }
                }
            }
            curPacketPtr = MIDIPacketNext(curPacketPtr)
        }
    }
}

// ============================================================================
// 2. HARDWARE ENGINE // COREMIDI & TELEMETRY
// ============================================================================

@MainActor
@Observable
final class BitchBoyEngine {
    @ObservationIgnored private var lastStreamUpdateTime: Double = 0
    var controls: [ControlItem] = []
    var selectedIndex: Int = 0
    var selectedIndices: Set<Int> = []
    var slots: [PresetSlot] = []
    var activeSlot: Int = 0

    // Hardware status
    var isConnected: Bool = false
    var deviceName: String = "BitchBoy V1 (Hardware)"
    var lastStreamMessage: String = "IDLE // READY"
    var midiLogs: [String] = []

    // Customization & Themes
    var currentTheme: ChassisTheme = .petrolTeal
    var ledPalette: LEDPaletteMode = .multiVelocity
    var soundPack: SoundPack = .arcade8Bit
    var currentFXMode: LEDFXMode = .staticFX
    var fxSpeed: Double = 1.0
    var vuMeterLEDsEnabled: Bool = false
    var isRainbowRunning: Bool = false

    // Mascot
    var mascotScale: CGFloat = 1.0
    var mascotSpeech: String = "ALL 69 HARDWARE CONTROLS LIVE!"
    var mascotSpeechVisible: Bool = false

    // In-Chassis Drawer
    var inChassisTab: String = "NOTES"
    var userNotesText: String = "Show notes: Slot A configured for live Ableton clip triggers."

    // CoreMIDI internals
    @ObservationIgnored private var midiClient = MIDIClientRef()
    @ObservationIgnored private var inputPort = MIDIPortRef()
    @ObservationIgnored private var outputPort = MIDIPortRef()
    @ObservationIgnored private var bitchBoyDestination: MIDIEndpointRef = 0

    @ObservationIgnored private var fxTimer: AnyCancellable?
    @ObservationIgnored private var watchdogTimer: AnyCancellable?
    // --- LEFT WING: MIDI ROUTER & OUTPUT MATRIX STATE ---
    var leftWingTab: String = "ROUTER" // "ROUTER", "TELEMETRY", "MACROS"
    var midiThruEnabled: Bool = true
    var virtualOutEnabled: Bool = true
    var forwardUIInteractions: Bool = true
    var forwardNotes: Bool = true
    var forwardCCs: Bool = true
    var remapChannel: Int = 0 // 0 = Original Ch 1, 1..16 = Forced Ch 1..16
    var transposeSemitones: Int = 0 // -24 .. +24
    var velocityCurve: MIDIVelocityCurve = .linear
    var availableOutputTargets: [MIDIOutputTarget] = []
    var selectedOutputNames: Set<String> = []
    var txPacketCount: Int = 0
    var lastRoutedMessage: String = "READY // NO TX YET"
    var routerPacketHistory: [String] = []
    var tapTempoBPM: Double = 120.0
    @ObservationIgnored private var lastTapTimes: [Date] = []
    @ObservationIgnored private var virtualSourceEndpoint = MIDIEndpointRef()
    @ObservationIgnored private var virtualDestinationEndpoint = MIDIEndpointRef()

    // --- PRO SHOW CONTROL: MSC, OSC, ART-NET & sACN BROADCAST STATE ---
    var mscBroadcastEnabled: Bool = true
    var mscDeviceID: UInt8 = 1
    var mscCommandFormat: MSCCommandFormat = .allTypes
    var mscCueNumber: String = "1.0"
    var mscCueList: String = ""
    var mscAutoTriggerOnInbound: Bool = true
    var mscLogHistory: [MSCMessage] = []
    @ObservationIgnored private var inboundSysExBuffer: [UInt8] = []

    // Custom OSC Transmitter
    var customOSCHost: String = "127.0.0.1"
    var customOSCPort: UInt16 = 53000 // Default QLab / DAW port
    var customOSCAddress: String = "/cue/selected/start"
    var customOSCArgType: String = "NONE" // NONE, FLOAT, INT, STRING, BOOLEAN_TRUE, BOOLEAN_FALSE
    var customOSCArgValue: String = "1.0"

    // Art-Net 4 Transmitter
    var artNetHost: String = "127.0.0.1"
    var artNetPort: UInt16 = 6454
    var artNetUniverse: UInt16 = 0
    var artNetChannels: [UInt8] = Array(repeating: 0, count: 512)
    var artNetSequence: UInt8 = 0
    var artNetMirrorLEDs: Bool = false

    // ANSI E1.31 sACN Transmitter
    var sacnHost: String = "" // Empty = standard Multicast 239.255.x.y
    var sacnPort: UInt16 = 5568
    var sacnUniverse: UInt16 = 1
    var sacnPriority: UInt8 = 100
    var sacnChannels: [UInt8] = Array(repeating: 0, count: 512)
    var sacnSequence: UInt8 = 0

    // Customizable Show Control & MIDI Feedback Engine
    var hardwareFeedbackEnabled: Bool = true
    var inboundMIDIEchoEnabled: Bool = true
    var showControlSubTab: String = "OSC" // "OSC", "MSC", "ARTNET", "SACN", "FEEDBACK"
    var oscStudioMode: String = "MAPPINGS" // "MAPPINGS", "TRANSMITTER"
    var oscHardwareBroadcastEnabled: Bool = false
    var artNetMirrorHardwareFaders: Bool = false
    var grandMasterLevel: Double = 1.0
    var isBlackoutActive: Bool = false

    // --- MIDI TO OSC CUSTOMIZATION MATRIX ---
    var midiToOSCMappingActive: Bool = true
    var midiToOSCFilter: String = "ALL" // "ALL", "GRID", "STRIP", "PAD", "VFADERS", "HFADERS", "MASTER_KNOBS"
    var midiToOSCSearchText: String = ""

    // --- RIGHT WING: CUSTOM LIGHTING FX STUDIO STATE ---
    var rightWingTab: String = "SEQUENCER" // "SEQUENCER", "WAVESYNTH", "LIBRARY"
    var customEffects: [CustomLightEffect] = []
    var editingCustomFX: CustomLightEffect = CustomLightEffect.buildStarterEffects()[0]
    var editingFrameIndex: Int = 0
    var customBrushVelocity: UInt8 = 78
    var paintOnMainChassis: Bool = false
    var isPlayingCustomFX: Bool = false
    var activeCustomFXName: String = ""
    @ObservationIgnored private var customFXStep: Int = 0
    @ObservationIgnored private var customFXDirection: Int = 1

    // --- RIGHT WING BOTTOM: REACTIVE MECHANICAL KEYBOARD FX ENGINE STATE ---
    var reactiveKeyFXMode: ReactiveKeyFXMode = .ripple
    var reactiveFXSpeed: Double = 1.4
    var reactiveFXColorVelocity: UInt8 = 78 // 0 = Rainbow Dynamic, >0 = Specific Neon Color
    var reactiveFXRainbowColor: Bool = true
    var reactiveWaveCount: Int = 0
    private(set) var activeReactivePulses: [ReactivePulseEvent] = []
    @ObservationIgnored private var lastReactiveOriginKey: Int = -1
    @ObservationIgnored private var reactiveFXTimer: DispatchSourceTimer?
    @ObservationIgnored private var lastSentReactiveLEDs: [UInt8] = Array(repeating: 255, count: 49)

    // --- COPY / PASTE CLIPBOARD ENGINE ---
    var copiedControlConfig: ControlClipboardData? = nil
    var copiedColorVelocity: UInt8? = nil
    var copiedFXFrame: [UInt8]? = nil
    var hasCopiedConfig: Bool { copiedControlConfig != nil || NSPasteboard.general.string(forType: .string)?.contains("feedbackMode") == true }
    var hasCopiedColor: Bool { copiedColorVelocity != nil }
    var hasCopiedFXFrame: Bool { copiedFXFrame != nil }

    // --- UNDO / REDO MEMORY ENGINE ---
    private var undoStack: [UndoSnapshot] = []
    private var redoStack: [UndoSnapshot] = []
    var undoStepsCount: Int = 0
    var redoStepsCount: Int = 0
    var maxUndoSteps: Int = 100
    var lastUndoActionName: String = ""
    var lastRedoActionName: String = ""
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // --- TOAST NOTIFICATION BANNER ENGINE ---
    var toastNotification: ToastNotificationItem? = nil
    @ObservationIgnored private var toastDismissTask: DispatchWorkItem? = nil

    // --- 120 FPS PROMOTION HIGH REFRESH RATE & TELEMETRY ---
    var targetFPS: Int = 120
    var measuredFPS: Double = 120.0
    var frameLatencyMs: Double = 8.3
    @ObservationIgnored private var lastFrameTimestamp: Double = 0
    @ObservationIgnored private var frameCountSinceLastMeasure: Int = 0
    @ObservationIgnored private var lastFPSMeasureTimestamp: Double = 0
    @ObservationIgnored private var lastHardwareMIDISendTime: Double = 0

    // --- UI SCALING / ZOOM & CUSTOM APP ICON STATE ---
    // --- ALWAYS ON TOP (FLOATING WINDOW) STATE ---
    var isWindowAlwaysOnTop: Bool = false
    private let alwaysOnTopStorageKey = "BitchBoy_AlwaysOnTop_v1"

    var uiScale: CGFloat = 1.15
    var autoFitWindow: Bool = true
    var lastComputedFitScale: CGFloat = 1.0
    private let uiScaleStorageKey = "BitchBoy_UIScale_v1"
    private let uiAutoFitStorageKey = "BitchBoy_UIAutoFit_v1"

    private let customFXStorageKey = "BitchBoy_CustomLightFX_v1"
    private let connectFXEnabledStorageKey = "BitchBoy_ConnectFXEnabled_v1"
    private let connectFXNameStorageKey = "BitchBoy_ConnectFXName_v1"

    // --- ON-CONNECT BITCHBOY HARDWARE NOTIFICATION & CUSTOM FX STATE ---
    var connectEffectEnabled: Bool = true
    var connectCustomFXName: String = "BITCHBOY CONNECT IGNITION"
    var showConnectionBanner: Bool = false
    var connectionBannerTitle: String = "🔌 BITCHBOY CONTROLLER CONNECTED & READY"
    var connectionBannerSubtitle: String = "Hardware Recognized // Playing On-Connect FX"

    // --- CUSTOM SOUND UPLOAD STUDIO & MODULE WINDOW / SPOTLIGHT / REARRANGE STATE ---
    var showCustomSoundStudio: Bool = false
    var customSoundUpdateToken: Int = 0
    var spotlightModule: StudioModuleID? = nil
    var moduleOrder: [StudioModuleID] = [.showControl, .memorySlots, .midiRouter, .customFXStudio, .reactiveKeyFX, .terminal, .hardwareMIDIFilter]
    var isRearrangingModules: Bool = false
    var draggingModule: StudioModuleID? = nil
    var detachedModules: Set<StudioModuleID> = []
    @ObservationIgnored fileprivate var moduleWindows: [StudioModuleID: NSWindow] = [:]
    @ObservationIgnored fileprivate var moduleWindowDelegates: [StudioModuleID: ModuleWindowCloseDelegate] = [:]
    var pinnedModuleWindows: Set<StudioModuleID> = []
    private let moduleOrderStorageKey = "BitchBoy_ModuleOrder_v1"
    private let soundPackStorageKey = "BitchBoy_SoundPack_v1"

    // --- HARDWARE MIDI I/O & MUTE CONTROL ENGINE ---
    var hardwareMIDISendEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(hardwareMIDISendEnabled, forKey: "bb_hw_midi_send_enabled")
            if hardwareMIDISendEnabled {
                hardwareInputActionsEnabled = true
            }
        }
    }
    var hardwareInputActionsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(hardwareInputActionsEnabled, forKey: "bb_hw_input_actions_enabled") }
    }
    var qwertyKeybindsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(qwertyKeybindsEnabled, forKey: "bb_hw_qwerty_enabled") }
    }
    var keyGridMIDISendEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(keyGridMIDISendEnabled, forKey: "bb_keygrid_midi_send")
            setSectionBlackout(section: "keyGrid", enabled: keyGridMIDISendEnabled)
            if keyGridMIDISendEnabled { hardwareInputActionsEnabled = true }
        }
    }
    var keyStripMIDISendEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(keyStripMIDISendEnabled, forKey: "bb_keystrip_midi_send")
            setSectionBlackout(section: "keyStrip", enabled: keyStripMIDISendEnabled)
            if keyStripMIDISendEnabled { hardwareInputActionsEnabled = true }
        }
    }
    var keypadMIDISendEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(keypadMIDISendEnabled, forKey: "bb_keypad_midi_send")
            setSectionBlackout(section: "keypad", enabled: keypadMIDISendEnabled)
            if keypadMIDISendEnabled { hardwareInputActionsEnabled = true }
        }
    }
    var verticalFadersMIDISendEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(verticalFadersMIDISendEnabled, forKey: "bb_vfaders_midi_send")
            if verticalFadersMIDISendEnabled { hardwareInputActionsEnabled = true }
        }
    }
    var horizontalFadersMIDISendEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(horizontalFadersMIDISendEnabled, forKey: "bb_hfaders_midi_send")
            if horizontalFadersMIDISendEnabled { hardwareInputActionsEnabled = true }
        }
    }
    var rotaryKnobsMIDISendEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(rotaryKnobsMIDISendEnabled, forKey: "bb_knobs_midi_send")
            if rotaryKnobsMIDISendEnabled { hardwareInputActionsEnabled = true }
        }
    }

    func isSectionEnabled(for index: Int) -> Bool {
        guard let section = HardwareSection.section(for: index) else { return true }
        switch section {
        case .grid8x4: return keyGridMIDISendEnabled
        case .strip1x8: return keyStripMIDISendEnabled
        case .keypad3x3: return keypadMIDISendEnabled
        case .verticalFaders: return verticalFadersMIDISendEnabled
        case .horizontalFaders: return horizontalFadersMIDISendEnabled
        case .rotaryKnobs: return rotaryKnobsMIDISendEnabled
        }
    }

    func controlIndex(forNote note: UInt8) -> Int? {
        if note < 128 {
            let idx = BitchBoyKeyMap.noteToIndex[Int(note)]
            if idx >= 0 { return idx }
        }
        return controls.firstIndex(where: { $0.kind == .key && $0.number == note })
    }

    func controlIndex(forCC cc: UInt8) -> Int? {
        if cc < 128 {
            let idx = BitchBoyKeyMap.ccToIndex[Int(cc)]
            if idx >= 0 { return idx }
        }
        return controls.firstIndex(where: { ($0.kind == .vfader || $0.kind == .hfader || $0.kind == .knob) && $0.number == cc })
    }

    func setSectionBlackout(section: HardwareSection, enabled: Bool) {
        setSectionBlackout(section: section.rawValue, enabled: enabled)
    }

    func setSectionBlackout(section: String, enabled: Bool) {
        let indices: [Int]
        switch section {
        case "keyGrid", HardwareSection.grid8x4.rawValue:
            indices = Array(HardwareSection.grid8x4.indexRange)
        case "keyStrip", HardwareSection.strip1x8.rawValue:
            indices = Array(HardwareSection.strip1x8.indexRange)
        case "keypad", HardwareSection.keypad3x3.rawValue:
            indices = Array(HardwareSection.keypad3x3.indexRange)
        case "all":
            indices = Array(0..<49)
        default:
            indices = []
        }

        var batch: [(note: UInt8, velocity: UInt8)] = []
        for idx in indices where idx < controls.count {
            if !enabled {
                controls[idx].currentLED = 0
                controls[idx].isPressed = false
                batch.append((note: controls[idx].number, velocity: 0))
            } else {
                let restoreVel: UInt8
                switch controls[idx].feedbackMode {
                case .toggle:
                    restoreVel = controls[idx].toggleLatched ? controls[idx].activeVelocity : controls[idx].idleVelocity
                case .disabled:
                    restoreVel = 0
                default:
                    restoreVel = controls[idx].idleVelocity
                }
                controls[idx].currentLED = restoreVel
                controls[idx].isPressed = false
                batch.append((note: controls[idx].number, velocity: restoreVel))
            }
        }
        if !batch.isEmpty {
            sendBatchNoteOn(notesAndVelocities: batch)
        }
    }
    var hardwareLEDSyncEnabled: Bool = true {
        didSet { UserDefaults.standard.set(hardwareLEDSyncEnabled, forKey: "bb_hw_led_sync_enabled") }
    }
    var oscSendEnabled: Bool = true {
        didSet { UserDefaults.standard.set(oscSendEnabled, forKey: "bb_osc_send_enabled") }
    }
    var artNetSendEnabled: Bool = true {
        didSet { UserDefaults.standard.set(artNetSendEnabled, forKey: "bb_artnet_send_enabled") }
    }
    var sacnSendEnabled: Bool = true {
        didSet { UserDefaults.standard.set(sacnSendEnabled, forKey: "bb_sacn_send_enabled") }
    }
    var uiClickSoundEnabled: Bool = true {
        didSet { UserDefaults.standard.set(uiClickSoundEnabled, forKey: "bb_ui_click_sound") }
    }
    var blockedMIDIPacketsCount: Int = 0
    var routedMIDIPacketsCount: Int = 0

    // High performance throttling timestamps for sub-millisecond smooth animations & gesture tracking
    @ObservationIgnored var lastStreamMessageUpdateTime: Date = Date.distantPast
    @ObservationIgnored var lastRoutedMessageUpdateTime: Date = Date.distantPast
    @ObservationIgnored var lastProtocolEventLogTime: Date = Date.distantPast

    func applyProfileHotkeysOnly() {
        hardwareMIDISendEnabled = false
        qwertyKeybindsEnabled = true
        hardwareInputActionsEnabled = true
        keyGridMIDISendEnabled = true
        keyStripMIDISendEnabled = true
        keypadMIDISendEnabled = true
        verticalFadersMIDISendEnabled = true
        horizontalFadersMIDISendEnabled = true
        rotaryKnobsMIDISendEnabled = true
        setSectionBlackout(section: "all", enabled: true)
        SoundEffect.keyTap.play(with: soundPack)
        log("⌨️ Switched Profile: HOTKEYS ONLY (MIDI Muted - No Keybind Conflicts)")
    }

    func applyProfileDAWMIDIOnly() {
        hardwareMIDISendEnabled = true
        qwertyKeybindsEnabled = false
        hardwareInputActionsEnabled = true
        keyGridMIDISendEnabled = true
        keyStripMIDISendEnabled = true
        keypadMIDISendEnabled = true
        verticalFadersMIDISendEnabled = true
        horizontalFadersMIDISendEnabled = true
        rotaryKnobsMIDISendEnabled = true
        setSectionBlackout(section: "all", enabled: true)
        SoundEffect.knobTick.play(with: soundPack)
        log("🎹 Switched Profile: DAW / MIDI ONLY (Hotkeys Muted)")
    }

    func applyProfileHybrid() {
        hardwareMIDISendEnabled = true
        qwertyKeybindsEnabled = true
        hardwareInputActionsEnabled = true
        keyGridMIDISendEnabled = true
        keyStripMIDISendEnabled = true
        keypadMIDISendEnabled = true
        verticalFadersMIDISendEnabled = true
        horizontalFadersMIDISendEnabled = true
        rotaryKnobsMIDISendEnabled = true
        setSectionBlackout(section: "all", enabled: true)
        SoundEffect.knobTick.play(with: soundPack)
        log("⚡️ Switched Profile: HYBRID (All MIDI & Hotkeys Active)")
    }

    func applyProfilePanicMute() {
        hardwareMIDISendEnabled = false
        qwertyKeybindsEnabled = false
        hardwareInputActionsEnabled = false
        keyGridMIDISendEnabled = false
        keyStripMIDISendEnabled = false
        keypadMIDISendEnabled = false
        verticalFadersMIDISendEnabled = false
        horizontalFadersMIDISendEnabled = false
        rotaryKnobsMIDISendEnabled = false
        setSectionBlackout(section: "all", enabled: false)
        SoundEffect.keyTap.play(with: soundPack)
        log("🛑 Switched Profile: PANIC MUTE (All Hardware Out Muted & Blacked Out)")
    }

    func unmuteAllInputs() {
        hardwareMIDISendEnabled = true
        hardwareInputActionsEnabled = true
        qwertyKeybindsEnabled = true
        keyGridMIDISendEnabled = true
        keyStripMIDISendEnabled = true
        keypadMIDISendEnabled = true
        verticalFadersMIDISendEnabled = true
        horizontalFadersMIDISendEnabled = true
        rotaryKnobsMIDISendEnabled = true
        midiThruEnabled = true
        forwardNotes = true
        forwardCCs = true
        forwardUIInteractions = true
        virtualOutEnabled = true
        setSectionBlackout(section: "all", enabled: true)
        blockedMIDIPacketsCount = 0
        if soundPack == .mute {
            soundPack = .arcade8Bit
        }
        uiClickSoundEnabled = true
        SoundEffect.keyTap.play(with: soundPack)
        log("🔊 Switched Profile: UNMUTE ALL (All Hardware, Sliders, Knobs & MIDI Routing Active)")
    }

    func toggleMasterHardwareMIDISend() {
        hardwareMIDISendEnabled.toggle()
        if hardwareMIDISendEnabled {
            hardwareInputActionsEnabled = true
        }
        SoundEffect.knobTick.play(with: soundPack)
        log(hardwareMIDISendEnabled ? "🔌 Hardware MIDI Send: ENABLED" : "🔇 Hardware MIDI Send: MUTED")
    }

    // --- PROTOCOL TERMINAL // INCOMING & OUTGOING PACKET MONITOR & NETWORK STATE ---
    var protocolEvents: [ProtocolEvent] = []
    var isProtocolPaused: Bool = false
    var protocolFilter: ProtocolEvent.EventType = .all
    var terminalTab: TerminalTab = .console
    var terminalFontSize: CGFloat = 11.5
    private let terminalFontSizeStorageKey = "BitchBoy_TerminalFontSize_v1"

    // Receiving OSC Configuration
    var oscIncomingHost: String = "0.0.0.0"
    var oscIncomingPort: UInt16 = 8000
    var isOSCListenerActive: Bool = false
    @ObservationIgnored private var oscListener: NWListener?

    // Receiving MIDI Configuration
    var availableInputSources: [String] = []
    var selectedMIDIInputDevice: String = "ALL" // "ALL", "AUTO", or device name
    var selectedMIDIInputChannel: Int = 0 // 0 = Omni (All), 1..16

    // Receiving Art-Net Configuration
    var artNetIncomingHost: String = "0.0.0.0"
    var artNetIncomingPort: UInt16 = 6454
    var artNetIncomingUniverse: UInt16 = 0
    var isArtNetListenerActive: Bool = false
    @ObservationIgnored private var artNetListener: NWListener?

    // Receiving sACN Configuration
    var sacnIncomingHost: String = "0.0.0.0"
    var sacnIncomingPort: UInt16 = 5568
    var sacnIncomingUniverse: UInt16 = 1
    var issACNListenerActive: Bool = false
    @ObservationIgnored private var sacnListener: NWListener?

    // Packet Telemetry & Counters
    var totalPacketsReceived: Int = 0
    var midiPacketsCount: Int = 0
    var oscPacketsCount: Int = 0
    var dmxPacketsCount: Int = 0
    var mscPacketsCount: Int = 0
    var lastPacketTime: Date? = nil

    private let oscPortStorageKey = "BitchBoy_OSCIncomingPort_v1"
    private let oscHostStorageKey = "BitchBoy_OSCIncomingHost_v1"
    private let midiDeviceStorageKey = "BitchBoy_MIDIInputDevice_v1"
    private let midiChannelStorageKey = "BitchBoy_MIDIInputChannel_v1"
    private let artNetPortStorageKey = "BitchBoy_ArtNetIncomingPort_v1"
    private let artNetHostStorageKey = "BitchBoy_ArtNetIncomingHost_v1"
    private let artNetUnivStorageKey = "BitchBoy_ArtNetIncomingUniverse_v1"
    private let sacnPortStorageKey = "BitchBoy_SACNIncomingPort_v1"
    private let sacnHostStorageKey = "BitchBoy_SACNIncomingHost_v1"
    private let sacnUnivStorageKey = "BitchBoy_SACNIncomingUniverse_v1" 

    // --- DYNAMIC MODULE PLACEMENT & RESIZING ENGINE ---
    var leftWingModules: [StudioModuleID] = [.showControl, .memorySlots]
    var rightWingModules: [StudioModuleID] = [.midiRouter, .customFXStudio]
    var bottomRackModules: [StudioModuleID] = [.reactiveKeyFX]
    var moduleCustomHeights: [StudioModuleID: CGFloat] = [:]
    var moduleCustomWidths: [StudioModuleID: CGFloat] = [:]
    var leftWingWidth: CGFloat = 380
    var rightWingWidth: CGFloat = 380
    private let leftWingStorageKey = "BitchBoy_LeftWingModules_v2"
    private let rightWingStorageKey = "BitchBoy_RightWingModules_v2"
    private let bottomRackStorageKey = "BitchBoy_BottomRackModules_v2"
    private let moduleHeightsStorageKey = "BitchBoy_ModuleHeights_v2"
    private let moduleWidthsStorageKey = "BitchBoy_ModuleWidths_v2"

    // --- CUSTOM THEMES STATE ---
    static var activeCustomThemeStatic: CustomChassisTheme = CustomChassisTheme.defaultCustom()
    var customThemes: [CustomChassisTheme] = []
    var activeCustomTheme: CustomChassisTheme = CustomChassisTheme.defaultCustom() {
        didSet {
            Self.activeCustomThemeStatic = activeCustomTheme
        }
    }
    var showCustomThemeStudio: Bool = false
    private let customThemesStorageKey = "BitchBoy_CustomThemes_v1"
    private let activeCustomThemeIDStorageKey = "BitchBoy_ActiveCustomThemeID_v1"
    private let themeStorageKey = "BitchBoy_ChassisTheme_v2"

    // --- GITHUB RELEASES AUTO-UPDATER STATE ---
    var isCheckingForUpdates: Bool = false
    var updateAvailable: Bool = false
    var latestRelease: GitHubReleaseInfo? = nil
    var showUpdateModal: Bool = false
    var isDownloadingUpdate: Bool = false
    var updateDownloadProgress: Double = 0.0
    var updateStatusMessage: String = ""
    var updateError: String? = nil
    var lastUpdateCheckDate: Date? = nil
    var showUpToDateNotice: Bool = false
    var updateCheckResultNotice: String = ""
    @ObservationIgnored private var periodicUpdateCheckTimer: AnyCancellable?
    @ObservationIgnored private var activeDownloadTask: URLSessionDownloadTask?

    var currentAppVersion: String {
        let bundleVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        if !bundleVer.isEmpty && bundleVer != "1.0" && bundleVer != "1.0.0" {
            return bundleVer
        }
        return "3.0.0"
    }

    private let storageKey = "BitchBoy_SavedSlots_v5"

    init() {
        self.controls = Self.buildDefault69Map()
        self.slots = Self.buildDefault8MemorySlots()
        let savedFPS = UserDefaults.standard.integer(forKey: "BitchBoy_TargetFPS_v1")
        self.targetFPS = (savedFPS == 60) ? 60 : 120
        let savedMaxUndo = UserDefaults.standard.integer(forKey: "BitchBoy_MaxUndoSteps_v1")
        self.maxUndoSteps = (savedMaxUndo >= 10 && savedMaxUndo <= 200) ? savedMaxUndo : 100
        loadFromDisk()
        loadCustomEffectsFromDisk()
        loadModuleOrderAndSoundSettings()
        loadUISettingsAndAppIcon()
        loadProtocolSettings()
        setupCoreMIDI()
        startHardwareWatchdog()
        startOSCListener(port: oscIncomingPort, host: oscIncomingHost)
        startArtNetListener(port: artNetIncomingPort)
        startsACNListener(port: sacnIncomingPort)
        recordProtocolEvent(type: .sys, command: "PROTOCOL TERMINAL READY", details: "CoreMIDI + UDP :\(oscIncomingPort) Active", rawHex: "7F 00 00 01", channel: "SYSTEM")

        // Guarantee any debounced slot write reaches disk before the process exits.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistSlotsNow()
            }
        }

        // Automatic GitHub Release Auto-Updater Check (runs 3s after boot, then every 4 hours)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.checkForUpdates(silent: true)
        }
        self.periodicUpdateCheckTimer = Timer.publish(every: 14400, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkForUpdates(silent: true)
            }
    }

    static func buildDefault8MemorySlots() -> [PresetSlot] {
        [
            PresetSlot(name: "SLOT A // PERFORMANCE", controls: Self.buildDefault69Map(), iconName: "music.mic", accentVelocity: 78),
            PresetSlot(name: "SLOT B // DAW PRODUCTION", controls: Self.buildDefault69Map(), iconName: "slider.horizontal.3", accentVelocity: 87),
            PresetSlot(name: "SLOT C // VISUALS & DMX", controls: Self.buildDefault69Map(), iconName: "sparkles", accentVelocity: 57),
            PresetSlot(name: "SLOT D // STREAM DECK", controls: Self.buildDefault69Map(), iconName: "square.grid.3x3.fill", accentVelocity: 74),
            PresetSlot(name: "SLOT E // SYNTH LEAD", controls: Self.buildDefault69Map(), iconName: "pianokeys", accentVelocity: 41),
            PresetSlot(name: "SLOT F // DRUM RACK", controls: Self.buildDefault69Map(), iconName: "waveform.path.ecg", accentVelocity: 72),
            PresetSlot(name: "SLOT G // VJ MATRIX", controls: Self.buildDefault69Map(), iconName: "tv.fill", accentVelocity: 67),
            PresetSlot(name: "SLOT H // MASTER CUSTOM", controls: Self.buildDefault69Map(), iconName: "cpu.fill", accentVelocity: 96)
        ]
    }

    static func buildDefault69Map() -> [ControlItem] {
        var items: [ControlItem] = []

        // 1. TOP-LEFT 8X4 KEY GRID (32 Mechanical Keys with LEDs)
        // Authentic hardware matrix
        let gridNotes: [[UInt8]] = [
            [64, 65, 66, 67, 96, 97, 98, 99],
            [60, 61, 62, 63, 92, 93, 94, 95],
            [56, 57, 58, 59, 88, 89, 90, 91],
            [52, 53, 54, 55, 84, 85, 86, 87]
        ]
        for r in 0..<4 {
            for c in 0..<8 {
                let lbl = "R\(r+1)C\(c+1)"
                items.append(ControlItem(
                    label: lbl,
                    customName: lbl,
                    kind: .key,
                    number: gridNotes[r][c],
                    zone: "8X4 GRID - ROW \(r+1), COL \(c+1)",
                    idleVelocity: 0,
                    activeVelocity: 3,
                    currentLED: 0,
                    feedbackMode: .momentary,
                    actionType: .passthrough
                ))
            }
        }

        // 2. MIDDLE 1X8 KEY STRIP (8 Keys with LEDs)
        let stripNotes: [UInt8] = [48, 49, 50, 51, 80, 81, 82, 83]
        for i in 0..<8 {
            let lbl = "S\(i+1)"
            items.append(ControlItem(
                label: lbl,
                customName: lbl,
                kind: .key,
                number: stripNotes[i],
                zone: "1X8 KEY STRIP - KEY \(i+1)",
                idleVelocity: 0,
                activeVelocity: 3,
                currentLED: 0,
                feedbackMode: .momentary,
                actionType: .passthrough
            ))
        }

        // 3. BOTTOM-RIGHT 3X3 KEYPAD (9 Keys with LEDs)
        let padNotes: [UInt8] = [44, 45, 46, 40, 41, 42, 36, 37, 38]
        for i in 0..<9 {
            let lbl = "P\(i+1)"
            items.append(ControlItem(
                label: lbl,
                customName: lbl,
                kind: .key,
                number: padNotes[i],
                zone: "3X3 KEYPAD - KEY \(i+1)",
                idleVelocity: 0,
                activeVelocity: 3,
                currentLED: 0,
                feedbackMode: .momentary,
                actionType: .passthrough
            ))
        }

        // 4. BOTTOM-LEFT 8 VERTICAL FADERS (CC 0..7)
        for i in 0..<8 {
            let lbl = "VF\(i+1)"
            items.append(ControlItem(
                label: lbl,
                customName: lbl,
                kind: .vfader,
                number: UInt8(i),
                zone: "VERTICAL FADER \(i+1) (ANALOG CC)",
                idleVelocity: 0,
                activeVelocity: 0,
                liveValue: UInt8(i * 16),
                feedbackMode: .momentary,
                actionType: .passthrough
            ))
        }

        // 5. TOP-MIDDLE 4 HORIZONTAL FADERS (CC 8..11)
        for i in 0..<4 {
            let lbl = "HF\(i+1)"
            items.append(ControlItem(
                label: lbl,
                customName: lbl,
                kind: .hfader,
                number: UInt8(8 + i),
                zone: "HORIZONTAL FADER \(i+1) (ANALOG CC)",
                idleVelocity: 0,
                activeVelocity: 0,
                liveValue: UInt8(32 + i * 24),
                feedbackMode: .momentary,
                actionType: .passthrough
            ))
        }

        // 6. TOP-RIGHT 2X4 ROTARY KNOBS (CC 20..27)
        for i in 0..<8 {
            let lbl = "K\(i+1)"
            items.append(ControlItem(
                label: lbl,
                customName: lbl,
                kind: .knob,
                number: UInt8(20 + i),
                zone: "ROTARY KNOB \(i+1) (ANALOG CC)",
                idleVelocity: 0,
                activeVelocity: 0,
                liveValue: UInt8(40 + i * 10),
                feedbackMode: .momentary,
                actionType: .passthrough
            ))
        }

        return items
    }

    // ------------------------------------------------------------------------
    // CORE MIDI COMMUNICATIONS
    // ------------------------------------------------------------------------
    private func setupCoreMIDI() {
        var status = MIDIClientCreateWithBlock("BitchBoyClient" as CFString, &midiClient, makeCoreMIDINotifyBlock(for: self))
        guard status == noErr else { return }

        status = MIDIInputPortCreateWithProtocol(
            midiClient,
            "BitchBoyInput" as CFString,
            ._1_0,
            &inputPort,
            makeCoreMIDIReceiveBlock(for: self)
        )

        MIDIOutputPortCreate(midiClient, "BitchBoyOutput" as CFString, &outputPort)
        MIDISourceCreate(midiClient, "BitchBoy Virtual Out" as CFString, &virtualSourceEndpoint)

        // Virtual Destination Endpoint: Named "BitchBoy Virtual In" to allow QLab / DAWs to send MSC & notes directly into BitchManager
        status = MIDIDestinationCreateWithBlock(
            midiClient,
            "BitchBoy Virtual In" as CFString,
            &virtualDestinationEndpoint,
            makeCoreMIDIVirtualInBlock(for: self)
        )

        scanForBitchBoy()
    }

    func scanForBitchBoy() {
        let destCount = MIDIGetNumberOfDestinations()
        var found = false
        var targetDest: MIDIEndpointRef = 0
        var targetName = "Unplugged"

        // 1. Strictly look ONLY for the physical BitchBoy hardware controller destination (NO simulated fallback!)
        for i in 0..<destCount {
            let dest = MIDIGetDestination(i)
            if dest == virtualDestinationEndpoint { continue }
            if isRealBitchBoyEndpoint(dest) {
                targetDest = dest
                targetName = getEndpointName(dest)
                found = true
                break
            }
        }

        // 2. Discover all MIDI input sources & connect per selectedMIDIInputDevice
        let srcCount = MIDIGetNumberOfSources()
        var discoveredSources: [String] = []
        for i in 0..<srcCount {
            let src = MIDIGetSource(i)
            let sName = getEndpointName(src)
            if src == virtualSourceEndpoint || sName.lowercased().contains("bitchboy virtual out") {
                MIDIPortDisconnectSource(inputPort, src)
                continue
            }
            if !discoveredSources.contains(sName) {
                discoveredSources.append(sName)
            }
            let isBB = isRealBitchBoyEndpoint(src)
            if isBB && !found {
                targetName = sName
                found = true
            }

            let shouldConnect: Bool
            if selectedMIDIInputDevice == "ALL" {
                shouldConnect = true
            } else if selectedMIDIInputDevice == "AUTO" {
                shouldConnect = isBB
            } else {
                shouldConnect = (sName == selectedMIDIInputDevice) || isBB
            }

            if shouldConnect {
                MIDIPortConnectSource(inputPort, src, nil)
            } else {
                MIDIPortDisconnectSource(inputPort, src)
            }
        }
        if availableInputSources != discoveredSources {
            availableInputSources = discoveredSources
        }

        // 3. Refresh all available MIDI output destinations for the MIDI Router
        var targets: [MIDIOutputTarget] = []
        for i in 0..<destCount {
            let dest = MIDIGetDestination(i)
            let dName = getEndpointName(dest)
            if dName.lowercased().contains("bitchboy virtual out") || dName.lowercased().contains("bitchboy virtual in") || dest == virtualDestinationEndpoint { continue }
            let isBB = (dest == targetDest && found) || isRealBitchBoyEndpoint(dest)
            targets.append(MIDIOutputTarget(name: dName, endpoint: dest, isHardwareBitchBoy: isBB))
        }
        let prevEmpty = availableOutputTargets.isEmpty
        if availableOutputTargets != targets {
            availableOutputTargets = targets
        }
        if selectedOutputNames.isEmpty || prevEmpty {
            // Auto-select any non-BitchBoy external DAW / IAC / Synth targets on first launch or when targets appear
            for t in targets where !t.isHardwareBitchBoy {
                selectedOutputNames.insert(t.name)
            }
        }

        let wasConnected = isConnected
        let prevDest = bitchBoyDestination

        bitchBoyDestination = found ? targetDest : 0
        deviceName = found ? targetName : "Unplugged"
        isConnected = found

        // CRITICAL: Only trigger connection celebration & LED sync when the physical BitchBoy controller is newly recognized!
        if isConnected && (!wasConnected || prevDest != bitchBoyDestination) {
            log("🔌 BitchBoy Hardware Recognized: \(deviceName)")
            applyBitchBoyMIDIStudioIcon(silent: true)
            triggerBitchBoyConnectedNotificationFX(isManualTest: false)
        } else if !isConnected && wasConnected {
            showConnectionBanner = false
            SoundEffect.hardwareDisconnected.play(with: soundPack)
            postVoiceOverAnnouncement("BitchBoy Hardware Disconnected")
            log("⚠️ BitchBoy Hardware Disconnected")
        }
    }

    private func isRealBitchBoyEndpoint(_ ep: MIDIEndpointRef) -> Bool {
        guard ep != 0, ep != virtualSourceEndpoint, ep != virtualDestinationEndpoint else { return false }

        // Check if endpoint or its parent entity/device is marked offline in CoreMIDI
        var offlineVal: Int32 = 0
        if MIDIObjectGetIntegerProperty(ep, kMIDIPropertyOffline, &offlineVal) == noErr, offlineVal != 0 {
            return false
        }

        var combinedNames: [String] = [
            getStringProperty(ep, kMIDIPropertyDisplayName),
            getStringProperty(ep, kMIDIPropertyName),
            getStringProperty(ep, kMIDIPropertyModel),
            getStringProperty(ep, kMIDIPropertyManufacturer)
        ]

        var entity = MIDIEntityRef()
        if MIDIEndpointGetEntity(ep, &entity) == noErr, entity != 0 {
            if MIDIObjectGetIntegerProperty(entity, kMIDIPropertyOffline, &offlineVal) == noErr, offlineVal != 0 {
                return false
            }
            var device = MIDIDeviceRef()
            if MIDIEntityGetDevice(entity, &device) == noErr, device != 0 {
                if MIDIObjectGetIntegerProperty(device, kMIDIPropertyOffline, &offlineVal) == noErr, offlineVal != 0 {
                    return false
                }
                combinedNames.append(getStringProperty(device, kMIDIPropertyDisplayName))
                combinedNames.append(getStringProperty(device, kMIDIPropertyName))
                combinedNames.append(getStringProperty(device, kMIDIPropertyModel))
                combinedNames.append(getStringProperty(device, kMIDIPropertyManufacturer))
            }
        }

        let joined = combinedNames.joined(separator: " ")
        return isRealBitchBoy(joined)
    }

    private func getStringProperty(_ obj: MIDIObjectRef, _ prop: CFString) -> String {
        var str: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(obj, prop, &str) == noErr, let s = str {
            return s.takeRetainedValue() as String
        }
        return ""
    }

    private func isRealBitchBoy(_ name: String) -> Bool {
        let n = name.lowercased()
        // Never treat our own virtual port or any other MIDI software/bus as the physical BitchBoy controller
        if n.contains("bitchboy virtual out") || n.contains("bitchboy virtual in") || n.contains("virtual out") || n.contains("virtual in") || n.contains("bitchmanager") || n.contains("simulated") {
            return false
        }
        if n.contains("qlab") || n.contains("iac") || n.contains("network") || n.contains("session") ||
           n.contains("ableton") || n.contains("logic") || n.contains("mainstage") || n.contains("pro tools") ||
           n.contains("reaper") || n.contains("bitwig") || n.contains("fl studio") || n.contains("cubase") ||
           n.contains("garageband") || n.contains("traktor") || n.contains("serato") || n.contains("rekordbox") ||
           n.contains("resolume") {
            return false
        }
        return n.contains("bitchboy") || n.contains("bitch boy") || n.contains("block system")
    }

    // ------------------------------------------------------------------------
    // ON-CONNECT BITCHBOY NOTIFICATION FX & MACOS MIDI STUDIO ICON ENGINE
    // ------------------------------------------------------------------------
    func setAsOnConnectFX(_ fx: CustomLightEffect) {
        connectCustomFXName = fx.name
        connectEffectEnabled = true
        UserDefaults.standard.set(connectCustomFXName, forKey: connectFXNameStorageKey)
        UserDefaults.standard.set(connectEffectEnabled, forKey: connectFXEnabledStorageKey)
        SoundEffect.presetSwitch.play(with: soundPack)
        log("🔌 Set '\(fx.name)' as the BitchBoy On-Connect Notification FX!")
    }

    func toggleConnectEffectEnabled() {
        connectEffectEnabled.toggle()
        UserDefaults.standard.set(connectEffectEnabled, forKey: connectFXEnabledStorageKey)
        SoundEffect.knobTick.play(with: soundPack)
        log(connectEffectEnabled ? "🔌 On-Connect FX: ENABLED (\(connectCustomFXName))" : "🔌 On-Connect FX: DISABLED")
    }

    func triggerBitchBoyConnectedNotificationFX(isManualTest: Bool = false) {
        // Strictly play automatically ONLY when the real BitchBoy controller is recognized!
        guard isConnected || isManualTest else { return }

        SoundEffect.hardwareConnected.play(with: soundPack)

        // 1. Show glowing on-screen HUD Connection Banner & Mascot Greeting
        let titleName = isConnected ? deviceName.uppercased() : "BITCHBOY (PREVIEW)"
        connectionBannerTitle = "🔌 \(titleName) CONNECTED & READY"
        connectionBannerSubtitle = connectEffectEnabled
            ? "PLAYING ON-CONNECT FX: \(connectCustomFXName)"
            : "69-CONTROL HARDWARE MATRIX SYNCHRONIZED"

        postVoiceOverAnnouncement("\(titleName) Connected and Ready")

        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
            showConnectionBanner = true
            mascotSpeech = "🔌 BITCHBOY CONTROLLER ONLINE & READY!"
            mascotSpeechVisible = true
            mascotScale = 1.1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                self.mascotScale = 1.0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
            withAnimation(.easeInOut(duration: 0.25)) {
                self.showConnectionBanner = false
                self.mascotSpeechVisible = false
            }
        }

        // 2. Play the user's selected Custom On-Connect Light Show on the 49 LEDs (then restore active preset)
        guard connectEffectEnabled else {
            if currentFXMode == .staticFX {
                restorePresetLEDs()
            } else {
                applyFXMode(currentFXMode)
            }
            return
        }

        let chosenFX = customEffects.first(where: { $0.name == connectCustomFXName })
            ?? CustomLightEffect.buildDefaultConnectEffect()

        var oneShotFX = chosenFX
        if !oneShotFX.isProcedural {
            oneShotFX.loopMode = .oneShot
        }
        playCustomEffect(oneShotFX)
        log("✨ Playing BitchBoy Connection FX: '\(oneShotFX.name)'")

        // If the chosen effect is procedural (continuous wave), stop it after 2.4s and restore preset LEDs
        if oneShotFX.isProcedural {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                guard let self = self else { return }
                if self.isPlayingCustomFX && self.activeCustomFXName == oneShotFX.name {
                    self.stopCustomEffect()
                }
            }
        }
    }

    func applyBitchBoyMIDIStudioIcon(style: String = "MASCOT", customFileURL: URL? = nil, silent: Bool = false) {
        if silent {
            // Offload disk I/O and image compression to background utility thread so UI & bootup never hitch
            Task.detached(priority: .utility) { [weak self] in
                await self?.performApplyBitchBoyMIDIStudioIcon(style: style, customFileURL: customFileURL, silent: true)
            }
        } else {
            performApplyBitchBoyMIDIStudioIcon(style: style, customFileURL: customFileURL, silent: false)
        }
    }

    private func performApplyBitchBoyMIDIStudioIcon(style: String = "MASCOT", customFileURL: URL? = nil, silent: Bool = false) {
        let baseImg: NSImage?
        if let customURL = customFileURL, let loaded = NSImage(contentsOf: customURL) {
            baseImg = loaded
        } else if style == "BADGE" {
            baseImg = NSImage(named: "BitchBoyBadgeIcon")
        } else if style == "LOGO" {
            baseImg = NSImage(named: "BitchBoyWordLogo") ?? NSImage(named: "BitchBoyBadgeIcon")
        } else {
            baseImg = NSImage(named: "BitchBoyMascot")
                ?? NSImage(contentsOfFile: "/Users/taylorfossen/Documents/BB/BB/Assets.xcassets/BitchBoyMascot.imageset/bitchboy.png")
                ?? NSImage(named: "BitchBoyBadgeIcon")
        }

        guard let sourceImage = baseImg else {
            if !silent { log("⚠️ Could not load BitchBoy icon image for MIDI Studio.") }
            return
        }

        // Render a crisp 128x128 PNG (CoreMIDI kMIDIPropertyImage standard max size: 128x128)
        let targetSize = NSSize(width: 128, height: 128)
        let rendered = NSImage(size: targetSize)
        rendered.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let srcSize = sourceImage.size
        let scale = min(120.0 / max(1.0, srcSize.width), 120.0 / max(1.0, srcSize.height))
        let drawW = srcSize.width * scale
        let drawH = srcSize.height * scale
        let drawRect = NSRect(x: (128.0 - drawW) * 0.5, y: (128.0 - drawH) * 0.5, width: drawW, height: drawH)
        sourceImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        rendered.unlockFocus()

        guard let tiffData = rendered.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }

        let fm = FileManager.default
        var savedPaths: [String] = []

        // 1. Save into ~/Library/Audio/MIDI Devices/Generic/Images/BitchBoy.png (macOS Audio MIDI Setup icon directory)
        let userMIDIImagesDir = NSHomeDirectory() + "/Library/Audio/MIDI Devices/Generic/Images"
        try? fm.createDirectory(atPath: userMIDIImagesDir, withIntermediateDirectories: true)
        let userMIDIIconPath = userMIDIImagesDir + "/BitchBoy.png"
        if (try? pngData.write(to: URL(fileURLWithPath: userMIDIIconPath))) != nil {
            savedPaths.append(userMIDIIconPath)
        }

        // 2. Also save into ~/Library/Application Support/BitchManager/BitchBoy.png
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("BitchManager", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent("BitchBoy_MIDIStudio_Icon.png")
            if (try? pngData.write(to: fileURL)) != nil {
                savedPaths.append(fileURL.path)
            }
        }

        guard let finalIconPath = savedPaths.first else { return }

        // 3. Apply kMIDIPropertyImage to all matching BitchBoy MIDIDeviceRef / MIDIEntityRef objects in CoreMIDI!
        var updatedCount = 0
        let devCount = MIDIGetNumberOfDevices()
        for i in 0..<devCount {
            let dev = MIDIGetDevice(i)
            let dName = getStringProperty(dev, kMIDIPropertyName) + " " + getStringProperty(dev, kMIDIPropertyDisplayName) + " " + getStringProperty(dev, kMIDIPropertyModel)
            if dName.lowercased().contains("bitchboy") || dName.lowercased().contains("bitch boy") {
                if MIDIObjectSetStringProperty(dev, kMIDIPropertyImage, finalIconPath as CFString) == noErr {
                    updatedCount += 1
                }
            }
        }

        // Also walk from any connected BitchBoy endpoint -> entity -> device
        if bitchBoyDestination != 0 {
            var ent = MIDIEntityRef()
            if MIDIEndpointGetEntity(bitchBoyDestination, &ent) == noErr, ent != 0 {
                var dev = MIDIDeviceRef()
                if MIDIEntityGetDevice(ent, &dev) == noErr, dev != 0 {
                    if MIDIObjectSetStringProperty(dev, kMIDIPropertyImage, finalIconPath as CFString) == noErr {
                        updatedCount += 1
                    }
                }
            }
        }

        if !silent {
            SoundEffect.presetSwitch.play(with: soundPack)
            if updatedCount > 0 {
                log("🖼️ Updated BitchBoy icon in macOS MIDI Studio! (Restart Audio MIDI Setup to refresh)")
            } else {
                log("🖼️ Saved BitchBoy icon to \(finalIconPath) — plug in BitchBoy to apply to MIDI Studio!")
            }
        }
    }

    func chooseCustomMIDIStudioIconFromDisk() {
        let panel = NSOpenPanel()
        panel.title = "Choose Custom Image for BitchBoy in macOS MIDI Studio"
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .icns]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            applyBitchBoyMIDIStudioIcon(style: "CUSTOM", customFileURL: url, silent: false)
        }
    }

    private func getEndpointName(_ ep: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        let err = MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &name)
        if err == noErr, let n = name {
            return n.takeRetainedValue() as String
        }
        return "MIDI Device"
    }

    private func startHardwareWatchdog() {
        watchdogTimer = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.scanForBitchBoy()
            }
    }

    // ------------------------------------------------------------------------
    // TRANSMIT MIDI & LED HARDWARE
    // ------------------------------------------------------------------------
    private func sendMIDIPacket(endpoint: MIDIEndpointRef, data: [UInt8], isVirtualSource: Bool = false) {
        guard endpoint != 0, !data.isEmpty else { return }
        let bufSize = max(1024, data.count + 256)
        var buffer = [UInt8](repeating: 0, count: bufSize)
        buffer.withUnsafeMutableBytes { rawBuf in
            guard let pktListPtr = rawBuf.baseAddress?.assumingMemoryBound(to: MIDIPacketList.self) else { return }
            let curPacket = MIDIPacketListInit(pktListPtr)
            var bytes = data
            _ = MIDIPacketListAdd(pktListPtr, bufSize, curPacket, 0, bytes.count, &bytes)
            if isVirtualSource {
                MIDIReceived(endpoint, pktListPtr)
            } else {
                MIDISend(outputPort, endpoint, pktListPtr)
            }
        }
    }

    func sendNoteOn(note: UInt8, velocity: UInt8) {
        if velocity > 0, let idx = controlIndex(forNote: note), !isSectionEnabled(for: idx) {
            return
        }
        recordProtocolEvent(
            type: .midiOut,
            command: "NOTE ON #\(note) (\(midiNoteName(note)))",
            details: "Velocity: \(velocity) [\(Int(round(Double(velocity)/127.0*100)))%]",
            rawHex: String(format: "90 %02X %02X", note, velocity),
            channel: "Ch:1"
        )
        guard isConnected, bitchBoyDestination != 0 else { return }
        if velocity == 0 {
            sendMIDIPacket(endpoint: bitchBoyDestination, data: [0x80, note, 0])
        } else {
            sendMIDIPacket(endpoint: bitchBoyDestination, data: [0x90, note, velocity])
        }
    }

    func sendCC(cc: UInt8, value: UInt8) {
        if let idx = controlIndex(forCC: cc) {
            guard isSectionEnabled(for: idx) else { return }
        }
        let now = Date()
        if now.timeIntervalSince(lastProtocolEventLogTime) >= 0.08 {
            lastProtocolEventLogTime = now
            recordProtocolEvent(
                type: .midiOut,
                command: "CC #\(cc)",
                details: "Value: \(value)",
                rawHex: String(format: "B0 %02X %02X", cc, value),
                channel: "Ch:1"
            )
        }
        guard isConnected, bitchBoyDestination != 0 else { return }
        sendMIDIPacket(endpoint: bitchBoyDestination, data: [0xB0, cc, value])
    }

    // High-performance batch NoteOn sender for zero-lag keyboard effects
    func sendBatchNoteOn(notesAndVelocities: [(note: UInt8, velocity: UInt8)]) {
        guard isConnected, bitchBoyDestination != 0, !notesAndVelocities.isEmpty else { return }
        let filteredNotesAndVelocities = notesAndVelocities.filter { item in
            if item.velocity == 0 { return true }
            if let idx = controlIndex(forNote: item.note) {
                return isSectionEnabled(for: idx)
            }
            return true
        }
        guard !filteredNotesAndVelocities.isEmpty else { return }
        var buffer = [UInt8](repeating: 0, count: 2048)
        buffer.withUnsafeMutableBytes { rawBuf in
            guard let pktListPtr = rawBuf.baseAddress?.assumingMemoryBound(to: MIDIPacketList.self) else { return }
            var curPacket = MIDIPacketListInit(pktListPtr)
            for item in filteredNotesAndVelocities {
                var data: [UInt8] = (item.velocity == 0) ? [0x80, item.note, 0] : [0x90, item.note, item.velocity]
                curPacket = MIDIPacketListAdd(pktListPtr, 2048, curPacket, 0, 3, &data)
            }
            MIDISend(outputPort, bitchBoyDestination, pktListPtr)
        }
    }

    // ------------------------------------------------------------------------
    // SHOW CONTROL: MSC (MIDI SHOW CONTROL) BROADCAST ENGINE
    // ------------------------------------------------------------------------
    func sendMSCBroadcast(
        command: MSCCommand,
        cue: String = "",
        cueList: String = "",
        deviceID: UInt8 = 1,
        format: MSCCommandFormat = .allTypes
    ) {
        var bytes: [UInt8] = [0xF0, 0x7F, deviceID, 0x02, format.rawValue, command.rawValue]
        if !cue.isEmpty {
            bytes.append(contentsOf: Array(cue.utf8))
        }
        if !cueList.isEmpty {
            bytes.append(0x00) // MSC Sub-Cue / List delimiter
            bytes.append(contentsOf: Array(cueList.utf8))
        }
        bytes.append(0xF7) // EOX

        // 1. Send to physical BitchBoy hardware
        if isConnected, bitchBoyDestination != 0 {
            sendMIDIPacket(endpoint: bitchBoyDestination, data: bytes)
        }

        // 2. Send to virtual source endpoint so QLab / DAWs receive it
        if virtualOutEnabled, virtualSourceEndpoint != 0 {
            sendMIDIPacket(endpoint: virtualSourceEndpoint, data: bytes, isVirtualSource: true)
        }

        // 3. Send to all selected external MIDI outputs in MIDI Router
        for target in availableOutputTargets where selectedOutputNames.contains(target.name) {
            if target.endpoint == bitchBoyDestination { continue }
            sendMIDIPacket(endpoint: target.endpoint, data: bytes)
        }

        let msg = MSCMessage(
            isOutbound: true,
            deviceID: deviceID,
            commandFormat: format,
            command: command,
            cueNumber: cue,
            cueList: cueList,
            rawBytes: bytes
        )
        mscLogHistory.insert(msg, at: 0)
        if mscLogHistory.count > 50 {
            mscLogHistory.removeLast()
        }
        log("📡 TX MSC: \(msg.summary)")
        SoundEffect.presetSwitch.play(with: soundPack)
    }

    func handleIncomingSysExBytes(_ bytes: [UInt8]) {
        for b in bytes {
            if b == 0xF0 {
                inboundSysExBuffer = [0xF0]
            } else if b == 0xF7 {
                if !inboundSysExBuffer.isEmpty && inboundSysExBuffer[0] == 0xF0 {
                    inboundSysExBuffer.append(0xF7)
                    processCompletedSysEx(inboundSysExBuffer)
                    inboundSysExBuffer.removeAll()
                }
            } else if !inboundSysExBuffer.isEmpty {
                inboundSysExBuffer.append(b)
                if inboundSysExBuffer.count > 512 {
                    inboundSysExBuffer.removeAll()
                }
            }
        }
    }

    private func processCompletedSysEx(_ bytes: [UInt8]) {
        // MSC SysEx: F0 7F <devID> 02 <format> <cmd> [cueData...] F7
        guard bytes.count >= 7,
              bytes[0] == 0xF0,
              bytes[1] == 0x7F,
              bytes[3] == 0x02,
              bytes.last == 0xF7 else { return }

        let deviceID = bytes[2]
        let formatRaw = bytes[4]
        let cmdRaw = bytes[5]

        let command = MSCCommand(rawValue: cmdRaw) ?? .go
        let format = MSCCommandFormat(rawValue: formatRaw) ?? .allTypes

        var cueStr = ""
        var listStr = ""
        if bytes.count > 7 {
            let dataSlice = bytes[6..<(bytes.count - 1)]
            let parts = dataSlice.split(separator: 0x00, omittingEmptySubsequences: false)
            if let first = parts.first, let s = String(bytes: first, encoding: .utf8) {
                cueStr = s
            }
            if parts.count > 1, let s = String(bytes: parts[1], encoding: .utf8) {
                listStr = s
            }
        }

        let mscMsg = MSCMessage(
            isOutbound: false,
            deviceID: deviceID,
            commandFormat: format,
            command: command,
            cueNumber: cueStr,
            cueList: listStr,
            rawBytes: bytes
        )

        mscLogHistory.insert(mscMsg, at: 0)
        if mscLogHistory.count > 50 {
            mscLogHistory.removeLast()
        }
        log("📥 RX MSC: \(mscMsg.summary)")
        recordProtocolEvent(
            type: .msc,
            command: "MSC \(command.title.uppercased())",
            details: "Format: \(format.rawValue) | Q: \(cueStr.isEmpty ? "None" : cueStr)",
            rawHex: bytes.prefix(10).map { String(format: "%02X", $0) }.joined(separator: " "),
            channel: "Dev:\(deviceID)"
        )
        SoundEffect.keyTap.play(with: soundPack)

        if mscAutoTriggerOnInbound {
            handleMSCAutoTrigger(command: command, cueNumber: cueStr)
        }
    }

    private func handleMSCAutoTrigger(command: MSCCommand, cueNumber: String) {
        switch command {
        case .go, .resume, .timedGo:
            selectSlot((activeSlot + 1) % slots.count)
            triggerRandomDemoReactiveFX()
            log("🎬 MSC Auto-Trigger: GO -> Preset Slot \(slots[activeSlot].name)")
        case .stop, .allOff, .reset, .goOff:
            setZoneLEDs(range: 0..<49, velocity: 0)
            currentFXMode = .staticFX
            fxTimer?.cancel()
            fxTimer = nil
            clearReactiveKeyFX()
            log("🛑 MSC Auto-Trigger: STOP / PANIC Blackout")
        case .load:
            if let cueInt = Int(cueNumber), cueInt >= 1, cueInt <= slots.count {
                selectSlot(cueInt - 1)
                log("📥 MSC Auto-Trigger: LOAD -> Preset Slot \(cueInt)")
            }
        case .fire:
            triggerBitchBoyConnectedNotificationFX(isManualTest: true)
            log("🔥 MSC Auto-Trigger: FIRE MACRO Ignition")
        default:
            break
        }
    }

    func clearMSCLogHistory() {
        mscLogHistory.removeAll()
    }

    // ------------------------------------------------------------------------
    // SHOW CONTROL: ART-NET 4 TRANSMITTER (UDP Port 6454)
    // ------------------------------------------------------------------------
    func sendArtNetDMX(
        host: String = "255.255.255.255",
        universe: UInt16 = 0,
        channels: [UInt8]
    ) {
        recordProtocolEvent(
            type: .dmx,
            command: "ART-NET DMX DUMP",
            details: "Univ: \(universe) | \(channels.count) Chans",
            rawHex: "41 72 74 2D 4E 65 74",
            channel: "\(host):\(artNetPort)"
        )
        let packet = ArtNetPacketBuilder.buildDMXPacket(universe: universe, channels: channels, sequence: artNetSequence)
        artNetSequence = (artNetSequence &+ 1)
        sendUDP(packet, host: host, port: artNetPort, protocolName: "Art-Net")
        log("💡 Art-Net DMX -> \(host):\(artNetPort) Univ:\(universe) (512 Ch)")
    }

    func sendArtNetFullRig() {
        let chs = Array(repeating: UInt8(255), count: 512)
        sendArtNetDMX(host: artNetHost, universe: artNetUniverse, channels: chs)
    }

    func sendArtNetBlackout() {
        let chs = Array(repeating: UInt8(0), count: 512)
        sendArtNetDMX(host: artNetHost, universe: artNetUniverse, channels: chs)
    }

    func sendArtNetRGBChase() {
        var chs = Array(repeating: UInt8(0), count: 512)
        for i in 0..<16 {
            chs[i * 3] = 255     // Red
            chs[i * 3 + 1] = 128 // Green
            chs[i * 3 + 2] = 0   // Blue
        }
        sendArtNetDMX(host: artNetHost, universe: artNetUniverse, channels: chs)
    }

    // ------------------------------------------------------------------------
    // SHOW CONTROL: ANSI E1.31 sACN TRANSMITTER (UDP Port 5568)
    // ------------------------------------------------------------------------
    func sendSACNDMX(
        host: String = "",
        universe: UInt16 = 1,
        priority: UInt8 = 100,
        channels: [UInt8]
    ) {
        let packet = SACNPacketBuilder.buildDMXPacket(
            universe: universe,
            priority: priority,
            channels: channels,
            sequence: sacnSequence,
            sourceName: "BitchManager Pro Show Control"
        )
        sacnSequence = (sacnSequence &+ 1)

        let targetHost: String
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let high = (universe >> 8) & 0xFF
            let low = universe & 0xFF
            targetHost = "239.255.\(high).\(low)"
        } else {
            targetHost = trimmed
        }

        recordProtocolEvent(
            type: .dmx,
            command: "sACN E1.31 DMX DUMP",
            details: "Univ: \(universe) | Pri: \(priority) | \(channels.count) Chans",
            rawHex: "41 53 43 2D 45 31 2E 31 37",
            channel: "\(targetHost):\(sacnPort)"
        )

        sendUDP(packet, host: targetHost, port: sacnPort, protocolName: "sACN")
        log("🌟 sACN E1.31 -> \(targetHost):\(sacnPort) Univ:\(universe) Pri:\(priority) (512 Ch)")
    }

    @inlinable
    func sendsACNDMX(
        host: String = "",
        universe: UInt16 = 1,
        priority: UInt8 = 100,
        channels: [UInt8]
    ) {
        sendSACNDMX(host: host, universe: universe, priority: priority, channels: channels)
    }

    func sendSACNFullRig() {
        let chs = Array(repeating: UInt8(255), count: 512)
        sendSACNDMX(host: sacnHost, universe: sacnUniverse, priority: sacnPriority, channels: chs)
    }

    @inlinable
    func sendsACNFullRig() {
        sendSACNFullRig()
    }

    func sendSACNBlackout() {
        let chs = Array(repeating: UInt8(0), count: 512)
        sendSACNDMX(host: sacnHost, universe: sacnUniverse, priority: sacnPriority, channels: chs)
    }

    @inlinable
    func sendsACNBlackout() {
        sendSACNBlackout()
    }

    func sendSACNRGBChase() {
        var chs = Array(repeating: UInt8(0), count: 512)
        for i in 0..<16 {
            chs[i * 3] = 255     // Red
            chs[i * 3 + 1] = 128 // Green
            chs[i * 3 + 2] = 0   // Blue
        }
        sendSACNDMX(host: sacnHost, universe: sacnUniverse, priority: sacnPriority, channels: chs)
    }

    // ------------------------------------------------------------------------
    // SHOW CONTROL: CUSTOM OSC TRANSMITTER (UDP)
    // ------------------------------------------------------------------------
    func sendCustomOSC(
        host: String,
        port: UInt16,
        address: String,
        argType: String,
        argValue: String
    ) {
        let valStr = argType == "NONE" ? "" : " [\(argType): \(argValue)]"
        let hexSample = address.data(using: .utf8)?.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ") ?? ""
        recordProtocolEvent(
            type: .oscOut,
            command: address,
            details: "Target: \(host):\(port)\(valStr)",
            rawHex: hexSample,
            channel: "\(host):\(port)"
        )

        let packet = OSCPacketBuilder.buildMessage(address: address, argType: argType, argValue: argValue)
        sendUDP(packet, host: host, port: port, protocolName: "OSC")
        log("📡 OSC UDP -> \(host):\(port) \(address)\(valStr)")
    }

    // MARK: - Pooled UDP Transmit
    // Opening a fresh NWConnection per packet costs a socket + path evaluation every time and,
    // during fader moves or DMX streaming, produced hundreds of short-lived connections per second.
    // Connections are now cached per host:port on a dedicated queue and evicted when they fail.
    @ObservationIgnored private var udpConnections: [String: NWConnection] = [:]
    @ObservationIgnored private let udpTransmitQueue = DispatchQueue(label: "com.bitchmanager.udp-transmit", qos: .userInitiated)

    private func sendUDP(_ packet: Data, host: String, port: UInt16, protocolName: String) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let key = "\(host):\(port)"
        let conn: NWConnection
        if let existing = udpConnections[key] {
            conn = existing
        } else {
            conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                switch state {
                case .failed, .cancelled:
                    Task { @MainActor [weak self] in
                        guard let self, let conn, self.udpConnections[key] === conn else { return }
                        self.udpConnections[key] = nil
                    }
                default:
                    break
                }
            }
            conn.start(queue: udpTransmitQueue)
            udpConnections[key] = conn
        }
        conn.send(content: packet, completion: .contentProcessed { [weak self] err in
            guard let err else { return }
            conn.cancel()
            Task { @MainActor [weak self] in
                self?.log("❌ \(protocolName) send error: \(err.localizedDescription)")
            }
        })
    }

    func sendCustomOSC(
        host: String,
        port: UInt16,
        address: String,
        argType: OSCArgumentType,
        argValue: String = ""
    ) {
        sendCustomOSC(host: host, port: port, address: address, argType: argType.rawValue, argValue: argValue)
    }

    // ------------------------------------------------------------------------
    // MIDI TO OSC CUSTOM MAPPING ENGINE (INDIVIDUAL KEYS & FADERS)
    // ------------------------------------------------------------------------
    func filteredControlIndices() -> [Int] {
        var indices = Array(0..<controls.count)
        if let sec = HardwareSection(rawValue: midiToOSCFilter) {
            indices = indices.filter { sec.indexRange.contains($0) }
        }
        let query = midiToOSCSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            indices = indices.filter { idx in
                let item = controls[idx]
                return item.label.lowercased().contains(query) ||
                       item.customName.lowercased().contains(query) ||
                       item.zone.lowercased().contains(query) ||
                       item.oscAddress.lowercased().contains(query) ||
                       "\(item.number)".contains(query)
            }
        }
        return indices
    }

    func sendOSCForControl(index: Int, isPress: Bool = true, liveVal: UInt8? = nil) {
        guard midiToOSCMappingActive, index >= 0, index < controls.count, isSectionEnabled(for: index) else { return }
        let item = controls[index]
        guard item.oscEnabled || item.actionType == .osc else { return }

        let targetHost = item.oscHost.trimmingCharacters(in: .whitespaces).isEmpty ? customOSCHost : item.oscHost.trimmingCharacters(in: .whitespaces)
        let targetPort = item.oscPort == 0 ? customOSCPort : item.oscPort
        var targetAddr = item.oscAddress.trimmingCharacters(in: .whitespaces)
        if targetAddr.isEmpty {
            if item.kind == .vfader || item.kind == .hfader || item.kind == .knob {
                targetAddr = "/bitchboy/fader/\(max(1, index - 48))"
            } else {
                targetAddr = "/bitchboy/key/\(index + 1)"
            }
        }
        if !targetAddr.hasPrefix("/") {
            targetAddr = "/" + targetAddr
        }

        if isPress {
            if item.kind == .vfader || item.kind == .hfader || item.kind == .knob {
                let rawVal = liveVal ?? item.liveValue
                let norm = Double(rawVal) / 127.0
                let scaled = item.oscMinVal + norm * (item.oscMaxVal - item.oscMinVal)
                switch item.oscArgType {
                case "INT":
                    sendCustomOSC(host: targetHost, port: targetPort, address: targetAddr, argType: "INT", argValue: "\(Int32(round(scaled)))")
                case "NONE":
                    sendCustomOSC(host: targetHost, port: targetPort, address: targetAddr, argType: "NONE", argValue: "")
                case "STRING":
                    sendCustomOSC(host: targetHost, port: targetPort, address: targetAddr, argType: "STRING", argValue: item.oscArgValue)
                default: // FLOAT
                    sendCustomOSC(host: targetHost, port: targetPort, address: targetAddr, argType: "FLOAT", argValue: String(format: "%.3f", scaled))
                }
            } else {
                // Key / Button press
                switch item.oscArgType {
                case "BOOLEAN":
                    sendCustomOSC(host: targetHost, port: targetPort, address: targetAddr, argType: "BOOLEAN_TRUE", argValue: "1")
                case "INT":
                    let rawV = liveVal ?? item.activeVelocity
                    let intVal = item.oscArgValue.trimmingCharacters(in: .whitespaces).isEmpty ? "\(rawV)" : item.oscArgValue
                    sendCustomOSC(host: targetHost, port: targetPort, address: targetAddr, argType: "INT", argValue: intVal)
                case "FLOAT":
                    let floatVal = item.oscArgValue.trimmingCharacters(in: .whitespaces).isEmpty ? "1.0" : item.oscArgValue
                    sendCustomOSC(host: targetHost, port: targetPort, address: targetAddr, argType: "FLOAT", argValue: floatVal)
                case "STRING":
                    sendCustomOSC(host: targetHost, port: targetPort, address: targetAddr, argType: "STRING", argValue: item.oscArgValue)
                default: // NONE / BANG
                    sendCustomOSC(host: targetHost, port: targetPort, address: targetAddr, argType: "NONE", argValue: "")
                }
            }
        } else {
            // Key release
            if item.oscSendRelease {
                if item.oscArgType == "BOOLEAN" {
                    sendCustomOSC(host: targetHost, port: targetPort, address: targetAddr, argType: "BOOLEAN_FALSE", argValue: "0")
                } else if item.oscArgType == "INT" {
                    let relVal = item.oscReleaseVal.trimmingCharacters(in: .whitespaces).isEmpty ? "0" : item.oscReleaseVal
                    sendCustomOSC(host: targetHost, port: targetPort, address: targetAddr, argType: "INT", argValue: relVal)
                } else if item.oscArgType == "FLOAT" {
                    let relVal = item.oscReleaseVal.trimmingCharacters(in: .whitespaces).isEmpty ? "0.0" : item.oscReleaseVal
                    sendCustomOSC(host: targetHost, port: targetPort, address: targetAddr, argType: "FLOAT", argValue: relVal)
                }
            }
        }
    }

    func applyOSCAutoMapTemplate() {
        for i in 0..<controls.count {
            controls[i].oscEnabled = true
            controls[i].oscHost = customOSCHost
            controls[i].oscPort = customOSCPort
            if i < 49 {
                controls[i].oscAddress = "/bitchboy/key/\(i + 1)"
                controls[i].oscArgType = "FLOAT"
                controls[i].oscArgValue = "1.0"
                controls[i].oscSendRelease = true
                controls[i].oscReleaseVal = "0.0"
            } else if i >= 49 && i < 57 {
                controls[i].oscAddress = "/bitchboy/fader/\(i - 48)"
                controls[i].oscArgType = "FLOAT"
                controls[i].oscMinVal = 0.0
                controls[i].oscMaxVal = 1.0
            } else if i >= 57 && i < 61 {
                controls[i].oscAddress = "/bitchboy/fader/h/\(i - 56)"
                controls[i].oscArgType = "FLOAT"
                controls[i].oscMinVal = 0.0
                controls[i].oscMaxVal = 1.0
            } else {
                controls[i].oscAddress = "/bitchboy/knob/\(i - 60)"
                controls[i].oscArgType = "FLOAT"
                controls[i].oscMinVal = 0.0
                controls[i].oscMaxVal = 1.0
            }
        }
        log("⚡ OSC Auto-Map Template Applied: All 65 controls configured with standard /bitchboy endpoints")
        SoundEffect.presetSwitch.play(with: soundPack)
    }

    func applyOSCQLabTemplate() {
        customOSCPort = 53000
        for i in 0..<controls.count {
            controls[i].oscEnabled = true
            controls[i].oscHost = customOSCHost
            controls[i].oscPort = 53000
            if i < 32 {
                controls[i].customName = "Cue \(i + 1)"
                controls[i].oscAddress = "/cue/\(i + 1)/start"
                controls[i].oscArgType = "NONE"
                controls[i].oscSendRelease = false
            } else if i == 32 {
                controls[i].customName = "QLab GO"
                controls[i].oscAddress = "/go"
                controls[i].oscArgType = "NONE"
            } else if i == 33 {
                controls[i].customName = "Panic All"
                controls[i].oscAddress = "/panic"
                controls[i].oscArgType = "NONE"
            } else if i == 34 {
                controls[i].customName = "Hard Stop"
                controls[i].oscAddress = "/hardStop"
                controls[i].oscArgType = "NONE"
            } else if i == 35 {
                controls[i].customName = "Pause"
                controls[i].oscAddress = "/pause"
                controls[i].oscArgType = "NONE"
            } else if i == 36 {
                controls[i].customName = "Resume"
                controls[i].oscAddress = "/resume"
                controls[i].oscArgType = "NONE"
            } else if i == 37 {
                controls[i].customName = "Prev Cue"
                controls[i].oscAddress = "/previous"
                controls[i].oscArgType = "NONE"
            } else if i == 38 {
                controls[i].customName = "Next Cue"
                controls[i].oscAddress = "/next"
                controls[i].oscArgType = "NONE"
            } else if i == 39 {
                controls[i].customName = "Reset"
                controls[i].oscAddress = "/reset"
                controls[i].oscArgType = "NONE"
            } else if i >= 40 && i < 49 {
                controls[i].customName = "Cue Pad \(i - 39)"
                controls[i].oscAddress = "/cue/\(i - 39)/start"
                controls[i].oscArgType = "NONE"
            } else if i >= 49 && i < 57 {
                let fIdx = i - 48
                controls[i].customName = "Cue \(fIdx) Vol"
                controls[i].oscAddress = "/cue/\(fIdx)/sliderLevel/1"
                controls[i].oscArgType = "FLOAT"
                controls[i].oscMinVal = -60.0
                controls[i].oscMaxVal = 12.0
            } else if i >= 57 && i < 61 {
                let hIdx = i - 56
                controls[i].customName = "Aux \(hIdx)"
                controls[i].oscAddress = "/cue/selected/level/\(hIdx)"
                controls[i].oscArgType = "FLOAT"
                controls[i].oscMinVal = 0.0
                controls[i].oscMaxVal = 1.0
            } else {
                controls[i].customName = "Master Level"
                controls[i].oscAddress = "/masterVolume"
                controls[i].oscArgType = "FLOAT"
                controls[i].oscMinVal = 0.0
                controls[i].oscMaxVal = 1.0
            }
        }
        log("🎭 QLab OSC Template Applied: Port 53000, 32 Cues, Transport Keys & 8 Volume Faders")
        SoundEffect.presetSwitch.play(with: soundPack)
    }

    func applyOSCResolumeTemplate() {
        customOSCPort = 7000
        for i in 0..<controls.count {
            controls[i].oscEnabled = true
            controls[i].oscHost = customOSCHost
            controls[i].oscPort = 7000
            if i < 32 {
                let layer = (i % 4) + 1
                let clip = (i / 4) + 1
                controls[i].customName = "L\(layer) C\(clip)"
                controls[i].oscAddress = "/composition/layers/\(layer)/clips/\(clip)/connect"
                controls[i].oscArgType = "INT"
                controls[i].oscArgValue = "1"
            } else if i >= 49 && i < 57 {
                let layer = i - 48
                controls[i].customName = "Layer \(layer) Opacity"
                controls[i].oscAddress = "/composition/layers/\(layer)/video/opacity"
                controls[i].oscArgType = "FLOAT"
                controls[i].oscMinVal = 0.0
                controls[i].oscMaxVal = 1.0
            } else if i >= 61 {
                controls[i].customName = "Master Opacity"
                controls[i].oscAddress = "/composition/master"
                controls[i].oscArgType = "FLOAT"
                controls[i].oscMinVal = 0.0
                controls[i].oscMaxVal = 1.0
            }
        }
        log("🎬 Resolume OSC Template Applied: Port 7000, Clip Grid Matrix & Layer Opacity Faders")
        SoundEffect.presetSwitch.play(with: soundPack)
    }

    func applyOSCEosTemplate() {
        customOSCPort = 8000
        for i in 0..<controls.count {
            controls[i].oscEnabled = true
            controls[i].oscHost = customOSCHost
            controls[i].oscPort = 8000
            if i < 32 {
                controls[i].customName = "EOS Key \(i + 1)"
                controls[i].oscAddress = "/eos/key/\(i + 1)"
                controls[i].oscArgType = "NONE"
            } else if i == 32 {
                controls[i].customName = "EOS GO"
                controls[i].oscAddress = "/eos/key/go_0"
                controls[i].oscArgType = "NONE"
            } else if i == 33 {
                controls[i].customName = "EOS Stop"
                controls[i].oscAddress = "/eos/key/stop"
                controls[i].oscArgType = "NONE"
            } else if i >= 49 && i < 57 {
                let fIdx = i - 48
                controls[i].customName = "Submaster \(fIdx)"
                controls[i].oscAddress = "/eos/fader/1/\(fIdx)"
                controls[i].oscArgType = "FLOAT"
                controls[i].oscMinVal = 0.0
                controls[i].oscMaxVal = 1.0
            }
        }
        log("💡 ETC EOS OSC Template Applied: Port 8000, Go/Stop & Submaster Faders")
        SoundEffect.presetSwitch.play(with: soundPack)
    }

    func clearAllOSCMappings() {
        for i in 0..<controls.count {
            controls[i].oscEnabled = false
            controls[i].oscAddress = ""
            controls[i].customName = ""
        }
        log("🧹 All MIDI to OSC Mappings Cleared")
        SoundEffect.keyTap.play(with: soundPack)
    }

    func toggleAllOSCMappings(enabled: Bool) {
        for i in 0..<controls.count {
            controls[i].oscEnabled = enabled
        }
        log("🔄 All MIDI to OSC Mappings: \(enabled ? "ENABLED" : "DISABLED")")
        SoundEffect.knobTick.play(with: soundPack)
    }

    // ------------------------------------------------------------------------
    // SHOW CONTROL PROTOCOL UTILITIES: BLACKOUT, MASTER & RIG CONTROL
    // ------------------------------------------------------------------------
    func panicBlackoutAll() {
        isBlackoutActive = true
        sendArtNetBlackout()
        sendSACNBlackout()
        sendMSCBroadcast(command: .allOff, cue: "", deviceID: 127)
        sendCustomOSC(host: customOSCHost, port: customOSCPort, address: "/panic", argType: "NONE", argValue: "")
        sendPanicAllNotesOffToOutputs()
        setZoneLEDs(range: 0..<49, velocity: 0)
        SoundEffect.hardwareDisconnected.play(with: soundPack)
        log("🚨 PANIC BLACKOUT EXECUTED: All Lighting, Audio, MSC & MIDI Silenced")
    }

    func toggleBlackout() {
        isBlackoutActive.toggle()
        if isBlackoutActive {
            panicBlackoutAll()
        } else {
            sendArtNetFullRig()
            sendSACNFullRig()
            SoundEffect.presetSwitch.play(with: soundPack)
            log("💡 Blackout Disengaged — Restored Rig Levels")
        }
    }

    func flashRigMomentary() {
        SoundEffect.presetSwitch.play(with: soundPack)
        let savedGM = grandMasterLevel
        grandMasterLevel = 1.0
        sendArtNetFullRig()
        sendSACNFullRig()
        setZoneLEDs(range: 0..<49, velocity: 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.grandMasterLevel = savedGM
            if self.isBlackoutActive {
                self.sendArtNetBlackout()
                self.sendSACNBlackout()
                self.setZoneLEDs(range: 0..<49, velocity: 0)
            } else {
                self.sendArtNetFullRig()
            }
        }
    }

    func setGrandMaster(_ level: Double) {
        grandMasterLevel = max(0.0, min(1.0, level))
        for i in 0..<8 {
            let baseVal = Double(controls[49 + i].liveValue) * 2.0
            artNetChannels[i] = UInt8(max(0.0, min(255.0, baseVal * grandMasterLevel)))
        }
        sendThrottledArtNetFaderMirror()
    }

    // ------------------------------------------------------------------------
    // INBOUND EXTERNAL MIDI (DAWs, QLab, Virtual Endpoint) & FEEDBACK ECHO
    // ------------------------------------------------------------------------
    func handleInboundExternalMIDI(status: UInt8, data1: UInt8, data2: UInt8) {
        let msgType = status & 0xF0
        let isNoteOn = (msgType == 0x90) && (data2 > 0)
        let isNoteOff = (msgType == 0x80) || ((msgType == 0x90) && (data2 == 0))
        let isCC = (msgType == 0xB0)

        guard let idx = (isCC ? controlIndex(forCC: data1) : (isNoteOn || isNoteOff ? controlIndex(forNote: data1) : nil)) else { return }

        guard isSectionEnabled(for: idx) else { return }

        if isNoteOn {
            controls[idx].isPressed = true
            lastStreamMessage = "[EXT RX // \(controls[idx].label)] NOTE #\(data1) VEL:\(data2)"
            if inboundMIDIEchoEnabled && idx < 49 {
                let echoVel = BitchBoyHardwareColor.closestHardwareVelocity(for: data2)
                controls[idx].currentLED = echoVel
                sendNoteOn(note: data1, velocity: echoVel)
                triggerReactiveKeyFX(at: idx)
            }
        } else if isNoteOff {
            controls[idx].isPressed = false
            if inboundMIDIEchoEnabled && idx < 49 && activeReactivePulses.isEmpty {
                let restore = controls[idx].idleVelocity
                controls[idx].currentLED = restore
                sendNoteOn(note: data1, velocity: restore)
            }
        } else if isCC {
            controls[idx].liveValue = data2
            lastStreamMessage = "[EXT RX // \(controls[idx].label)] CC #\(data1) VAL:\(data2)"
        }
    }

    // ------------------------------------------------------------------------
    // INTERACTION & SIMULATION
    // ------------------------------------------------------------------------
    func handleKeyPressWithModifiers(index: Int, isShiftDown: Bool) {
        guard index >= 0 && index < controls.count, isSectionEnabled(for: index) else { return }
        if paintOnMainChassis && index < 49 {
            paintCustomFXKey(keyIndex: index, velocity: customBrushVelocity)
            selectedIndex = index
            return
        }
        if isShiftDown {
            if selectedIndices.contains(index) {
                selectedIndices.remove(index)
            } else {
                selectedIndices.insert(index)
            }
            selectedIndex = index
        } else {
            selectedIndices = [index]
            selectedIndex = index
        }
        simulateKeyPress(at: index)
    }

    func simulateKeyPress(at index: Int) {
        guard index < controls.count, isSectionEnabled(for: index) else { return }
        selectedIndex = index
        if !selectedIndices.contains(index) {
            selectedIndices.insert(index)
        }

        controls[index].isPressed = true
        let note = controls[index].number
        let activeVel = controls[index].activeVelocity

        SoundEffect.keyTap.play(with: soundPack)
        lastStreamMessage = "[\(controls[index].label)] PRESS #\(note) V:\(activeVel)"
        log("🎹 Tap: \(controls[index].label) (Note #\(note) Vel: \(activeVel))")

        if hardwareFeedbackEnabled {
            switch controls[index].feedbackMode {
            case .momentary:
                controls[index].currentLED = activeVel
                sendNoteOn(note: note, velocity: activeVel)
            case .toggle:
                controls[index].toggleLatched.toggle()
                let v = controls[index].toggleLatched ? activeVel : controls[index].idleVelocity
                controls[index].currentLED = v
                sendNoteOn(note: note, velocity: v)
            case .staticLED:
                controls[index].currentLED = controls[index].idleVelocity
                sendNoteOn(note: note, velocity: controls[index].idleVelocity)
            case .customVelocity:
                let v = controls[index].feedbackCustomVelocity
                controls[index].currentLED = v
                sendNoteOn(note: note, velocity: v)
            case .echoInbound:
                controls[index].currentLED = activeVel
                sendNoteOn(note: note, velocity: activeVel)
            case .disabled:
                break
            }
        }

        executeAction(for: controls[index])
        if index < 49 {
            triggerReactiveKeyFX(at: index)
        }
        sendOSCForControl(index: index, isPress: true)
        if forwardUIInteractions {
            routeIncomingMIDIToTargets(status: 0x90, data1: note, data2: activeVel, isFromHardware: false)
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self.controls[index].isPressed = false
            self.sendOSCForControl(index: index, isPress: false)
            if (self.controls[index].feedbackMode == .momentary || self.controls[index].feedbackMode == .customVelocity) && self.activeReactivePulses.isEmpty {
                let idleVel = self.controls[index].idleVelocity
                self.controls[index].currentLED = idleVel
                if self.hardwareFeedbackEnabled {
                    self.sendNoteOn(note: note, velocity: idleVel)
                }
                self.lastStreamMessage = "[\(self.controls[index].label)] RELEASE #\(note) V:\(idleVel)"
            }
            if self.forwardUIInteractions {
                self.routeIncomingMIDIToTargets(status: 0x80, data1: note, data2: 0, isFromHardware: false)
            }
        }
    }

    // ------------------------------------------------------------------------
    // REACTIVE MECHANICAL KEYBOARD INTERACTIVE FX ENGINE (49-KEY MATRIX)
    // ------------------------------------------------------------------------
    func triggerReactiveKeyFX(at keyIndex: Int) {
        guard keyIndex >= 0 && keyIndex < 49, reactiveKeyFXMode != .off else { return }
        lastReactiveOriginKey = keyIndex
        let pos = BitchBoyKeyMap.keyPositions[keyIndex]
        let palette: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 57, 3]
        let chosenVel: UInt8 = reactiveFXRainbowColor
            ? palette[(keyIndex * 3 + activeReactivePulses.count * 2) % palette.count]
            : reactiveFXColorVelocity

        var targets = Set<Int>()
        if reactiveKeyFXMode == .arcLightning {
            var pool = Array(0..<49).filter { $0 != keyIndex }
            pool.shuffle()
            targets = Set(pool.prefix(8))
        }

        let pulse = ReactivePulseEvent(
            originKeyIndex: keyIndex,
            originCol: Double(pos.col),
            originRow: Double(pos.row),
            mode: reactiveKeyFXMode,
            baseVelocity: chosenVel,
            age: 0.0,
            lightningTargets: targets
        )
        activeReactivePulses.append(pulse)
        if activeReactivePulses.count > 4 {
            activeReactivePulses.removeFirst(activeReactivePulses.count - 4)
        }

        if reactiveWaveCount != activeReactivePulses.count {
            reactiveWaveCount = activeReactivePulses.count
        }

        startReactiveTimerIfNeeded()
    }

    private func startReactiveTimerIfNeeded() {
        guard reactiveFXTimer == nil else { return }
        lastSentReactiveLEDs = Array(repeating: 255, count: 49)
        lastFrameTimestamp = CACurrentMediaTime()
        let intervalMicros = targetFPS == 120 ? 8333 : 16666
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + .microseconds(intervalMicros), repeating: .microseconds(intervalMicros), leeway: .microseconds(250))
        timer.setEventHandler { [weak self] in
            self?.stepReactiveKeyFX()
        }
        reactiveFXTimer = timer
        timer.resume()
    }

    private func stopReactiveTimer() {
        reactiveFXTimer?.cancel()
        reactiveFXTimer = nil
    }

    func triggerRandomDemoReactiveFX() {
        let centerKeys = [11, 12, 19, 20, 18, 21, 44]
        let randomKey = centerKeys.randomElement() ?? Int.random(in: 0..<49)
        if reactiveKeyFXMode == .off {
            reactiveKeyFXMode = .ripple
        }
        triggerReactiveKeyFX(at: randomKey)
        SoundEffect.keyTap.play(with: soundPack)
    }

    private func stepReactiveKeyFX() {
        guard !activeReactivePulses.isEmpty else {
            stopReactiveTimer()
            if reactiveWaveCount != 0 {
                reactiveWaveCount = 0
            }
            return
        }

        let now = CACurrentMediaTime()
        let elapsed = lastFrameTimestamp > 0 ? (now - lastFrameTimestamp) : (1.0 / Double(targetFPS))
        lastFrameTimestamp = now
        let dt = min(0.04, elapsed) * max(0.3, reactiveFXSpeed)

        frameCountSinceLastMeasure += 1
        if now - lastFPSMeasureTimestamp >= 0.5 {
            let mElapsed = now - lastFPSMeasureTimestamp
            measuredFPS = Double(frameCountSinceLastMeasure) / mElapsed
            frameLatencyMs = (1.0 / max(1.0, measuredFPS)) * 1000.0
            frameCountSinceLastMeasure = 0
            lastFPSMeasureTimestamp = now
        }

        for i in activeReactivePulses.indices {
            activeReactivePulses[i].age += dt
        }
        activeReactivePulses.removeAll { $0.age > 1.05 }

        if reactiveWaveCount != activeReactivePulses.count {
            reactiveWaveCount = activeReactivePulses.count
        }

        let palette: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 57, 3]

        var batch = controls
        var didChangeUI = false
        var hardwareNotes: [(keyIndex: Int, note: UInt8, velocity: UInt8, delta: Int)] = []

        for k in 0..<49 {
            guard isSectionEnabled(for: k) else { continue }
            let baseVel: UInt8
            if batch[k].isPressed {
                baseVel = batch[k].activeVelocity
            } else if batch[k].feedbackMode == .toggle && batch[k].toggleLatched {
                baseVel = batch[k].activeVelocity
            } else {
                baseVel = batch[k].idleVelocity
            }

            var effectVel: UInt8 = 0
            var maxIntensity: Double = 0.0
            let kPos = BitchBoyKeyMap.keyPositions[k]
            let kc = Double(kPos.col)
            let kr = Double(kPos.row)

            for pulse in activeReactivePulses {
                let dist = BitchBoyKeyMap.keyDistances[k][pulse.originKeyIndex]
                let dx = kc - pulse.originCol
                let dy = kr - pulse.originRow
                var intensity: Double = 0.0

                switch pulse.mode {
                case .ripple:
                    let radius = pulse.age * 11.5
                    let ringDiff = abs(dist - radius)
                    if ringDiff < 1.45 {
                        intensity = (1.0 - ringDiff / 1.45) * max(0.0, 1.0 - pulse.age * 0.75)
                    }
                case .crossLaser:
                    let beamPos = pulse.age * 11.0
                    if Int(kr) == Int(pulse.originRow) {
                        let d = abs( abs(dx) - beamPos )
                        if d < 1.6 {
                            intensity = (1.0 - d / 1.6) * (1.0 - pulse.age * 0.65)
                        }
                    }
                    if Int(kc) == Int(pulse.originCol) {
                        let d = abs( abs(dy) - beamPos * 0.65 )
                        if d < 1.3 {
                            intensity = max(intensity, (1.0 - d / 1.3) * (1.0 - pulse.age * 0.65))
                        }
                    }
                case .supernova:
                    let maxR = 6.5 * sin(pulse.age * .pi)
                    if dist <= maxR {
                        intensity = (1.0 - dist / max(0.5, maxR)) * (1.0 - pulse.age * 0.5)
                    }
                case .heatTrail:
                    if k == pulse.originKeyIndex {
                        intensity = max(0.0, 1.0 - pulse.age)
                    } else if dist <= 1.5 {
                        intensity = max(0.0, (0.65 - pulse.age * 0.85) * (1.0 - dist / 1.6))
                    }
                case .meteorRain:
                    if Int(kc) == Int(pulse.originCol) {
                        let dropRow = fmod(pulse.originRow + pulse.age * 7.5, 5.0)
                        let d = abs(kr - dropRow)
                        if d < 1.35 {
                            intensity = (1.0 - d / 1.35) * (1.0 - pulse.age * 0.65)
                        }
                    }
                case .arcLightning:
                    if k == pulse.originKeyIndex || pulse.lightningTargets.contains(k) {
                        let flicker = sin(pulse.age * 42.0 + Double(k)) > -0.2 ? 1.0 : 0.35
                        intensity = (1.0 - pulse.age * 0.85) * flicker
                    }
                case .off:
                    break
                }

                if intensity > maxIntensity {
                    maxIntensity = intensity
                    if reactiveFXRainbowColor {
                        let pIdx = abs(Int(round(dist + pulse.age * 8.0)) + pulse.originKeyIndex) % palette.count
                        effectVel = intensity > 0.72 ? 3 : palette[pIdx]
                    } else {
                        effectVel = intensity > 0.82 ? 3 : pulse.baseVelocity
                    }
                }
            }

            let finalVel: UInt8 = maxIntensity > 0.14 ? effectVel : baseVel
            if batch[k].currentLED != finalVel {
                batch[k].currentLED = finalVel
                didChangeUI = true
            }

            let lastSent = lastSentReactiveLEDs[k]
            let delta = abs(Int(lastSent) - Int(finalVel))
            let isSignificant = delta >= 3 || (finalVel == 0 && lastSent != 0) || (lastSent == 0 && finalVel != 0)
            if isSignificant {
                hardwareNotes.append((keyIndex: k, note: batch[k].number, velocity: finalVel, delta: delta))
            }
        }

        if didChangeUI {
            controls = batch
        }

        if !hardwareNotes.isEmpty && isConnected && bitchBoyDestination != 0 && (now - lastHardwareMIDISendTime >= 0.016) {
            lastHardwareMIDISendTime = now
            if hardwareNotes.count > 16 {
                hardwareNotes.sort { $0.delta > $1.delta }
                hardwareNotes = Array(hardwareNotes.prefix(16))
            }
            for item in hardwareNotes {
                lastSentReactiveLEDs[item.keyIndex] = item.velocity
            }
            let sendItems = hardwareNotes.map { (note: $0.note, velocity: $0.velocity) }
            sendBatchNoteOn(notesAndVelocities: sendItems)
        }

        if activeReactivePulses.isEmpty {
            stopReactiveTimer()
            if reactiveWaveCount != 0 {
                reactiveWaveCount = 0
            }
            var restoreNotes: [(note: UInt8, velocity: UInt8)] = []
            for k in 0..<49 {
                guard isSectionEnabled(for: k) else { continue }
                let v = controls[k].currentLED
                if lastSentReactiveLEDs[k] != v {
                    lastSentReactiveLEDs[k] = v
                    restoreNotes.append((note: controls[k].number, velocity: v))
                }
            }
            if !restoreNotes.isEmpty {
                sendBatchNoteOn(notesAndVelocities: restoreNotes)
            }
        }
    }

    @ObservationIgnored private var lastFaderSlideSoundTime: Date = Date.distantPast

    func setControlLiveValue(index: Int, value: UInt8) {
        guard index < controls.count, isSectionEnabled(for: index) else { return }
        if controls[index].liveValue == value && selectedIndex == index {
            return
        }
        recordUndoSnapshot(actionName: "Move \(controls[index].label)", debounceSeconds: 0.8)
        if selectedIndex != index {
            selectedIndex = index
        }
        controls[index].liveValue = value

        // Determine if hardware MIDI output is enabled for this section
        let canSendCC: Bool = {
            guard hardwareMIDISendEnabled else { return false }
            if index >= 49 && index < 57 { return verticalFadersMIDISendEnabled }
            if index >= 57 && index < 61 { return horizontalFadersMIDISendEnabled }
            if index >= 61 && index < 69 { return rotaryKnobsMIDISendEnabled }
            return true
        }()

        if canSendCC {
            sendCC(cc: controls[index].number, value: value)
            if forwardUIInteractions {
                routeIncomingMIDIToTargets(status: 0xB0, data1: controls[index].number, data2: value, isFromHardware: false)
            }
        }

        if oscSendEnabled {
            sendOSCForControl(index: index, isPress: true, liveVal: value)
        }

        let now = Date()
        if now.timeIntervalSince(lastStreamMessageUpdateTime) >= 0.08 {
            lastStreamMessageUpdateTime = now
            lastStreamMessage = "[\(controls[index].label)] CC #\(controls[index].number) VAL: \(value)"
        }

        if now.timeIntervalSince(lastFaderSlideSoundTime) >= 0.08 && uiClickSoundEnabled {
            lastFaderSlideSoundTime = now
            SoundEffect.faderSlide.play(with: soundPack)
        }
        if currentFXMode == .vuMeter && index >= 49 && index < 57 {
            updateVUMeterFaders()
        }
    }

    func batchUpdateLEDs(_ updates: [(index: Int, velocity: UInt8)]) {
        guard !updates.isEmpty else { return }
        var didChangeUI = false
        var batch = controls
        var midiNotes: [(note: UInt8, velocity: UInt8)] = []

        for (idx, vel) in updates {
            guard idx < batch.count else { continue }
            let targetVel: UInt8 = isSectionEnabled(for: idx) ? vel : 0
            if batch[idx].currentLED != targetVel {
                batch[idx].currentLED = targetVel
                didChangeUI = true
                midiNotes.append((note: batch[idx].number, velocity: targetVel))
            }
        }

        if didChangeUI {
            controls = batch
        }

        if !midiNotes.isEmpty && isConnected && bitchBoyDestination != 0 {
            sendBatchNoteOn(notesAndVelocities: midiNotes)
        }
    }

    // ------------------------------------------------------------------------
    // LIGHTING EFFECTS ENGINE (15 PROCEDURAL SHOWS + CONTINUOUS HARDWARE SYNC)
    // ------------------------------------------------------------------------
    func cycleFXMode() {
        let modes = LEDFXMode.allCases
        if let idx = modes.firstIndex(of: currentFXMode) {
            let next = modes[(idx + 1) % modes.count]
            applyFXMode(next)
        }
    }

    func applyFXMode(_ mode: LEDFXMode) {
        isPlayingCustomFX = false
        activeCustomFXName = ""
        currentFXMode = mode
        vuMeterLEDsEnabled = (mode == .vuMeter)
        fxTimer?.cancel()
        fxTimer = nil

        switch mode {
        case .staticFX:
            restorePresetLEDs()
            log("💡 FX Mode: STATIC PRESET (Restored LEDs)")
        case .rainbowContinuous:
            startContinuousRainbowFX()
            log("🌈 FX Mode: CONTINUOUS RAINBOW WAVE")
        case .knightRider:
            startKnightRiderFX()
            log("⚡️ FX Mode: CYLON SCANNER")
        case .matrixRain:
            startMatrixRainFX()
            log("🌧️ FX Mode: DIGITAL MATRIX RAIN")
        case .cyberPulse:
            startCyberPulseFX()
            log("🔮 FX Mode: CYBERPUNK PULSE")
        case .vuMeter:
            startVUMeterFX()
            log("🎚️ FX Mode: LIVE FADER VU METER")
        case .fireEmbers:
            startFireEmbersFX()
            log("🔥 FX Mode: FIRE & EMBERS")
        case .waterRipple:
            startWaterRippleFX()
            log("💧 FX Mode: CENTER RIPPLE")
        case .starfield:
            startStarfieldFX()
            log("✨ FX Mode: TWINKLE STARS")
        case .audioStrobe:
            startAudioStrobeFX()
            log("⚡️ FX Mode: STROBE FLASH")
        case .heartbeat:
            startHeartbeatFX()
            log("💓 FX Mode: HEARTBEAT")
        case .plasmaWave:
            startPlasmaWaveFX()
            log("🌀 FX Mode: PLASMA FIELD")
        case .spiralVortex:
            startSpiralVortexFX()
            log("🌪️ FX Mode: SPIRAL VORTEX")
        case .eqDance:
            startEQDanceFX()
            log("📊 FX Mode: EQ DANCE")
        case .colorChase:
            startColorChaseFX()
            log("🐍 FX Mode: COLOR RUNNER")
        }
    }

    func restorePresetLEDs() {
        var batchNotes: [(note: UInt8, velocity: UInt8)] = []
        for i in 0..<49 {
            let targetVel: UInt8
            if !isSectionEnabled(for: i) {
                targetVel = 0
            } else {
                switch controls[i].feedbackMode {
                case .toggle:
                    targetVel = controls[i].toggleLatched ? controls[i].activeVelocity : controls[i].idleVelocity
                case .disabled:
                    targetVel = 0
                default:
                    targetVel = controls[i].idleVelocity
                }
            }
            controls[i].currentLED = targetVel
            batchNotes.append((note: controls[i].number, velocity: targetVel))
        }
        sendBatchNoteOn(notesAndVelocities: batchNotes)
    }

    func clearReactiveKeyFX() {
        activeReactivePulses.removeAll()
        reactiveWaveCount = 0
        stopReactiveTimer()
        lastSentReactiveLEDs = Array(repeating: 255, count: 49)
        restorePresetLEDs()
    }

    // 1. Authentic Rainbow Wave Refresh Sweep (sweeps 11 columns and restores presets)
    func runRainbowWaveRefresh() {
        guard !isRainbowRunning else { return }
        isRainbowRunning = true
        log("✨ Sweeping Rainbow Wave Hardware LED Refresh...")

        Task { @MainActor in
            let rainbowVelocities: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 57, 3]
            let totalSteps = 22
            for step in 0..<totalSteps {
                var updates: [(index: Int, velocity: UInt8)] = []
                updates.reserveCapacity(49)
                for k in 0..<49 {
                    let col = BitchBoyKeyMap.keyPositions[k].col
                    let wavePos = step - col
                    if wavePos >= 0 && wavePos < rainbowVelocities.count {
                        updates.append((k, rainbowVelocities[wavePos]))
                    } else if wavePos >= rainbowVelocities.count {
                        updates.append((k, self.controls[k].idleVelocity))
                    }
                }
                self.batchUpdateLEDs(updates)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if self.currentFXMode == .staticFX {
                self.restorePresetLEDs()
            }
            self.isRainbowRunning = false
            self.log("✅ Rainbow Wave Refresh Complete")
        }
    }

    // 2. Continuous 11-Column Rainbow Wave (Loops forever until stopped)
    private func startContinuousRainbowFX() {
        let rainbowVelocities: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 57, 3]
        var step = 0
        let interval = 0.07 / max(0.2, fxSpeed)
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                step += 1
                var updates: [(index: Int, velocity: UInt8)] = []
                updates.reserveCapacity(49)
                for k in 0..<49 {
                    let col = BitchBoyKeyMap.keyPositions[k].col
                    let vel = rainbowVelocities[(step + col) % rainbowVelocities.count]
                    updates.append((k, vel))
                }
                self.batchUpdateLEDs(updates)
            }
    }

    // 3. Knight Rider / Cylon Scanner (Sweeps across columns 0..10)
    private func startKnightRiderFX() {
        var step = 0
        let interval = 0.05 / max(0.2, fxSpeed)
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                step = (step + 1) % 20
                let activeCol = step <= 10 ? step : (20 - step)
                var updates: [(index: Int, velocity: UInt8)] = []
                updates.reserveCapacity(49)
                for k in 0..<49 {
                    let col = BitchBoyKeyMap.keyPositions[k].col
                    let dist = abs(col - activeCol)
                    let vel: UInt8 = dist == 0 ? 72 : (dist == 1 ? 61 : (dist == 2 ? 83 : 0))
                    updates.append((k, vel))
                }
                self.batchUpdateLEDs(updates)
            }
    }

    // 4. Digital Matrix Rain (Cascading droplets down columns)
    private func startMatrixRainFX() {
        var step = 0
        let interval = 0.07 / max(0.2, fxSpeed)
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                step += 1
                var updates: [(index: Int, velocity: UInt8)] = []
                updates.reserveCapacity(49)
                for k in 0..<49 {
                    let col = BitchBoyKeyMap.keyPositions[k].col
                    let row = BitchBoyKeyMap.keyPositions[k].row
                    let dropRow = (step + col * 3) % 7
                    let vel: UInt8 = (row == dropRow) ? 3 : (row == (dropRow - 1 + 7) % 7 ? 87 : (row == (dropRow - 2 + 7) % 7 ? 33 : 0))
                    updates.append((k, vel))
                }
                self.batchUpdateLEDs(updates)
            }
    }

    // 5. Cyberpunk Pulse (Smooth breathing through neon velocities)
    private func startCyberPulseFX() {
        var phase: Double = 0
        let baseInterval = 0.04 / max(0.2, fxSpeed)
        let interval = max(1.0 / Double(targetFPS), baseInterval / (Double(targetFPS) / 25.0))
        let phaseStep = 0.12 * (interval / baseInterval)
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                phase += phaseStep
                let normalized = (sin(phase) + 1.0) * 0.5
                let vel = UInt8(normalized * 115.0 + 12.0)
                var updates: [(index: Int, velocity: UInt8)] = []
                updates.reserveCapacity(49)
                for k in 0..<49 {
                    updates.append((k, vel))
                }
                self.batchUpdateLEDs(updates)
            }
    }

    // 6. Live Fader VU Meter (8 vertical faders control columns 0..7)
    private func startVUMeterFX() {
        let interval = 0.08 / max(0.2, fxSpeed)
        var bgTick = 0
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                bgTick += 1
                self.updateVUMeterFaders(bgTick: bgTick)
            }
    }

    func updateVUMeterFaders(bgTick: Int = 0) {
        var updates: [(index: Int, velocity: UInt8)] = []
        updates.reserveCapacity(49)
        for col in 0..<8 {
            let faderVal = Double(controls[49 + col].liveValue)
            let colKeyIndices = [32 + col, 24 + col, 16 + col, 8 + col, 0 + col]
            let thresholds: [Double] = [15, 40, 65, 90, 115]
            let colors: [UInt8] = [87, 87, 74, 61, 72]
            for seg in 0..<5 {
                let kIdx = colKeyIndices[seg]
                let isLit = faderVal >= thresholds[seg]
                let vel: UInt8 = isLit ? colors[seg] : 0
                updates.append((kIdx, vel))
            }
        }
        let padWave = UInt8(((sin(Double(bgTick) * 0.2) + 1.0) * 0.5) * 40.0 + 10.0)
        for p in 40..<49 {
            updates.append((p, padWave))
        }
        batchUpdateLEDs(updates)
    }

    // 7. Fire & Embers (Organic flame simulation with flickering coals)
    private func startFireEmbersFX() {
        let interval = 0.08 / max(0.2, fxSpeed)
        let firePal: [UInt8] = [0, 83, 72, 61, 96, 74, 3]
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                var updates: [(index: Int, velocity: UInt8)] = []
                updates.reserveCapacity(49)
                for k in 0..<49 {
                    let row = BitchBoyKeyMap.keyPositions[k].row
                    let heatIdx = min(firePal.count - 1, max(0, (4 - row) + Int.random(in: -1...1)))
                    updates.append((k, firePal[heatIdx]))
                }
                self.batchUpdateLEDs(updates)
            }
    }

    // 8. Center Ripple (Concentric shockwaves expanding outward)
    private func startWaterRippleFX() {
        var phase: Double = 0
        let baseInterval = 0.05 / max(0.2, fxSpeed)
        let interval = max(1.0 / Double(targetFPS), baseInterval / (Double(targetFPS) / 20.0))
        let phaseStep = 0.25 * (interval / baseInterval)
        let waterPal: [UInt8] = [0, 41, 33, 78, 3]
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                phase += phaseStep
                let centerCol = 3.5
                let centerRow = 2.0
                var updates: [(index: Int, velocity: UInt8)] = []
                updates.reserveCapacity(49)
                for k in 0..<49 {
                    let col = Double(BitchBoyKeyMap.keyPositions[k].col)
                    let row = Double(BitchBoyKeyMap.keyPositions[k].row)
                    let dist = sqrt(pow(col - centerCol, 2) + pow(row - centerRow, 2))
                    let wave = sin(dist * 1.6 - phase)
                    let norm = max(0.0, wave)
                    let pIdx = Int(norm * Double(waterPal.count - 1))
                    let vel = waterPal[min(waterPal.count - 1, max(0, pIdx))]
                    updates.append((k, vel))
                }
                self.batchUpdateLEDs(updates)
            }
    }

    // 9. Twinkle Stars (Deep-space twinkling night sky)
    private func startStarfieldFX() {
        var starBrightness: [UInt8] = Array(repeating: 0, count: 49)
        let interval = 0.08 / max(0.2, fxSpeed)
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                for i in 0..<49 {
                    if starBrightness[i] > 14 {
                        starBrightness[i] -= 14
                    } else {
                        starBrightness[i] = 0
                    }
                }
                for _ in 0..<Int.random(in: 2...4) {
                    let rIdx = Int.random(in: 0..<49)
                    starBrightness[rIdx] = [3, 78, 33, 41, 74, 57].randomElement() ?? 3
                }
                var updates: [(index: Int, velocity: UInt8)] = []
                updates.reserveCapacity(49)
                for k in 0..<49 {
                    updates.append((k, starBrightness[k]))
                }
                self.batchUpdateLEDs(updates)
            }
    }

    // 10. Strobe Flash (Fast stroboscopic burst)
    private func startAudioStrobeFX() {
        var count = 0
        let interval = 0.07 / max(0.2, fxSpeed)
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                count += 1
                let vel: UInt8 = (count % 3 == 0) ? 3 : 0
                var updates: [(index: Int, velocity: UInt8)] = []
                updates.reserveCapacity(49)
                for k in 0..<49 {
                    updates.append((k, vel))
                }
                self.batchUpdateLEDs(updates)
            }
    }

    // 11. Heartbeat (Realistic double-thump cardiac pulse)
    private func startHeartbeatFX() {
        var step = 0
        let interval = 0.05 / max(0.2, fxSpeed)
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                step = (step + 1) % 24
                let vel: UInt8
                switch step {
                case 0: vel = 72 // Lub (Red)
                case 1: vel = 61 // (Orange)
                case 2: vel = 83 // (Brown/dim)
                case 4: vel = 72 // Dub (Red)
                case 5: vel = 61 // (Orange)
                case 6: vel = 83 // (Brown/dim)
                default: vel = 0 // Pause
                }
                var updates: [(index: Int, velocity: UInt8)] = []
                updates.reserveCapacity(49)
                for k in 0..<49 {
                    updates.append((k, vel))
                }
                self.batchUpdateLEDs(updates)
            }
    }

    // 12. Plasma Field (Trigonometric 2D undulating field)
    private func startPlasmaWaveFX() {
        var t: Double = 0
        let baseInterval = 0.06 / max(0.2, fxSpeed)
        let interval = max(1.0 / Double(targetFPS), baseInterval / (Double(targetFPS) / 16.0))
        let tStep = 0.16 * (interval / baseInterval)
        let plasmaPal: [UInt8] = [41, 67, 57, 78, 33, 87, 74, 61, 72]
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                t += tStep
                var updates: [(index: Int, velocity: UInt8)] = []
                updates.reserveCapacity(49)
                for k in 0..<49 {
                    let c = Double(BitchBoyKeyMap.keyPositions[k].col)
                    let r = Double(BitchBoyKeyMap.keyPositions[k].row)
                    let v1 = sin(c * 0.7 + t)
                    let v2 = cos(r * 0.8 + t * 0.9)
                    let v3 = sin((c + r) * 0.5 + t * 1.1)
                    let norm = (v1 + v2 + v3 + 3.0) / 6.0
                    let pIdx = Int(norm * Double(plasmaPal.count - 1))
                    let vel = plasmaPal[min(plasmaPal.count - 1, max(0, pIdx))]
                    updates.append((k, vel))
                }
                self.batchUpdateLEDs(updates)
            }
    }

    // 13. Spiral Vortex (Rotating light beam around center)
    private func startSpiralVortexFX() {
        var angle: Double = 0
        let baseInterval = 0.06 / max(0.2, fxSpeed)
        let interval = max(1.0 / Double(targetFPS), baseInterval / (Double(targetFPS) / 16.0))
        let angleStep = 0.32 * (interval / baseInterval)
        let vortexPal: [UInt8] = [0, 41, 67, 78, 33, 3]
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                angle += angleStep
                let centerCol = 4.0
                let centerRow = 2.0
                var updates: [(index: Int, velocity: UInt8)] = []
                updates.reserveCapacity(49)
                for k in 0..<49 {
                    let dx = Double(BitchBoyKeyMap.keyPositions[k].col) - centerCol
                    let dy = Double(BitchBoyKeyMap.keyPositions[k].row) - centerRow
                    let keyAngle = atan2(dy, dx)
                    let diff = fmod(keyAngle - angle + .pi * 4, .pi * 2)
                    let norm = max(0.0, 1.0 - diff / (.pi * 2))
                    let pIdx = Int(norm * Double(vortexPal.count - 1))
                    let vel = vortexPal[min(vortexPal.count - 1, max(0, pIdx))]
                    updates.append((k, vel))
                }
                self.batchUpdateLEDs(updates)
            }
    }

    // 14. EQ Dance (Graphic equalizer bands jumping to imaginary track)
    private func startEQDanceFX() {
        var colHeights = [1, 2, 3, 4, 3, 2, 4, 2]
        let interval = 0.08 / max(0.2, fxSpeed)
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                for c in 0..<8 {
                    let delta = Int.random(in: -2...2)
                    colHeights[c] = max(0, min(5, colHeights[c] + delta))
                }
                var updates: [(index: Int, velocity: UInt8)] = []
                updates.reserveCapacity(49)
                for k in 0..<49 {
                    let col = BitchBoyKeyMap.keyPositions[k].col
                    let row = BitchBoyKeyMap.keyPositions[k].row
                    if col < 8 {
                        let activeLevel = 4 - row
                        let isLit = activeLevel < colHeights[col]
                        let vel: UInt8 = isLit ? UInt8(40 + activeLevel * 20) : 0
                        updates.append((k, vel))
                    } else {
                        let padVel = UInt8.random(in: 20...70)
                        updates.append((k, padVel))
                    }
                }
                self.batchUpdateLEDs(updates)
            }
    }

    // 15. Color Runner (Snake head chasing with fading tail)
    private func startColorChaseFX() {
        var head = 0
        let trailColors: [UInt8] = [3, 78, 87, 74, 61, 72, 57]
        let interval = 0.05 / max(0.2, fxSpeed)
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                head = (head + 1) % 49
                var updates: [(index: Int, velocity: UInt8)] = []
                updates.reserveCapacity(49)
                for k in 0..<49 {
                    let dist = (head - k + 49) % 49
                    let vel: UInt8 = dist < trailColors.count ? trailColors[dist] : 0
                    updates.append((k, vel))
                }
                self.batchUpdateLEDs(updates)
            }
    }

    // ------------------------------------------------------------------------
    // MASCOT & ACTIONS
    // ------------------------------------------------------------------------
    func triggerMascotTap() {
        // Short pop that settles back to 1.0 so the mascot never outgrows its layout slot.
        mascotScale = 1.1
        SoundEffect.mascotSqueak.play(with: soundPack)
        let quotes = [
            "\"CORE TELEMETRY NOMINAL // 100%\"",
            "\"ALL 69 HARDWARE CONTROLS LIVE\"",
            "\"LOW LATENCY CORE AUDIO & MIDI ENGINE\"",
            "\"CALIBRATED 12-BIT ADC STREAMING\"",
            "\"HOLD SHIFT TO MULTI-SELECT CHANNELS\"",
            "\"USB BUFFER HEALTH: 0 DROPPED FRAMES\"",
            "\"TAYLOR FOSSEN ENGINEERING EDITION\"",
            "\"HARDWARE CONTROLLER SYNCHRONIZED\"",
            "\"DUAL USB-MIDI PIPELINE ONLINE\"",
            "\"DSP MATRIX CALIBRATION COMPLETE\"",
            "\"STUDIO MASTER ROUTING ENGAGED\""
        ]
        mascotSpeech = quotes.randomElement() ?? quotes[0]
        mascotSpeechVisible = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                self.mascotScale = 1.0
            }
            try? await Task.sleep(nanoseconds: 6_170_000_000)
            withAnimation {
                self.mascotSpeechVisible = false
            }
        }
    }

    func blackoutPanic() {
        fxTimer?.cancel()
        fxTimer = nil
        currentFXMode = .staticFX
        for i in 0..<49 {
            controls[i].idleVelocity = 0
            controls[i].currentLED = 0
            sendNoteOn(note: controls[i].number, velocity: 0)
        }
        lastStreamMessage = "🚨 BLACKOUT / PANIC ALL LEDS OFF"
        log("🚨 PANIC BLACKOUT TRIGGERED")
    }

    func cloneCurrentSlot() {
        let nextIdx = (activeSlot + 1) % max(1, slots.count)
        cloneCurrentSlotTo(nextIdx)
    }

    func cloneCurrentSlotTo(_ targetIdx: Int) {
        guard slots.indices.contains(activeSlot), slots.indices.contains(targetIdx) else { return }
        saveCurrentSlot()
        let current = slots[activeSlot]
        let slotLetter = ["A", "B", "C", "D", "E", "F", "G", "H"][targetIdx % 8]
        slots[targetIdx].controls = current.controls
        slots[targetIdx].globalRules = current.globalRules
        slots[targetIdx].iconName = current.iconName
        slots[targetIdx].accentVelocity = current.accentVelocity
        slots[targetIdx].name = "SLOT \(slotLetter) // CLONE"
        saveCurrentSlot()
        SoundEffect.presetSwitch.play(with: soundPack)
        log("📋 Cloned \(current.name) into Slot \(slotLetter)")
    }

    func resetCurrentSlotToDefault() {
        guard slots.indices.contains(activeSlot) else { return }
        let defaults = Self.buildDefault8MemorySlots()
        let fallback = defaults[activeSlot % defaults.count]
        slots[activeSlot].controls = Self.buildDefault69Map()
        slots[activeSlot].globalRules = ""
        slots[activeSlot].name = fallback.name
        slots[activeSlot].iconName = fallback.iconName
        slots[activeSlot].accentVelocity = fallback.accentVelocity
        controls = slots[activeSlot].controls
        saveCurrentSlot()
        restorePresetLEDs()
        SoundEffect.presetSwitch.play(with: soundPack)
        log("🔄 Reset \(slots[activeSlot].name) to factory defaults")
    }

    func exportPresetToJSON() -> String {
        guard let data = try? JSONEncoder().encode(slots[activeSlot]),
              let str = String(data: data, encoding: .utf8) else { return "" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
        log("⤓ Exported \(slots[activeSlot].name) to Clipboard JSON")
        return str
    }

    func importPresetFromClipboard() {
        guard let str = NSPasteboard.general.string(forType: .string),
              let data = str.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PresetSlot.self, from: data) else {
            log("❌ Invalid Preset JSON in Clipboard")
            return
        }
        guard decoded.controls.count == 69 else {
            log("❌ Incompatible Preset: Expected 69 controls, received \(decoded.controls.count)")
            return
        }
        slots[activeSlot] = decoded
        controls = decoded.controls
        saveCurrentSlot()
        restorePresetLEDs()
        log("⤒ Imported Preset into Slot \(activeSlot)")
    }

    // ------------------------------------------------------------------------
    // PROTOCOL TERMINAL // MULTI-PROTOCOL RECEIVER & NETWORK LISTENER ENGINE
    // ------------------------------------------------------------------------

    func loadProtocolSettings() {
        if UserDefaults.standard.object(forKey: oscPortStorageKey) != nil {
            let p = UserDefaults.standard.integer(forKey: oscPortStorageKey)
            if p > 0 && p < 65536 { oscIncomingPort = UInt16(p) }
        }
        if let h = UserDefaults.standard.string(forKey: oscHostStorageKey), !h.isEmpty {
            oscIncomingHost = h
        }
        if let dev = UserDefaults.standard.string(forKey: midiDeviceStorageKey), !dev.isEmpty {
            selectedMIDIInputDevice = dev
        }
        if UserDefaults.standard.object(forKey: midiChannelStorageKey) != nil {
            selectedMIDIInputChannel = UserDefaults.standard.integer(forKey: midiChannelStorageKey)
        }
        if UserDefaults.standard.object(forKey: artNetPortStorageKey) != nil {
            let p = UserDefaults.standard.integer(forKey: artNetPortStorageKey)
            if p > 0 && p < 65536 { artNetIncomingPort = UInt16(p) }
        }
        if let h = UserDefaults.standard.string(forKey: artNetHostStorageKey), !h.isEmpty {
            artNetIncomingHost = h
        }
        if UserDefaults.standard.object(forKey: artNetUnivStorageKey) != nil {
            artNetIncomingUniverse = UInt16(UserDefaults.standard.integer(forKey: artNetUnivStorageKey))
        }
        if UserDefaults.standard.object(forKey: sacnPortStorageKey) != nil {
            let p = UserDefaults.standard.integer(forKey: sacnPortStorageKey)
            if p > 0 && p < 65536 { sacnIncomingPort = UInt16(p) }
        }
        if let h = UserDefaults.standard.string(forKey: sacnHostStorageKey), !h.isEmpty {
            sacnIncomingHost = h
        }
        if UserDefaults.standard.object(forKey: sacnUnivStorageKey) != nil {
            sacnIncomingUniverse = UInt16(UserDefaults.standard.integer(forKey: sacnUnivStorageKey))
        }
        if UserDefaults.standard.object(forKey: terminalFontSizeStorageKey) != nil {
            let sz = UserDefaults.standard.double(forKey: terminalFontSizeStorageKey)
            if sz >= 8.0 && sz <= 24.0 { terminalFontSize = CGFloat(sz) }
        }
        if UserDefaults.standard.object(forKey: "bb_hw_midi_send_enabled") != nil {
            hardwareMIDISendEnabled = UserDefaults.standard.bool(forKey: "bb_hw_midi_send_enabled")
        }
        if UserDefaults.standard.object(forKey: "bb_hw_input_actions_enabled") != nil {
            hardwareInputActionsEnabled = UserDefaults.standard.bool(forKey: "bb_hw_input_actions_enabled")
        }
        if UserDefaults.standard.object(forKey: "bb_hw_qwerty_enabled") != nil {
            qwertyKeybindsEnabled = UserDefaults.standard.bool(forKey: "bb_hw_qwerty_enabled")
        }
        if UserDefaults.standard.object(forKey: "bb_keygrid_midi_send") != nil {
            keyGridMIDISendEnabled = UserDefaults.standard.bool(forKey: "bb_keygrid_midi_send")
        }
        if UserDefaults.standard.object(forKey: "bb_keystrip_midi_send") != nil {
            keyStripMIDISendEnabled = UserDefaults.standard.bool(forKey: "bb_keystrip_midi_send")
        }
        if UserDefaults.standard.object(forKey: "bb_keypad_midi_send") != nil {
            keypadMIDISendEnabled = UserDefaults.standard.bool(forKey: "bb_keypad_midi_send")
        }
        if UserDefaults.standard.object(forKey: "bb_vfaders_midi_send") != nil {
            verticalFadersMIDISendEnabled = UserDefaults.standard.bool(forKey: "bb_vfaders_midi_send")
        }
        if UserDefaults.standard.object(forKey: "bb_hfaders_midi_send") != nil {
            horizontalFadersMIDISendEnabled = UserDefaults.standard.bool(forKey: "bb_hfaders_midi_send")
        }
        if UserDefaults.standard.object(forKey: "bb_knobs_midi_send") != nil {
            rotaryKnobsMIDISendEnabled = UserDefaults.standard.bool(forKey: "bb_knobs_midi_send")
        }
        if UserDefaults.standard.object(forKey: "bb_hw_led_sync_enabled") != nil {
            hardwareLEDSyncEnabled = UserDefaults.standard.bool(forKey: "bb_hw_led_sync_enabled")
        }
        // Self-healing: If sections or master MIDI output are active, ensure inputs are not deadlocked
        let anySectionActive = keyGridMIDISendEnabled || keyStripMIDISendEnabled || keypadMIDISendEnabled || verticalFadersMIDISendEnabled || horizontalFadersMIDISendEnabled || rotaryKnobsMIDISendEnabled
        if hardwareMIDISendEnabled || anySectionActive {
            hardwareInputActionsEnabled = true
        }
    }

    func saveProtocolSettings() {
        UserDefaults.standard.set(Int(oscIncomingPort), forKey: oscPortStorageKey)
        UserDefaults.standard.set(oscIncomingHost, forKey: oscHostStorageKey)
        UserDefaults.standard.set(selectedMIDIInputDevice, forKey: midiDeviceStorageKey)
        UserDefaults.standard.set(selectedMIDIInputChannel, forKey: midiChannelStorageKey)
        UserDefaults.standard.set(Int(artNetIncomingPort), forKey: artNetPortStorageKey)
        UserDefaults.standard.set(artNetIncomingHost, forKey: artNetHostStorageKey)
        UserDefaults.standard.set(Int(artNetIncomingUniverse), forKey: artNetUnivStorageKey)
        UserDefaults.standard.set(Int(sacnIncomingPort), forKey: sacnPortStorageKey)
        UserDefaults.standard.set(sacnIncomingHost, forKey: sacnHostStorageKey)
        UserDefaults.standard.set(Int(sacnIncomingUniverse), forKey: sacnUnivStorageKey)
        UserDefaults.standard.set(Double(terminalFontSize), forKey: terminalFontSizeStorageKey)
    }

    func updateOSCReceiver(port: UInt16, host: String) {
        oscIncomingPort = port
        oscIncomingHost = host
        saveProtocolSettings()
        startOSCListener(port: port, host: host)
        SoundEffect.keyTap.play(with: soundPack)
        log("📡 OSC Receiver updated: \(host):\(port)")
    }

    func updateMIDIReceiver(device: String, channel: Int) {
        selectedMIDIInputDevice = device
        selectedMIDIInputChannel = channel
        saveProtocolSettings()
        scanForBitchBoy()
        SoundEffect.keyTap.play(with: soundPack)
        log("🎹 MIDI Receiver: \(device) (\(channel == 0 ? "Omni" : "Ch \(channel)"))")
    }

    func updateArtNetReceiver(port: UInt16, host: String, universe: UInt16) {
        artNetIncomingPort = port
        artNetIncomingHost = host
        artNetIncomingUniverse = universe
        saveProtocolSettings()
        if isArtNetListenerActive {
            startArtNetListener(port: port)
        }
        SoundEffect.keyTap.play(with: soundPack)
        log("💡 Art-Net Receiver: \(host):\(port) Univ:\(universe)")
    }

    func updatesACNReceiver(port: UInt16, host: String, universe: UInt16) {
        sacnIncomingPort = port
        sacnIncomingHost = host
        sacnIncomingUniverse = universe
        saveProtocolSettings()
        if issACNListenerActive {
            startsACNListener(port: port)
        }
        SoundEffect.keyTap.play(with: soundPack)
        log("🌟 sACN Receiver: \(host):\(port) Univ:\(universe)")
    }

    func startOSCListener(port: UInt16 = 8000, host: String = "0.0.0.0") {
        stopOSCListener()
        oscIncomingPort = port
        oscIncomingHost = host
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .global(qos: .userInitiated))
                self?.receiveOSCPacket(conn: conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isOSCListenerActive = true
                        self?.recordProtocolEvent(type: .sys, command: "OSC UDP LISTENER ONLINE", details: "Listening on \(host):\(port)", rawHex: "")
                    case .failed(let err):
                        self?.isOSCListenerActive = false
                        self?.recordProtocolEvent(type: .sys, command: "OSC LISTENER FAILED", details: err.localizedDescription, rawHex: "")
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .global())
            self.oscListener = listener
        } catch {
            recordProtocolEvent(type: .sys, command: "OSC LISTENER ERROR", details: error.localizedDescription, rawHex: "")
        }
    }

    // Inbound Art-Net Receiver
    func startArtNetListener(port: UInt16 = 6454) {
        stopArtNetListener()
        artNetIncomingPort = port
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .global(qos: .userInitiated))
                self?.receiveArtNetPacket(conn: conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isArtNetListenerActive = true
                        self?.recordProtocolEvent(type: .sys, command: "ART-NET LISTENER ONLINE", details: "Listening on UDP :\(port)", rawHex: "")
                    case .failed(let err):
                        self?.isArtNetListenerActive = false
                        self?.recordProtocolEvent(type: .sys, command: "ART-NET LISTENER FAILED", details: err.localizedDescription, rawHex: "")
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .global())
            self.artNetListener = listener
        } catch {
            recordProtocolEvent(type: .sys, command: "ART-NET LISTENER ERROR", details: error.localizedDescription, rawHex: "")
        }
    }

    nonisolated private func receiveArtNetPacket(conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data = data, data.count >= 18 {
                Task { @MainActor [weak self] in
                    self?.parseAndRecordIncomingArtNet(data: data, remote: "\(conn.endpoint)")
                }
            }
            if error == nil {
                self?.receiveArtNetPacket(conn: conn)
            } else {
                conn.cancel()
            }
        }
    }

    private func parseAndRecordIncomingArtNet(data: Data, remote: String) {
        guard data.count >= 18,
              data[0] == 0x41 && data[1] == 0x72 && data[2] == 0x74 && data[3] == 0x2D &&
              data[4] == 0x4E && data[5] == 0x65 && data[6] == 0x74 && data[7] == 0x00 else {
            return
        }
        let opCode = UInt16(data[8]) | (UInt16(data[9]) << 8)
        if opCode == 0x5000 {
            let universe = UInt16(data[14]) | (UInt16(data[15]) << 8)
            let length = (Int(data[16]) << 8) | Int(data[17])
            let dmxData = data.subdata(in: 18..<min(18 + length, data.count))
            let firstChans = dmxData.prefix(6).map { String($0) }.joined(separator: ", ")
            let hex = data.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
            self.recordProtocolEvent(
                type: .dmx,
                command: "ART-NET DMX RX (Univ \(universe))",
                details: "\(length) Chans [\(firstChans)...]",
                rawHex: hex,
                channel: remote
            )
        }
    }

    func stopArtNetListener() {
        artNetListener?.cancel()
        artNetListener = nil
        isArtNetListenerActive = false
    }

    // Inbound sACN Receiver
    func startsACNListener(port: UInt16 = 5568) {
        stopsACNListener()
        sacnIncomingPort = port
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .global(qos: .userInitiated))
                self?.receivesACNPacket(conn: conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.issACNListenerActive = true
                        self?.recordProtocolEvent(type: .sys, command: "sACN E1.31 LISTENER ONLINE", details: "Listening on UDP :\(port)", rawHex: "")
                    case .failed(let err):
                        self?.issACNListenerActive = false
                        self?.recordProtocolEvent(type: .sys, command: "sACN LISTENER FAILED", details: err.localizedDescription, rawHex: "")
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .global())
            self.sacnListener = listener
        } catch {
            recordProtocolEvent(type: .sys, command: "sACN LISTENER ERROR", details: error.localizedDescription, rawHex: "")
        }
    }

    nonisolated private func receivesACNPacket(conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data = data, data.count >= 126 {
                Task { @MainActor [weak self] in
                    self?.parseAndRecordIncomingsACN(data: data, remote: "\(conn.endpoint)")
                }
            }
            if error == nil {
                self?.receivesACNPacket(conn: conn)
            } else {
                conn.cancel()
            }
        }
    }

    private func parseAndRecordIncomingsACN(data: Data, remote: String) {
        guard data.count >= 126 else { return }
        let universe = (UInt16(data[113]) << 8) | UInt16(data[114])
        let priority = data[108]
        let hex = data.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
        self.recordProtocolEvent(
            type: .dmx,
            command: "sACN E1.31 RX (Univ \(universe))",
            details: "Priority: \(priority) | Remote: \(remote)",
            rawHex: hex,
            channel: remote
        )
    }

    func stopsACNListener() {
        sacnListener?.cancel()
        sacnListener = nil
        issACNListenerActive = false
    }

    nonisolated private func receiveOSCPacket(conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, isComplete, error in
            if let data = data, !data.isEmpty {
                Task { @MainActor [weak self] in
                    self?.parseAndRecordIncomingOSC(data: data, remote: "\(conn.endpoint)")
                }
            }
            if error == nil {
                self?.receiveOSCPacket(conn: conn)
            } else {
                conn.cancel()
            }
        }
    }

    private func parseAndRecordIncomingOSC(data: Data, remote: String) {
        let hex = data.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
        if let nullIdx = data.firstIndex(of: 0),
           let addr = String(data: data[..<nullIdx], encoding: .utf8),
           addr.starts(with: "/") {
            var details = "Remote: \(remote)"
            let remainder = data.subdata(in: min(nullIdx + 1, data.count)..<data.count)
            if let commaIdx = remainder.firstIndex(of: 0x2C) {
                if let typeNull = remainder[commaIdx...].firstIndex(of: 0),
                   let typeTag = String(data: remainder[commaIdx..<typeNull], encoding: .utf8) {
                    details += " | Tags: \(typeTag)"
                }
            }
            self.recordProtocolEvent(type: .oscIn, command: addr, details: details, rawHex: hex, channel: remote)
        } else {
            let str = String(data: data, encoding: .utf8) ?? "Binary [\(data.count) bytes]"
            self.recordProtocolEvent(type: .oscIn, command: "UDP PACKET", details: str, rawHex: hex, channel: remote)
        }
    }

    func stopOSCListener() {
        oscListener?.cancel()
        oscListener = nil
        isOSCListenerActive = false
    }

    func recordProtocolEvent(type: ProtocolEvent.EventType, command: String, details: String, rawHex: String = "", channel: String = "") {
        guard !isProtocolPaused else { return }
        pendingTelemetry.total += 1
        switch type {
        case .midiIn, .midiOut: pendingTelemetry.midi += 1
        case .oscIn, .oscOut: pendingTelemetry.osc += 1
        case .dmx: pendingTelemetry.dmx += 1
        case .msc: pendingTelemetry.msc += 1
        case .sys, .all: break
        }

        pendingProtocolEvents.append(ProtocolEvent(
            timestamp: Date(),
            type: type,
            channelOrTarget: channel,
            command: command,
            details: details,
            rawHex: rawHex
        ))
        // Bound the staging buffer so a packet flood can't grow memory between flushes.
        if pendingProtocolEvents.count > Self.maxProtocolEvents {
            pendingProtocolEvents.removeFirst(pendingProtocolEvents.count - Self.maxProtocolEvents)
        }
        scheduleTelemetryFlush()
    }

    // MARK: - Coalesced Telemetry Publishing
    // MIDI / OSC / DMX traffic can arrive hundreds of times per second. Publishing every packet
    // individually invalidates the whole console UI per packet, so events and log lines are staged
    // in non-observed buffers and committed to observed state in a single batch at ~20 Hz.
    private static let maxProtocolEvents = 300
    private static let maxLogLines = 40
    private static let telemetryFlushInterval: Duration = .milliseconds(50)

    @ObservationIgnored private var pendingProtocolEvents: [ProtocolEvent] = []
    @ObservationIgnored private var pendingLogLines: [String] = []
    @ObservationIgnored private var pendingTelemetry = (total: 0, midi: 0, osc: 0, dmx: 0, msc: 0)
    @ObservationIgnored private var telemetryFlushTask: Task<Void, Never>?

    private func scheduleTelemetryFlush() {
        guard telemetryFlushTask == nil else { return }
        telemetryFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.telemetryFlushInterval)
            self?.flushTelemetry()
        }
    }

    /// Commits all staged protocol events, counters and log lines to observed state at once.
    func flushTelemetry() {
        telemetryFlushTask?.cancel()
        telemetryFlushTask = nil

        if pendingTelemetry.total > 0 {
            totalPacketsReceived += pendingTelemetry.total
            if pendingTelemetry.midi > 0 { midiPacketsCount += pendingTelemetry.midi }
            if pendingTelemetry.osc > 0 { oscPacketsCount += pendingTelemetry.osc }
            if pendingTelemetry.dmx > 0 { dmxPacketsCount += pendingTelemetry.dmx }
            if pendingTelemetry.msc > 0 { mscPacketsCount += pendingTelemetry.msc }
            lastPacketTime = pendingProtocolEvents.last?.timestamp ?? Date()
            pendingTelemetry = (0, 0, 0, 0, 0)
        }

        if !pendingProtocolEvents.isEmpty {
            // Newest first, capped at maxProtocolEvents, built in one mutation.
            var merged = Array(pendingProtocolEvents.reversed())
            merged.append(contentsOf: protocolEvents.prefix(max(0, Self.maxProtocolEvents - merged.count)))
            pendingProtocolEvents.removeAll(keepingCapacity: true)
            protocolEvents = merged
        }

        if !pendingLogLines.isEmpty {
            var merged = Array(pendingLogLines.reversed())
            merged.append(contentsOf: midiLogs.prefix(max(0, Self.maxLogLines - merged.count)))
            pendingLogLines.removeAll(keepingCapacity: true)
            midiLogs = Array(merged.prefix(Self.maxLogLines))
        }
    }

    func clearProtocolLogs() {
        pendingProtocolEvents.removeAll()
        protocolEvents.removeAll()
        SoundEffect.keyTap.play(with: soundPack)
        log("🗑 Protocol logs cleared")
    }

    func toggleProtocolLoggingPaused() {
        isProtocolPaused.toggle()
        SoundEffect.knobTick.play(with: soundPack)
    }

    func increaseTerminalFontSize() {
        setTerminalFontSize(terminalFontSize + 1.0)
    }

    func decreaseTerminalFontSize() {
        setTerminalFontSize(terminalFontSize - 1.0)
    }

    func setTerminalFontSize(_ size: CGFloat) {
        let clamped = min(22.0, max(8.5, size))
        terminalFontSize = clamped
        UserDefaults.standard.set(Double(clamped), forKey: terminalFontSizeStorageKey)
    }

    func resetTerminalFontSize() {
        setTerminalFontSize(11.5)
    }

    func exportProtocolLogsToClipboard() {
        flushTelemetry()
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        let text = protocolEvents.reversed().map {
            "[\(df.string(from: $0.timestamp))] [\($0.type.rawValue)] \($0.channelOrTarget) \($0.command) | \($0.details) \($0.rawHex.isEmpty ? "" : "[\($0.rawHex)]")"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        SoundEffect.presetSwitch.play(with: soundPack)
        log("📋 Copied \(protocolEvents.count) protocol entries to clipboard")
    }

    func injectTestProtocolPacket(type: ProtocolEvent.EventType = .oscIn) {
        SoundEffect.keyTap.play(with: soundPack)
        switch type {
        case .midiIn:
            recordProtocolEvent(type: .midiIn, command: "NOTE ON #60 (C4)", details: "Vel: 127 [100%]", rawHex: "90 3C 7F", channel: "Ch:1")
        case .midiOut:
            recordProtocolEvent(type: .midiOut, command: "CC #1 (MOD WHEEL)", details: "Value: 64 [50%]", rawHex: "B0 01 40", channel: "Ch:1")
        case .oscIn:
            recordProtocolEvent(type: .oscIn, command: "/qlab/cue/1/start", details: "Type: ,f | Arg: 1.0", rawHex: "2F 71 6C 61 62", channel: "127.0.0.1:53000")
        case .oscOut:
            recordProtocolEvent(type: .oscOut, command: "/live/track/1/volume", details: "Arg: 0.85", rawHex: "2F 6C 69 76 65", channel: "\(customOSCHost):\(customOSCPort)")
        case .dmx:
            recordProtocolEvent(type: .dmx, command: "ART-NET DMX DUMP", details: "Univ: 0 | Chans 1..8: [255, 128, 0, 255...]", rawHex: "41 72 74 2D 4E 65 74", channel: "\(artNetHost):6454")
        case .msc:
            recordProtocolEvent(type: .msc, command: "MSC GO", details: "Cue: 101.5 | Q-List: 1", rawHex: "F0 7F 01 02 01 01 F7", channel: "All Call")
        case .sys, .all:
            recordProtocolEvent(type: .sys, command: "HEARTBEAT PING", details: "CoreMIDI Engine Latency: 0.4ms", rawHex: "", channel: "System")
        }
    }

    // ------------------------------------------------------------------------
    // INCOMING MIDI PARSER
    // ------------------------------------------------------------------------
    fileprivate func handleMIDIMessage(status: UInt8, data1: UInt8, data2: UInt8) {
        let channelNum = Int((status & 0x0F) + 1)
        if selectedMIDIInputChannel > 0 && channelNum != selectedMIDIInputChannel {
            return
        }
        guard hardwareInputActionsEnabled else {
            blockedMIDIPacketsCount += 1
            return
        }

        let msgType = status & 0xF0
        let isNoteOn = (msgType == 0x90) && (data2 > 0)
        let isNoteOff = (msgType == 0x80) || ((msgType == 0x90) && (data2 == 0))
        let isCC = (msgType == 0xB0)
        let isNote = (msgType == 0x90 || msgType == 0x80)
        let channelStr = "Ch:\((status & 0x0F) + 1)"

        guard let idx = (isCC ? controlIndex(forCC: data1) : (isNote ? controlIndex(forNote: data1) : nil)) else {
            // General external MIDI input (e.g. from an external MIDI keyboard, controller, or DAW)
            // Do NOT drop or mute! Record in protocol terminal and route to targets!
            routedMIDIPacketsCount += 1
            if isNoteOn {
                recordProtocolEvent(type: .midiIn, command: "NOTE ON #\(data1) (\(midiNoteName(data1)))", details: "Velocity: \(data2) [\(Int(round(Double(data2)/127.0*100)))%]", rawHex: String(format: "%02X %02X %02X", status, data1, data2), channel: channelStr)
            } else if isNoteOff {
                recordProtocolEvent(type: .midiIn, command: "NOTE OFF #\(data1) (\(midiNoteName(data1)))", details: "Velocity: 0", rawHex: String(format: "%02X %02X %02X", status, data1, data2), channel: channelStr)
            } else if isCC {
                recordProtocolEvent(type: .midiIn, command: "CC #\(data1)", details: "Value: \(data2)", rawHex: String(format: "%02X %02X %02X", status, data1, data2), channel: channelStr)
            }
            routeIncomingMIDIToTargets(status: status, data1: data1, data2: data2, isFromHardware: false)
            return
        }

        // Hard isolation check: if section is blacked out, drop ALL info immediately!
        guard isSectionEnabled(for: idx) else {
            blockedMIDIPacketsCount += 1
            return
        }

        routedMIDIPacketsCount += 1
        routeIncomingMIDIToTargets(status: status, data1: data1, data2: data2, isFromHardware: true)

        if isNoteOn {
            recordProtocolEvent(type: .midiIn, command: "NOTE ON #\(data1) (\(midiNoteName(data1)))", details: "Velocity: \(data2) [\(Int(round(Double(data2)/127.0*100)))%]", rawHex: String(format: "%02X %02X %02X", status, data1, data2), channel: channelStr)
        } else if isNoteOff {
            recordProtocolEvent(type: .midiIn, command: "NOTE OFF #\(data1) (\(midiNoteName(data1)))", details: "Velocity: 0", rawHex: String(format: "%02X %02X %02X", status, data1, data2), channel: channelStr)
        } else if isCC {
            recordProtocolEvent(type: .midiIn, command: "CC #\(data1)", details: "Value: \(data2)", rawHex: String(format: "%02X %02X %02X", status, data1, data2), channel: channelStr)
        }

        selectedIndex = idx

        if isNoteOn || isNoteOff {
            if isNoteOn {
                controls[idx].isPressed = true
                lastStreamMessage = "[\(controls[idx].label)] ON #\(data1) V:\(data2)"
                SoundEffect.keyTap.play(with: soundPack)

                if hardwareFeedbackEnabled && hardwareLEDSyncEnabled {
                    switch controls[idx].feedbackMode {
                    case .momentary:
                        controls[idx].currentLED = controls[idx].activeVelocity
                        sendNoteOn(note: data1, velocity: controls[idx].activeVelocity)
                    case .toggle:
                        controls[idx].toggleLatched.toggle()
                        let v = controls[idx].toggleLatched ? controls[idx].activeVelocity : controls[idx].idleVelocity
                        controls[idx].currentLED = v
                        sendNoteOn(note: data1, velocity: v)
                    case .staticLED:
                        controls[idx].currentLED = controls[idx].idleVelocity
                        sendNoteOn(note: data1, velocity: controls[idx].idleVelocity)
                    case .customVelocity:
                        let v = controls[idx].feedbackCustomVelocity
                        controls[idx].currentLED = v
                        sendNoteOn(note: data1, velocity: v)
                    case .echoInbound:
                        let echoVel = BitchBoyHardwareColor.closestHardwareVelocity(for: data2)
                        controls[idx].currentLED = echoVel
                        sendNoteOn(note: data1, velocity: echoVel)
                    case .disabled:
                        break
                    }
                }

                executeAction(for: controls[idx])
                if idx < 49 {
                    triggerReactiveKeyFX(at: idx)
                }
                if oscSendEnabled {
                    sendOSCForControl(index: idx, isPress: true, liveVal: data2)
                }
            } else if isNoteOff {
                controls[idx].isPressed = false
                lastStreamMessage = "[\(controls[idx].label)] OFF #\(data1) V:0"
                if oscSendEnabled {
                    sendOSCForControl(index: idx, isPress: false, liveVal: 0)
                }
                if hardwareFeedbackEnabled && hardwareLEDSyncEnabled && activeReactivePulses.isEmpty {
                    let restoreVel: UInt8
                    switch controls[idx].feedbackMode {
                    case .toggle:
                        restoreVel = controls[idx].toggleLatched ? controls[idx].activeVelocity : controls[idx].idleVelocity
                    case .disabled:
                        restoreVel = controls[idx].currentLED
                    default:
                        restoreVel = controls[idx].idleVelocity
                    }
                    controls[idx].currentLED = restoreVel
                    if controls[idx].feedbackMode != .disabled {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 15_000_000)
                            if self.activeReactivePulses.isEmpty {
                                self.sendNoteOn(note: data1, velocity: restoreVel)
                            }
                        }
                    }
                }
            }
        } else if isCC {
            controls[idx].liveValue = data2
            let now = CACurrentMediaTime()
            if now - lastStreamUpdateTime > 0.04 {
                lastStreamMessage = "[\(controls[idx].label)] CC #\(data1) VAL:\(data2)"
                lastStreamUpdateTime = now
            }
            if currentFXMode == .vuMeter && idx >= 49 && idx < 57 {
                updateVUMeterFaders()
            }
            if artNetMirrorHardwareFaders && idx >= 49 && idx < 57 {
                let fIdx = idx - 49
                artNetChannels[fIdx] = UInt8(min(255.0, max(0.0, Double(data2) / 127.0 * 255.0 * grandMasterLevel)))
                sendThrottledArtNetFaderMirror()
            }
            if oscSendEnabled {
                sendOSCForControl(index: idx, isPress: true, liveVal: data2)
            }
        }
    }

    // MARK: - Art-Net Fader Mirror Rate Limiting
    // Hardware faders emit a CC per step; mirroring each one as a full 512-channel frame floods the
    // network far beyond the DMX refresh rate. Frames are capped at 40 Hz with a trailing send so the
    // final fader position always goes out.
    @ObservationIgnored private var lastArtNetMirrorSendTime: CFTimeInterval = 0
    @ObservationIgnored private var artNetMirrorTrailingTask: Task<Void, Never>?

    private func sendThrottledArtNetFaderMirror() {
        let minInterval: CFTimeInterval = 1.0 / 40.0
        let now = CACurrentMediaTime()
        if now - lastArtNetMirrorSendTime >= minInterval {
            artNetMirrorTrailingTask?.cancel()
            artNetMirrorTrailingTask = nil
            lastArtNetMirrorSendTime = now
            sendArtNetDMX(host: artNetHost, universe: artNetUniverse, channels: artNetChannels)
        } else if artNetMirrorTrailingTask == nil {
            artNetMirrorTrailingTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(25))
                guard let self, !Task.isCancelled else { return }
                self.artNetMirrorTrailingTask = nil
                self.lastArtNetMirrorSendTime = CACurrentMediaTime()
                self.sendArtNetDMX(host: self.artNetHost, universe: self.artNetUniverse, channels: self.artNetChannels)
            }
        }
    }

    // ------------------------------------------------------------------------
    // MIDI ROUTER & MULTI-PROGRAM OUTPUT ENGINE
    // ------------------------------------------------------------------------
    func routeIncomingMIDIToTargets(status: UInt8, data1: UInt8, data2: UInt8, isFromHardware: Bool) {
        guard midiThruEnabled else { return }
        if isFromHardware && !hardwareMIDISendEnabled {
            blockedMIDIPacketsCount += 1
            return
        }
        let msgType = status & 0xF0
        let isNote = (msgType == 0x90 || msgType == 0x80)
        let isCC = (msgType == 0xB0)

        let targetIdx: Int? = isCC ? controlIndex(forCC: data1) : (isNote ? controlIndex(forNote: data1) : nil)
        if let idx = targetIdx {
            guard isSectionEnabled(for: idx) else {
                blockedMIDIPacketsCount += 1
                return
            }
        }

        if isNote && !forwardNotes { return }
        if isCC && !forwardCCs { return }

        // Channel Remap (0 = keep original channel, 1..16 = force channel 0..15)
        let outChan: UInt8 = remapChannel == 0 ? (status & 0x0F) : UInt8((remapChannel - 1) & 0x0F)
        let outStatus: UInt8 = msgType | outChan

        // Note Transpose & Velocity Curve
        let outData1: UInt8
        let outData2: UInt8
        if isNote {
            let shifted = max(0, min(127, Int(data1) + transposeSemitones))
            outData1 = UInt8(shifted)
            if msgType == 0x90 && data2 > 0 {
                outData2 = velocityCurve.transform(data2)
            } else {
                outData2 = data2
            }
        } else {
            outData1 = data1
            outData2 = data2
        }

        let bytes: [UInt8] = [outStatus, outData1, outData2]

        // 1. Broadcast to macOS Virtual MIDI Source ("BitchBoy Virtual Out")
        if virtualOutEnabled && virtualSourceEndpoint != 0 {
            sendMIDIPacket(endpoint: virtualSourceEndpoint, data: bytes, isVirtualSource: true)
        }

        // 2. Send to all checked external MIDI Destinations (DAWs, IAC Driver, Synths, QLab, etc.)
        for target in availableOutputTargets where selectedOutputNames.contains(target.name) {
            // Avoid echoing back into the physical BitchBoy LED port when routing from hardware
            if isFromHardware && target.endpoint == bitchBoyDestination { continue }
            sendMIDIPacket(endpoint: target.endpoint, data: bytes)
        }

        let now = Date()
        let shouldUpdateHistory = !isCC || now.timeIntervalSince(lastRoutedMessageUpdateTime) >= 0.08
        if shouldUpdateHistory {
            lastRoutedMessageUpdateTime = now
            txPacketCount += 1
            let chDisplay = Int(outChan) + 1
            let hexStr = String(format: "%02X %02X %02X", outStatus, outData1, outData2)
            let desc: String
            if isCC {
                desc = "CH\(chDisplay) CC#\(outData1) = \(outData2)"
            } else if msgType == 0x90 && outData2 > 0 {
                desc = "CH\(chDisplay) NOTE ON #\(outData1) V:\(outData2)"
            } else {
                desc = "CH\(chDisplay) NOTE OFF #\(outData1)"
            }
            lastRoutedMessage = "\(desc) [\(hexStr)]"
            routerPacketHistory.insert("[\(hexStr)] \(desc)", at: 0)
            if routerPacketHistory.count > 16 {
                routerPacketHistory.removeLast()
            }
        }
    }

    func toggleOutputTarget(_ name: String) {
        if selectedOutputNames.contains(name) {
            selectedOutputNames.remove(name)
        } else {
            selectedOutputNames.insert(name)
        }
    }

    func selectAllExternalOutputs() {
        for t in availableOutputTargets where !t.isHardwareBitchBoy {
            selectedOutputNames.insert(t.name)
        }
        log("🔌 Selected all \(selectedOutputNames.count) external MIDI outputs")
    }

    func sendTestNoteToOutputs() {
        let chord: [UInt8] = [60, 64, 67, 72]
        for n in chord {
            routeIncomingMIDIToTargets(status: 0x90, data1: n, data2: 110, isFromHardware: false)
        }
        SoundEffect.presetSwitch.play(with: soundPack)
        log("🎵 Sent Test C-Major Chord to routed MIDI outputs")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            for n in chord {
                self.routeIncomingMIDIToTargets(status: 0x80, data1: n, data2: 0, isFromHardware: false)
            }
        }
    }

    func sendPanicAllNotesOffToOutputs() {
        for ch: UInt8 in 0..<16 {
            routeIncomingMIDIToTargets(status: 0xB0 | ch, data1: 123, data2: 0, isFromHardware: false)
        }
        log("🚨 Sent All-Notes-Off (CC 123) across Channels 1–16")
    }

    func openAudioMIDISetupApp() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
        NSWorkspace.shared.open(url)
        log("🎛️ Opened macOS Audio MIDI Setup")
    }

    func registerTapTempo() {
        let now = Date()
        lastTapTimes.append(now)
        lastTapTimes = lastTapTimes.filter { now.timeIntervalSince($0) < 4.0 }
        if lastTapTimes.count >= 2 {
            var intervals: [Double] = []
            for i in 1..<lastTapTimes.count {
                intervals.append(lastTapTimes[i].timeIntervalSince(lastTapTimes[i - 1]))
            }
            let avg = intervals.reduce(0, +) / Double(intervals.count)
            if avg > 0.15 {
                tapTempoBPM = min(240.0, max(40.0, round(60.0 / avg)))
                // Also sync fxSpeed to BPM (120 BPM = 1.0x)
                fxSpeed = min(2.5, max(0.4, round((tapTempoBPM / 120.0) * 10.0) / 10.0))
                log("⏱️ Tap Tempo: \(Int(tapTempoBPM)) BPM (FX Speed \(String(format: "%.1fx", fxSpeed)))")
            }
        }
        SoundEffect.knobTick.play(with: soundPack)
    }

    // ------------------------------------------------------------------------
    // GROUND-UP CUSTOM LIGHTING FX STUDIO ENGINE
    // ------------------------------------------------------------------------
    // ------------------------------------------------------------------------
    // UI SCALING / ZOOM & CUSTOM APP ICON ENGINE
    // ------------------------------------------------------------------------
    // CONSOLE DIMENSIONS & ASPECT-RATIO ENGINE
    // ------------------------------------------------------------------------
    static let consoleBaseWidth: CGFloat = 1566
    static let consoleBaseHeight: CGFloat = 840

    var hasLeftWing: Bool {
        !leftWingModules.filter({ !$0.isHardwareModule }).isEmpty || isRearrangingModules
    }

    var hasRightWing: Bool {
        !rightWingModules.filter({ !$0.isHardwareModule }).isEmpty || isRearrangingModules
    }

    var totalLeftWingWidth: CGFloat {
        guard hasLeftWing else { return 0 }
        return leftWingWidth + 14 + 10 // Left wing ScrollView (leftWingWidth) + Divider (14) + Spacing (10)
    }

    var centerConsoleWidth: CGFloat {
        1032
    }

    var totalRightWingWidth: CGFloat {
        guard hasRightWing else { return 0 }
        return 10 + 14 + rightWingWidth // Spacing (10) + Divider (14) + Right wing ScrollView (rightWingWidth)
    }

    var chassisContentWidth: CGFloat {
        totalLeftWingWidth + centerConsoleWidth + totalRightWingWidth
    }

    var chassisTotalWidth: CGFloat {
        chassisContentWidth + 44 // 22 left bezel padding + 22 right bezel padding (clearance for corner screws)
    }

    var effectiveConsoleWidth: CGFloat {
        chassisTotalWidth + 32 // 16 left window padding + 16 right window padding
    }

    var leftWingContentHeight: CGFloat {
        guard !leftWingModules.isEmpty || isRearrangingModules else { return 0 }
        let nonHw = leftWingModules.filter { !$0.isHardwareModule }
        let rearrangeExtra: CGFloat = isRearrangingModules ? (CGFloat(nonHw.count) * 32 + 90) : 0
        let modsH = nonHw.reduce(CGFloat(0)) { $0 + (moduleCustomHeights[$1] ?? $1.defaultSlotHeight) + 12 }
        if nonHw.isEmpty && isRearrangingModules {
            return 140
        }
        return modsH + rearrangeExtra + 20
    }

    var rightWingContentHeight: CGFloat {
        guard !rightWingModules.isEmpty || isRearrangingModules else { return 0 }
        let nonHw = rightWingModules.filter { !$0.isHardwareModule }
        let rearrangeExtra: CGFloat = isRearrangingModules ? (CGFloat(nonHw.count) * 32 + 90) : 0
        let modsH = nonHw.reduce(CGFloat(0)) { $0 + (moduleCustomHeights[$1] ?? $1.defaultSlotHeight) + 12 }
        if nonHw.isEmpty && isRearrangingModules {
            return 140
        }
        return modsH + rearrangeExtra + 20
    }

    var centerDeckHeight: CGFloat {
        604
    }

    var bottomRackContentHeight: CGFloat {
        let nonHw = bottomRackModules.filter { !$0.isHardwareModule }
        guard !nonHw.isEmpty || isRearrangingModules else { return 0 }
        let rearrangeExtra: CGFloat = isRearrangingModules ? 34 : 0
        let maxRackH = nonHw.map { moduleCustomHeights[$0] ?? $0.defaultSlotHeight }.max() ?? 260
        return maxRackH + rearrangeExtra + 45
    }

    var centerTotalHeight: CGFloat {
        centerDeckHeight + bottomRackContentHeight
    }

    // Exact physical content height of the faceplate columns (encompassing all wings, deck, and bottom expansion rack)
    var chassisContentHeight: CGFloat {
        let maxColumnH = max(centerTotalHeight, max(leftWingContentHeight, rightWingContentHeight))
        return max(604, maxColumnH)
    }

    var effectiveConsoleHeight: CGFloat {
        let faceplateTotalH = chassisContentHeight + 40 // 20px top & 20px bottom padding inside chassis
        let totalWindowH = faceplateTotalH + 50 + 12 + 28 // Top nav (50) + spacing (12) + outer window vertical padding (28)
        return totalWindowH
    }

    var wingMaxHeight: CGFloat {
        chassisContentHeight
    }

    func loadUISettingsAndAppIcon() {
        // Always set the live macOS Dock / Application icon to our BitchBoyBadgeIcon / AppIcon artwork
        UserDefaults.standard.removeObject(forKey: "BitchBoy_CustomAppIconPath_v1")
        if let badgeIcon = NSImage(named: "BitchBoyBadgeIcon") {
            NSApplication.shared.applicationIconImage = badgeIcon
        }

        // Always keep autoFitWindow = true so dragging/resizing the window NEVER clips the controls!
        autoFitWindow = true
        if UserDefaults.standard.object(forKey: uiScaleStorageKey) != nil {
            let saved = UserDefaults.standard.double(forKey: uiScaleStorageKey)
            if saved >= 0.15 && saved <= 2.5 {
                uiScale = CGFloat(saved)
            }
        }
        if UserDefaults.standard.object(forKey: alwaysOnTopStorageKey) != nil {
            isWindowAlwaysOnTop = UserDefaults.standard.bool(forKey: alwaysOnTopStorageKey)
        }

        // Load custom glow themes
        if let themeData = UserDefaults.standard.data(forKey: customThemesStorageKey),
           let decoded = try? JSONDecoder().decode([CustomChassisTheme].self, from: themeData),
           !decoded.isEmpty {
            self.customThemes = decoded
        } else {
            self.customThemes = CustomChassisTheme.starterThemes()
        }

        if let savedThemeID = UserDefaults.standard.string(forKey: activeCustomThemeIDStorageKey),
           let match = customThemes.first(where: { $0.id.uuidString == savedThemeID }) {
            self.activeCustomTheme = match
        } else {
            self.activeCustomTheme = customThemes[0]
        }
        Self.activeCustomThemeStatic = self.activeCustomTheme

        if let savedThemeName = UserDefaults.standard.string(forKey: themeStorageKey),
           let savedTh = ChassisTheme(rawValue: savedThemeName) {
            self.currentTheme = savedTh
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.applyWindowAlwaysOnTop()
        }
    }

    func toggleWindowAlwaysOnTop() {
        isWindowAlwaysOnTop.toggle()
        UserDefaults.standard.set(isWindowAlwaysOnTop, forKey: alwaysOnTopStorageKey)
        applyWindowAlwaysOnTop()
        SoundEffect.knobTick.play(with: soundPack)
        log(isWindowAlwaysOnTop ? "📌 Window pinned Always On Top" : "📌 Window unpinned (normal level)")
    }

    func applyWindowAlwaysOnTop() {
        if let badgeIcon = NSImage(named: "BitchBoyBadgeIcon") {
            NSApplication.shared.applicationIconImage = badgeIcon
        }
        let minW = effectiveConsoleWidth * 0.15
        let minH = effectiveConsoleHeight * 0.15
        let detachedWinSet = Set(moduleWindows.values)
        for (mod, win) in moduleWindows {
            win.level = isModuleWindowTopMost(mod) ? .floating : .normal
        }
        for window in NSApplication.shared.windows {
            if detachedWinSet.contains(window) {
                continue
            }
            let className = String(describing: type(of: window))
            if className.contains("StatusBar") || className.contains("Menu") { continue }
            window.title = "BitchManager"
            window.level = isWindowAlwaysOnTop ? .floating : .normal
            window.contentMinSize = NSSize(width: minW, height: minH)
            window.contentResizeIncrements = NSSize(width: 1.0, height: 1.0)
        }
    }

    func isModuleWindowTopMost(_ module: StudioModuleID) -> Bool {
        pinnedModuleWindows.contains(module) || isWindowAlwaysOnTop
    }

    func toggleModuleWindowTopMost(_ module: StudioModuleID) {
        if pinnedModuleWindows.contains(module) {
            pinnedModuleWindows.remove(module)
        } else {
            pinnedModuleWindows.insert(module)
        }
        if let win = moduleWindows[module] {
            win.level = isModuleWindowTopMost(module) ? .floating : .normal
        }
        SoundEffect.knobTick.play(with: soundPack)
    }

    // ------------------------------------------------------------------------
    // CUSTOM CHASSIS THEME SYSTEM METHODS
    // ------------------------------------------------------------------------
    func applyCustomTheme(_ theme: CustomChassisTheme) {
        activeCustomTheme = theme
        Self.activeCustomThemeStatic = theme
        currentTheme = .customUser
        UserDefaults.standard.set(theme.id.uuidString, forKey: activeCustomThemeIDStorageKey)
        UserDefaults.standard.set(currentTheme.rawValue, forKey: themeStorageKey)
        SoundEffect.presetSwitch.play(with: soundPack)
        log("🎨 Applied Custom Theme: '\(theme.name)'")
    }

    func saveAndApplyActiveCustomTheme() {
        if let idx = customThemes.firstIndex(where: { $0.id == activeCustomTheme.id }) {
            customThemes[idx] = activeCustomTheme
        } else {
            customThemes.append(activeCustomTheme)
        }
        if let encoded = try? JSONEncoder().encode(customThemes) {
            UserDefaults.standard.set(encoded, forKey: customThemesStorageKey)
        }
        Self.activeCustomThemeStatic = activeCustomTheme
        if currentTheme == .customUser {
            currentTheme = .customUser
        }
    }

    func createNewCustomTheme() {
        var newTheme = CustomChassisTheme.defaultCustom()
        newTheme.id = UUID()
        newTheme.name = "CUSTOM THEME #\(customThemes.count + 1)"
        customThemes.append(newTheme)
        if let encoded = try? JSONEncoder().encode(customThemes) {
            UserDefaults.standard.set(encoded, forKey: customThemesStorageKey)
        }
        applyCustomTheme(newTheme)
    }

    func duplicateActiveCustomTheme() {
        var copy = activeCustomTheme
        copy.id = UUID()
        copy.name = "\(activeCustomTheme.name) (COPY)"
        customThemes.append(copy)
        if let encoded = try? JSONEncoder().encode(customThemes) {
            UserDefaults.standard.set(encoded, forKey: customThemesStorageKey)
        }
        applyCustomTheme(copy)
    }

    func deleteActiveCustomTheme() {
        let doomedID = activeCustomTheme.id
        customThemes.removeAll { $0.id == doomedID }
        if customThemes.isEmpty {
            customThemes = CustomChassisTheme.starterThemes()
        }
        if let encoded = try? JSONEncoder().encode(customThemes) {
            UserDefaults.standard.set(encoded, forKey: customThemesStorageKey)
        }
        applyCustomTheme(customThemes[0])
    }

    func updateCustomThemeName(_ name: String) {
        activeCustomTheme.name = name
        saveAndApplyActiveCustomTheme()
    }

    func updateCustomThemeColor<T>(key: WritableKeyPath<CustomChassisTheme, T>, value: T) {
        activeCustomTheme[keyPath: key] = value
        saveAndApplyActiveCustomTheme()
    }

    enum StarterPresetType {
        case neoTokyo, acidLime, inferno, deepIce
    }

    func loadPresetToActiveTheme(_ preset: StarterPresetType) {
        let starters = CustomChassisTheme.starterThemes()
        let template: CustomChassisTheme
        switch preset {
        case .neoTokyo: template = starters[0]
        case .acidLime: template = starters[1]
        case .inferno: template = starters[2]
        case .deepIce: template = starters[3]
        }
        activeCustomTheme.pcbHex = template.pcbHex
        activeCustomTheme.bezelStartHex = template.bezelStartHex
        activeCustomTheme.bezelEndHex = template.bezelEndHex
        activeCustomTheme.accentGlowHex = template.accentGlowHex
        activeCustomTheme.outlineHex = template.outlineHex
        activeCustomTheme.headerTextHex = template.headerTextHex
        saveAndApplyActiveCustomTheme()
        SoundEffect.presetSwitch.play(with: soundPack)
    }

    // ------------------------------------------------------------------------
    // GITHUB AUTO-UPDATER ENGINE
    // ------------------------------------------------------------------------
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let cleanCandidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
        let cleanCurrent = current.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
        let candParts = cleanCandidate.split(separator: ".").compactMap { Int($0) }
        let currParts = cleanCurrent.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(candParts.count, currParts.count)
        for i in 0..<maxLen {
            let c = i < candParts.count ? candParts[i] : 0
            let cur = i < currParts.count ? currParts[i] : 0
            if c > cur { return true }
            if c < cur { return false }
        }
        return false
    }

    func checkForUpdates(silent: Bool = false, showModalIfCurrent: Bool = false) {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        updateError = nil

        let urlString = "https://api.github.com/repos/kookly/BitchManager/releases/latest"
        guard let url = URL(string: urlString) else {
            isCheckingForUpdates = false
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("BitchManagerApp/\(currentAppVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10.0

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isCheckingForUpdates = false
                self.lastUpdateCheckDate = Date()

                if let error = error {
                    if !silent {
                        let nsErr = error as NSError
                        let errDetail: String
                        if nsErr.code == NSURLErrorCannotFindHost || nsErr.code == NSURLErrorNotConnectedToInternet {
                            errDetail = "Network unreachable or sandbox blocked. (Rebuild the project in Xcode so the outgoing network entitlement is loaded)."
                        } else {
                            errDetail = error.localizedDescription
                        }
                        self.updateError = "Network notice: \(errDetail)"
                        self.updateCheckResultNotice = "GitHub check: \(errDetail)"
                        self.showUpToDateNotice = true
                    }
                    return
                }

                guard let httpResp = response as? HTTPURLResponse else {
                    if !silent {
                        self.updateCheckResultNotice = "Invalid server response from GitHub."
                        self.showUpToDateNotice = true
                    }
                    return
                }

                if httpResp.statusCode == 404 {
                    self.updateAvailable = false
                    if showModalIfCurrent || !silent {
                        self.updateCheckResultNotice = "Connected to GitHub! You're on v\(self.currentAppVersion). No release published yet on kookly/BitchManager."
                        self.showUpToDateNotice = true
                    }
                    return
                }

                guard httpResp.statusCode == 200, let data = data else {
                    if !silent {
                        self.updateCheckResultNotice = "GitHub returned status code \(httpResp.statusCode)."
                        self.showUpToDateNotice = true
                    }
                    return
                }

                do {
                    let release = try JSONDecoder().decode(GitHubReleaseInfo.self, from: data)
                    let isNewer = Self.isVersion(release.tagName, newerThan: self.currentAppVersion)
                    self.latestRelease = release

                    if isNewer {
                        self.updateAvailable = true
                        self.showUpdateModal = true
                        SoundEffect.hardwareConnected.play(with: self.soundPack)
                    } else {
                        self.updateAvailable = false
                        if showModalIfCurrent || !silent {
                            self.updateCheckResultNotice = "BitchManager v\(self.currentAppVersion) is currently the latest version!"
                            self.showUpToDateNotice = true
                        }
                    }
                } catch {
                    if !silent {
                        self.updateCheckResultNotice = "Failed to parse GitHub release info."
                        self.showUpToDateNotice = true
                    }
                }
            }
        }.resume()
    }

    func simulateGitHubUpdateForTesting() {
        let simulated = GitHubReleaseInfo(
            id: 999999,
            tagName: "v3.0.0",
            name: "BitchManager v3.0.0 // Mapping & Show Control Release",
            body: """
            ### 🚀 BitchManager v3.0.0 Release Notes

            - **Right-Click Mapping Editor**: View and edit any key, fader, or knob's mapping, LED feedback, and action assignment.
            - **Show Control Engines**: Per-key OSC, MIDI Show Control, Art-Net 4, and sACN (E1.31) output.
            - **Undo / Redo & Copy / Paste**: Full undo history plus copy, paste, and duplicate for control configs and LED colors.
            - **Hardware MIDI Isolation**: Per-section mute switches, quick scenario profiles, and live packet counters.
            - **Creator Card**: Click the TAYLOR FOSSEN badge to say hi (and buy me a coffee ☕).
            """,
            htmlURL: "https://github.com/kookly/BitchManager/releases",
            publishedAt: "2026-10-24T12:00:00Z",
            assets: [
                GitHubReleaseAsset(
                    id: 101,
                    name: "BitchManager.zip",
                    browserDownloadURL: "https://github.com/kookly/BitchManager/releases",
                    size: 14_850_000,
                    contentType: "application/zip"
                )
            ]
        )
        self.latestRelease = simulated
        self.updateAvailable = true
        self.showUpdateModal = true
        SoundEffect.hardwareConnected.play(with: soundPack)
    }

    func cancelUpdateDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        isDownloadingUpdate = false
        updateStatusMessage = ""
        updateDownloadProgress = 0.0
    }

    func installUpdateFromGitHub() {
        guard let release = latestRelease else { return }

        // Simulated test release mode: smoothly demonstrate progress UI
        if release.id == 999999 {
            isDownloadingUpdate = true
            updateError = nil
            updateDownloadProgress = 0.05
            updateStatusMessage = "Testing update UI: Simulating package download..."

            Task { @MainActor [weak self] in
                for step in 1...10 {
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    guard let self = self, self.isDownloadingUpdate else { break }
                    self.updateDownloadProgress = min(1.0, Double(step) * 0.12)
                    if step < 5 {
                        self.updateStatusMessage = "Simulating download of BitchManager.zip (\(Int(self.updateDownloadProgress * 100))%)..."
                    } else if step < 8 {
                        self.updateStatusMessage = "Simulating package extraction & quarantine clearance..."
                    } else {
                        self.updateDownloadProgress = 1.0
                        self.updateStatusMessage = "Simulation complete! Real GitHub update will auto-restart the app."
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        self.isDownloadingUpdate = false
                        self.showUpdateModal = false
                        self.updateCheckResultNotice = "Update simulation completed successfully!"
                        self.showUpToDateNotice = true
                        break
                    }
                }
            }
            return
        }

        guard let asset = release.bestAsset, let assetURL = URL(string: asset.browserDownloadURL), assetURL.scheme?.hasPrefix("http") == true else {
            if let webURL = URL(string: release.htmlURL) {
                NSWorkspace.shared.open(webURL)
            }
            return
        }

        isDownloadingUpdate = true
        updateError = nil
        updateDownloadProgress = 0.05
        updateStatusMessage = "Connecting to GitHub & downloading \(asset.name)..."

        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent("BitchManager_Update_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)

        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig)

        let task = session.downloadTask(with: assetURL) { [weak self] localURL, response, error in
            let archiveDest = tempBase.appendingPathComponent(asset.name)
            // Only accept a successful payload; a 404/HTML error page must never be treated as the archive.
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
            if let localURL = localURL, (200..<300).contains(statusCode) {
                try? FileManager.default.removeItem(at: archiveDest)
                try? FileManager.default.moveItem(at: localURL, to: archiveDest)
            }

            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    self.isDownloadingUpdate = false
                    self.updateError = "Download failed: \(error.localizedDescription)"
                    self.updateStatusMessage = ""
                    return
                }

                guard FileManager.default.fileExists(atPath: archiveDest.path) else {
                    self.isDownloadingUpdate = false
                    self.updateError = "Downloaded file could not be saved."
                    self.updateStatusMessage = ""
                    return
                }

                self.updateDownloadProgress = 0.70
                self.updateStatusMessage = "Extracting update package..."

                DispatchQueue.global(qos: .userInitiated).async {
                    let fileExt = (asset.name as NSString).pathExtension.lowercased()
                    let targetAppPath = Bundle.main.bundleURL.path
                    let extractedDir = tempBase.appendingPathComponent("Extracted")
                    try? FileManager.default.createDirectory(at: extractedDir, withIntermediateDirectories: true)

                    var newAppBundleURL: URL? = nil

                    if fileExt == "zip" {
                        let dittoProc = Process()
                        dittoProc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                        dittoProc.arguments = ["-xk", archiveDest.path, extractedDir.path]
                        try? dittoProc.run()
                        dittoProc.waitUntilExit()

                        if let enumerator = FileManager.default.enumerator(at: extractedDir, includingPropertiesForKeys: nil) {
                            for case let fileURL as URL in enumerator {
                                if fileURL.pathExtension == "app" {
                                    newAppBundleURL = fileURL
                                    break
                                }
                            }
                        }
                    } else if fileExt == "dmg" {
                        let mountPoint = tempBase.appendingPathComponent("DMGMount")
                        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

                        let hdiProc = Process()
                        hdiProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                        hdiProc.arguments = ["attach", archiveDest.path, "-mountpoint", mountPoint.path, "-nobrowse", "-quiet", "-readonly"]
                        try? hdiProc.run()
                        hdiProc.waitUntilExit()

                        if let enumerator = FileManager.default.enumerator(at: mountPoint, includingPropertiesForKeys: nil) {
                            for case let fileURL as URL in enumerator {
                                if fileURL.pathExtension == "app" {
                                    let copyDest = extractedDir.appendingPathComponent(fileURL.lastPathComponent)
                                    try? FileManager.default.copyItem(at: fileURL, to: copyDest)
                                    newAppBundleURL = copyDest
                                    break
                                }
                            }
                        }

                        let detachProc = Process()
                        detachProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                        detachProc.arguments = ["detach", mountPoint.path, "-quiet", "-force"]
                        try? detachProc.run()
                        detachProc.waitUntilExit()
                    }

                    DispatchQueue.main.async {
                        guard let newAppURL = newAppBundleURL else {
                            self.isDownloadingUpdate = false
                            if let webURL = URL(string: release.htmlURL) {
                                NSWorkspace.shared.open(webURL)
                            }
                            self.updateError = "The release asset did not contain an installable BitchManager.app. Opening GitHub release page."
                            return
                        }

                        self.updateDownloadProgress = 0.95
                        self.updateStatusMessage = "Installing update & relaunching BitchManager..."

                        let scriptPath = tempBase.appendingPathComponent("bitchmanager_update.sh")
                        let currentPID = ProcessInfo.processInfo.processIdentifier

                        let scriptContent = """
                        #!/bin/bash
                        # Wait for current BitchManager instance to exit
                        for i in {1..30}; do
                            if ! ps -p \(currentPID) > /dev/null 2>&1; then
                                break
                            fi
                            sleep 0.2
                        done

                        # Strip quarantine attribute
                        xattr -dr com.apple.quarantine "\(newAppURL.path)" 2>/dev/null || true

                        # Replace existing app bundle
                        rm -rf "\(targetAppPath)"
                        cp -R "\(newAppURL.path)" "\(targetAppPath)"
                        xattr -dr com.apple.quarantine "\(targetAppPath)" 2>/dev/null || true

                        # Launch updated app
                        open -n -a "\(targetAppPath)"

                        # Clean up temp
                        sleep 2
                        rm -rf "\(tempBase.path)"
                        exit 0
                        """

                        try? scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)

                        let chmodProc = Process()
                        chmodProc.executableURL = URL(fileURLWithPath: "/bin/chmod")
                        chmodProc.arguments = ["+x", scriptPath.path]
                        try? chmodProc.run()
                        chmodProc.waitUntilExit()

                        let launchProc = Process()
                        launchProc.executableURL = URL(fileURLWithPath: "/bin/bash")
                        launchProc.arguments = [scriptPath.path]
                        try? launchProc.run()

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                }
            }
        }
        activeDownloadTask = task
        task.resume()
        // Release the one-off session once the download finishes; un-invalidated sessions are never freed.
        session.finishTasksAndInvalidate()
    }

    func resizeMainWindowToScale(_ scale: CGFloat) {
        let clamped = min(2.2, max(0.15, scale))
        let targetW = round(effectiveConsoleWidth * clamped)
        let targetH = round(effectiveConsoleHeight * clamped)
        DispatchQueue.main.async {
            let detachedWinSet = Set(self.moduleWindows.values)
            for window in NSApplication.shared.windows {
                if detachedWinSet.contains(window) { continue }
                let className = String(describing: type(of: window))
                if className.contains("StatusBar") || className.contains("Menu") { continue }
                window.contentMinSize = NSSize(width: self.effectiveConsoleWidth * 0.15, height: self.effectiveConsoleHeight * 0.15)
                window.contentResizeIncrements = NSSize(width: 1.0, height: 1.0)
                window.setContentSize(NSSize(width: targetW, height: targetH))
            }
        }
    }

    // ------------------------------------------------------------------------
    // CUSTOM SOUND STUDIO & USER AUDIO UPLOAD ENGINE
    // ------------------------------------------------------------------------
    func loadModuleOrderAndSoundSettings() {
        if let savedPackRaw = UserDefaults.standard.string(forKey: soundPackStorageKey),
           let savedPack = SoundPack(rawValue: savedPackRaw) {
            soundPack = savedPack
        }

        // Load Left Wing
        if let data = UserDefaults.standard.data(forKey: leftWingStorageKey),
           let decoded = try? JSONDecoder().decode([StudioModuleID].self, from: data) {
            leftWingModules = decoded
        } else {
            leftWingModules = [.showControl, .memorySlots]
        }

        // Load Right Wing
        if let data = UserDefaults.standard.data(forKey: rightWingStorageKey),
           let decoded = try? JSONDecoder().decode([StudioModuleID].self, from: data) {
            rightWingModules = decoded
        } else {
            rightWingModules = [.midiRouter, .customFXStudio]
        }

        // Load Bottom Rack
        if let data = UserDefaults.standard.data(forKey: bottomRackStorageKey),
           let decoded = try? JSONDecoder().decode([StudioModuleID].self, from: data) {
            bottomRackModules = decoded
        } else {
            bottomRackModules = [.reactiveKeyFX]
        }

        // Ensure all studio expansion modules are strictly deduplicated and accounted for
        sanitizeAndDeduplicateModules()

        // Load Custom Heights
        if let hData = UserDefaults.standard.data(forKey: moduleHeightsStorageKey),
           let decodedHeights = try? JSONDecoder().decode([String: Double].self, from: hData) {
            for (key, val) in decodedHeights {
                if let mod = StudioModuleID(rawValue: key) {
                    var heightVal = CGFloat(val)
                    if mod == .customFXStudio && heightVal < 380 {
                        heightVal = 490
                    }
                    moduleCustomHeights[mod] = heightVal
                }
            }
        }

        // Load Custom Widths (enforce safe min 380 so modules never overlap)
        if let wData = UserDefaults.standard.data(forKey: moduleWidthsStorageKey),
           let decodedWidths = try? JSONDecoder().decode([String: Double].self, from: wData) {
            for (key, val) in decodedWidths {
                if let mod = StudioModuleID(rawValue: key) {
                    moduleCustomWidths[mod] = max(380, CGFloat(val))
                }
            }
        }

        // Load Wing Widths with safe minimum of 380px so studio modules never clip horizontally
        let savedLW = UserDefaults.standard.double(forKey: "BitchBoy_LeftWingWidth_v2")
        if savedLW > 0 {
            leftWingWidth = max(380, CGFloat(savedLW))
        } else {
            leftWingWidth = 380
        }
        UserDefaults.standard.set(Double(leftWingWidth), forKey: "BitchBoy_LeftWingWidth_v2")

        let savedRW = UserDefaults.standard.double(forKey: "BitchBoy_RightWingWidth_v2")
        if savedRW > 0 {
            rightWingWidth = max(380, CGFloat(savedRW))
        } else {
            rightWingWidth = 380
        }
        UserDefaults.standard.set(Double(rightWingWidth), forKey: "BitchBoy_RightWingWidth_v2")

        moduleOrder = leftWingModules + rightWingModules + bottomRackModules
    }

    func setSoundPack(_ pack: SoundPack) {
        soundPack = pack
        UserDefaults.standard.set(pack.rawValue, forKey: soundPackStorageKey)
        SoundEffect.presetSwitch.play(with: pack)
    }

    func uploadCustomSoundFile(for effect: SoundEffect) {
        let panel = NSOpenPanel()
        panel.title = "Select Custom Audio File for \(effect.displayName)"
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            if let _ = CustomSoundBank.shared.setCustomSound(url: url, for: effect) {
                soundPack = .customUser
                UserDefaults.standard.set(soundPack.rawValue, forKey: soundPackStorageKey)
                customSoundUpdateToken += 1
                effect.play(with: .customUser)
                log("🔊 Uploaded Custom Sound '\(url.lastPathComponent)' for \(effect.displayName)")
            }
        }
    }

    func clearCustomSoundFile(for effect: SoundEffect) {
        CustomSoundBank.shared.clearCustomSound(for: effect)
        customSoundUpdateToken += 1
        SoundEffect.knobTick.play(with: soundPack)
        log("🗑️ Cleared custom sound for \(effect.displayName)")
    }

    func clearAllCustomSoundFiles() {
        CustomSoundBank.shared.clearAllCustomSounds()
        customSoundUpdateToken += 1
        SoundEffect.knobTick.play(with: soundPack)
        log("🗑️ Reset all custom sounds to default")
    }

    // ------------------------------------------------------------------------
    // MODULE DYNAMIC PLACEMENT, RESIZING, SPOTLIGHT & FLOATING WINDOWS
    // ------------------------------------------------------------------------
    func currentZone(of module: StudioModuleID) -> ModuleZone {
        if detachedModules.contains(module) { return .floating }
        if module.isHardwareModule { return .floating }
        if leftWingModules.contains(module) { return .leftWing }
        if rightWingModules.contains(module) { return .rightWing }
        if bottomRackModules.contains(module) { return .bottomRack }
        return .leftWing
    }

    func sanitizeAndDeduplicateModules() {
        // Strip any hardware modules from expansion bays
        leftWingModules.removeAll(where: { $0.isHardwareModule })
        rightWingModules.removeAll(where: { $0.isHardwareModule })
        bottomRackModules.removeAll(where: { $0.isHardwareModule })

        var placed = Set<StudioModuleID>()

        func dedupeList(_ list: inout [StudioModuleID]) {
            var unique: [StudioModuleID] = []
            for m in list {
                if !placed.contains(m) && !detachedModules.contains(m) && StudioModuleID.expansionModules.contains(m) {
                    placed.insert(m)
                    unique.append(m)
                }
            }
            list = unique
        }

        dedupeList(&leftWingModules)
        dedupeList(&rightWingModules)
        dedupeList(&bottomRackModules)

        // Ensure all studio expansion modules exist across the 3 zones at most once
        for m in StudioModuleID.expansionModules {
            if !placed.contains(m) && !detachedModules.contains(m) {
                if leftWingModules.count < 2 {
                    leftWingModules.append(m)
                } else if rightWingModules.count < 2 {
                    rightWingModules.append(m)
                } else {
                    bottomRackModules.append(m)
                }
                placed.insert(m)
            }
        }

        moduleOrder = leftWingModules + rightWingModules + bottomRackModules
        saveModuleLayout()
    }

    func moveModuleToZone(_ module: StudioModuleID, zone: ModuleZone, atIndex: Int? = nil) {
        if spotlightModule == module {
            withAnimation { spotlightModule = nil }
        }
        if module.isHardwareModule {
            // Hardware controls reside strictly on the faceplate surface or float as pop-out windows.
            // Never dock or duplicate into the expansion bay / wings!
            if zone == .floating {
                popOutModuleToWindow(module)
            } else {
                dockModuleBackFromWindow(module)
            }
            return
        }

        // Close any standalone window if it was popped out
        if let win = moduleWindows[module] {
            win.delegate = nil
            win.close()
            moduleWindows.removeValue(forKey: module)
            moduleWindowDelegates.removeValue(forKey: module)
        }
        detachedModules.remove(module)

        // Clean out from ALL zones first so duplicates are impossible
        leftWingModules.removeAll(where: { $0 == module })
        rightWingModules.removeAll(where: { $0 == module })
        bottomRackModules.removeAll(where: { $0 == module })

        switch zone {
        case .floating:
            popOutModuleToWindow(module)
            return
        case .leftWing:
            let idx = min(atIndex ?? leftWingModules.count, leftWingModules.count)
            leftWingModules.insert(module, at: idx)
        case .rightWing:
            let idx = min(atIndex ?? rightWingModules.count, rightWingModules.count)
            rightWingModules.insert(module, at: idx)
        case .bottomRack:
            let idx = min(atIndex ?? bottomRackModules.count, bottomRackModules.count)
            bottomRackModules.insert(module, at: idx)
        }

        sanitizeAndDeduplicateModules()
        SoundEffect.keyTap.play(with: soundPack)
        log("📍 Moved '\(module.shortName)' to \(zone.displayName)")
    }

    func moveModuleWithinZone(_ module: StudioModuleID, direction: Int) {
        let zone = currentZone(of: module)
        switch zone {
        case .leftWing:
            guard let idx = leftWingModules.firstIndex(of: module) else { return }
            let newIdx = idx + direction
            if newIdx >= 0 && newIdx < leftWingModules.count {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    leftWingModules.swapAt(idx, newIdx)
                }
                saveModuleLayout()
                SoundEffect.keyTap.play(with: soundPack)
            }
        case .rightWing:
            guard let idx = rightWingModules.firstIndex(of: module) else { return }
            let newIdx = idx + direction
            if newIdx >= 0 && newIdx < rightWingModules.count {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    rightWingModules.swapAt(idx, newIdx)
                }
                saveModuleLayout()
                SoundEffect.keyTap.play(with: soundPack)
            }
        case .bottomRack:
            guard let idx = bottomRackModules.firstIndex(of: module) else { return }
            let newIdx = idx + direction
            if newIdx >= 0 && newIdx < bottomRackModules.count {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    bottomRackModules.swapAt(idx, newIdx)
                }
                saveModuleLayout()
                SoundEffect.keyTap.play(with: soundPack)
            }
        case .floating:
            break
        }
        moduleOrder = leftWingModules + rightWingModules + bottomRackModules
    }

    func setModuleHeight(_ module: StudioModuleID, height: CGFloat, save: Bool = true) {
        let clamped = max(160, min(650, height))
        moduleCustomHeights[module] = clamped
        if save {
            saveModuleSizes()
        }
    }

    func resetModuleHeight(_ module: StudioModuleID) {
        moduleCustomHeights.removeValue(forKey: module)
        saveModuleSizes()
        SoundEffect.presetSwitch.play(with: soundPack)
    }

    func cycleModuleSizePreset(_ module: StudioModuleID) {
        let currentH = moduleCustomHeights[module] ?? module.defaultSlotHeight
        let nextH: CGFloat
        switch module {
        case .customFXStudio:
            if currentH < 380 { nextH = 490 }
            else if currentH < 560 { nextH = 640 }
            else { nextH = 320 }
        case .reactiveKeyFX:
            if currentH < 260 { nextH = 320 }
            else if currentH < 380 { nextH = 440 }
            else { nextH = 220 }
        case .midiRouter:
            if currentH < 340 { nextH = 440 }
            else if currentH < 500 { nextH = 580 }
            else { nextH = 280 }
        case .memorySlots:
            if currentH < 200 { nextH = 240 }
            else if currentH < 300 { nextH = 340 }
            else { nextH = 180 }
        case .showControl:
            if currentH < 360 { nextH = 480 }
            else if currentH < 540 { nextH = 620 }
            else { nextH = 300 }
        case .terminal:
            if currentH < 250 { nextH = 340 }
            else if currentH < 400 { nextH = 480 }
            else { nextH = 220 }
        case .keyGrid8x4:
            if currentH < 230 { nextH = 260 }
            else if currentH < 300 { nextH = 340 }
            else { nextH = 210 }
        case .keyStrip1x8:
            if currentH < 130 { nextH = 150 }
            else if currentH < 180 { nextH = 200 }
            else { nextH = 120 }
        case .keypad3x3:
            if currentH < 300 { nextH = 350 }
            else if currentH < 400 { nextH = 450 }
            else { nextH = 270 }
        case .verticalFaders:
            if currentH < 220 { nextH = 260 }
            else if currentH < 300 { nextH = 340 }
            else { nextH = 200 }
        case .horizontalFaders:
            if currentH < 170 { nextH = 200 }
            else if currentH < 240 { nextH = 280 }
            else { nextH = 150 }
        case .rotaryKnobs:
            if currentH < 280 { nextH = 340 }
            else if currentH < 380 { nextH = 420 }
            else { nextH = 250 }
        case .colorPickerHUD:
            if currentH < 320 { nextH = 380 }
            else if currentH < 440 { nextH = 480 }
            else { nextH = 290 }
        case .hardwareMIDIFilter:
            if currentH < 340 { nextH = 460 }
            else if currentH < 540 { nextH = 620 }
            else { nextH = 300 }
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            moduleCustomHeights[module] = nextH
        }
        saveModuleSizes()
        SoundEffect.knobTick.play(with: soundPack)
    }

    func moduleSizePresetLabel(_ module: StudioModuleID) -> String {
        let h = moduleCustomHeights[module] ?? module.defaultSlotHeight
        switch module {
        case .customFXStudio:
            if h <= 350 { return "COMPACT" }
            if h <= 540 { return "STANDARD" }
            return "EXPANDED"
        case .reactiveKeyFX:
            if h <= 250 { return "COMPACT" }
            if h <= 360 { return "STANDARD" }
            return "EXPANDED"
        case .midiRouter:
            if h <= 320 { return "COMPACT" }
            if h <= 480 { return "STANDARD" }
            return "EXPANDED"
        case .memorySlots:
            if h <= 200 { return "COMPACT" }
            if h <= 280 { return "STANDARD" }
            return "EXPANDED"
        case .showControl:
            if h <= 340 { return "COMPACT" }
            if h <= 520 { return "STANDARD" }
            return "EXPANDED"
        case .terminal:
            if h <= 240 { return "COMPACT" }
            if h <= 380 { return "STANDARD" }
            return "EXPANDED"
        case .keyGrid8x4:
            if h <= 230 { return "COMPACT" }
            if h <= 300 { return "STANDARD" }
            return "EXPANDED"
        case .keyStrip1x8:
            if h <= 130 { return "COMPACT" }
            if h <= 170 { return "STANDARD" }
            return "EXPANDED"
        case .keypad3x3:
            if h <= 300 { return "COMPACT" }
            if h <= 380 { return "STANDARD" }
            return "EXPANDED"
        case .verticalFaders:
            if h <= 220 { return "COMPACT" }
            if h <= 290 { return "STANDARD" }
            return "EXPANDED"
        case .horizontalFaders:
            if h <= 170 { return "COMPACT" }
            if h <= 230 { return "STANDARD" }
            return "EXPANDED"
        case .rotaryKnobs:
            if h <= 280 { return "COMPACT" }
            if h <= 360 { return "STANDARD" }
            return "EXPANDED"
        case .colorPickerHUD:
            if h <= 320 { return "COMPACT" }
            if h <= 420 { return "STANDARD" }
            return "EXPANDED"
        case .hardwareMIDIFilter:
            if h <= 340 { return "COMPACT" }
            if h <= 520 { return "STANDARD" }
            return "EXPANDED"
        }
    }

    func isModuleExpanded(_ module: StudioModuleID, isSpotlight: Bool = false) -> Bool {
        if isSpotlight { return true }
        let h = moduleCustomHeights[module] ?? module.defaultSlotHeight
        switch module {
        case .customFXStudio: return h > 540
        case .reactiveKeyFX: return h > 360
        case .midiRouter: return h > 480
        case .memorySlots: return h > 280
        case .showControl: return h > 520
        case .terminal: return h > 380
        case .keyGrid8x4: return h > 300
        case .keyStrip1x8: return h > 170
        case .keypad3x3: return h > 380
        case .verticalFaders: return h > 290
        case .horizontalFaders: return h > 230
        case .rotaryKnobs: return h > 360
        case .colorPickerHUD: return h > 420
        case .hardwareMIDIFilter: return h > 520
        }
    }

    func moduleTextScale(_ module: StudioModuleID, isSpotlight: Bool = false) -> CGFloat {
        if isSpotlight { return 1.75 }
        return 1.42
    }

    func toggleSpotlightModule(_ module: StudioModuleID) {
        SoundEffect.presetSwitch.play(with: soundPack)
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            if spotlightModule == module {
                spotlightModule = nil
            } else {
                showCustomSoundStudio = false
                spotlightModule = module
            }
        }
    }

    func toggleRearrangeModulesMode() {
        SoundEffect.knobTick.play(with: soundPack)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
            isRearrangingModules.toggle()
        }
        log(isRearrangingModules ? "📱 Module Placement & Dynamic Resizing Mode: ACTIVE" : "✅ Module Layout Locked")
    }

    func swapModules(_ first: StudioModuleID, _ second: StudioModuleID) {
        guard first != second else { return }
        guard !first.isHardwareModule && !second.isHardwareModule else { return }
        let zone1 = currentZone(of: first)
        let zone2 = currentZone(of: second)

        if zone1 == zone2 {
            switch zone1 {
            case .leftWing:
                guard let i1 = leftWingModules.firstIndex(of: first),
                      let i2 = leftWingModules.firstIndex(of: second) else { return }
                leftWingModules.swapAt(i1, i2)
            case .rightWing:
                guard let i1 = rightWingModules.firstIndex(of: first),
                      let i2 = rightWingModules.firstIndex(of: second) else { return }
                rightWingModules.swapAt(i1, i2)
            case .bottomRack:
                guard let i1 = bottomRackModules.firstIndex(of: first),
                      let i2 = bottomRackModules.firstIndex(of: second) else { return }
                bottomRackModules.swapAt(i1, i2)
            case .floating:
                break
            }
        } else {
            moveModuleToZone(first, zone: zone2)
        }
        moduleOrder = leftWingModules + rightWingModules + bottomRackModules
        saveModuleLayout()
        SoundEffect.keyTap.play(with: soundPack)
    }

    func moveModule(_ module: StudioModuleID, toSlot slotIndex: Int) {
        if slotIndex < 2 {
            moveModuleToZone(module, zone: .leftWing, atIndex: slotIndex)
        } else if slotIndex < 4 {
            moveModuleToZone(module, zone: .rightWing, atIndex: slotIndex - 2)
        } else {
            moveModuleToZone(module, zone: .bottomRack, atIndex: slotIndex - 4)
        }
    }

    func saveModuleLayout() {
        if let lw = try? JSONEncoder().encode(leftWingModules) {
            UserDefaults.standard.set(lw, forKey: leftWingStorageKey)
        }
        if let rw = try? JSONEncoder().encode(rightWingModules) {
            UserDefaults.standard.set(rw, forKey: rightWingStorageKey)
        }
        if let br = try? JSONEncoder().encode(bottomRackModules) {
            UserDefaults.standard.set(br, forKey: bottomRackStorageKey)
        }
        if let encoded = try? JSONEncoder().encode(moduleOrder) {
            UserDefaults.standard.set(encoded, forKey: moduleOrderStorageKey)
        }
    }

    func saveModuleSizes() {
        let rawHeights = moduleCustomHeights.reduce(into: [String: Double]()) { dict, pair in
            dict[pair.key.rawValue] = Double(pair.value)
        }
        if let data = try? JSONEncoder().encode(rawHeights) {
            UserDefaults.standard.set(data, forKey: moduleHeightsStorageKey)
        }
        let rawWidths = moduleCustomWidths.reduce(into: [String: Double]()) { dict, pair in
            dict[pair.key.rawValue] = Double(pair.value)
        }
        if let data = try? JSONEncoder().encode(rawWidths) {
            UserDefaults.standard.set(data, forKey: moduleWidthsStorageKey)
        }
    }

    func setModuleWidth(_ module: StudioModuleID, width: CGFloat, save: Bool = true) {
        let clamped = max(260, min(894, width))
        moduleCustomWidths[module] = clamped
        if save {
            saveModuleSizes()
        }
    }

    func cycleModuleWidthPreset(_ module: StudioModuleID) {
        let currentW = moduleCustomWidths[module] ?? 435
        let nextW: CGFloat
        if currentW < 410 {
            nextW = 435 // Half rack (435px)
        } else if currentW < 550 {
            nextW = 640 // Wide (640px)
        } else if currentW < 800 {
            nextW = 894 // Full rack (894px)
        } else {
            nextW = 380 // Compact (380px)
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            moduleCustomWidths[module] = nextW
        }
        saveModuleSizes()
        SoundEffect.knobTick.play(with: soundPack)
    }

    func moduleWidthPresetLabel(_ module: StudioModuleID) -> String {
        guard let w = moduleCustomWidths[module] else { return "HALF" }
        if w <= 390 { return "COMPACT" }
        if w <= 500 { return "HALF" }
        if w <= 750 { return "WIDE" }
        return "FULL"
    }

    func resetModuleLayout() {
        SoundEffect.presetSwitch.play(with: soundPack)
        withAnimation(.spring(response: 0.36, dampingFraction: 0.75)) {
            leftWingModules = [.showControl, .memorySlots]
            rightWingModules = [.midiRouter, .customFXStudio]
            bottomRackModules = [.terminal, .reactiveKeyFX]
            moduleCustomHeights.removeAll()
            moduleCustomWidths.removeAll()
            leftWingWidth = 380
            rightWingWidth = 380
            sanitizeAndDeduplicateModules()
        }
        saveModuleSizes()
        log("🔄 Reset Module Layout to Default Positions")
    }

    private func saveModuleOrder() {
        if let encoded = try? JSONEncoder().encode(moduleOrder) {
            UserDefaults.standard.set(encoded, forKey: moduleOrderStorageKey)
        }
    }

    func popOutModuleToWindow(_ module: StudioModuleID) {
        if spotlightModule == module {
            withAnimation { spotlightModule = nil }
        }
        if let existing = moduleWindows[module] {
            existing.makeKeyAndOrderFront(nil)
            detachedModules.insert(module)
            return
        }

        let defaultSize = module.idealWindowSize
        let win = DetachedModuleWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultSize.width, height: defaultSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.moduleID = module
        win.engine = self
        win.title = "BitchManager // \(module.rawValue)"
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(calibratedRed: 0.02, green: 0.06, blue: 0.05, alpha: 1.0)
        win.isReleasedWhenClosed = false
        win.level = isModuleWindowTopMost(module) ? .floating : .normal
        win.contentMinSize = module.minWindowSize
        win.contentResizeIncrements = NSSize(width: 1.0, height: 1.0)
        win.center()

        let delegate = ModuleWindowCloseDelegate(module: module, engine: self)
        moduleWindowDelegates[module] = delegate
        win.delegate = delegate

        let rootView = DetachedModuleWindowHostView(engine: self, module: module)
        win.contentView = NSHostingView(rootView: rootView)
        moduleWindows[module] = win
        detachedModules.insert(module)
        win.makeKeyAndOrderFront(nil)
        SoundEffect.presetSwitch.play(with: soundPack)
        log("⧉ Popped out '\(module.rawValue)' into standalone window")
    }

    func dockModuleBackFromWindow(_ module: StudioModuleID, fromWindowClose: Bool = false) {
        if !fromWindowClose, let win = moduleWindows[module] {
            win.delegate = nil
            win.close()
        }
        moduleWindows.removeValue(forKey: module)
        moduleWindowDelegates.removeValue(forKey: module)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
            _ = detachedModules.remove(module)
            // If it's a studio expansion module, ensure it is re-docked into its expansion bay
            if !module.isHardwareModule {
                leftWingModules.removeAll(where: { $0 == module })
                rightWingModules.removeAll(where: { $0 == module })
                bottomRackModules.removeAll(where: { $0 == module })
                switch module {
                case .showControl, .memorySlots:
                    leftWingModules.append(module)
                case .midiRouter, .customFXStudio:
                    rightWingModules.append(module)
                default:
                    bottomRackModules.append(module)
                }
                sanitizeAndDeduplicateModules()
            }
        }
        SoundEffect.knobTick.play(with: soundPack)
        log("↙ Re-docked '\(module.rawValue)' back into console")
    }

    func dockAllModules() {
        // Only re-dock modules that are actually popped out; re-docking an already-docked module
        // would move it back to its default wing and wipe the user's custom layout.
        for mod in StudioModuleID.allCases where detachedModules.contains(mod) || moduleWindows[mod] != nil {
            dockModuleBackFromWindow(mod)
        }
        log("↙ All modules docked back into main console")
    }

    func setManualZoom(_ newScale: CGFloat) {
        let clamped = min(2.2, max(0.15, (newScale * 20.0).rounded() / 20.0))
        uiScale = clamped
        autoFitWindow = true // Keep auto-fit active so resizing the window afterwards still scales the UI and never clips!
        UserDefaults.standard.set(Double(uiScale), forKey: uiScaleStorageKey)
        resizeMainWindowToScale(clamped)
        log("🔍 Window & UI scaled to \(Int(round(clamped * 100)))%")
    }

    func zoomInUI() {
        let base = autoFitWindow ? lastComputedFitScale : uiScale
        setManualZoom(base + 0.10)
    }

    func zoomOutUI() {
        let base = autoFitWindow ? lastComputedFitScale : uiScale
        setManualZoom(base - 0.10)
    }

    func enableAutoFitWindow() {
        autoFitWindow = true
        UserDefaults.standard.set(true, forKey: uiAutoFitStorageKey)
        log("📐 UI Scaling set to Auto-Fit Window")
    }

    func loadCustomEffectsFromDisk() {
        if UserDefaults.standard.object(forKey: connectFXEnabledStorageKey) != nil {
            connectEffectEnabled = UserDefaults.standard.bool(forKey: connectFXEnabledStorageKey)
        }
        if let savedConnectName = UserDefaults.standard.string(forKey: connectFXNameStorageKey), !savedConnectName.isEmpty {
            connectCustomFXName = savedConnectName
        }

        if let data = UserDefaults.standard.data(forKey: customFXStorageKey),
           var decoded = try? JSONDecoder().decode([CustomLightEffect].self, from: data),
           !decoded.isEmpty {
            // Ensure the built-in BITCHBOY CONNECT IGNITION effect is present
            if !decoded.contains(where: { $0.name == "BITCHBOY CONNECT IGNITION" }) {
                decoded.insert(CustomLightEffect.buildDefaultConnectEffect(), at: 0)
            }
            self.customEffects = decoded
            self.editingCustomFX = decoded[0]
            return
        }
        let starters = CustomLightEffect.buildStarterEffects()
        self.customEffects = starters
        self.editingCustomFX = starters[0]
        saveCustomEffectsToDisk()
    }

    func saveCustomEffectsToDisk() {
        if let encoded = try? JSONEncoder().encode(customEffects) {
            UserDefaults.standard.set(encoded, forKey: customFXStorageKey)
        }
    }

    func saveEditingCustomFXToLibrary() {
        if let idx = customEffects.firstIndex(where: { $0.id == editingCustomFX.id }) {
            customEffects[idx] = editingCustomFX
        } else {
            var copy = editingCustomFX
            copy.id = UUID()
            customEffects.insert(copy, at: 0)
            editingCustomFX = copy
        }
        saveCustomEffectsToDisk()
        SoundEffect.presetSwitch.play(with: soundPack)
        log("💾 Saved Custom Light Show: '\(editingCustomFX.name)'")
    }

    func createNewBlankCustomFX() {
        let blank = CustomLightEffect(
            name: "CUSTOM SHOW #\(customEffects.count + 1)",
            isProcedural: false,
            frames: [CustomLightEffect.emptyFrame(fill: 0)],
            fps: 10.0,
            loopMode: .loop
        )
        editingCustomFX = blank
        editingFrameIndex = 0
        previewCurrentCustomFrameOnHardware()
        log("✨ Created new blank Custom Light Show")
    }

    func deleteSavedCustomFX(_ fx: CustomLightEffect) {
        customEffects.removeAll { $0.id == fx.id }
        if customEffects.isEmpty {
            customEffects = CustomLightEffect.buildStarterEffects()
        }
        saveCustomEffectsToDisk()
        log("🗑️ Deleted Custom Show '\(fx.name)'")
    }

    func selectCustomFXForEditing(_ fx: CustomLightEffect) {
        editingCustomFX = fx
        editingFrameIndex = 0
        rightWingTab = fx.isProcedural ? "WAVESYNTH" : "SEQUENCER"
        previewCurrentCustomFrameOnHardware()
        log("✏️ Loaded '\(fx.name)' into FX Studio")
    }

    func previewCurrentCustomFrameOnHardware() {
        guard !editingCustomFX.frames.isEmpty else { return }
        let safeIdx = min(max(0, editingFrameIndex), editingCustomFX.frames.count - 1)
        let frame = editingCustomFX.frames[safeIdx]
        for k in 0..<min(49, frame.count) {
            let v = frame[k]
            controls[k].currentLED = v
            sendNoteOn(note: controls[k].number, velocity: v)
        }
    }

    func paintCustomFXKey(keyIndex: Int, velocity: UInt8) {
        guard keyIndex >= 0 && keyIndex < 49 else { return }
        if editingCustomFX.frames.isEmpty {
            editingCustomFX.frames = [CustomLightEffect.emptyFrame()]
        }
        let safeIdx = min(max(0, editingFrameIndex), editingCustomFX.frames.count - 1)
        editingFrameIndex = safeIdx
        // Toggle off if already painted with the exact same non-zero velocity
        let currentVel = editingCustomFX.frames[safeIdx][keyIndex]
        let newVel: UInt8 = (currentVel == velocity && velocity > 0) ? 0 : velocity
        editingCustomFX.frames[safeIdx][keyIndex] = newVel
        controls[keyIndex].currentLED = newVel
        sendNoteOn(note: controls[keyIndex].number, velocity: newVel)
        SoundEffect.keyTap.play(with: soundPack)
    }

    func addCustomFXFrame() {
        recordUndoSnapshot(actionName: "Add FX Frame")
        let newFrame = CustomLightEffect.emptyFrame(fill: 0)
        editingCustomFX.frames.append(newFrame)
        editingFrameIndex = editingCustomFX.frames.count - 1
        previewCurrentCustomFrameOnHardware()
        SoundEffect.knobTick.play(with: soundPack)
    }

    func duplicateCustomFXFrame() {
        guard !editingCustomFX.frames.isEmpty else { return }
        recordUndoSnapshot(actionName: "Duplicate FX Frame")
        let safeIdx = min(max(0, editingFrameIndex), editingCustomFX.frames.count - 1)
        let copy = editingCustomFX.frames[safeIdx]
        editingCustomFX.frames.insert(copy, at: safeIdx + 1)
        editingFrameIndex = safeIdx + 1
        previewCurrentCustomFrameOnHardware()
        SoundEffect.knobTick.play(with: soundPack)
    }

    func deleteCustomFXFrame() {
        guard editingCustomFX.frames.count > 1 else {
            clearCurrentCustomFXFrame()
            return
        }
        recordUndoSnapshot(actionName: "Delete FX Frame")
        let safeIdx = min(max(0, editingFrameIndex), editingCustomFX.frames.count - 1)
        editingCustomFX.frames.remove(at: safeIdx)
        editingFrameIndex = max(0, safeIdx - 1)
        previewCurrentCustomFrameOnHardware()
    }

    func clearCurrentCustomFXFrame() {
        guard !editingCustomFX.frames.isEmpty else { return }
        let safeIdx = min(max(0, editingFrameIndex), editingCustomFX.frames.count - 1)
        editingCustomFX.frames[safeIdx] = CustomLightEffect.emptyFrame(fill: 0)
        previewCurrentCustomFrameOnHardware()
    }

    func fillCurrentCustomFXFrame(with vel: UInt8) {
        guard !editingCustomFX.frames.isEmpty else { return }
        let safeIdx = min(max(0, editingFrameIndex), editingCustomFX.frames.count - 1)
        editingCustomFX.frames[safeIdx] = CustomLightEffect.emptyFrame(fill: vel)
        previewCurrentCustomFrameOnHardware()
    }

    func shiftCurrentFrame(dx: Int, dy: Int) {
        guard !editingCustomFX.frames.isEmpty else { return }
        let safeIdx = min(max(0, editingFrameIndex), editingCustomFX.frames.count - 1)
        let oldFrame = editingCustomFX.frames[safeIdx]
        var newFrame = CustomLightEffect.emptyFrame(fill: 0)

        for k in 0..<49 {
            let pos = BitchBoyKeyMap.keyPositions[k]
            let srcCol = (pos.col - dx + 11) % 11
            let srcRow = (pos.row - dy + 5) % 5
            if let srcIdx = BitchBoyKeyMap.keyPositions.firstIndex(where: { $0.col == srcCol && $0.row == srcRow }) {
                newFrame[k] = oldFrame[srcIdx]
            }
        }
        editingCustomFX.frames[safeIdx] = newFrame
        previewCurrentCustomFrameOnHardware()
        SoundEffect.knobTick.play(with: soundPack)
    }

    func invertCurrentFrame() {
        guard !editingCustomFX.frames.isEmpty else { return }
        let safeIdx = min(max(0, editingFrameIndex), editingCustomFX.frames.count - 1)
        for k in 0..<49 {
            let v = editingCustomFX.frames[safeIdx][k]
            editingCustomFX.frames[safeIdx][k] = (v == 0) ? customBrushVelocity : 0
        }
        previewCurrentCustomFrameOnHardware()
    }

    func mirrorCurrentFrameHorizontal() {
        guard !editingCustomFX.frames.isEmpty else { return }
        let safeIdx = min(max(0, editingFrameIndex), editingCustomFX.frames.count - 1)
        let oldFrame = editingCustomFX.frames[safeIdx]
        var newFrame = oldFrame
        // Mirror 8x4 & 1x8 (cols 0..7) and 3x3 (cols 8..10)
        for k in 0..<49 {
            let pos = BitchBoyKeyMap.keyPositions[k]
            let mirrorCol = pos.col < 8 ? (7 - pos.col) : (18 - pos.col)
            if let srcIdx = BitchBoyKeyMap.keyPositions.firstIndex(where: { $0.col == mirrorCol && $0.row == pos.row }) {
                newFrame[k] = oldFrame[srcIdx]
            }
        }
        editingCustomFX.frames[safeIdx] = newFrame
        previewCurrentCustomFrameOnHardware()
    }

    func randomizeCurrentFrameSparks() {
        guard !editingCustomFX.frames.isEmpty else { return }
        let safeIdx = min(max(0, editingFrameIndex), editingCustomFX.frames.count - 1)
        let palette: [UInt8] = [0, 0, 72, 61, 96, 74, 87, 33, 78, 41, 67, 57, 3]
        for k in 0..<49 {
            editingCustomFX.frames[safeIdx][k] = palette.randomElement() ?? 0
        }
        previewCurrentCustomFrameOnHardware()
    }

    func applyRainbowToCurrentFrame() {
        guard !editingCustomFX.frames.isEmpty else { return }
        let safeIdx = min(max(0, editingFrameIndex), editingCustomFX.frames.count - 1)
        let rainbow: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 57, 3]
        for k in 0..<49 {
            let col = BitchBoyKeyMap.keyPositions[k].col
            editingCustomFX.frames[safeIdx][k] = rainbow[(col + safeIdx) % rainbow.count]
        }
        previewCurrentCustomFrameOnHardware()
    }

    // Evaluates a procedural wave at phase t (0..1+) for key index k (0..<49)
    func evaluateProceduralWave(fx: CustomLightEffect, keyIndex: Int, phase: Double) -> UInt8 {
        let pos = BitchBoyKeyMap.keyPositions[keyIndex]
        let x = Double(pos.col) / 10.0
        let y = Double(pos.row) / 4.0
        let cx = x - 0.45
        let cy = y - 0.5

        let coord: Double
        switch fx.waveDirection {
        case .leftToRight: coord = x
        case .topToBottom: coord = y
        case .diagonal: coord = (x + y) * 0.5
        case .centerOut: coord = sqrt(cx * cx + cy * cy) * 1.4
        case .outerIn: coord = 1.0 - min(1.0, sqrt(cx * cx + cy * cy) * 1.4)
        }

        let arg = (coord * fx.waveFrequency - phase) * 2.0 * .pi
        let norm: Double
        switch fx.waveShape {
        case .sine:
            norm = (sin(arg) + 1.0) * 0.5
        case .sawtooth:
            let f = (coord * fx.waveFrequency - phase)
            norm = f - floor(f)
        case .triangle:
            let f = (coord * fx.waveFrequency - phase)
            let frac = f - floor(f)
            norm = frac < 0.5 ? (frac * 2.0) : (1.0 - (frac - 0.5) * 2.0)
        case .square:
            norm = sin(arg) >= 0 ? 1.0 : 0.0
        case .radial:
            let dist = sqrt(cx * cx + cy * cy)
            norm = (sin((dist * 3.0 * fx.waveFrequency - phase) * 2.0 * .pi) + 1.0) * 0.5
        case .spiral:
            let angle = atan2(cy, cx) / (2.0 * .pi)
            let dist = sqrt(cx * cx + cy * cy)
            norm = (sin((angle * 2.0 + dist * fx.waveFrequency - phase) * 2.0 * .pi) + 1.0) * 0.5
        case .sparkle:
            let hash = sin(Double(keyIndex * 37) + floor(phase * 12.0) * 17.3)
            norm = hash > 0.25 ? ((hash - 0.25) / 0.75) : 0.0
        }

        let lo = Double(min(fx.minVelocity, fx.maxVelocity))
        let hi = Double(max(fx.minVelocity, fx.maxVelocity))
        return UInt8(clamping: Int(round(lo + norm * (hi - lo))))
    }

    func bakeProceduralWaveToFrames() {
        var baked: [[UInt8]] = []
        let frameCount = 12
        for fIdx in 0..<frameCount {
            let phase = Double(fIdx) / Double(frameCount)
            var frame = CustomLightEffect.emptyFrame()
            for k in 0..<49 {
                frame[k] = evaluateProceduralWave(fx: editingCustomFX, keyIndex: k, phase: phase)
            }
            baked.append(frame)
        }
        editingCustomFX.frames = baked
        editingCustomFX.isProcedural = false
        editingFrameIndex = 0
        rightWingTab = "SEQUENCER"
        previewCurrentCustomFrameOnHardware()
        SoundEffect.presetSwitch.play(with: soundPack)
        log("⚡ Baked Procedural Wave into 12 editable keyframes!")
    }

    func playCustomEffect(_ fx: CustomLightEffect) {
        fxTimer?.cancel()
        fxTimer = nil
        currentFXMode = .staticFX
        vuMeterLEDsEnabled = false
        editingCustomFX = fx
        isPlayingCustomFX = true
        activeCustomFXName = fx.name
        customFXStep = 0
        customFXDirection = 1

        let interval = max(0.035, 1.0 / max(1.0, fx.fps * fxSpeed))
        var phase: Double = 0.0

        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                let activeFX = self.editingCustomFX
                if activeFX.isProcedural {
                    phase += 0.06 * self.fxSpeed
                    var updates: [(index: Int, velocity: UInt8)] = []
                    updates.reserveCapacity(49)
                    for k in 0..<49 {
                        let v = self.evaluateProceduralWave(fx: activeFX, keyIndex: k, phase: phase)
                        updates.append((k, v))
                    }
                    self.batchUpdateLEDs(updates)
                } else {
                    let count = activeFX.frames.count
                    guard count > 0 else { return }
                    let idx = min(max(0, self.customFXStep), count - 1)
                    if self.editingFrameIndex != idx {
                        self.editingFrameIndex = idx
                    }
                    let frame = activeFX.frames[idx]
                    var updates: [(index: Int, velocity: UInt8)] = []
                    updates.reserveCapacity(min(49, frame.count))
                    for k in 0..<min(49, frame.count) {
                        updates.append((k, frame[k]))
                    }
                    self.batchUpdateLEDs(updates)

                    if count > 1 {
                        switch activeFX.loopMode {
                        case .loop:
                            self.customFXStep = (self.customFXStep + 1) % count
                        case .pingPong:
                            let next = self.customFXStep + self.customFXDirection
                            if next >= count {
                                self.customFXDirection = -1
                                self.customFXStep = max(0, count - 2)
                            } else if next < 0 {
                                self.customFXDirection = 1
                                self.customFXStep = min(count - 1, 1)
                            } else {
                                self.customFXStep = next
                            }
                        case .oneShot:
                            if self.customFXStep + 1 < count {
                                self.customFXStep += 1
                            } else {
                                self.stopCustomEffect()
                            }
                        }
                    }
                }
            }
        log("▶️ Playing Custom FX: \(fx.name)")
    }

    func stopCustomEffect() {
        isPlayingCustomFX = false
        activeCustomFXName = ""
        fxTimer?.cancel()
        fxTimer = nil
        restorePresetLEDs()
        log("⏹ Stopped Custom FX (Restored Preset LEDs)")
    }

    func exportCustomFXToClipboard() {
        guard let data = try? JSONEncoder().encode(editingCustomFX),
              let str = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
        log("⤓ Exported Custom FX '\(editingCustomFX.name)' to Clipboard JSON")
    }

    func importCustomFXFromClipboard() {
        guard let str = NSPasteboard.general.string(forType: .string),
              let data = str.data(using: .utf8),
              var decoded = try? JSONDecoder().decode(CustomLightEffect.self, from: data) else {
            log("❌ Clipboard does not contain valid Custom FX JSON")
            return
        }
        decoded.id = UUID()
        customEffects.insert(decoded, at: 0)
        editingCustomFX = decoded
        editingFrameIndex = 0
        saveCustomEffectsToDisk()
        previewCurrentCustomFrameOnHardware()
        log("⤒ Imported Custom FX '\(decoded.name)'!")
    }

    func executeAction(for item: ControlItem) {
        if let idx = controls.firstIndex(where: { $0.id == item.id }) {
            guard isSectionEnabled(for: idx) else { return }
        }
        switch item.actionType {
        case .passthrough: break
        case .qwerty:
            guard qwertyKeybindsEnabled else { return }
            Task { @MainActor in
                for step in item.qwertySteps {
                    if step.delayMs > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(step.delayMs) * 1_000_000)
                    }
                    self.triggerSingleQwerty(key: step.key, cmd: step.cmd, shift: step.shift, alt: step.alt, ctrl: step.ctrl)
                }
            }
        case .osc:
            // Unified handling with range scaling, release, and live values in sendOSCForControl
            break
        case .applescript:
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", item.appleScript]
            try? task.run()
        case .msc:
            sendMSCBroadcast(command: item.typedMSCCommand, cue: item.mscCueNumber, deviceID: mscDeviceID, format: mscCommandFormat)
        case .artnet:
            sendArtNetFullRig()
        case .sacn:
            sendSACNFullRig()
        }
    }

    // MARK: - Native Sub-Millisecond QWERTY Keystroke Dispatch (CoreGraphics)
    func triggerSingleQwerty(key: String, cmd: Bool, shift: Bool, alt: Bool, ctrl: Bool) {
        let cleanKey = key.lowercased().trimmingCharacters(in: .whitespaces)
        guard !cleanKey.isEmpty else { return }

        // Virtual keycodes from <Carbon/HIToolbox/Events.h>
        let keyCodes: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51, "enter": 36, "return": 36,
            "escape": 53, "esc": 53,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
            "left": 123, "right": 124, "down": 125, "up": 126
        ]

        var flags = CGEventFlags()
        if cmd { flags.insert(.maskCommand) }
        if shift { flags.insert(.maskShift) }
        if alt { flags.insert(.maskAlternate) }
        if ctrl { flags.insert(.maskControl) }

        let src = CGEventSource(stateID: .hidSystemState)

        if let code = keyCodes[cleanKey] {
            if let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
                down.flags = flags
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
                up.flags = flags
                up.post(tap: .cghidEventTap)
            }
            log("⌨️ Native QWERTY Fired: \(cleanKey.uppercased())")
            return
        }

        // Direct Unicode string fallback for any other character
        let utf16Chars = Array(cleanKey.utf16)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
            down.flags = flags
            down.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
        log("⌨️ Native QWERTY Unicode Fired: \(cleanKey)")
    }

    func sendOSC(host: String, port: UInt16, address: String) {
        sendCustomOSC(host: host, port: port, address: address, argType: .none, argValue: "")
    }

    func selectSlot(_ idx: Int) {
        guard slots.indices.contains(idx) else { return }
        saveCurrentSlot()
        activeSlot = idx
        controls = slots[idx].controls
        globalRules = slots[idx].globalRules
        SoundEffect.presetSwitch.play(with: soundPack)
        log("Loaded \(slots[idx].name)")
        runRainbowWaveRefresh()
    }

    var globalRules: String {
        get { slots.indices.contains(activeSlot) ? slots[activeSlot].globalRules : "" }
        set {
            if slots.indices.contains(activeSlot) {
                slots[activeSlot].globalRules = newValue
            }
        }
    }

    func saveCurrentSlot() {
        guard slots.indices.contains(activeSlot) else { return }
        slots[activeSlot].controls = controls
        slots[activeSlot].globalRules = globalRules
        scheduleSlotPersistence()
    }

    // MARK: - Debounced Slot Persistence
    // saveCurrentSlot() is called on every edit (including continuous fader drags). Encoding all
    // 8 slots x 69 controls to JSON and writing UserDefaults on each call stalls the main thread,
    // so the in-memory slot is updated immediately and the disk write is coalesced.
    @ObservationIgnored private var slotPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    private func scheduleSlotPersistence() {
        slotPersistenceTask?.cancel()
        slotPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistSlotsNow()
        }
    }

    /// Writes all memory slots to disk immediately. Called after edits settle and on app termination.
    func persistSlotsNow() {
        slotPersistenceTask?.cancel()
        slotPersistenceTask = nil
        guard let encoded = try? JSONEncoder().encode(slots) else { return }
        UserDefaults.standard.set(encoded, forKey: storageKey)
        postVoiceOverAnnouncement("Presets saved to internal memory for slot \(activeSlot + 1)")
    }

    // MARK: - Toast Notifications Engine
    func showToast(_ message: String, icon: String = "checkmark.circle.fill") {
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            self.toastNotification = ToastNotificationItem(message: message, icon: icon)
        }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) {
                self?.toastNotification = nil
            }
        }
        toastDismissTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    // MARK: - Undo / Redo Memory Engine
    func recordUndoSnapshot(actionName: String, debounceSeconds: Double = 0.0) {
        let now = Date()
        if debounceSeconds > 0,
           let last = undoStack.last,
           last.description == actionName,
           now.timeIntervalSince(last.timestamp) < debounceSeconds {
            return
        }
        let snapshot = UndoSnapshot(
            description: actionName,
            controls: self.controls,
            activeSlot: self.activeSlot,
            timestamp: now,
            customEffects: self.customEffects,
            editingCustomFX: self.editingCustomFX,
            editingFrameIndex: self.editingFrameIndex
        )
        undoStack.append(snapshot)
        if undoStack.count > maxUndoSteps {
            undoStack.removeFirst(undoStack.count - maxUndoSteps)
        }
        redoStack.removeAll()
        undoStepsCount = undoStack.count
        redoStepsCount = 0
        lastUndoActionName = actionName
        lastRedoActionName = ""
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        let current = UndoSnapshot(
            description: previous.description,
            controls: self.controls,
            activeSlot: self.activeSlot,
            timestamp: Date(),
            customEffects: self.customEffects,
            editingCustomFX: self.editingCustomFX,
            editingFrameIndex: self.editingFrameIndex
        )
        redoStack.append(current)
        if redoStack.count > maxUndoSteps {
            redoStack.removeFirst()
        }
        undoStepsCount = undoStack.count
        redoStepsCount = redoStack.count
        lastUndoActionName = undoStack.last?.description ?? ""
        lastRedoActionName = previous.description

        let oldControls = self.controls
        self.controls = previous.controls
        self.activeSlot = previous.activeSlot
        if let fx = previous.customEffects { self.customEffects = fx }
        if let cur = previous.editingCustomFX { self.editingCustomFX = cur }
        if let fi = previous.editingFrameIndex { self.editingFrameIndex = fi }

        var notesToSend: [(note: UInt8, velocity: UInt8)] = []
        for i in 0..<min(oldControls.count, previous.controls.count) {
            if previous.controls[i].hasLED && oldControls[i].currentLED != previous.controls[i].currentLED {
                notesToSend.append((note: previous.controls[i].number, velocity: previous.controls[i].currentLED))
            }
        }
        if !notesToSend.isEmpty && isConnected && bitchBoyDestination != 0 {
            sendBatchNoteOn(notesAndVelocities: notesToSend)
        }
        saveCurrentSlot()
        showToast("UNDO: \(previous.description)", icon: "arrow.uturn.backward.circle.fill")
        log("↩️ Undid: \(previous.description) (\(undoStack.count) steps in memory)")
        SoundEffect.presetSwitch.play(with: soundPack)
        postVoiceOverAnnouncement("Undid: \(previous.description)")
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        let current = UndoSnapshot(
            description: next.description,
            controls: self.controls,
            activeSlot: self.activeSlot,
            timestamp: Date(),
            customEffects: self.customEffects,
            editingCustomFX: self.editingCustomFX,
            editingFrameIndex: self.editingFrameIndex
        )
        undoStack.append(current)
        if undoStack.count > maxUndoSteps {
            undoStack.removeFirst()
        }
        undoStepsCount = undoStack.count
        redoStepsCount = redoStack.count
        lastUndoActionName = next.description
        lastRedoActionName = redoStack.last?.description ?? ""

        let oldControls = self.controls
        self.controls = next.controls
        self.activeSlot = next.activeSlot
        if let fx = next.customEffects { self.customEffects = fx }
        if let cur = next.editingCustomFX { self.editingCustomFX = cur }
        if let fi = next.editingFrameIndex { self.editingFrameIndex = fi }

        var notesToSend: [(note: UInt8, velocity: UInt8)] = []
        for i in 0..<min(oldControls.count, next.controls.count) {
            if next.controls[i].hasLED && oldControls[i].currentLED != next.controls[i].currentLED {
                notesToSend.append((note: next.controls[i].number, velocity: next.controls[i].currentLED))
            }
        }
        if !notesToSend.isEmpty && isConnected && bitchBoyDestination != 0 {
            sendBatchNoteOn(notesAndVelocities: notesToSend)
        }
        saveCurrentSlot()
        showToast("REDO: \(next.description)", icon: "arrow.uturn.forward.circle.fill")
        log("↪️ Redid: \(next.description)")
        SoundEffect.presetSwitch.play(with: soundPack)
        postVoiceOverAnnouncement("Redid: \(next.description)")
    }

    func clearUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        undoStepsCount = 0
        redoStepsCount = 0
        lastUndoActionName = ""
        lastRedoActionName = ""
        showToast("CLEARED UNDO MEMORY", icon: "trash.circle.fill")
        log("🗑️ Undo / Redo history cleared from memory.")
        SoundEffect.knobTick.play(with: soundPack)
    }

    // MARK: - Copy & Paste Control Operations
    func copyControl(at index: Int? = nil) {
        let idx = index ?? selectedIndex
        guard idx >= 0 && idx < controls.count else { return }
        let clip = ControlClipboardData(from: controls[idx])
        self.copiedControlConfig = clip
        if let data = try? JSONEncoder().encode(clip),
           let str = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
        showToast("COPIED CONFIG: \(controls[idx].label)", icon: "doc.on.doc.fill")
        log("📋 Copied control settings for \(controls[idx].label)")
        SoundEffect.knobTick.play(with: soundPack)
        postVoiceOverAnnouncement("Copied configuration for \(controls[idx].label)")
    }

    @inlinable
    func copyControl(index: Int) {
        copyControl(at: index)
    }

    private func resolveClipboardData() -> ControlClipboardData? {
        if let clip = copiedControlConfig { return clip }
        if let str = NSPasteboard.general.string(forType: .string),
           let data = str.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ControlClipboardData.self, from: data) {
            self.copiedControlConfig = decoded
            return decoded
        }
        return nil
    }

    func pasteControl(to targetIndex: Int) {
        guard targetIndex >= 0 && targetIndex < controls.count else { return }
        guard let clip = resolveClipboardData() else {
            showToast("CLIPBOARD EMPTY", icon: "exclamationmark.triangle.fill")
            return
        }
        recordUndoSnapshot(actionName: "Paste Config to \(controls[targetIndex].label)")
        clip.apply(to: &controls[targetIndex])
        if controls[targetIndex].hasLED {
            sendNoteOn(note: controls[targetIndex].number, velocity: controls[targetIndex].currentLED)
        }
        saveCurrentSlot()
        showToast("PASTED CONFIG TO \(controls[targetIndex].label)", icon: "doc.badge.arrow.up.fill")
        log("📋 Pasted configuration onto \(controls[targetIndex].label)")
        SoundEffect.keyTap.play(with: soundPack)
        postVoiceOverAnnouncement("Pasted configuration to \(controls[targetIndex].label)")
    }

    func pasteControlToSelected() {
        let targets = selectedIndices.isEmpty ? [selectedIndex] : Array(selectedIndices)
        guard !targets.isEmpty else { return }
        guard let clip = resolveClipboardData() else {
            showToast("CLIPBOARD EMPTY", icon: "exclamationmark.triangle.fill")
            return
        }
        recordUndoSnapshot(actionName: targets.count > 1 ? "Paste Config to \(targets.count) Controls" : "Paste Config")
        var notesToSend: [(note: UInt8, velocity: UInt8)] = []
        for idx in targets where idx < controls.count {
            clip.apply(to: &controls[idx])
            if controls[idx].hasLED {
                notesToSend.append((note: controls[idx].number, velocity: controls[idx].currentLED))
            }
        }
        if !notesToSend.isEmpty && isConnected && bitchBoyDestination != 0 {
            sendBatchNoteOn(notesAndVelocities: notesToSend)
        }
        saveCurrentSlot()
        showToast(targets.count > 1 ? "PASTED TO \(targets.count) CONTROLS" : "PASTED TO \(controls[targets[0]].label)", icon: "doc.badge.arrow.up.fill")
        log("📋 Pasted configuration to \(targets.count) control(s)")
        SoundEffect.keyTap.play(with: soundPack)
    }

    func duplicateControl(at index: Int? = nil) {
        let idx = index ?? selectedIndex
        guard idx >= 0 && idx < controls.count else { return }
        let clip = ControlClipboardData(from: controls[idx])
        self.copiedControlConfig = clip
        let target = min(controls.count - 1, idx + 1)
        if target != idx {
            recordUndoSnapshot(actionName: "Duplicate \(controls[idx].label)")
            clip.apply(to: &controls[target])
            if controls[target].hasLED {
                sendNoteOn(note: controls[target].number, velocity: controls[target].currentLED)
            }
            selectedIndex = target
            saveCurrentSlot()
            showToast("DUPLICATED TO \(controls[target].label)", icon: "plus.square.on.square.fill")
            SoundEffect.keyTap.play(with: soundPack)
        }
    }

    @inlinable
    func duplicateControl(index: Int) {
        duplicateControl(at: index)
    }

    func copyColor(at index: Int? = nil) {
        let idx = index ?? selectedIndex
        guard idx >= 0 && idx < controls.count else { return }
        let vel = controls[idx].activeVelocity > 0 ? controls[idx].activeVelocity : controls[idx].idleVelocity
        copiedColorVelocity = vel
        showToast("COPIED COLOR: \(BitchBoyHardwareColor.formattedLabel(for: vel))", icon: "paintpalette.fill")
        log("🎨 Copied LED color: \(BitchBoyHardwareColor.formattedLabel(for: vel)) (Vel #\(vel))")
        SoundEffect.knobTick.play(with: soundPack)
    }

    @inlinable
    func copySelectedColor(index: Int? = nil) {
        copyColor(at: index)
    }

    func pasteColor(to targetIndex: Int) {
        guard targetIndex >= 0 && targetIndex < controls.count, controls[targetIndex].hasLED else { return }
        guard let vel = copiedColorVelocity else {
            showToast("NO COLOR COPIED", icon: "exclamationmark.triangle.fill")
            return
        }
        recordUndoSnapshot(actionName: "Paste Color to \(controls[targetIndex].label)")
        controls[targetIndex].activeVelocity = vel
        controls[targetIndex].idleVelocity = vel
        controls[targetIndex].currentLED = vel
        sendNoteOn(note: controls[targetIndex].number, velocity: vel)
        saveCurrentSlot()
        showToast("PASTED COLOR: \(BitchBoyHardwareColor.formattedLabel(for: vel))", icon: "paintbrush.fill")
        SoundEffect.knobTick.play(with: soundPack)
    }

    func pasteColorToSelected() {
        guard let vel = copiedColorVelocity else {
            showToast("NO COLOR COPIED", icon: "exclamationmark.triangle.fill")
            return
        }
        let targets = selectedIndices.isEmpty ? [selectedIndex] : Array(selectedIndices)
        let ledTargets = targets.filter { $0 < controls.count && controls[$0].hasLED }
        guard !ledTargets.isEmpty else { return }
        recordUndoSnapshot(actionName: ledTargets.count > 1 ? "Paste Color to \(ledTargets.count) Keys" : "Paste Color")
        var notesToSend: [(note: UInt8, velocity: UInt8)] = []
        for idx in ledTargets {
            controls[idx].activeVelocity = vel
            controls[idx].idleVelocity = vel
            controls[idx].currentLED = vel
            notesToSend.append((note: controls[idx].number, velocity: vel))
        }
        if !notesToSend.isEmpty && isConnected && bitchBoyDestination != 0 {
            sendBatchNoteOn(notesAndVelocities: notesToSend)
        }
        saveCurrentSlot()
        showToast(ledTargets.count > 1 ? "PASTED COLOR TO \(ledTargets.count) KEYS" : "PASTED COLOR", icon: "paintbrush.fill")
        SoundEffect.knobTick.play(with: soundPack)
    }

    func resetControl(at index: Int? = nil) {
        let idx = index ?? selectedIndex
        guard idx >= 0 && idx < controls.count else { return }
        let defaultSlot = Self.buildDefault8MemorySlots()[0]
        guard idx < defaultSlot.controls.count else { return }
        recordUndoSnapshot(actionName: "Reset \(controls[idx].label)")
        controls[idx] = defaultSlot.controls[idx]
        if controls[idx].hasLED {
            sendNoteOn(note: controls[idx].number, velocity: controls[idx].currentLED)
        }
        saveCurrentSlot()
        showToast("RESET \(controls[idx].label) TO DEFAULT", icon: "arrow.counterclockwise.circle.fill")
        log("🔄 Reset \(controls[idx].label) to default factory mapping")
        SoundEffect.keyTap.play(with: soundPack)
    }

    @inlinable
    func resetControl(index: Int) {
        resetControl(at: index)
    }

    func resetSelectedControls() {
        let targets = selectedIndices.isEmpty ? [selectedIndex] : Array(selectedIndices)
        guard !targets.isEmpty else { return }
        let defaultSlot = Self.buildDefault8MemorySlots()[0]
        recordUndoSnapshot(actionName: targets.count > 1 ? "Reset \(targets.count) Controls" : "Reset Control")
        var notesToSend: [(note: UInt8, velocity: UInt8)] = []
        for idx in targets where idx < controls.count && idx < defaultSlot.controls.count {
            controls[idx] = defaultSlot.controls[idx]
            if controls[idx].hasLED {
                notesToSend.append((note: controls[idx].number, velocity: controls[idx].currentLED))
            }
        }
        if !notesToSend.isEmpty && isConnected && bitchBoyDestination != 0 {
            sendBatchNoteOn(notesAndVelocities: notesToSend)
        }
        saveCurrentSlot()
        showToast(targets.count > 1 ? "RESET \(targets.count) CONTROLS" : "RESET CONTROL", icon: "arrow.counterclockwise.circle.fill")
        log("🔄 Reset \(targets.count) control(s) to factory defaults")
        SoundEffect.keyTap.play(with: soundPack)
    }

    func selectAllOfKind(_ kind: ControlKind) {
        let matches = controls.indices.filter { controls[$0].kind == kind }
        selectedIndices = Set(matches)
        showToast("SELECTED ALL \(matches.count) \(kind.rawValue)s", icon: "square.grid.2x2.fill")
        SoundEffect.knobTick.play(with: soundPack)
    }

    func copyCurrentFXFrame() {
        guard editingCustomFX.frames.indices.contains(editingFrameIndex) else { return }
        copiedFXFrame = editingCustomFX.frames[editingFrameIndex]
        showToast("COPIED FX FRAME #\(editingFrameIndex + 1)", icon: "doc.on.doc.fill")
        log("📋 Copied Custom FX Frame #\(editingFrameIndex + 1)")
        SoundEffect.knobTick.play(with: soundPack)
    }

    func pasteFXFrame() {
        guard let frame = copiedFXFrame else {
            showToast("NO FRAME COPIED", icon: "exclamationmark.triangle.fill")
            return
        }
        recordUndoSnapshot(actionName: "Paste FX Frame")
        if editingCustomFX.frames.indices.contains(editingFrameIndex) {
            editingCustomFX.frames[editingFrameIndex] = frame
        } else {
            editingCustomFX.frames.append(frame)
            editingFrameIndex = editingCustomFX.frames.count - 1
        }
        saveCustomEffectsToDisk()
        previewCurrentCustomFrameOnHardware()
        showToast("PASTED FX FRAME #\(editingFrameIndex + 1)", icon: "doc.badge.arrow.up.fill")
        log("📋 Pasted Custom FX Frame onto #\(editingFrameIndex + 1)")
        SoundEffect.keyTap.play(with: soundPack)
    }

    // MARK: - 120 FPS Target & High-Rate Performance Configuration
    func setTargetFPS(_ fps: Int) {
        targetFPS = (fps == 60) ? 60 : 120
        UserDefaults.standard.set(targetFPS, forKey: "BitchBoy_TargetFPS_v1")
        if reactiveFXTimer != nil {
            stopReactiveTimer()
            startReactiveTimerIfNeeded()
        }
        if isPlayingCustomFX {
            playCustomEffect(editingCustomFX)
        }
        showToast("ENGINE SET TO \(targetFPS) FPS PROMOTION", icon: "bolt.fill")
        log("⚡️ Graphics & Lighting Engine Frame Rate set to \(targetFPS) FPS")
        SoundEffect.knobTick.play(with: soundPack)
    }

    private func loadFromDisk() {
        let default8 = Self.buildDefault8MemorySlots()
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([PresetSlot].self, from: data),
           (decoded.count == 4 || decoded.count == 8) {
            if let firstSlot = decoded.first, firstSlot.controls.count == 69,
               firstSlot.controls[0].number == 64,
               firstSlot.controls[4].number == 96,
               firstSlot.controls[32].number == 48,
               firstSlot.controls[36].number == 80,
               firstSlot.controls[40].number == 44 {
                if decoded.count == 4 {
                    var migrated = decoded
                    migrated.append(contentsOf: default8[4..<8])
                    self.slots = migrated
                } else {
                    self.slots = decoded
                }
                self.controls = self.slots[activeSlot].controls
                return
            }
        }

        self.slots = default8
        self.controls = slots[0].controls
        saveCurrentSlot()
    }

    func setZoneLEDs(range: Range<Int>, velocity: UInt8) {
        for i in range where controls[i].hasLED {
            controls[i].idleVelocity = velocity
            controls[i].currentLED = velocity
            sendNoteOn(note: controls[i].number, velocity: velocity)
        }
        saveCurrentSlot()
        SoundEffect.keyTap.play(with: soundPack)
        log("⚡️ Applied Velocity \(velocity) to Range [\(range.lowerBound)..\(range.upperBound - 1)]")
    }

    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func log(_ msg: String) {
        let ts = Self.logDateFormatter.string(from: Date())
        pendingLogLines.append("[\(ts)] \(msg)")
        if pendingLogLines.count > Self.maxLogLines {
            pendingLogLines.removeFirst(pendingLogLines.count - Self.maxLogLines)
        }
        scheduleTelemetryFlush()
    }
}

// ============================================================================
// 3. HARDWARE VISUAL COMPONENTS & INTERACTIVE HOVER ENGINE
// ============================================================================

struct HoverGrowModifier: ViewModifier {
    var scale: CGFloat = 1.06
    var lift: CGFloat = 0.0
    var brightnessBoost: Double = 0.03
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect((isHovered && !reduceMotion) ? scale : 1.0)
            .offset(y: (isHovered && !reduceMotion) ? -lift : 0)
            .brightness(isHovered ? brightnessBoost : 0.0)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.72), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

extension View {
    func hoverGrow(_ scale: CGFloat = 1.06, lift: CGFloat = 0.0, brightnessBoost: Double = 0.03) -> some View {
        self.modifier(HoverGrowModifier(scale: scale, lift: lift, brightnessBoost: brightnessBoost))
    }
}

struct ScrewRivetView: View {
    var size: CGFloat = 11

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.94), Color(white: 0.65), Color(white: 0.35)],
                        center: .topLeading,
                        startRadius: 1,
                        endRadius: size / 1.7
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.7), radius: 1, x: 0.5, y: 0.5)

            // Cross slot
            Rectangle()
                .fill(Color(white: 0.18))
                .frame(width: size * 0.65, height: 1.2)
            Rectangle()
                .fill(Color(white: 0.18))
                .frame(width: 1.2, height: size * 0.65)
        }
        .accessibilityHidden(true)
    }
}

struct BitchBoyOfficialMascotView: View {
    var auraColor: Color = .cyan
    var onTap: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var mascotNSImage: NSImage? {
        if let img = NSImage(named: "BitchBoyMascot") { return img }
        if let url = Bundle.main.url(forResource: "bitchboy", withExtension: "png"),
           let img = NSImage(contentsOf: url) { return img }
        return nil
    }

    var body: some View {
        Button(action: {
            isPressed = true
            onTap?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                isPressed = false
            }
        }) {
            Group {
                if let nsImg = mascotNSImage {
                    Image(nsImage: nsImg)
                        .interpolation(.none) // Keep crisp pixel art edge
                        .resizable()
                        .scaledToFit()
                        .frame(width: 124, height: 70)
                        .blendMode(.screen) // Melts any dark background into the PCB
                        .shadow(color: auraColor.opacity(isHovered ? 1.0 : 0.85), radius: isHovered ? 10 : 7)
                        .shadow(color: auraColor.opacity(isHovered ? 0.70 : 0.40), radius: isHovered ? 18 : 12)
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 42))
                        .foregroundColor(auraColor)
                        .shadow(color: auraColor.opacity(0.85), radius: 8)
                }
            }
            // Tall enough for the 70pt art at peak bounce (1.1 pop × 1.06 hover ≈ 82pt), so it never overlaps neighbors.
            .frame(width: 226, height: 84)
            .scaleEffect((isPressed && !reduceMotion) ? 0.94 : ((isHovered && !reduceMotion) ? 1.06 : 1.0))
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: isPressed)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .onHover { h in isHovered = h }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("BitchBoy Mascot")
        .accessibilityHint("Click to trigger mascot interaction sound")
    }
}

struct BitchBoyGlowingLogoView: View {
    var auraColor: Color = .cyan
    var onTap: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var logoNSImage: NSImage? {
        if let img = NSImage(named: "BitchBoyWordLogo") { return img }
        if let url = Bundle.main.url(forResource: "bitchboy_logo", withExtension: "png"),
           let img = NSImage(contentsOf: url) { return img }
        return nil
    }

    var body: some View {
        Button(action: {
            isPressed = true
            onTap?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                isPressed = false
            }
        }) {
            Group {
                if let nsImg = logoNSImage {
                    Image(nsImage: nsImg)
                        .interpolation(.high)
                        .resizable()
                        .scaledToFit()
                        .padding(.horizontal, 6)
                        .blendMode(.screen)
                        .shadow(color: auraColor.opacity(isHovered ? 1.0 : 0.85), radius: isHovered ? 8 : 6)
                        .shadow(color: auraColor.opacity(isHovered ? 0.65 : 0.35), radius: isHovered ? 16 : 12)
                } else {
                    Text("BiTCHBOY")
                        .font(.system(size: 22, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                        .shadow(color: auraColor.opacity(0.85), radius: 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .scaleEffect((isPressed && !reduceMotion) ? 0.95 : ((isHovered && !reduceMotion) ? 1.03 : 1.0))
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: isPressed)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .onHover { h in isHovered = h }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityLabel("BitchBoy Logo")
        .accessibilityHint("Click to trigger logo interaction sound")
    }
}

struct HardwareKeyCap: View, Equatable {
    let item: ControlItem
    let isSelected: Bool
    let color: Color
    let sectionBorder: Color
    var keyWidth: CGFloat = 52
    var keyHeight: CGFloat = 45
    let onTap: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isLit: Bool { item.currentLED > 0 }

    static func == (lhs: HardwareKeyCap, rhs: HardwareKeyCap) -> Bool {
        return lhs.item.number == rhs.item.number &&
               lhs.item.currentLED == rhs.item.currentLED &&
               lhs.item.isPressed == rhs.item.isPressed &&
               lhs.item.actionType == rhs.item.actionType &&
               lhs.item.customName == rhs.item.customName &&
               lhs.item.qwertySteps.first?.key == rhs.item.qwertySteps.first?.key &&
               lhs.item.qwertySteps.first?.cmd == rhs.item.qwertySteps.first?.cmd &&
               lhs.item.qwertySteps.first?.shift == rhs.item.qwertySteps.first?.shift &&
               lhs.item.qwertySteps.first?.alt == rhs.item.qwertySteps.first?.alt &&
               lhs.item.qwertySteps.first?.ctrl == rhs.item.qwertySteps.first?.ctrl &&
               lhs.isSelected == rhs.isSelected &&
               lhs.color == rhs.color &&
               lhs.sectionBorder == rhs.sectionBorder &&
               lhs.keyWidth == rhs.keyWidth &&
               lhs.keyHeight == rhs.keyHeight
    }

    var body: some View {
        Button(action: {
            NSApp.keyWindow?.makeFirstResponder(nil)
            onTap()
        }) {
            ZStack {
                // Keycap Base: Precision milled dark obsidian keycap with satin sheen
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: isLit
                                ? [color.opacity(0.92), color.opacity(0.50)]
                                : [Color(red: 0.16, green: 0.18, blue: 0.21), Color(red: 0.08, green: 0.09, blue: 0.11)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Top chamfer specular light reflection edge
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(isLit ? 0.38 : 0.18), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )

                // Ambient LED halo underglow when active
                if isLit {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            RadialGradient(
                                colors: [color.opacity(0.48), Color.clear],
                                center: .center,
                                startRadius: 2,
                                endRadius: 24
                            )
                        )
                }

                // Key Face Bezel with sharp selection border
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected
                            ? Color(red: 0.22, green: 0.96, blue: 0.76)
                            : (isHovered ? Color.white.opacity(0.85) : sectionBorder.opacity(0.75)),
                        lineWidth: (isSelected || isHovered) ? 1.8 : 0.9
                    )
                    .shadow(
                        color: isHovered
                            ? (isLit ? color.opacity(0.9) : Color.white.opacity(0.35))
                            : (isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76).opacity(0.85) : (isLit ? color.opacity(0.55) : .clear)),
                        radius: isHovered ? 5 : (isSelected ? 5 : (isLit ? 4 : 0))
                    )

                // Labels & Center Action Icon / QWERTY Shortcut Badge
                VStack(spacing: 0) {
                    Text(item.customName.isEmpty ? item.label : item.customName)
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundColor(isLit ? .white : Color(white: 0.92))
                        .padding(.top, 2.5)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    // Center QWERTY shortcut badge or Action Icon
                    ZStack {
                        if item.actionType == .qwerty, let step = item.qwertySteps.first {
                            let modPrefix = (step.cmd ? "⌘" : "") + (step.shift ? "⇧" : "") + (step.alt ? "⌥" : "") + (step.ctrl ? "⌃" : "")
                            let keyDisp: String = {
                                switch step.key.lowercased() {
                                case "space": return "␣"
                                case "return", "enter": return "↵"
                                case "escape", "esc": return "ESC"
                                case "tab": return "⇥"
                                case "delete", "backspace": return "⌫"
                                case "up": return "↑"
                                case "down": return "↓"
                                case "left": return "←"
                                case "right": return "→"
                                default: return step.key.uppercased()
                                }
                            }()
                            Text(modPrefix + keyDisp)
                                .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                                .foregroundColor(.black)
                                .lineLimit(1)
                                .padding(.horizontal, 3.5)
                                .padding(.vertical, 1.5)
                                .background(Color(red: 0.98, green: 0.78, blue: 0.25))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        } else {
                            Circle()
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                                .frame(width: 14, height: 14)

                            Image(systemName: actionIconName(item.actionType))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(isLit ? .white : Color(white: 0.80))
                        }
                    }

                    Spacer(minLength: 0)

                    Text("N\(item.number)")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundColor(isLit ? .white.opacity(0.95) : (isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76) : Color(white: 0.70)))
                        .padding(.bottom, 2.5)
                }
            }
            .frame(width: keyWidth, height: keyHeight)
            .scaleEffect((item.isPressed && !reduceMotion) ? 0.93 : ((isHovered && !reduceMotion) ? 1.04 : 1.0))
            .offset(y: (item.isPressed && !reduceMotion) ? 1.5 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.65), value: isHovered)
            .animation(reduceMotion ? nil : .spring(response: 0.15, dampingFraction: 0.6), value: item.isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.customName.isEmpty ? item.label : item.customName)
        .accessibilityValue("Note \(item.number), \(isLit ? "Lit" : "Off"), \(item.actionType.rawValue)")
        .accessibilityHint("Click to trigger key")
    }

    private func actionIconName(_ type: ActionType) -> String {
        switch type {
        case .passthrough: return "plus"
        case .qwerty: return "command"
        case .osc: return "antenna.radiowaves.left.and.right"
        case .applescript: return "applescript"
        case .msc: return "dot.radiowaves.left.and.right"
        case .artnet: return "lightbulb.fill"
        case .sacn: return "sparkles"
        }
    }
}

struct HardwareVerticalFader: View, Equatable {
    let item: ControlItem
    let isSelected: Bool
    var faderWidth: CGFloat = 52
    var faderHeight: CGFloat = 210
    let onSelect: () -> Void
    let onValueChange: (UInt8) -> Void

    @State private var isDragging: Bool = false
    @State private var lastSentVal: UInt8? = nil

    static func == (lhs: HardwareVerticalFader, rhs: HardwareVerticalFader) -> Bool {
        return lhs.item.number == rhs.item.number &&
               lhs.item.liveValue == rhs.item.liveValue &&
               lhs.isSelected == rhs.isSelected &&
               lhs.faderWidth == rhs.faderWidth &&
               lhs.faderHeight == rhs.faderHeight
    }

    private var dbReadout: String {
        if item.liveValue == 0 { return "-∞ dB" }
        if item.liveValue >= 126 { return "+6.0 dB" }
        let ratio = Double(item.liveValue) / 100.0
        let db = 20.0 * log10(max(0.01, ratio))
        return String(format: "%+.1f dB", min(6.0, db))
    }

    var body: some View {
        VStack(spacing: 3) {
            // Channel Header: Label & Live dB Readout
            VStack(spacing: 1) {
                Text(item.label)
                    .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76) : Color(white: 0.90))

                Text(dbReadout)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? Color(red: 0.38, green: 0.94, blue: 0.78) : Color(white: 0.55))
            }
            .frame(width: faderWidth - 4)
            .padding(.vertical, 2)
            .background(isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76).opacity(0.18) : Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 3.5))

            // Precision Fader Track with Decibel Markings & VU Level Ladder
            GeometryReader { geo in
                let slotHeight = max(30, geo.size.height)
                let capHeight: CGFloat = 20
                let travel = max(10, slotHeight - capHeight)
                let normalizedVal = CGFloat(item.liveValue) / 127.0
                let capOffsetFromTop = (1.0 - normalizedVal) * travel

                HStack(spacing: 2) {
                    // Left Decibel Scale Markings
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("+6").font(.system(size: 6.5, weight: .bold, design: .monospaced)).foregroundColor(Color(white: 0.70))
                        Spacer()
                        HStack(spacing: 1) {
                            Text("0").font(.system(size: 7, weight: .heavy, design: .monospaced)).foregroundColor(Color(red: 0.22, green: 0.96, blue: 0.76))
                            Rectangle().fill(Color(red: 0.22, green: 0.96, blue: 0.76)).frame(width: 3.5, height: 1)
                        }
                        Spacer()
                        Text("-6").font(.system(size: 6.5, weight: .bold, design: .monospaced)).foregroundColor(Color(white: 0.65))
                        Spacer()
                        Text("-12").font(.system(size: 6.5, weight: .bold, design: .monospaced)).foregroundColor(Color(white: 0.65))
                        Spacer()
                        Text("-24").font(.system(size: 6.5, weight: .bold, design: .monospaced)).foregroundColor(Color(white: 0.60))
                        Spacer()
                        Text("-∞").font(.system(size: 7, weight: .heavy, design: .monospaced)).foregroundColor(Color(white: 0.70))
                    }
                    .frame(width: 13)
                    .padding(.vertical, 6)

                    // Recessed Center Track Slot with Level / VU Fill & Full-Throw Cap
                    ZStack(alignment: .top) {
                        // Recessed dark well
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.02, green: 0.03, blue: 0.04), Color(red: 0.05, green: 0.06, blue: 0.08)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 7, height: slotHeight)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.16), lineWidth: 0.8))

                        // Active Glowing Level Bar rising from bottom
                        VStack {
                            Spacer()
                            RoundedRectangle(cornerRadius: 2)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.98, green: 0.35, blue: 0.35),
                                            Color(red: 0.96, green: 0.76, blue: 0.18),
                                            Color(red: 0.22, green: 0.96, blue: 0.65)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 3.5, height: max(0, normalizedVal * (slotHeight - 4)))
                                .padding(.bottom, 2)
                                .opacity(0.85)
                        }
                        .frame(width: 7, height: slotHeight)

                        // Studio Aluminum Fader Cap (Goes all the way up to top edge at 127)
                        ZStack {
                            // Cap outer body with metallic chamfer
                            RoundedRectangle(cornerRadius: 3.5)
                                .fill(
                                    LinearGradient(
                                        colors: isSelected
                                            ? [Color(red: 0.32, green: 0.37, blue: 0.40), Color(red: 0.17, green: 0.19, blue: 0.22)]
                                            : [Color(red: 0.26, green: 0.28, blue: 0.31), Color(red: 0.13, green: 0.14, blue: 0.16)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 26, height: capHeight)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3.5)
                                        .stroke(
                                            isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76) : Color.white.opacity(0.35),
                                            lineWidth: isSelected ? 1.5 : 0.8
                                        )
                                )
                                .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 2)

                            // Horizontal finger grip ribs
                            VStack(spacing: 2.5) {
                                Rectangle().fill(Color.white.opacity(0.20)).frame(width: 16, height: 1)
                                Rectangle().fill(Color.white.opacity(0.20)).frame(width: 16, height: 1)
                            }

                            // Center high-contrast index line
                            Rectangle()
                                .fill(
                                    isSelected
                                        ? Color(red: 0.22, green: 0.96, blue: 0.76)
                                        : Color(red: 0.98, green: 0.52, blue: 0.44)
                                )
                                .frame(width: 20, height: 2)
                                .shadow(color: isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76) : Color(red: 0.98, green: 0.52, blue: 0.44), radius: 2)
                        }
                        .frame(width: 26, height: capHeight)
                        .offset(y: capOffsetFromTop)
                    }
                    .frame(width: 26, height: slotHeight)

                    // Right side tick marks
                    VStack(alignment: .leading, spacing: 0) {
                        Rectangle().fill(Color.white.opacity(0.25)).frame(width: 3, height: 1)
                        Spacer()
                        Rectangle().fill(Color(red: 0.22, green: 0.96, blue: 0.76)).frame(width: 4.5, height: 1.2)
                        Spacer()
                        Rectangle().fill(Color.white.opacity(0.20)).frame(width: 3, height: 1)
                        Spacer()
                        Rectangle().fill(Color.white.opacity(0.18)).frame(width: 3, height: 1)
                        Spacer()
                        Rectangle().fill(Color.white.opacity(0.15)).frame(width: 3, height: 1)
                        Spacer()
                        Rectangle().fill(Color.white.opacity(0.20)).frame(width: 3, height: 1)
                    }
                    .frame(width: 5)
                    .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            if !isDragging {
                                isDragging = true
                                onSelect()
                                NSApp.keyWindow?.makeFirstResponder(nil)
                            }
                            let clampedY = min(max(0, gesture.location.y - (capHeight / 2)), travel)
                            let fraction = travel > 0 ? (1.0 - (clampedY / travel)) : 0
                            let newVal: UInt8 = clampedY <= 0.5 ? 127 : (clampedY >= travel - 0.5 ? 0 : UInt8(min(127, max(0, Int(round(fraction * 127.0))))))
                            if newVal != lastSentVal && newVal != item.liveValue {
                                lastSentVal = newVal
                                onValueChange(newVal)
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                            lastSentVal = nil
                        }
                )
            }
            .frame(width: faderWidth, height: max(60, faderHeight - 48))

            // Channel Footer (CC identifier & integer readout)
            HStack(spacing: 2) {
                Text("CC\(item.number)")
                    .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.38))

                Text("\(item.liveValue)")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.65))
            }
            .padding(.vertical, 1.5)
            .padding(.horizontal, 3)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 1)
        .frame(width: faderWidth, height: faderHeight)
        .background(isSelected ? Color.white.opacity(0.06) : Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76).opacity(0.65) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .onTapGesture(count: 2) {
            if item.liveValue == 100 {
                onValueChange(0)
            } else {
                onValueChange(100)
            }
        }
        .onTapGesture(count: 1) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            onSelect()
        }
        .help("\(item.label) CC\(item.number): \(item.liveValue) (\(dbReadout)) - Double-click for Unity (100) / 0")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.label), Control Change \(item.number)")
        .accessibilityValue("\(item.liveValue) out of 127, \(dbReadout)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onValueChange(min(127, item.liveValue + 1))
            case .decrement:
                onValueChange(item.liveValue > 0 ? item.liveValue - 1 : 0)
            @unknown default:
                break
            }
        }
        .accessibilityAction(named: "Set to Unity Gain (100)") {
            onValueChange(100)
        }
        .accessibilityAction(named: "Reset to Zero") {
            onValueChange(0)
        }
    }
}

struct HardwareHorizontalFader: View, Equatable {
    let item: ControlItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onValueChange: (UInt8) -> Void

    @State private var isDragging: Bool = false
    @State private var lastSentVal: UInt8? = nil

    static func == (lhs: HardwareHorizontalFader, rhs: HardwareHorizontalFader) -> Bool {
        return lhs.item.number == rhs.item.number &&
               lhs.item.liveValue == rhs.item.liveValue &&
               lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(spacing: 8) {
            // Channel Header Label (Matching Vertical Fader styling)
            Text(item.label)
                .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                .foregroundColor(isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76) : Color(white: 0.90))
                .frame(width: 32, height: 22)
                .background(isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76).opacity(0.18) : Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 3.5))

            // Precision Horizontal Track with Level Meter & Matching Brushed Aluminum Cap
            GeometryReader { geo in
                let trackWidth = max(30, geo.size.width)
                let capWidth: CGFloat = 20
                let capHeight: CGFloat = 26
                let travel = max(10, trackWidth - capWidth)
                let normalizedVal = CGFloat(item.liveValue) / 127.0
                let capOffsetFromLeft = normalizedVal * travel

                ZStack(alignment: .leading) {
                    // Recessed dark well track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.02, green: 0.03, blue: 0.04), Color(red: 0.05, green: 0.06, blue: 0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: trackWidth, height: 7)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.16), lineWidth: 0.8))

                    // Active glowing level meter extending from left
                    HStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.22, green: 0.96, blue: 0.65),
                                        Color(red: 0.96, green: 0.76, blue: 0.18),
                                        Color(red: 0.98, green: 0.35, blue: 0.35)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, normalizedVal * (trackWidth - 4)), height: 3.5)
                            .padding(.leading, 2)
                            .opacity(0.85)
                        Spacer(minLength: 0)
                    }
                    .frame(width: trackWidth, height: 7)

                    // Studio Aluminum Fader Cap (Exact same theme as Vertical Fader)
                    ZStack {
                        // Cap outer body with metallic chamfer
                        RoundedRectangle(cornerRadius: 3.5)
                            .fill(
                                LinearGradient(
                                    colors: isSelected
                                        ? [Color(red: 0.32, green: 0.37, blue: 0.40), Color(red: 0.17, green: 0.19, blue: 0.22)]
                                        : [Color(red: 0.26, green: 0.28, blue: 0.31), Color(red: 0.13, green: 0.14, blue: 0.16)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: capWidth, height: capHeight)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3.5)
                                    .stroke(
                                        isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76) : Color.white.opacity(0.35),
                                        lineWidth: isSelected ? 1.5 : 0.8
                                    )
                            )
                            .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 2)

                        // Vertical finger grip ribs (perpendicular to throw direction)
                        HStack(spacing: 2.5) {
                            Rectangle().fill(Color.white.opacity(0.20)).frame(width: 1, height: 16)
                            Rectangle().fill(Color.white.opacity(0.20)).frame(width: 1, height: 16)
                        }

                        // Center high-contrast index line
                        Rectangle()
                            .fill(
                                isSelected
                                    ? Color(red: 0.22, green: 0.96, blue: 0.76)
                                    : Color(red: 0.98, green: 0.52, blue: 0.44)
                            )
                            .frame(width: 2, height: 20)
                            .shadow(color: isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76) : Color(red: 0.98, green: 0.52, blue: 0.44), radius: 2)
                    }
                    .frame(width: capWidth, height: capHeight)
                    .offset(x: capOffsetFromLeft)
                }
                .frame(width: trackWidth, height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            if !isDragging {
                                isDragging = true
                                onSelect()
                                NSApp.keyWindow?.makeFirstResponder(nil)
                            }
                            let clampedX = min(max(0, gesture.location.x - (capWidth / 2)), travel)
                            let fraction = travel > 0 ? (clampedX / travel) : 0
                            let newVal: UInt8 = clampedX >= travel - 0.5 ? 127 : (clampedX <= 0.5 ? 0 : UInt8(min(127, max(0, Int(round(fraction * 127.0))))))
                            if newVal != lastSentVal && newVal != item.liveValue {
                                lastSentVal = newVal
                                onValueChange(newVal)
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                            lastSentVal = nil
                        }
                )
            }
            .frame(height: 28)

            // Channel Footer Badge (Matching Vertical Fader styling)
            HStack(spacing: 2) {
                Text("CC\(item.number)")
                    .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.38))

                Text("\(item.liveValue)")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.65))
            }
            .padding(.vertical, 1.5)
            .padding(.horizontal, 4)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.white.opacity(0.06) : Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76).opacity(0.65) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .onTapGesture(count: 2) {
            onValueChange(0)
        }
        .onTapGesture(count: 1) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            onSelect()
        }
        .help("\(item.label) CC\(item.number): \(item.liveValue) (Double-click to reset 0)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.label), Control Change \(item.number)")
        .accessibilityValue("\(item.liveValue) out of 127")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onValueChange(min(127, item.liveValue + 1))
            case .decrement:
                onValueChange(item.liveValue > 0 ? item.liveValue - 1 : 0)
            @unknown default:
                break
            }
        }
        .accessibilityAction(named: "Reset to Zero") {
            onValueChange(0)
        }
        .accessibilityAction(named: "Center to 64") {
            onValueChange(64)
        }
        .accessibilityAction(named: "Set to Maximum 127") {
            onValueChange(127)
        }
    }
}

struct HardwareKnob: View, Equatable {
    let item: ControlItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onValueChange: (UInt8) -> Void

    @State private var dragInitialValue: Double? = nil

    static func == (lhs: HardwareKnob, rhs: HardwareKnob) -> Bool {
        return lhs.item.number == rhs.item.number &&
               lhs.item.liveValue == rhs.item.liveValue &&
               lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                // Dial body with metallic rim
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(white: 0.22), Color(white: 0.10)],
                            center: .center,
                            startRadius: 2,
                            endRadius: 16
                        )
                    )
                    .frame(width: 38, height: 38)
                    .overlay(
                        Circle().stroke(isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76) : Color.white.opacity(0.2), lineWidth: isSelected ? 1.8 : 1.0)
                    )
                    .shadow(color: isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76).opacity(0.5) : .black.opacity(0.6), radius: 3)

                // Indicator line
                Rectangle()
                    .fill(Color(white: 0.98))
                    .frame(width: 2, height: 10)
                    .offset(y: -7)
                    .rotationEffect(.degrees(Double(item.liveValue) / 127.0 * 270.0 - 135.0))
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragInitialValue == nil {
                            onSelect()
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            dragInitialValue = Double(item.liveValue) / 127.0
                        }
                        let start = dragInitialValue ?? (Double(item.liveValue) / 127.0)
                        let delta = -Double(gesture.translation.height) / 140.0
                        let clamped = min(max(0.0, start + delta), 1.0)
                        let newVal = UInt8(round(clamped * 127.0))
                        if newVal != item.liveValue {
                            onValueChange(newVal)
                        }
                    }
                    .onEnded { _ in
                        dragInitialValue = nil
                    }
            )

            HStack(spacing: 3) {
                Text(item.label)
                    .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76) : Color(red: 0.45, green: 0.88, blue: 0.75))
                Text("CC\(item.number)")
                    .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.38))
            }
        }
        .frame(width: 58)
        .padding(2)
        .onTapGesture(count: 2) {
            onValueChange(64) // Center knob to 64!
        }
        .onTapGesture(count: 1) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            onSelect()
        }
        .help("\(item.label) CC\(item.number): \(item.liveValue) (Double-click to center 64)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.label), Control Change \(item.number)")
        .accessibilityValue("\(item.liveValue) out of 127")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onValueChange(min(127, item.liveValue + 1))
            case .decrement:
                onValueChange(item.liveValue > 0 ? item.liveValue - 1 : 0)
            @unknown default:
                break
            }
        }
        .accessibilityAction(named: "Center to 64") {
            onValueChange(64)
        }
        .accessibilityAction(named: "Reset to Zero") {
            onValueChange(0)
        }
        .accessibilityAction(named: "Set to Maximum 127") {
            onValueChange(127)
        }
    }
}

// ============================================================================
// 4. MAIN CONTENT VIEW // TWO SYMMETRIC UNITED COLUMNS
// ============================================================================

struct WindowLevelAndSizeAccessor: NSViewRepresentable {
    var isAlwaysOnTop: Bool
    var baseSize: NSSize
    var minScale: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let win = view?.window else { return }
            configureWindow(win)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let win = nsView.window else { return }
        let targetLevel: NSWindow.Level = isAlwaysOnTop ? .floating : .normal
        if win.level != targetLevel {
            win.level = targetLevel
        }
        win.contentResizeIncrements = NSSize(width: 1.0, height: 1.0)
        let targetMin = NSSize(width: max(380, baseSize.width * minScale), height: max(260, baseSize.height * minScale))
        if win.contentMinSize != targetMin {
            win.contentMinSize = targetMin
        }
    }

    private func configureWindow(_ window: NSWindow) {
        window.level = isAlwaysOnTop ? .floating : .normal
        window.contentResizeIncrements = NSSize(width: 1.0, height: 1.0)
        window.contentMinSize = NSSize(width: max(380, baseSize.width * minScale), height: max(260, baseSize.height * minScale))
    }
}

final class DetachedModuleWindow: NSWindow {
    var moduleID: StudioModuleID?
    weak var engine: BitchBoyEngine?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.deviceIndependentFlagsMask]) == .command,
           event.charactersIgnoringModifiers == "w" {
            if let mod = moduleID, let eng = engine {
                eng.dockModuleBackFromWindow(mod, fromWindowClose: false)
                return true
            }
            self.performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.deviceIndependentFlagsMask]) == .command,
           event.charactersIgnoringModifiers == "w" {
            if let mod = moduleID, let eng = engine {
                eng.dockModuleBackFromWindow(mod, fromWindowClose: false)
                return
            }
            self.performClose(nil)
            return
        }
        super.keyDown(with: event)
    }
}

final class ModuleWindowCloseDelegate: NSObject, NSWindowDelegate {
    let module: StudioModuleID
    weak var engine: BitchBoyEngine?

    init(module: StudioModuleID, engine: BitchBoyEngine) {
        self.module = module
        self.engine = engine
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.engine?.dockModuleBackFromWindow(self.module, fromWindowClose: true)
        }
    }
}

struct ModuleSlotDropDelegate: DropDelegate {
    let targetModule: StudioModuleID
    let engine: BitchBoyEngine

    func performDrop(info: DropInfo) -> Bool {
        guard !targetModule.isHardwareModule else { return false }
        if let dragged = engine.draggingModule, dragged != targetModule, !dragged.isHardwareModule {
            engine.swapModules(dragged, targetModule)
        }
        engine.draggingModule = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard !targetModule.isHardwareModule else { return }
        guard let dragged = engine.draggingModule, dragged != targetModule, !dragged.isHardwareModule else { return }
        engine.swapModules(dragged, targetModule)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

struct ZoneDropDelegate: DropDelegate {
    let targetZone: ModuleZone
    let engine: BitchBoyEngine

    func performDrop(info: DropInfo) -> Bool {
        if let dragged = engine.draggingModule, !dragged.isHardwareModule {
            engine.moveModuleToZone(dragged, zone: targetZone)
        }
        engine.draggingModule = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

struct DetachedModuleWindowHostView: View {
    let engine: BitchBoyEngine
    let module: StudioModuleID

    var body: some View {
        ContentView(engine: engine, standaloneModule: module)
    }
}

// ============================================================================
// PER-CONTROL MAPPING & ASSIGNMENT EDITOR (RIGHT-CLICK → EDIT MAPPING)
// ============================================================================

/// Identifies which control the mapping editor sheet is presenting.
struct ControlMappingTarget: Identifiable {
    let id: Int
}

/// Sheet for viewing and editing a single control's mapping: hardware identity,
/// LED feedback, and the action it triggers (QWERTY, OSC, MSC, AppleScript, DMX).
struct ControlMappingEditorView: View {
    @Bindable var engine: BitchBoyEngine
    let index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if index >= 0 && index < engine.controls.count {
                let item = engine.controls[index]
                header(for: item)
                Divider()
                Form {
                    identitySection(for: item)
                    if item.hasLED {
                        feedbackSection(for: item)
                    }
                    actionSection(for: item)
                    if item.actionType == .osc || item.oscEnabled {
                        oscSection(for: item)
                    }
                }
                .formStyle(.grouped)
            } else {
                Text("This control is no longer available.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 620)
    }

    // MARK: - Layout

    private func header(for item: ControlItem) -> some View {
        HStack(spacing: 10) {
            if item.hasLED {
                RoundedRectangle(cornerRadius: 4)
                    .fill(BitchBoyHardwareColor.color(for: item.idleVelocity))
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.3), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.customName.isEmpty ? item.label : item.customName)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                Text("\(kindTitle(item.kind)) · \(numberTitle(for: item)) · Zone \(item.zone)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                engine.resetControl(index: index)
            } label: {
                Text("Reset to Factory Default")
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - Sections

    private func identitySection(for item: ControlItem) -> some View {
        Section("Hardware Identity") {
            LabeledContent("Hardware Label", value: item.label)
            LabeledContent("Type", value: kindTitle(item.kind))
            LabeledContent(item.kind == .key ? "MIDI Note" : "MIDI CC", value: "\(item.number)")
            LabeledContent("Zone", value: item.zone)
            if item.kind != .key {
                LabeledContent("Live Value", value: "\(item.liveValue)")
            }
            TextField("Custom Name", text: field(\.customName, "Rename Control"), prompt: Text(item.label))
        }
    }

    private func feedbackSection(for item: ControlItem) -> some View {
        Section("LED Feedback") {
            Picker("Feedback Mode", selection: field(\.feedbackMode, "Change Feedback Mode")) {
                ForEach(FeedbackMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            velocityRow("Idle Color", value: idleVelocityBinding)
            velocityRow("Active Color", value: field(\.activeVelocity, "Change Active Color"))
            if item.feedbackMode == .customVelocity {
                velocityRow("Custom Feedback Color", value: field(\.feedbackCustomVelocity, "Change Feedback Color"))
            }
            Toggle("Invert Feedback", isOn: field(\.feedbackInvert, "Toggle Feedback Invert"))
        }
    }

    private func actionSection(for item: ControlItem) -> some View {
        Section("Action Assignment") {
            Picker("Action", selection: field(\.actionType, "Change Action")) {
                ForEach(ActionType.allCases, id: \.self) { type in
                    Text(actionTitle(type)).tag(type)
                }
            }

            switch item.actionType {
            case .passthrough:
                Text("Sends the raw MIDI message only. No extra action is triggered.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .qwerty:
                qwertyStepsEditor(for: item)
            case .osc:
                EmptyView()
            case .applescript:
                TextEditor(text: field(\.appleScript, "Edit AppleScript"))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 90)
            case .msc:
                Picker("MSC Command", selection: mscCommandBinding) {
                    ForEach(MSCCommand.allCases) { command in
                        Text(command.title).tag(command)
                    }
                }
                TextField("Cue Number", text: field(\.mscCueNumber, "Edit MSC Cue"), prompt: Text("e.g. 12.5"))
            case .artnet, .sacn:
                Text("Broadcasts the full rig's DMX state using the global \(item.actionType == .artnet ? "Art-Net" : "sACN") settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if item.actionType != .osc {
                Toggle("Also Send OSC", isOn: field(\.oscEnabled, "Toggle OSC Send"))
            }
        }
    }

    private func oscSection(for item: ControlItem) -> some View {
        Section {
            TextField("Host", text: field(\.oscHost, "Edit OSC Host"), prompt: Text(engine.customOSCHost))
            TextField("Port", value: field(\.oscPort, "Edit OSC Port"), format: .number.grouping(.never))
            TextField("Address", text: field(\.oscAddress, "Edit OSC Address"), prompt: Text("/bitchboy/key/\(index + 1)"))
            Picker("Argument Type", selection: oscArgTypeBinding) {
                ForEach(OSCArgumentType.allCases) { type in
                    Text(type.label).tag(type)
                }
            }
            if item.kind == .key {
                TextField("Press Value", text: field(\.oscArgValue, "Edit OSC Value"))
                Toggle("Send on Release", isOn: field(\.oscSendRelease, "Toggle OSC Release"))
                if item.oscSendRelease {
                    TextField("Release Value", text: field(\.oscReleaseVal, "Edit OSC Release Value"))
                }
            } else {
                TextField("Range Min", value: field(\.oscMinVal, "Edit OSC Range"), format: .number)
                TextField("Range Max", value: field(\.oscMaxVal, "Edit OSC Range"), format: .number)
            }
        } header: {
            Text("OSC Output")
        } footer: {
            if !engine.midiToOSCMappingActive {
                Text("MIDI → OSC mapping is currently turned off globally, so OSC won't be sent until it's enabled.")
                    .foregroundColor(.orange)
            }
        }
    }

    private func qwertyStepsEditor(for item: ControlItem) -> some View {
        Group {
            ForEach(Array(item.qwertySteps.enumerated()), id: \.element.id) { stepIndex, _ in
                HStack(spacing: 8) {
                    TextField("Key", text: qwertyStepBinding(stepIndex, \.key), prompt: Text("space"))
                        .frame(width: 80)
                    Toggle("⌘", isOn: qwertyStepBinding(stepIndex, \.cmd)).toggleStyle(.button)
                    Toggle("⇧", isOn: qwertyStepBinding(stepIndex, \.shift)).toggleStyle(.button)
                    Toggle("⌥", isOn: qwertyStepBinding(stepIndex, \.alt)).toggleStyle(.button)
                    Toggle("⌃", isOn: qwertyStepBinding(stepIndex, \.ctrl)).toggleStyle(.button)
                    TextField("Delay", value: qwertyStepBinding(stepIndex, \.delayMs), format: .number)
                        .frame(width: 50)
                    Text("ms").foregroundColor(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        engine.recordUndoSnapshot(actionName: "Remove QWERTY Step")
                        engine.controls[index].qwertySteps.remove(at: stepIndex)
                        engine.saveCurrentSlot()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                engine.recordUndoSnapshot(actionName: "Add QWERTY Step")
                engine.controls[index].qwertySteps.append(QwertyStep(key: ""))
                engine.saveCurrentSlot()
            } label: {
                Label("Add Keystroke", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            if !engine.qwertyKeybindsEnabled {
                Text("QWERTY keybinds are currently turned off globally.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    private func velocityRow(_ title: String, value: Binding<UInt8>) -> some View {
        HStack {
            Text(title)
            Spacer()
            RoundedRectangle(cornerRadius: 3)
                .fill(BitchBoyHardwareColor.color(for: value.wrappedValue))
                .frame(width: 18, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.3), lineWidth: 1))
            Stepper(value: value, in: 0...127) {
                Text("\(value.wrappedValue)")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }

    // MARK: - Bindings

    /// Binds a control field to the engine, recording a debounced undo step and saving the slot on change.
    private func field<Value>(_ keyPath: WritableKeyPath<ControlItem, Value>, _ undoName: String) -> Binding<Value> {
        Binding(
            get: { engine.controls[index][keyPath: keyPath] },
            set: { newValue in
                engine.recordUndoSnapshot(actionName: undoName, debounceSeconds: 1.0)
                engine.controls[index][keyPath: keyPath] = newValue
                engine.saveCurrentSlot()
            }
        )
    }

    /// The idle color is what the LED shows at rest, so push it to the hardware immediately.
    private var idleVelocityBinding: Binding<UInt8> {
        Binding(
            get: { engine.controls[index].idleVelocity },
            set: { newValue in
                engine.recordUndoSnapshot(actionName: "Change Idle Color", debounceSeconds: 1.0)
                engine.controls[index].idleVelocity = newValue
                if !engine.controls[index].isPressed && !engine.controls[index].toggleLatched {
                    engine.controls[index].currentLED = newValue
                    engine.sendNoteOn(note: engine.controls[index].number, velocity: newValue)
                }
                engine.saveCurrentSlot()
            }
        )
    }

    private var mscCommandBinding: Binding<MSCCommand> {
        Binding(
            get: { engine.controls[index].typedMSCCommand },
            set: { newValue in
                engine.recordUndoSnapshot(actionName: "Change MSC Command")
                engine.controls[index].typedMSCCommand = newValue
                engine.saveCurrentSlot()
            }
        )
    }

    private var oscArgTypeBinding: Binding<OSCArgumentType> {
        Binding(
            get: { engine.controls[index].typedOSCArgType },
            set: { newValue in
                engine.recordUndoSnapshot(actionName: "Change OSC Argument")
                engine.controls[index].typedOSCArgType = newValue
                engine.saveCurrentSlot()
            }
        )
    }

    private func qwertyStepBinding<Value>(_ stepIndex: Int, _ keyPath: WritableKeyPath<QwertyStep, Value>) -> Binding<Value> {
        Binding(
            // Fall back to a blank step if this row was just removed but SwiftUI reads it once more.
            get: {
                let steps = engine.controls[index].qwertySteps
                return (steps.indices.contains(stepIndex) ? steps[stepIndex] : QwertyStep(key: ""))[keyPath: keyPath]
            },
            set: { newValue in
                guard stepIndex < engine.controls[index].qwertySteps.count else { return }
                engine.recordUndoSnapshot(actionName: "Edit QWERTY Step", debounceSeconds: 1.0)
                engine.controls[index].qwertySteps[stepIndex][keyPath: keyPath] = newValue
                engine.saveCurrentSlot()
            }
        )
    }

    // MARK: - Display Names

    private func kindTitle(_ kind: ControlKind) -> String {
        switch kind {
        case .key: return "Key"
        case .vfader: return "Vertical Fader"
        case .hfader: return "Horizontal Fader"
        case .knob: return "Rotary Knob"
        }
    }

    private func numberTitle(for item: ControlItem) -> String {
        item.kind == .key ? "Note \(item.number)" : "CC \(item.number)"
    }

    private func actionTitle(_ type: ActionType) -> String {
        switch type {
        case .passthrough: return "MIDI Passthrough"
        case .qwerty: return "QWERTY Macro"
        case .osc: return "OSC (UDP)"
        case .applescript: return "AppleScript"
        case .msc: return "MIDI Show Control"
        case .artnet: return "Art-Net DMX"
        case .sacn: return "sACN (E1.31)"
        }
    }
}

// ============================================================================
// CREATOR CARD (OPENED FROM THE "TAYLOR FOSSEN" BADGE)
// ============================================================================

struct CreatorCardView: View {
    var accentColor: Color = .cyan
    @Environment(\.dismiss) private var dismiss

    private let coffeeURL = URL(string: "https://buymeacoffee.com/fossen")

    var body: some View {
        VStack(spacing: 16) {
            // Square asset with the artwork centered, so a circular crop keeps the squirrel in the middle.
            Image("SquirrelLogo")
                .resizable()
                .scaledToFill()
                .frame(width: 220, height: 220)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(accentColor.opacity(0.85), lineWidth: 2)
                )
                .shadow(color: accentColor.opacity(0.35), radius: 10)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Taylor Fossen squirrel logo")

            HStack(spacing: 6) {
                Text("Made with")
                Image(systemName: "heart.fill")
                    .foregroundColor(.pink)
                    .accessibilityLabel("love")
                Text("by Taylor Fossen")
            }
            .font(.system(size: 16, weight: .heavy, design: .monospaced))

            if let coffeeURL {
                Link(destination: coffeeURL) {
                    Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(accentColor.opacity(0.22)))
                        .overlay(Capsule().stroke(accentColor, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("buymeacoffee.com/fossen")

                Text("buymeacoffee.com/fossen")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 408)
    }
}

struct ContentView: View {
    @Bindable var engine: BitchBoyEngine
    var standaloneModule: StudioModuleID? = nil

    @State private var isHoveringLoveBadge: Bool = false
    @State private var isHoveringTitleLogo: Bool = false
    @State private var activeMemoryBank: Int = 0 // 0 = BANK 1 (A-D), 1 = BANK 2 (E-H)
    @State private var showSlotCustomizer: Bool = false
    @State private var mappingEditorTarget: ControlMappingTarget? = nil
    @State private var showCreatorCard: Bool = false
    @State private var inspectorTab: Int = 0 // 0 = LEDs, 1 = QWERTY
    @State private var isEditingNameBox: Bool = false
    @FocusState private var isNameFieldFocused: Bool
    @State private var isEditingSlotName: Bool = false
    @State private var isEditingShowName: Bool = false
    @State private var isEditingSynthName: Bool = false
    @State private var resizingModule: StudioModuleID? = nil
    @State private var dragInitialHeight: CGFloat = 0
    @State private var terminalQuickCommand: String = ""

    func currentScale(for module: StudioModuleID, isSpotlight: Bool = false) -> CGFloat {
        engine.moduleTextScale(module, isSpotlight: isSpotlight || engine.spotlightModule == module || standaloneModule == module)
    }

    func isExpanded(module: StudioModuleID, isSpotlight: Bool = false) -> Bool {
        engine.isModuleExpanded(module, isSpotlight: isSpotlight || engine.spotlightModule == module || standaloneModule == module)
    }

    private func setQwertyKeyForSelection(_ key: String) {
        isEditingNameBox = false
        let targets = engine.selectedIndices.count > 1 ? Array(engine.selectedIndices) : [engine.selectedIndex]
        for idx in targets where engine.controls[idx].hasLED {
            engine.controls[idx].actionType = .qwerty
            if engine.controls[idx].qwertySteps.isEmpty {
                engine.controls[idx].qwertySteps = [QwertyStep(key: key)]
            } else {
                engine.controls[idx].qwertySteps[0].key = key
            }
        }
        engine.saveCurrentSlot()
    }

    private func toggleQwertyModifierForSelection(_ modify: (inout QwertyStep) -> Void) {
        let targets = engine.selectedIndices.count > 1 ? Array(engine.selectedIndices) : [engine.selectedIndex]
        for idx in targets where engine.controls[idx].hasLED {
            if engine.controls[idx].qwertySteps.isEmpty {
                engine.controls[idx].qwertySteps = [QwertyStep(key: "space")]
            }
            modify(&engine.controls[idx].qwertySteps[0])
        }
        engine.saveCurrentSlot()
        SoundEffect.knobTick.play(with: engine.soundPack)
    }

    var selectedControl: ControlItem {
        if engine.selectedIndex < engine.controls.count {
            return engine.controls[engine.selectedIndex]
        }
        return engine.controls[0]
    }

    private func ledColor(_ vel: UInt8) -> Color {
        if vel == 0 { return BitchBoyHardwareColor.off }

        switch engine.ledPalette {
        case .multiVelocity:
            return BitchBoyHardwareColor.color(for: vel)
        case .cyberCyan:
            return BitchBoyHardwareColor.cyan
        case .matrixGreen:
            return BitchBoyHardwareColor.green
        case .solarAmber:
            return BitchBoyHardwareColor.amber
        case .synthMagenta:
            return BitchBoyHardwareColor.pink
        case .arcticWhite:
            return BitchBoyHardwareColor.white
        }
    }

    var body: some View {
        Group {
            if let detachedMod = standaloneModule {
                standaloneModuleWindowBody(for: detachedMod)
                    .preferredColorScheme(.dark)
            } else {
                mainConsoleWindowBody
                    .preferredColorScheme(.dark)
            }
        }
        .sheet(item: $mappingEditorTarget) { target in
            ControlMappingEditorView(engine: engine, index: target.id)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showCreatorCard) {
            CreatorCardView(accentColor: engine.currentTheme.accentPrimary)
                .preferredColorScheme(.dark)
        }
    }

    private func standaloneModuleWindowBody(for module: StudioModuleID) -> some View {
        GeometryReader { geo in
            let isTopMost = engine.isModuleWindowTopMost(module)

            ZStack {
                Color(red: 0.02, green: 0.05, blue: 0.04)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: module.iconName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                        Text("FLOATING // \(module.rawValue.uppercased())")
                            .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                            .foregroundColor(.white)
                        Spacer()

                        // TOP MOST PIN TOGGLE
                        Button(action: {
                            engine.toggleModuleWindowTopMost(module)
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: isTopMost ? "pin.fill" : "pin")
                                Text(isTopMost ? "PINNED" : "PIN")
                            }
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isTopMost ? Color(red: 1.0, green: 0.35, blue: 0.15) : Color.white.opacity(0.12))
                            .foregroundColor(isTopMost ? .black : .white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isTopMost ? Color.orange : Color.white.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Pin window Always on Top")
                        .hoverGrow(1.05)

                        // DOCK BACK
                        Button(action: {
                            engine.dockModuleBackFromWindow(module)
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.down.left.square.fill")
                                Text("DOCK ⌘W")
                            }
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(engine.currentTheme.accentPrimary)
                            .foregroundColor(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .hoverGrow(1.05)
                        .help("Re-dock module into console (or press ⌘W)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6))
                    .overlay(
                        Rectangle().frame(height: 1.5).foregroundColor(
                            engine.currentTheme.isRainbow
                                ? Color(red: 1.0, green: 0.35, blue: 0.85)
                                : engine.currentTheme.accentPrimary.opacity(0.4)
                        ),
                        alignment: .bottom
                    )

                    moduleContentView(for: module, isSpotlight: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    private var mainConsoleWindowBody: some View {
        GeometryReader { windowGeo in
            let baseChassisBaseW: CGFloat = (engine.hasLeftWing ? engine.leftWingWidth + 24 : 0)
                + engine.centerConsoleWidth
                + (engine.hasRightWing ? engine.rightWingWidth + 24 : 0)
                + 44
            let baseWidth: CGFloat = baseChassisBaseW + 32
            let baseHeight: CGFloat = engine.effectiveConsoleHeight

            // Fit scale ensures all vertical content fits nicely inside the window:
            let fitH = max(0.15, min(2.5, windowGeo.size.height / baseHeight))
            let fitW = max(0.15, min(2.5, windowGeo.size.width / baseWidth))

            // When window is wider than base aspect ratio, fitScale is determined by height (fitH),
            // and we stretch the UI horizontally across the entire width of the window!
            let fitScale = min(fitW, fitH)

            // Available unscaled width inside the window bounds at this fitScale:
            let availableUnscaledWidth = max(baseChassisBaseW, (windowGeo.size.width / fitScale) - 32)
            let extraWidth = max(0, availableUnscaledWidth - baseChassisBaseW)

            // Compute dynamic wing widths that stretch out to the sides:
            let effLeftW: CGFloat = {
                guard engine.hasLeftWing else { return 0 }
                if engine.hasRightWing {
                    return engine.leftWingWidth + (extraWidth / 2)
                } else {
                    return engine.leftWingWidth + extraWidth
                }
            }()

            let effRightW: CGFloat = {
                guard engine.hasRightWing else { return 0 }
                if engine.hasLeftWing {
                    return engine.rightWingWidth + (extraWidth / 2)
                } else {
                    return engine.rightWingWidth + extraWidth
                }
            }()

            let totalLeftW: CGFloat = engine.hasLeftWing ? (effLeftW + 24) : 0
            let totalRightW: CGFloat = engine.hasRightWing ? (effRightW + 24) : 0
            let currentChassisWidth = totalLeftW + engine.centerConsoleWidth + totalRightW + 44
            let currentContainerWidth = currentChassisWidth + 32

            let isOverlayActive = (engine.spotlightModule != nil || engine.showCustomSoundStudio || engine.showCustomThemeStudio || engine.showUpdateModal)

            ZStack {
                // Lock NSWindow minimum size so dragging the window scales the whole controller proportionally with zero clipping
                WindowLevelAndSizeAccessor(
                    isAlwaysOnTop: engine.isWindowAlwaysOnTop,
                    baseSize: NSSize(width: baseWidth, height: baseHeight),
                    minScale: 0.15
                )
                .frame(width: 0, height: 0)

                // Dark Cyber Background
                Color(red: 0.02, green: 0.05, blue: 0.04)
                    .ignoresSafeArea()

                ZStack {
                    // Main Console Layer (Blurs smoothly when a module is Spotlit in the center or Custom Sound Studio is open!)
                    ZStack(alignment: .top) {
                        VStack(spacing: 12) {
                            topNavigationBar(width: currentChassisWidth)
                            mainHardwareFaceplate(effLeftW: effLeftW, effRightW: effRightW, chassisWidth: currentChassisWidth)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        if let toast = engine.toastNotification {
                            HStack(spacing: 8) {
                                Image(systemName: toast.icon)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(engine.currentTheme.accentPrimary)
                                Text(toast.message)
                                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.92))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(engine.currentTheme.accentPrimary.opacity(0.8), lineWidth: 1.2))
                            .shadow(color: engine.currentTheme.accentPrimary.opacity(0.5), radius: 8)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                            .padding(.top, 48)
                            .zIndex(999)
                        }

                        if engine.showConnectionBanner {
                            HStack(spacing: 12) {
                                Image("BitchBoyBadgeIcon")
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                                    .frame(width: 32, height: 32)
                                    .shadow(color: Color(red: 0.2, green: 0.98, blue: 0.55), radius: 8)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(engine.connectionBannerTitle)
                                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                        .foregroundColor(Color(red: 0.25, green: 1.0, blue: 0.60))
                                    Text(engine.connectionBannerSubtitle)
                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                }

                                Button(action: {
                                    withAnimation { engine.showConnectionBanner = false }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(Color.white.opacity(0.75))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Dismiss connection banner")
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(red: 0.03, green: 0.16, blue: 0.12).opacity(0.96))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color(red: 0.2, green: 0.98, blue: 0.55), lineWidth: 1.8)
                            )
                            .shadow(color: Color(red: 0.2, green: 0.98, blue: 0.55).opacity(0.75), radius: 18, x: 0, y: 4)
                            .padding(.top, 54)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if engine.showUpToDateNotice {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundColor(Color.green)
                                Text(engine.updateCheckResultNotice)
                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                Button(action: {
                                    withAnimation { engine.showUpToDateNotice = false }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(Color.white.opacity(0.75))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Dismiss update notice")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(red: 0.03, green: 0.16, blue: 0.12).opacity(0.96))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.green.opacity(0.8), lineWidth: 1.5)
                            )
                            .shadow(color: Color.green.opacity(0.6), radius: 14, x: 0, y: 3)
                            .padding(.top, 54)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .compositingGroup()
                    .blur(radius: isOverlayActive ? 14 : 0)
                    .scaleEffect(isOverlayActive ? 0.97 : 1.0)
                    .animation(.spring(response: 0.34, dampingFraction: 0.8), value: isOverlayActive)
                }
                .frame(width: currentContainerWidth, height: baseHeight, alignment: .top)
                .scaleEffect(fitScale, anchor: .center)
                .frame(width: windowGeo.size.width, height: windowGeo.size.height, alignment: .center)

                // FLOATING REARRANGE & DYNAMIC RESIZING STATUS BANNER
                if engine.isRearrangingModules {
                    VStack {
                        HStack(spacing: 12) {
                            HStack(spacing: 6) {
                                Image(systemName: "hand.draw.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Color(red: 0.96, green: 0.76, blue: 0.18))
                                Text("REARRANGE & RESIZE MODE ACTIVE")
                                    .font(.system(size: 11, weight: .bold, design: .default))
                                    .foregroundColor(.white)
                            }

                            Text("• Drag cards or use [⇦ LW] [⇨ RW] [⇩ RACK] pills")
                                .font(.system(size: 9.5, weight: .medium, design: .default))
                                .foregroundColor(Color(white: 0.85))

                            Button(action: {
                                engine.toggleRearrangeModulesMode()
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text("LOCK LAYOUT")
                                }
                                .font(.system(size: 10, weight: .bold, design: .default))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background(Color(red: 0.96, green: 0.76, blue: 0.18))
                                .foregroundColor(.black)
                                .clipShape(Capsule())
                                .shadow(color: Color(red: 0.96, green: 0.76, blue: 0.18).opacity(0.55), radius: 5)
                            }
                            .buttonStyle(.plain)
                            .hoverGrow(1.05)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.08, green: 0.10, blue: 0.12).opacity(0.96))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color(red: 0.96, green: 0.76, blue: 0.18).opacity(0.85), lineWidth: 1.2)
                        )
                        .shadow(color: .black.opacity(0.65), radius: 10, y: 4)
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))

                        Spacer()
                    }
                }

                // CENTER SPOTLIGHT MODULE OVERLAY (When user clicks the top bar of any module!)
                // Rendered at native unscaled resolution outside fitScale for razor-sharp legibility on any display size!
                if let spotMod = engine.spotlightModule {
                    let spotW = min(880, max(520, windowGeo.size.width - 32))
                    let spotH = min(720, max(420, windowGeo.size.height - 32))

                    ZStack {
                        // Clickable translucent cyber backdrop over the blurred console
                        Color.black.opacity(0.68)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                    engine.spotlightModule = nil
                                }
                            }

                        VStack(spacing: 0) {
                            // Spotlight Control Strip
                            HStack(spacing: 8) {
                                Image(systemName: spotMod.iconName)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(engine.currentTheme.accentPrimary)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text("CENTER SPOTLIGHT // \(spotMod.rawValue.uppercased())")
                                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                            .foregroundColor(.white)
                                        Circle().fill(Color.green).frame(width: 6, height: 6)
                                        Text("LIVE")
                                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                            .foregroundColor(Color.green)
                                    }
                                    Text("Enlarged studio view • Edit settings or pop out to floating window")
                                        .font(.system(size: 8.5, design: .monospaced))
                                        .foregroundColor(Color(white: 0.72))
                                }

                                Spacer()

                                // Dynamic Size Presets inside Spotlight
                                HStack(spacing: 3) {
                                    Button(action: {
                                        engine.setModuleHeight(spotMod, height: 210, save: true)
                                    }) {
                                        Text("COMPACT")
                                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 4)
                                            .background(Color.white.opacity(0.10))
                                            .foregroundColor(Color(white: 0.85))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: {
                                        engine.setModuleHeight(spotMod, height: 340, save: true)
                                    }) {
                                        Text("STANDARD")
                                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 4)
                                            .background(Color.white.opacity(0.10))
                                            .foregroundColor(Color(white: 0.85))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: {
                                        engine.setModuleHeight(spotMod, height: 480, save: true)
                                    }) {
                                        Text("EXPANDED")
                                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 4)
                                            .background(Color.white.opacity(0.10))
                                            .foregroundColor(Color(white: 0.85))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    .buttonStyle(.plain)
                                }

                                Button(action: {
                                    engine.popOutModuleToWindow(spotMod)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "macwindow.badge.plus")
                                        Text("OPEN IN OWN WINDOW")
                                    }
                                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.14))
                                    .foregroundColor(engine.currentTheme.accentPrimary)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .hoverGrow(1.05)

                                Button(action: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                        engine.spotlightModule = nil
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "xmark.circle.fill")
                                        Text("RETURN TO DOCK (ESC)")
                                    }
                                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(engine.currentTheme.accentPrimary)
                                    .foregroundColor(.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .keyboardShortcut(.escape, modifiers: [])
                                .hoverGrow(1.05)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(red: 0.04, green: 0.10, blue: 0.09).opacity(0.98))
                            .overlay(Rectangle().frame(height: 1).foregroundColor(engine.currentTheme.accentPrimary.opacity(0.3)), alignment: .bottom)

                            // Module Content Rendered in full width, crisp and responsive with NO scaleEffect!
                            moduleContentView(for: spotMod, isSpotlight: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                        .frame(width: spotW, height: spotH)
                        .background(Color(red: 0.03, green: 0.05, blue: 0.06).opacity(0.98))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(engine.currentTheme.accentPrimary, lineWidth: 1.5))
                        .shadow(color: engine.currentTheme.accentPrimary.opacity(0.45), radius: 24, x: 0, y: 8)
                        .shadow(color: Color.black.opacity(0.9), radius: 36, x: 0, y: 14)
                        .transition(.scale(scale: 0.90).combined(with: .opacity))
                    }
                }

                // CUSTOM SOUND UPLOAD STUDIO OVERLAY (Centered with Blurred Console Behind It)
                if engine.showCustomSoundStudio {
                    customSoundStudioOverlay
                        .transition(.scale(scale: 0.90).combined(with: .opacity))
                }

                // CUSTOM THEME STUDIO OVERLAY (Centered with Blurred Console Behind It)
                if engine.showCustomThemeStudio {
                    customThemeStudioOverlay
                        .transition(.scale(scale: 0.90).combined(with: .opacity))
                }

                // GITHUB AUTO-UPDATER OVERLAY (Centered with Blurred Console Behind It)
                if engine.showUpdateModal {
                    updateSheetOverlay
                        .transition(.scale(scale: 0.90).combined(with: .opacity))
                }
            }
            .onAppear {
                engine.lastComputedFitScale = fitScale
                engine.applyWindowAlwaysOnTop()
            }
            .onChange(of: windowGeo.size) {
                if abs(engine.lastComputedFitScale - fitScale) >= 0.05 {
                    engine.lastComputedFitScale = fitScale
                }
            }

        }
    }

    // ------------------------------------------------------------------------
    // TOP NAVIGATION & SYSTEM BAR (CLEAN 3-ZONE CYBER COMMAND CONSOLE)
    // ------------------------------------------------------------------------
    private func topNavigationBar(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            // ZONE 1: BRAND IDENTITY & HARDWARE STATUS
            HStack(spacing: 8) {
                // Neon Glowing BITCHMANAGER Header & Mascot
                HStack(spacing: 8) {
                    Image("BitchBoyBadgeIcon")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .shadow(color: engine.currentTheme.accentPrimary.opacity(isHoveringTitleLogo ? 0.95 : 0.65), radius: isHoveringTitleLogo ? 9 : 5, x: 0, y: 0)
                        .shadow(color: engine.currentTheme.accentPrimary.opacity(isHoveringTitleLogo ? 0.65 : 0.35), radius: isHoveringTitleLogo ? 16 : 10, x: 0, y: 0)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("BITCHMANAGER")
                            .font(.system(size: 19, weight: .heavy, design: .default))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        .white,
                                        isHoveringTitleLogo ? .white : engine.currentTheme.accentPrimary.opacity(0.96)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .tracking(1.2)
                            .shadow(color: engine.currentTheme.accentPrimary.opacity(0.85), radius: isHoveringTitleLogo ? 6 : 3)

                        Text("BLOCK HARDWARE // PROTOCOL ENGINE")
                            .font(.system(size: 11, weight: .bold, design: .default))
                            .foregroundColor(engine.currentTheme.headerText.opacity(0.85))
                            .tracking(0.8)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .onHover { isHoveringTitleLogo = $0 }

                // Hardware Status Pill (Strict BitchBoy USB / MIDI)
                Menu {
                    Section("BitchBoy Hardware Status") {
                        Button(action: { engine.scanForBitchBoy() }) {
                            Label("Rescan for BitchBoy Hardware Now", systemImage: "arrow.clockwise")
                        }
                    }
                    Section("On-Connect Notification FX") {
                        Button(action: { engine.toggleConnectEffectEnabled() }) {
                            Label(
                                engine.connectEffectEnabled ? "On-Connect FX: ENABLED" : "On-Connect FX: DISABLED",
                                systemImage: engine.connectEffectEnabled ? "checkmark.circle.fill" : "circle"
                            )
                        }
                        ForEach(engine.customEffects) { fx in
                            Button(action: { engine.setAsOnConnectFX(fx) }) {
                                Label(
                                    fx.name == engine.connectCustomFXName ? "★ \(fx.name) (Active Connect FX)" : "Set '\(fx.name)' as Connect FX",
                                    systemImage: fx.name == engine.connectCustomFXName ? "bolt.fill" : "sparkles"
                                )
                            }
                        }
                        Divider()
                        Button(action: { engine.triggerBitchBoyConnectedNotificationFX(isManualTest: true) }) {
                            Label("Preview On-Connect FX Now", systemImage: "play.fill")
                        }
                    }
                    Section("BitchManager Updates & GitHub Release") {
                        Text("Installed Version: v\(engine.currentAppVersion)")
                        if let rel = engine.latestRelease {
                            Text("Latest on GitHub: \(rel.tagName)")
                        }
                        Button(action: { engine.checkForUpdates(showModalIfCurrent: true) }) {
                            Label(engine.isCheckingForUpdates ? "Checking GitHub..." : "Check for Updates on GitHub...", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(engine.isCheckingForUpdates)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(engine.isConnected ? Color(red: 0.2, green: 0.95, blue: 0.45) : Color(red: 0.98, green: 0.25, blue: 0.25))
                            .frame(width: 9, height: 9)
                            .shadow(color: engine.isConnected ? Color.green : Color.red, radius: 4)

                        Text(engine.isConnected ? "ONLINE" : "OFFLINE")
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.isConnected ? Color(red: 0.2, green: 0.95, blue: 0.45) : Color(red: 0.98, green: 0.35, blue: 0.35))

                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(white: 0.7))
                    }
                    .frame(height: 37)
                    .padding(.horizontal, 12)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(engine.isConnected ? Color.green.opacity(0.4) : Color.red.opacity(0.4), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .hoverGrow(1.05)

                // Update Available Pill
                if engine.updateAvailable, let rel = engine.latestRelease {
                    Button(action: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                            engine.showUpdateModal = true
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .bold))
                            Text("UPDATE \(rel.tagName)")
                                .font(.system(size: 11, weight: .bold, design: .default))
                        }
                        .frame(height: 37)
                        .padding(.horizontal, 11)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.98, green: 0.72, blue: 0.22), Color(red: 0.95, green: 0.42, blue: 0.15)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .shadow(color: Color.orange.opacity(0.7), radius: 6)
                    }
                    .buttonStyle(.plain)
                    .hoverGrow(1.05)
                }

                // Quick Hardware MIDI Send Toggle (Prevents keybind conflicts!)
                Button(action: {
                    engine.toggleMasterHardwareMIDISend()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: engine.hardwareMIDISendEnabled ? "cable.connector" : "cable.connector.slash")
                            .font(.system(size: 11.5, weight: .bold))
                        Text(engine.hardwareMIDISendEnabled ? "HW MIDI: ON" : "HW MIDI: MUTED")
                            .font(.system(size: 11.5, weight: .bold, design: .default))
                    }
                    .frame(height: 37)
                    .padding(.horizontal, 10)
                    .background(engine.hardwareMIDISendEnabled ? Color(red: 0.12, green: 0.32, blue: 0.22) : Color(red: 0.38, green: 0.12, blue: 0.14))
                    .foregroundColor(engine.hardwareMIDISendEnabled ? Color(red: 0.32, green: 0.98, blue: 0.62) : Color(red: 0.98, green: 0.42, blue: 0.42))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(engine.hardwareMIDISendEnabled ? Color(red: 0.32, green: 0.98, blue: 0.62).opacity(0.4) : Color(red: 0.98, green: 0.42, blue: 0.42).opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .hoverGrow(1.05)
                .help("Toggle Master Hardware MIDI Output — Mute to prevent keybind confusion")
            }

            Spacer(minLength: 4)

            // ZONE 2: STUDIO WORKSPACE, TERMINAL, PRESETS & FX
            HStack(spacing: 6) {
                // Undo & Redo History Controls
                HStack(spacing: 2) {
                    Button(action: { engine.undo() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11.5, weight: .bold))
                            if engine.undoStepsCount > 0 {
                                Text("\(engine.undoStepsCount)")
                                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            }
                        }
                        .frame(height: 37)
                        .padding(.horizontal, 9)
                        .background(Color.white.opacity(engine.canUndo ? 0.08 : 0.03))
                        .foregroundColor(engine.canUndo ? engine.currentTheme.accentPrimary : Color.white.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(engine.canUndo ? engine.currentTheme.accentPrimary.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!engine.canUndo)
                    .hoverGrow(1.05)
                    .help("Undo last change (⌘Z)\(engine.lastUndoActionName.isEmpty ? "" : " — " + engine.lastUndoActionName)")

                    Button(action: { engine.redo() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.system(size: 11.5, weight: .bold))
                            if engine.redoStepsCount > 0 {
                                Text("\(engine.redoStepsCount)")
                                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            }
                        }
                        .frame(height: 37)
                        .padding(.horizontal, 9)
                        .background(Color.white.opacity(engine.canRedo ? 0.08 : 0.03))
                        .foregroundColor(engine.canRedo ? engine.currentTheme.accentPrimary : Color.white.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(engine.canRedo ? engine.currentTheme.accentPrimary.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!engine.canRedo)
                    .hoverGrow(1.05)
                    .help("Redo last change (⇧⌘Z)\(engine.lastRedoActionName.isEmpty ? "" : " — " + engine.lastRedoActionName)")
                }

                // Copy & Paste Quick Action Pill
                HStack(spacing: 2) {
                    Button(action: { engine.copyControl(index: engine.selectedIndex) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11, weight: .bold))
                            Text("COPY")
                                .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                        }
                        .frame(height: 37)
                        .padding(.horizontal, 8)
                        .background(Color.white.opacity(0.08))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .hoverGrow(1.05)
                    .help("Copy selected control configuration (⌘C)")

                    Button(action: { engine.pasteControlToSelected() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.badge.arrow.up")
                                .font(.system(size: 11, weight: .bold))
                            Text(engine.selectedIndices.count > 1 ? "PASTE (\(engine.selectedIndices.count))" : "PASTE")
                                .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                        }
                        .frame(height: 37)
                        .padding(.horizontal, 8)
                        .background(engine.hasCopiedConfig ? engine.currentTheme.accentPrimary.opacity(0.25) : Color.white.opacity(0.04))
                        .foregroundColor(engine.hasCopiedConfig ? engine.currentTheme.accentPrimary : Color.white.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(engine.hasCopiedConfig ? engine.currentTheme.accentPrimary.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!engine.hasCopiedConfig)
                    .hoverGrow(1.05)
                    .help("Paste configuration to selected control(s) (⌘V)")
                }

                // 120 FPS ProMotion Quality Switcher
                Menu {
                    Section("Display Engine Frame Rate") {
                        Button(action: { engine.setTargetFPS(120) }) {
                            HStack {
                                Text("120 FPS // ProMotion Ultra")
                                if engine.targetFPS == 120 {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Button(action: { engine.setTargetFPS(60) }) {
                            HStack {
                                Text("60 FPS // Standard (Power Saver)")
                                if engine.targetFPS == 60 {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Section("Engine Telemetry") {
                        Text("Active Engine Rate: \(String(format: "%.1f", engine.measuredFPS)) FPS")
                        Text("Frame Interval: \(String(format: "%.2f", engine.frameLatencyMs)) ms")
                        Text("Hardware MIDI Bus: 60Hz Throttled & Protected")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(engine.targetFPS == 120 ? Color(red: 0.2, green: 0.95, blue: 0.5) : Color.cyan)
                            .frame(width: 7, height: 7)
                            .shadow(color: engine.targetFPS == 120 ? Color.green : Color.cyan, radius: 3)
                        Text("\(engine.targetFPS) FPS")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.targetFPS == 120 ? Color(red: 0.2, green: 0.95, blue: 0.5) : Color.cyan)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(Color(white: 0.6))
                    }
                    .frame(height: 37)
                    .padding(.horizontal, 9)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(engine.targetFPS == 120 ? Color.green.opacity(0.35) : Color.cyan.opacity(0.35), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .hoverGrow(1.05)
                .help("Display Engine Quality: 120 FPS ProMotion / 60 FPS")

                // Preset Slot Quick Switcher
                Menu {
                    ForEach(0..<engine.slots.count, id: \.self) { idx in
                        Button(action: {
                            engine.selectSlot(idx)
                            activeMemoryBank = idx / 4
                        }) {
                            HStack {
                                Text(engine.slots[idx].name)
                                if engine.activeSlot == idx {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Divider()
                    Button(action: {
                        engine.saveCurrentSlot()
                        engine.log("💾 Presets saved to internal memory.")
                    }) {
                        Label("Save Slot to Memory", systemImage: "square.and.arrow.down")
                    }
                    Button(action: {
                        engine.cloneCurrentSlot()
                    }) {
                        Label("Clone to Next Slot", systemImage: "doc.on.doc")
                    }
                    Button(action: {
                        _ = engine.exportPresetToJSON()
                    }) {
                        Label("Export Slot JSON...", systemImage: "square.and.arrow.up")
                    }
                    Button(action: {
                        engine.importPresetFromClipboard()
                    }) {
                        Label("Import Slot JSON...", systemImage: "square.and.arrow.down.on.square")
                    }
                    Divider()
                    Button(action: {
                        engine.blackoutPanic()
                    }) {
                        Label("Emergency Blackout (All Off)", systemImage: "bolt.slash.fill")
                    }
                } label: {
                    let slotLetters = ["SLOT A", "SLOT B", "SLOT C", "SLOT D", "SLOT E", "SLOT F", "SLOT G", "SLOT H"]
                    HStack(spacing: 4) {
                        Image(systemName: engine.slots.indices.contains(engine.activeSlot) ? engine.slots[engine.activeSlot].iconName : "folder.fill")
                            .font(.system(size: 13.5, weight: .bold))
                        Text(slotLetters[engine.activeSlot % slotLetters.count])
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .frame(height: 37)
                    .padding(.horizontal, 11)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(engine.currentTheme.accentPrimary.opacity(0.35), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .hoverGrow(1.05)

                // Modules Manager & Layout Presets
                HStack(spacing: 2) {
                    Button(action: { engine.toggleRearrangeModulesMode() }) {
                        HStack(spacing: 4) {
                            Image(systemName: engine.isRearrangingModules ? "checkmark.circle.fill" : "square.grid.2x2.fill")
                                .font(.system(size: 12.5, weight: .bold))
                            Text(engine.isRearrangingModules ? "DONE (LOCK)" : "MODULES")
                                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        }
                        .frame(height: 37)
                        .padding(.horizontal, 12)
                        .background(engine.isRearrangingModules ? Color(red: 0.96, green: 0.76, blue: 0.18) : Color.white.opacity(0.08))
                        .foregroundColor(engine.isRearrangingModules ? .black : engine.currentTheme.accentPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(engine.isRearrangingModules ? Color.white : engine.currentTheme.accentPrimary.opacity(0.35), lineWidth: 1))
                        .shadow(color: engine.isRearrangingModules ? Color(red: 0.96, green: 0.76, blue: 0.18).opacity(0.4) : .clear, radius: 4)
                    }
                    .buttonStyle(.plain)
                    .hoverGrow(1.05)
                    .help("Toggle Rearrange & Dynamic Resizing Mode")

                    Menu {
                        Button(action: { engine.toggleRearrangeModulesMode() }) {
                            Label(engine.isRearrangingModules ? "Lock Layout (Exit Rearrange Mode)" : "Rearrange Mode (Drag or Move into Slots)", systemImage: engine.isRearrangingModules ? "lock.fill" : "hand.draw.fill")
                        }
                        Button(action: { engine.dockAllModules() }) {
                            Label("Dock All Floating Windows Back to Console", systemImage: "macwindow.and.cursorarrow")
                        }
                        Divider()
                        Section("LAYOUT PRESETS") {
                            Button(action: { engine.resetModuleLayout() }) {
                                Label("Reset All Modules to Default Positions", systemImage: "arrow.counterclockwise")
                            }
                            Button(action: {
                                for m in StudioModuleID.allCases {
                                    engine.setModuleHeight(m, height: 210, save: false)
                                }
                                engine.saveModuleSizes()
                            }) {
                                Label("Compact All Modules (210px)", systemImage: "arrow.down.forward.and.arrow.up.backward")
                            }
                            Button(action: {
                                for m in StudioModuleID.allCases {
                                    engine.setModuleHeight(m, height: 380, save: false)
                                }
                                engine.saveModuleSizes()
                            }) {
                                Label("Standard Size All Modules (380px)", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            Button(action: {
                                for m in StudioModuleID.allCases {
                                    engine.setModuleHeight(m, height: 490, save: false)
                                }
                                engine.saveModuleSizes()
                            }) {
                                Label("Expanded Size All Modules (490px)", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9.5, weight: .bold))
                            .frame(width: 20, height: 37)
                            .background(Color.white.opacity(0.08))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .menuStyle(.borderlessButton)
                    .hoverGrow(1.05)
                }

                // Quick Terminal Button
                Button(action: {
                    if engine.spotlightModule == .terminal {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                            engine.spotlightModule = nil
                        }
                    } else if engine.detachedModules.contains(.terminal) {
                        engine.toggleSpotlightModule(.terminal)
                    } else {
                        engine.toggleSpotlightModule(.terminal)
                    }
                    SoundEffect.keyTap.play(with: engine.soundPack)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "apple.terminal.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("TERMINAL")
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        Circle()
                            .fill(engine.protocolEvents.isEmpty ? Color.gray : Color.green)
                            .frame(width: 6.5, height: 6.5)
                    }
                    .frame(height: 37)
                    .padding(.horizontal, 11)
                    .background(engine.spotlightModule == .terminal ? Color.cyan.opacity(0.25) : Color.white.opacity(0.08))
                    .foregroundColor(engine.spotlightModule == .terminal ? Color.cyan : Color(white: 0.88))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(engine.spotlightModule == .terminal ? Color.cyan : Color.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .hoverGrow(1.05)
                .help("Toggle Protocol Terminal & Packet Monitor")

                // LED Cycle / Wave Refresh
                Button(action: {
                    engine.runRainbowWaveRefresh()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11.5, weight: .bold))
                        Text("LED CYCLE")
                            .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                    }
                    .frame(height: 37)
                    .padding(.horizontal, 12)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.40, green: 0.22, blue: 0.70), Color(red: 0.18, green: 0.58, blue: 0.72)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .hoverGrow(1.05)
                .help("Trigger Full Hardware LED Calibration Cycle")
                .hoverGrow(1.05)
                .disabled(engine.isRainbowRunning)

                // FX Light Show Menu & Stop Button
                HStack(spacing: 2) {
                    Menu {
                        ForEach(LEDFXMode.allCases) { mode in
                            Button(action: {
                                engine.applyFXMode(mode)
                            }) {
                                HStack {
                                    Image(systemName: mode.icon)
                                    Text(mode.rawValue)
                                    if engine.currentFXMode == mode {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                        Divider()
                        Text("★ USER CUSTOM LIGHT SHOWS")
                        ForEach(engine.customEffects) { cfx in
                            Button(action: {
                                engine.playCustomEffect(cfx)
                            }) {
                                HStack {
                                    Image(systemName: cfx.isProcedural ? "waveform.path.ecg" : "film.stack")
                                    Text("★ \(cfx.name)")
                                    if engine.isPlayingCustomFX && engine.activeCustomFXName == cfx.name {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("⏹ STOP FX (RESTORE PRESET)") {
                            engine.stopCustomEffect()
                            engine.applyFXMode(.staticFX)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: engine.isPlayingCustomFX ? "wand.and.stars" : (engine.currentFXMode == .staticFX ? "sparkles" : engine.currentFXMode.icon))
                                .font(.system(size: 12, weight: .bold))
                            Text(engine.isPlayingCustomFX ? "FX: \(engine.activeCustomFXName)" : "FX: \(engine.currentFXMode.rawValue)")
                                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9.5, weight: .bold))
                        }
                        .frame(height: 37)
                        .padding(.horizontal, 11)
                        .background((engine.currentFXMode == .staticFX && !engine.isPlayingCustomFX) ? Color(red: 0.08, green: 0.25, blue: 0.24) : Color(red: 0.92, green: 0.45, blue: 0.15).opacity(0.88))
                        .foregroundColor((engine.currentFXMode == .staticFX && !engine.isPlayingCustomFX) ? Color(red: 0.22, green: 0.96, blue: 0.76) : .white)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(red: 0.22, green: 0.96, blue: 0.76).opacity(0.5), lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .hoverGrow(1.05)

                    if engine.currentFXMode != .staticFX || engine.isPlayingCustomFX {
                        Button(action: {
                            engine.stopCustomEffect()
                            engine.applyFXMode(.staticFX)
                        }) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 7.5, weight: .heavy))
                                .frame(width: 30, height: 37)
                                .background(Color.red.opacity(0.85))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .hoverGrow(1.05)
                        .help("Stop active FX and restore preset LEDs")
                    }
                }
            }

            Spacer(minLength: 4)

            // ZONE 3: VIEW, AESTHETICS, WINDOW CONTROL & SIGNATURE
            HStack(spacing: 6) {
                // UI Zoom / Scale segmented control
                HStack(spacing: 1) {
                    Button(action: { engine.zoomOutUI() }) {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 34, height: 37)
                            .background(Color.white.opacity(0.08))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zoom Out Console")

                    Menu {
                        Button(action: { engine.enableAutoFitWindow() }) {
                            HStack {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                Text("AUTO-FIT TO WINDOW")
                                if engine.autoFitWindow {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Divider()
                        ForEach([15, 25, 35, 50, 65, 75, 85, 100, 115, 125, 140, 160, 180, 200], id: \.self) { pct in
                            Button(action: { engine.setManualZoom(CGFloat(pct) / 100.0) }) {
                                HStack {
                                    Text("ZOOM \(pct)%")
                                    if !engine.autoFitWindow && Int(round(engine.uiScale * 100)) == pct {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        let displayPct = Int(round(engine.lastComputedFitScale * 100))
                        Text("\(displayPct)%")
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                            .frame(height: 37)
                            .padding(.horizontal, 12)
                            .background(engine.autoFitWindow ? engine.currentTheme.accentPrimary.opacity(0.22) : Color.white.opacity(0.08))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                    }
                    .menuStyle(.borderlessButton)

                    Button(action: { engine.zoomInUI() }) {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 34, height: 37)
                            .background(Color.white.opacity(0.08))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zoom In Console")
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.18), lineWidth: 1))

                // Themes & Sounds Combined Menu
                Menu {
                    Section("CYBER CHASSIS THEMES") {
                        ForEach(ChassisTheme.allCases.filter { $0 != .customUser }) { th in
                            Button(action: {
                                engine.currentTheme = th
                                UserDefaults.standard.set(th.rawValue, forKey: "BitchBoy_ChassisTheme_v2")
                                if th == .prismRainbow {
                                    engine.runRainbowWaveRefresh()
                                }
                                SoundEffect.presetSwitch.play(with: engine.soundPack)
                            }) {
                                HStack {
                                    Text(th.rawValue)
                                    if engine.currentTheme == th {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                        ForEach(engine.customThemes) { customTh in
                            Button(action: { engine.applyCustomTheme(customTh) }) {
                                HStack {
                                    Text("★ \(customTh.name)")
                                    if engine.currentTheme == .customUser && engine.activeCustomTheme.id == customTh.id {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                        Button(action: {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                                engine.spotlightModule = nil
                                engine.showCustomSoundStudio = false
                                engine.showCustomThemeStudio = true
                            }
                        }) {
                            Label("🎨 Custom Theme Studio...", systemImage: "paintpalette.fill")
                        }
                    }

                    Section("AUDIO FEEDBACK SOUND PACKS") {
                        ForEach(SoundPack.allCases) { pack in
                            Button(action: { engine.setSoundPack(pack) }) {
                                HStack {
                                    Text(pack.rawValue)
                                    if engine.soundPack == pack {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                        Button(action: {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                                engine.spotlightModule = nil
                                engine.showCustomSoundStudio = true
                            }
                        }) {
                            Label("🎙️ Manage Custom Sounds...", systemImage: "waveform.badge.plus")
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("🎨")
                        Text(engine.currentTheme == .customUser ? engine.activeCustomTheme.name : engine.currentTheme.rawValue)
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .frame(height: 37)
                    .padding(.horizontal, 11)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.18), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .hoverGrow(1.05)

                // Pop Out & Floating Modules Menu
                Menu {
                    Section("HARDWARE MODULES") {
                        Button(action: { engine.popOutModuleToWindow(.keyGrid8x4) }) {
                            HStack {
                                Label("8x4 Key Grid (32 Keys)", systemImage: "square.grid.4x3.fill")
                                if engine.detachedModules.contains(.keyGrid8x4) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Button(action: { engine.popOutModuleToWindow(.keyStrip1x8) }) {
                            HStack {
                                Label("1x8 Key Strip (8 Keys)", systemImage: "rectangle.split.3x1.fill")
                                if engine.detachedModules.contains(.keyStrip1x8) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Button(action: { engine.popOutModuleToWindow(.keypad3x3) }) {
                            HStack {
                                Label("3x3 Keypad & Mascot", systemImage: "circle.grid.3x3.fill")
                                if engine.detachedModules.contains(.keypad3x3) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Button(action: { engine.popOutModuleToWindow(.verticalFaders) }) {
                            HStack {
                                Label("8 Vertical Faders (CC 0-7)", systemImage: "slider.vertical.3")
                                if engine.detachedModules.contains(.verticalFaders) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Button(action: { engine.popOutModuleToWindow(.horizontalFaders) }) {
                            HStack {
                                Label("4 Horizontal Faders (CC 8-11)", systemImage: "slider.horizontal.below.rectangle")
                                if engine.detachedModules.contains(.horizontalFaders) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Button(action: { engine.popOutModuleToWindow(.rotaryKnobs) }) {
                            HStack {
                                Label("2x4 Rotary Knobs (CC 20-27)", systemImage: "dial.low.fill")
                                if engine.detachedModules.contains(.rotaryKnobs) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Button(action: { engine.popOutModuleToWindow(.colorPickerHUD) }) {
                            HStack {
                                Label("Color Picker // LED Inspector", systemImage: "paintpalette.fill")
                                if engine.detachedModules.contains(.colorPickerHUD) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }

                    Section("EXPANSION MODULES") {
                        Button(action: { engine.popOutModuleToWindow(.terminal) }) {
                            HStack {
                                Label("Protocol Terminal", systemImage: "apple.terminal.fill")
                                if engine.detachedModules.contains(.terminal) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Button(action: { engine.popOutModuleToWindow(.showControl) }) {
                            HStack {
                                Label("Show Control // OSC Studio", systemImage: "dot.radiowaves.left.and.right")
                                if engine.detachedModules.contains(.showControl) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Button(action: { engine.popOutModuleToWindow(.midiRouter) }) {
                            HStack {
                                Label("MIDI Router // Out", systemImage: "point.3.connected.trianglepath.dotted")
                                if engine.detachedModules.contains(.midiRouter) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Button(action: { engine.popOutModuleToWindow(.customFXStudio) }) {
                            HStack {
                                Label("Custom FX Studio", systemImage: "wand.and.stars")
                                if engine.detachedModules.contains(.customFXStudio) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Button(action: { engine.popOutModuleToWindow(.reactiveKeyFX) }) {
                            HStack {
                                Label("Reactive Key FX", systemImage: "waveform.circle.fill")
                                if engine.detachedModules.contains(.reactiveKeyFX) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Button(action: { engine.popOutModuleToWindow(.memorySlots) }) {
                            HStack {
                                Label("Memory Slots Bank", systemImage: "memorychip.fill")
                                if engine.detachedModules.contains(.memorySlots) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Button(action: { engine.popOutModuleToWindow(.hardwareMIDIFilter) }) {
                            HStack {
                                Label("Hardware MIDI & Mute", systemImage: "switch.2")
                                if engine.detachedModules.contains(.hardwareMIDIFilter) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }

                    Divider()

                    Button(action: { engine.dockAllModules() }) {
                        Label("Dock All Floating Windows", systemImage: "arrow.down.left.square.fill")
                    }
                    Button(action: { engine.toggleRearrangeModulesMode() }) {
                        Label(engine.isRearrangingModules ? "Done Rearranging" : "Rearrange Rack & Wings...", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.system(size: 11, weight: .bold))
                        Text("MODULES")
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        if !engine.detachedModules.isEmpty {
                            Text("\(engine.detachedModules.count)")
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1)
                                .background(engine.currentTheme.accentPrimary)
                                .foregroundColor(.black)
                                .clipShape(Capsule())
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                    }
                    .frame(height: 37)
                    .padding(.horizontal, 10)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.18), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .hoverGrow(1.05)
                .help("Pop out any control into its own window or dock back")

                // Window Always-On-Top Pin Button
                Button(action: { engine.toggleWindowAlwaysOnTop() }) {
                    Image(systemName: engine.isWindowAlwaysOnTop ? "pin.fill" : "pin")
                        .font(.system(size: 13, weight: .bold))
                        .rotationEffect(.degrees(engine.isWindowAlwaysOnTop ? 0 : 45))
                        .frame(width: 37, height: 37)
                        .background(engine.isWindowAlwaysOnTop ? engine.currentTheme.accentPrimary : Color.white.opacity(0.08))
                        .foregroundColor(engine.isWindowAlwaysOnTop ? .black : engine.currentTheme.accentPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(engine.isWindowAlwaysOnTop ? Color.white.opacity(0.6) : Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: engine.isWindowAlwaysOnTop ? engine.currentTheme.accentPrimary.opacity(0.6) : .clear, radius: 6)
                }
                .buttonStyle(.plain)
                .hoverGrow(1.05)
                .help("Toggle Window Always On Top")
                .accessibilityLabel(engine.isWindowAlwaysOnTop ? "Unpin window from floating on top" : "Keep window always on top")

                // Hardware Designer & Studio Signature Badge (opens the creator card)
                Button(action: {
                    showCreatorCard = true
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                        Text("TAYLOR FOSSEN")
                            .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                            .foregroundColor(isHoveringLoveBadge ? .white : Color(white: 0.85))
                    }
                    .frame(height: 37)
                    .padding(.horizontal, 12)
                    .background(
                        Capsule()
                            .fill(isHoveringLoveBadge ? engine.currentTheme.accentPrimary.opacity(0.25) : Color.black.opacity(0.48))
                    )
                    .overlay(
                        Capsule()
                            .stroke(isHoveringLoveBadge ? engine.currentTheme.accentPrimary : Color.white.opacity(0.18), lineWidth: 1.0)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .shadow(color: isHoveringLoveBadge ? engine.currentTheme.accentPrimary.opacity(0.5) : Color.clear, radius: 8)
                .scaleEffect(isHoveringLoveBadge ? 1.03 : 1.0)
                .animation(.easeInOut(duration: 0.18), value: isHoveringLoveBadge)
                .onHover { isHoveringLoveBadge = $0 }
                .help("BitchBoy Hardware & DSP Architecture Designed by Taylor Fossen")
                .accessibilityLabel("Made by Taylor Fossen")
                .accessibilityHint("Opens the creator card")
            }

        }
        .frame(width: width)
    }

    // ------------------------------------------------------------------------
    // MAIN HARDWARE FACEPLATE (THE AUTHENTIC CONSOLE LAYOUT)
    // ------------------------------------------------------------------------
    private func mainHardwareFaceplate(effLeftW: CGFloat, effRightW: CGFloat, chassisWidth: CGFloat) -> some View {
        ZStack(alignment: .top) {
            // Chassis Surface
            RoundedRectangle(cornerRadius: 20)
                .fill(engine.currentTheme.pcbBackground)

            // Metallic Bezel
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    engine.currentTheme.isRainbow
                        ? AnyShapeStyle(engine.currentTheme.rainbowGradient)
                        : AnyShapeStyle(LinearGradient(
                            colors: engine.currentTheme.outerBezelColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )),
                    lineWidth: 5.5
                )

            // Metallic Screws in Bezel Corners
            VStack {
                HStack {
                    ScrewRivetView(size: 12)
                    Spacer()
                    ScrewRivetView(size: 12)
                }
                Spacer()
                HStack {
                    ScrewRivetView(size: 12)
                    Spacer()
                    ScrewRivetView(size: 12)
                }
            }
            .padding(8)

            // FULL-CHASSIS HARDWARE CONSOLE: LEFT WING + CENTER BITCHBOY MATRIX + RIGHT WING
            HStack(alignment: .top, spacing: 0) {
                // LEFT WING (Modules placed in Left Wing)
                if engine.hasLeftWing {
                    HStack(alignment: .top, spacing: 10) {
                        ScrollView([.vertical], showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(engine.leftWingModules.filter { !$0.isHardwareModule }) { mod in
                                    dynamicModuleContainer(for: mod, in: .leftWing, customWidth: effLeftW)
                                }
                                if engine.isRearrangingModules {
                                    dropTargetCard(forZone: .leftWing)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(width: effLeftW)
                        .frame(height: engine.chassisContentHeight, alignment: .top)

                        WingHorizontalResizeDivider(width: $engine.leftWingWidth, isLeft: true)
                    }
                    .frame(width: effLeftW + 24, alignment: .leading)
                }

                // CENTER HARDWARE CONSOLE: 8x4 Grid + 1x8 Strip + 8 VFaders + 4 HFaders + Logo + HUD + Knobs + 3x3 Keypad + OPTIONAL BOTTOM RACK
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 0) {
                        // LEFT COLUMN: 8x4 Grid + 1x8 Strip + Spaced Down 8 Vertical Faders (Width: 486)
                        VStack(alignment: .leading, spacing: 0) {
                            section1KeyGrid8x4
                                .padding(.bottom, 8)
                            section2KeyStrip1x8
                                .padding(.bottom, 16)

                            // Console Demarcation Gutter (spaces the faders down!)
                            HStack(spacing: 6) {
                                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                                Text("MASTER MIXING TIER // 8 DUAL-RAIL FADERS")
                                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                                    .foregroundColor(Color.white.opacity(0.35))
                                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                            }
                            .padding(.horizontal, 4)
                            .padding(.bottom, 10)

                            section4VerticalFaders
                        }
                        .frame(width: 486)

                        Spacer().frame(width: 16)

                        // Middle Column: 4 Horizontal Faders + Glowing BitchBoy Logo + Center Inspector HUD (Width: 280)
                        VStack(alignment: .leading, spacing: 10) {
                            section5HorizontalFaders
                                .frame(width: 280)

                            // Glowing BitchBoy Mascot Logo
                            BitchBoyGlowingLogoView(auraColor: engine.currentTheme.accentPrimary) {
                                SoundEffect.mascotSqueak.play(with: engine.soundPack)
                                engine.log("✨ BITCHBOY LOGO ACTIVATED")
                            }
                            .frame(width: 280, height: 58, alignment: .center)

                            centerInspectorHUD
                                .frame(width: 280, height: 360)
                        }
                        .frame(width: 280)

                        Spacer().frame(width: 24)

                        // Far-Right Column: 2x4 Knobs + Official Mascot & 3x3 Keypad (Width: 226)
                        VStack(alignment: .center, spacing: 10) {
                            section6RotaryKnobs
                                .frame(width: 226)

                            section3KeypadAndMascot
                                .frame(width: 226)
                        }
                        .frame(width: 226)
                    }
                    .frame(width: engine.centerConsoleWidth, height: engine.centerDeckHeight)

                    // BOTTOM CONSOLE RACK (Expansion Bay for modules placed in bottom rack!)
                    if !engine.bottomRackModules.filter({ !$0.isHardwareModule }).isEmpty || engine.isRearrangingModules {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                Image(systemName: "rectangle.bottomthird.inset.filled")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(engine.currentTheme.accentPrimary)
                                Text("CONSOLE EXPANSION BAY // BOTTOM RACK")
                                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                    .foregroundColor(engine.currentTheme.headerText)
                                Spacer()
                            }
                            .padding(.horizontal, 4)

                            let nonHw = engine.bottomRackModules.filter { !$0.isHardwareModule }
                            let availableW = max(760, engine.centerConsoleWidth - 20)
                            let slotW = (availableW - 12) / 2

                            HStack(alignment: .top, spacing: 12) {
                                ForEach(nonHw) { mod in
                                    dynamicModuleContainer(for: mod, in: .bottomRack)
                                }
                                if engine.isRearrangingModules && nonHw.count < 2 {
                                    dropTargetCard(forZone: .bottomRack)
                                        .frame(width: nonHw.isEmpty ? availableW : slotW)
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 4)
                            .frame(maxWidth: availableW, alignment: .leading)
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    engine.currentTheme.isRainbow
                                        ? AnyShapeStyle(engine.currentTheme.rainbowGradient)
                                        : AnyShapeStyle(engine.currentTheme.sectionOutline.opacity(0.4)),
                                    lineWidth: engine.currentTheme.isRainbow ? 1.8 : 1
                                )
                        )
                        .clipped()
                        .onDrop(of: [.plainText], delegate: ZoneDropDelegate(targetZone: .bottomRack, engine: engine))
                    }
                }
                .frame(width: engine.centerConsoleWidth, height: engine.chassisContentHeight, alignment: .top)

                // RIGHT WING (Modules placed in Right Wing)
                if engine.hasRightWing {
                    HStack(alignment: .top, spacing: 10) {
                        WingHorizontalResizeDivider(width: $engine.rightWingWidth, isLeft: false)

                        ScrollView([.vertical], showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(engine.rightWingModules.filter { !$0.isHardwareModule }) { mod in
                                    dynamicModuleContainer(for: mod, in: .rightWing, customWidth: effRightW)
                                }
                                if engine.isRearrangingModules {
                                    dropTargetCard(forZone: .rightWing)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(width: effRightW)
                        .frame(height: engine.chassisContentHeight, alignment: .top)
                    }
                    .frame(width: effRightW + 24, alignment: .trailing)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .frame(width: chassisWidth, alignment: .leading)
        }
        .frame(width: chassisWidth, height: engine.chassisContentHeight + 44)
    }

    private var bottomRackEmptyShelf: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.bottomthird.inset.filled")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                Text("CONSOLE EXPANSION BAY // BOTTOM RACK READY")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)
                Spacer()
                Menu {
                    ForEach(StudioModuleID.expansionModules) { m in
                        if engine.currentZone(of: m) != .bottomRack {
                            Button("Dock \(m.rawValue) Here") {
                                engine.moveModuleToZone(m, zone: .bottomRack)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("DOCK MODULE HERE")
                    }
                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .menuStyle(.borderlessButton)
                .hoverGrow(1.06)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 6) {
                Image(systemName: "arrow.down.and.line.horizontal.and.arrow.up")
                    .font(.system(size: 14))
                    .foregroundColor(engine.currentTheme.accentPrimary.opacity(0.6))
                Text("BOTTOM RACK EXPANSION BAY")
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                Text("Drag any module here from wings, or use the menu above to dock a module in this space")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 14)
            .background(Color.black.opacity(0.28))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        LinearGradient(
                            colors: [engine.currentTheme.sectionOutline.opacity(0.6), engine.currentTheme.accentPrimary.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: 894, maxHeight: .infinity)
        .padding(8)
        .background(Color.black.opacity(0.32))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(engine.currentTheme.sectionOutline.opacity(0.4), lineWidth: 1))
        .onDrop(of: [.plainText], delegate: ZoneDropDelegate(targetZone: .bottomRack, engine: engine))
    }

    // ------------------------------------------------------------------------
    // DYNAMIC MODULAR SYSTEM: PLACEMENT ANYWHERE, RESIZING & SPOTLIGHT
    // ------------------------------------------------------------------------
    private func moduleContentView(for module: StudioModuleID, isSpotlight: Bool = false) -> AnyView {
        switch module {
        case .midiRouter:
            return AnyView(leftWingStudioPanel(isSpotlight: isSpotlight))
        case .memorySlots:
            return AnyView(leftWingMemorySlotsPanel(isSpotlight: isSpotlight))
        case .customFXStudio:
            return AnyView(rightWingStudioPanel(isSpotlight: isSpotlight))
        case .reactiveKeyFX:
            return AnyView(rightWingReactiveKeyFXPanel(isSpotlight: isSpotlight))
        case .showControl:
            return AnyView(showControlStudioPanel(isSpotlight: isSpotlight))
        case .terminal:
            return AnyView(protocolTerminalStudioPanel(isSpotlight: isSpotlight))
        case .keyGrid8x4:
            return AnyView(keyGridStudioPanel(isSpotlight: isSpotlight))
        case .keyStrip1x8:
            return AnyView(keyStripStudioPanel(isSpotlight: isSpotlight))
        case .verticalFaders:
            return AnyView(verticalFadersStudioPanel(isSpotlight: isSpotlight))
        case .horizontalFaders:
            return AnyView(horizontalFadersStudioPanel(isSpotlight: isSpotlight))
        case .rotaryKnobs:
            return AnyView(rotaryKnobsStudioPanel(isSpotlight: isSpotlight))
        case .keypad3x3:
            return AnyView(keypadStudioPanel(isSpotlight: isSpotlight))
        case .colorPickerHUD:
            return AnyView(colorPickerStudioPanel(isSpotlight: isSpotlight))
        case .hardwareMIDIFilter:
            return AnyView(hardwareMIDIFilterStudioPanel(isSpotlight: isSpotlight))
        }
    }

    private func moduleHeaderControls(for module: StudioModuleID) -> some View {
        HStack(spacing: 3) {
            // Dynamic Size Preset Quick-Cycle Button (Uniform 72x19 box in every module)
            Button(action: {
                engine.cycleModuleSizePreset(module)
            }) {
                HStack(spacing: 2.5) {
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 9.5, weight: .bold))
                    Text(engine.moduleSizePresetLabel(module))
                        .font(.system(size: 10, weight: .semibold, design: .default))
                        .lineLimit(1)
                }
                .foregroundColor(engine.currentTheme.accentPrimary)
                .frame(height: 22)
                .padding(.horizontal, 6)
                .background(engine.currentTheme.accentPrimary.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5)
                        .stroke(engine.currentTheme.accentPrimary.opacity(0.4), lineWidth: 0.8)
                )
                .clipShape(RoundedRectangle(cornerRadius: 3.5))
            }
            .buttonStyle(.plain)
            .hoverGrow(1.08)
            .help("Cycle Height: Compact (210) / Standard (340) / Expanded (480)")
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)

            // Width Preset Quick-Cycle Button (For Bottom Rack)
            if engine.currentZone(of: module) == .bottomRack {
                Button(action: {
                    engine.cycleModuleWidthPreset(module)
                }) {
                    HStack(spacing: 2.5) {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 9.5, weight: .bold))
                        Text(engine.moduleWidthPresetLabel(module))
                            .font(.system(size: 10, weight: .semibold, design: .default))
                            .lineLimit(1)
                    }
                    .foregroundColor(Color(red: 0.96, green: 0.76, blue: 0.18))
                    .frame(height: 22)
                    .padding(.horizontal, 6)
                    .background(Color(red: 0.96, green: 0.76, blue: 0.18).opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3.5)
                            .stroke(Color(red: 0.96, green: 0.76, blue: 0.18).opacity(0.4), lineWidth: 0.8)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
                }
                .buttonStyle(.plain)
                .hoverGrow(1.08)
                .help("Cycle Width in Rack: Compact / Half / Wide / Full Console")
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            }

            // Placement Menu Button (Move anywhere there is space!)
            Menu {
                Section("PLACEMENT ZONE") {
                    Button(action: { engine.moveModuleToZone(module, zone: .leftWing) }) {
                        Label("Left Wing", systemImage: "sidebar.left")
                    }
                    Button(action: { engine.moveModuleToZone(module, zone: .rightWing) }) {
                        Label("Right Wing", systemImage: "sidebar.right")
                    }
                    Button(action: { engine.moveModuleToZone(module, zone: .bottomRack) }) {
                        Label("Bottom Console Rack", systemImage: "rectangle.bottomthird.inset.filled")
                    }
                    Divider()
                    Button(action: { engine.popOutModuleToWindow(module) }) {
                        Label("Pop Out into Floating Window", systemImage: "macwindow.badge.plus")
                    }
                    Button(action: { engine.toggleSpotlightModule(module) }) {
                        Label("Center in Spotlight", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                Section("REORDER IN ZONE") {
                    Button(action: { engine.moveModuleWithinZone(module, direction: -1) }) {
                        Label("Move Up / Left", systemImage: "arrow.up")
                    }
                    Button(action: { engine.moveModuleWithinZone(module, direction: 1) }) {
                        Label("Move Down / Right", systemImage: "arrow.down")
                    }
                }
                Section("HEIGHT PRESETS") {
                    Button("Compact (210 px)") { engine.setModuleHeight(module, height: 210, save: true) }
                    Button("Standard (340 px)") { engine.setModuleHeight(module, height: 340, save: true) }
                    Button("Expanded (480 px)") { engine.setModuleHeight(module, height: 480, save: true) }
                    Button("Reset to Default") { engine.resetModuleHeight(module) }
                }
                if engine.currentZone(of: module) == .bottomRack {
                    Section("WIDTH PRESETS (BOTTOM RACK)") {
                        Button("Compact (320 px)") { engine.setModuleWidth(module, width: 320, save: true) }
                        Button("Half Rack (435 px)") { engine.setModuleWidth(module, width: 435, save: true) }
                        Button("Wide (620 px)") { engine.setModuleWidth(module, width: 620, save: true) }
                        Button("Full Console (894 px)") { engine.setModuleWidth(module, width: 894, save: true) }
                    }
                }
            } label: {
                Image(systemName: "square.split.bottomrightquarter")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(white: 0.90))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
            }
            .menuStyle(.borderlessButton)
            .hoverGrow(1.08)
            .help("Move or Resize Module")
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)

            // Center Spotlight / Blur Background Toggle
            Button(action: {
                engine.toggleSpotlightModule(module)
            }) {
                Image(systemName: engine.spotlightModule == module ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(engine.spotlightModule == module ? .black : engine.currentTheme.accentPrimary)
                    .frame(width: 22, height: 22)
                    .background(engine.spotlightModule == module ? engine.currentTheme.accentPrimary : Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
            }
            .buttonStyle(.plain)
            .hoverGrow(1.08)
            .help("Center Module on Screen with Blurred Background")
            .accessibilityLabel(engine.spotlightModule == module ? "Exit module spotlight" : "Center \(module.shortName) module in spotlight")
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)

            // Pop Out Into Standalone Floating Window
            if standaloneModule == nil {
                Button(action: {
                    engine.popOutModuleToWindow(module)
                }) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(white: 0.90))
                        .frame(width: 28, height: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4.5))
                }
                .buttonStyle(.plain)
                .hoverGrow(1.08)
                .help("Pop Out Module Into Its Own Window")
                .accessibilityLabel("Pop out \(module.shortName) module into standalone window")
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
    }

    private func dynamicModuleContainer(for mod: StudioModuleID, in zone: ModuleZone, customWidth: CGFloat? = nil) -> some View {
        let isDetached = engine.detachedModules.contains(mod)
        let targetHeight = engine.moduleCustomHeights[mod] ?? mod.defaultSlotHeight
        let cardWidth: CGFloat = {
            if let customWidth = customWidth {
                return customWidth
            }
            switch zone {
            case .leftWing: return max(380, engine.leftWingWidth)
            case .rightWing: return max(380, engine.rightWingWidth)
            case .bottomRack:
                let activeModules = engine.bottomRackModules.filter { !$0.isHardwareModule }
                let effectiveSlots = activeModules.count + (engine.isRearrangingModules && activeModules.count < 2 ? 1 : 0)
                let availableW = max(760, engine.centerConsoleWidth - 20)
                if effectiveSlots <= 1 {
                    return availableW
                } else {
                    let totalGaps = CGFloat(effectiveSlots - 1) * 12
                    return (availableW - totalGaps) / CGFloat(effectiveSlots)
                }
            case .floating: return max(380, engine.moduleCustomWidths[mod] ?? 435)
            }
        }()

        let cardBase = VStack(spacing: 0) {
            // If in Rearrange Mode, show the Quick Move / Zone Transfer pill bar above card
            if engine.isRearrangingModules {
                moduleRearrangeActionBar(for: mod, currentZone: zone)
                    .padding(.bottom, 3)
            }

            if isDetached {
                detachedModulePlaceholderCard(for: mod)
                    .frame(width: cardWidth)
            } else {
                VStack(spacing: 0) {
                    // Module Content (Internally scrollable so NOTHING ever cuts off!)
                    moduleContentView(for: mod)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipped()

                    // Interactive Bottom Drag-to-Resize Handle Bar
                    moduleResizeHandleBar(for: mod, currentHeight: targetHeight, zone: zone)
                }
                .frame(width: cardWidth)
                .frame(height: targetHeight)
                .background(Color(red: 0.10, green: 0.12, blue: 0.15).opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            engine.isRearrangingModules
                                ? AnyShapeStyle(Color(red: 0.96, green: 0.76, blue: 0.18))
                                : (engine.currentTheme.isRainbow
                                    ? AnyShapeStyle(engine.currentTheme.rainbowGradient)
                                    : AnyShapeStyle(LinearGradient(
                                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))),
                            style: StrokeStyle(lineWidth: engine.isRearrangingModules ? 2.0 : 1.0, dash: engine.isRearrangingModules ? [6, 4] : [])
                        )
                )
            }
        }
        .frame(width: cardWidth)
        .clipped()
        .contextMenu {
            moduleContextMenu(for: mod, zone: zone)
        }

        return Group {
            if engine.isRearrangingModules {
                cardBase
                    .onDrag {
                        engine.draggingModule = mod
                        return NSItemProvider(object: mod.rawValue as NSString)
                    }
                    .onDrop(of: [.plainText], delegate: ModuleSlotDropDelegate(targetModule: mod, engine: engine))
            } else {
                cardBase
            }
        }
    }

    struct WingHorizontalResizeDivider: View {
        @Binding var width: CGFloat
        let isLeft: Bool
        let minWidth: CGFloat = 350
        let maxWidth: CGFloat = 1200
        let defaultWidth: CGFloat = 380

        @State private var isHovered: Bool = false
        @State private var dragStartWidth: CGFloat = 0

        var body: some View {
            ZStack {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 14)

                Rectangle()
                    .fill(isHovered ? Color.cyan.opacity(0.9) : Color.white.opacity(0.12))
                    .frame(width: isHovered ? 2 : 1)

                VStack(spacing: 3) {
                    Circle().fill(isHovered ? Color.cyan : Color.white.opacity(0.35)).frame(width: 3, height: 3)
                    Capsule().fill(isHovered ? Color.cyan : Color.white.opacity(0.25)).frame(width: 3, height: 26)
                    Circle().fill(isHovered ? Color.cyan : Color.white.opacity(0.35)).frame(width: 3, height: 3)
                }
                .shadow(color: isHovered ? Color.cyan.opacity(0.8) : Color.clear, radius: 4)
            }
            .frame(width: 14)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { val in
                        if dragStartWidth == 0 {
                            dragStartWidth = width
                        }
                        let delta = isLeft ? val.translation.width : -val.translation.width
                        let target = max(minWidth, min(maxWidth, dragStartWidth + delta))
                        width = target
                    }
                    .onEnded { _ in
                        dragStartWidth = 0
                        UserDefaults.standard.set(Double(width), forKey: isLeft ? "BitchBoy_LeftWingWidth_v2" : "BitchBoy_RightWingWidth_v2")
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    width = defaultWidth
                }
                UserDefaults.standard.set(Double(defaultWidth), forKey: isLeft ? "BitchBoy_LeftWingWidth_v2" : "BitchBoy_RightWingWidth_v2")
            }
            .help("Grab and drag horizontally to resize wing smoothly. Double-click to reset width.")
        }
    }

    private func moduleResizeHandleBar(for mod: StudioModuleID, currentHeight: CGFloat, zone: ModuleZone) -> some View {
        HStack(spacing: 4) {
            Text("↕ RESIZE")
                .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                .foregroundColor(Color(white: 0.70))

            Spacer()

            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: 28, height: 3)

            Spacer()

            if zone == .bottomRack {
                Button(action: {
                    engine.cycleModuleWidthPreset(mod)
                }) {
                    Text("WIDTH: \(engine.moduleWidthPresetLabel(mod))")
                        .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color(red: 0.96, green: 0.76, blue: 0.18))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.white.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help("Cycle width preset in Bottom Rack (Compact / Half / Wide / Full)")
            }

            Text("\(Int(currentHeight))PX")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundColor(engine.currentTheme.accentPrimary.opacity(0.95))

            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(engine.currentTheme.accentPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.75))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { val in
                    if resizingModule != mod {
                        resizingModule = mod
                        dragInitialHeight = currentHeight
                    }
                    let newH = max(160, min(650, dragInitialHeight + val.translation.height))
                    engine.setModuleHeight(mod, height: newH, save: false)
                }
                .onEnded { val in
                    let newH = max(160, min(650, dragInitialHeight + val.translation.height))
                    engine.setModuleHeight(mod, height: newH, save: true)
                    resizingModule = nil
                }
        )
        .onTapGesture(count: 2) {
            engine.cycleModuleSizePreset(mod)
        }
        .help("Drag vertically to dynamically resize module. Double-click to cycle presets (Compact / Standard / Tall).")
    }

    private func moduleRearrangeActionBar(for mod: StudioModuleID, currentZone: ModuleZone) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "hand.draw.fill")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.22))
            Text("MOVE:")
                .font(.system(size: 9, weight: .bold, design: .default))
                .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.22))

            Spacer(minLength: 2)

            Button("⇦ LW") { engine.moveModuleToZone(mod, zone: .leftWing) }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .semibold, design: .default))
                .padding(.horizontal, 4.5)
                .padding(.vertical, 2)
                .background(currentZone == .leftWing ? Color(red: 0.96, green: 0.76, blue: 0.18) : Color.white.opacity(0.12))
                .foregroundColor(currentZone == .leftWing ? .black : .white)
                .clipShape(RoundedRectangle(cornerRadius: 3))

            Button("⇨ RW") { engine.moveModuleToZone(mod, zone: .rightWing) }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .semibold, design: .default))
                .padding(.horizontal, 4.5)
                .padding(.vertical, 2)
                .background(currentZone == .rightWing ? Color(red: 0.96, green: 0.76, blue: 0.18) : Color.white.opacity(0.12))
                .foregroundColor(currentZone == .rightWing ? .black : .white)
                .clipShape(RoundedRectangle(cornerRadius: 3))

            Button("⇩ RACK") { engine.moveModuleToZone(mod, zone: .bottomRack) }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .semibold, design: .default))
                .padding(.horizontal, 4.5)
                .padding(.vertical, 2)
                .background(currentZone == .bottomRack ? Color(red: 0.96, green: 0.76, blue: 0.18) : Color.white.opacity(0.12))
                .foregroundColor(currentZone == .bottomRack ? .black : .white)
                .clipShape(RoundedRectangle(cornerRadius: 3))

            Button(action: { engine.popOutModuleToWindow(mod) }) {
                Image(systemName: "macwindow.badge.plus")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(engine.currentTheme.accentPrimary.opacity(0.28))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
            }
            .buttonStyle(.plain)
            .hoverGrow(1.08)
            .accessibilityLabel("Pop out \(mod.shortName) module into standalone window")
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2.5)
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(red: 0.96, green: 0.76, blue: 0.18), lineWidth: 0.8))
    }

    private func dropTargetCard(forZone zone: ModuleZone) -> some View {
        Button(action: {
            if let dragged = engine.draggingModule {
                engine.moveModuleToZone(dragged, zone: zone)
            }
        }) {
            VStack(spacing: 4) {
                Image(systemName: "plus.circle.dashed")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color(red: 0.96, green: 0.76, blue: 0.18))
                Text("+ EXPANSION SLOT: \(zone.displayName)")
                    .font(.system(size: 10.5, weight: .bold, design: .default))
                    .foregroundColor(Color(red: 0.96, green: 0.76, blue: 0.18))
                Text("Drag module here or tap ⇦ LW / ⇨ RW / ⇩ RACK on any card")
                    .font(.system(size: 9, weight: .regular, design: .default))
                    .foregroundColor(Color.white.opacity(0.6))
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(Color(red: 0.96, green: 0.76, blue: 0.18).opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.4, dash: [6, 4]))
                    .foregroundColor(Color(red: 0.96, green: 0.76, blue: 0.18).opacity(0.75))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onDrop(of: [.plainText], delegate: ZoneDropDelegate(targetZone: zone, engine: engine))
    }

    private func detachedModulePlaceholderCard(for mod: StudioModuleID) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: mod.iconName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                Text(mod.rawValue)
                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)
                Spacer()
                Text("POPPED OUT")
                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(engine.currentTheme.accentPrimary.opacity(0.22))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            VStack(spacing: 6) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 20))
                    .foregroundColor(engine.currentTheme.accentPrimary.opacity(0.85))
                Text("ACTIVE IN FLOATING WINDOW")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)

                HStack(spacing: 6) {
                    Button(action: {
                        engine.popOutModuleToWindow(mod)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "macwindow")
                            Text("FOCUS WINDOW")
                        }
                        .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        engine.dockModuleBackFromWindow(mod)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.left.square.fill")
                            Text("DOCK BACK HERE")
                        }
                        .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(engine.currentTheme.accentPrimary)
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .background(Color.black.opacity(0.42))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .foregroundColor(engine.currentTheme.accentPrimary.opacity(0.65))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func moduleContextMenu(for mod: StudioModuleID, zone: ModuleZone) -> some View {
        Menu("Move Module To...") {
            Button("Left Wing") { engine.moveModuleToZone(mod, zone: .leftWing) }
            Button("Right Wing") { engine.moveModuleToZone(mod, zone: .rightWing) }
            Button("Bottom Console Rack") { engine.moveModuleToZone(mod, zone: .bottomRack) }
            Button("Floating Window") { engine.popOutModuleToWindow(mod) }
        }
        Menu("Module Height...") {
            Button("Compact (210 px)") { engine.setModuleHeight(mod, height: 210, save: true) }
            Button("Standard (340 px)") { engine.setModuleHeight(mod, height: 340, save: true) }
            Button("Tall (480 px)") { engine.setModuleHeight(mod, height: 480, save: true) }
            Button("Reset to Default") { engine.resetModuleHeight(mod) }
        }
        Divider()
        Button(action: { engine.toggleSpotlightModule(mod) }) {
            Label("Center Module on Screen (Blur Background)", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        Button(action: { engine.popOutModuleToWindow(mod) }) {
            Label("Open Module in Own Window", systemImage: "macwindow.badge.plus")
        }
        Divider()
        Button(action: { engine.toggleRearrangeModulesMode() }) {
            Label(engine.isRearrangingModules ? "Lock Module Layout" : "Rearrange Modules & Spaces", systemImage: "square.grid.2x2.fill")
        }
        Button(action: { engine.resetModuleLayout() }) {
            Label("Reset Module Positions to Default", systemImage: "arrow.counterclockwise")
        }
    }

    // ------------------------------------------------------------------------
    // CUSTOM SOUND STUDIO OVERLAY (UPLOAD USER AUDIO FILES FOR ANY EVENT)
    // ------------------------------------------------------------------------
    private var customSoundStudioOverlay: some View {
        let _ = engine.customSoundUpdateToken
        return ZStack {
            Color.black.opacity(0.58)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                        engine.showCustomSoundStudio = false
                    }
                }

            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(engine.currentTheme.accentPrimary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("CUSTOM SOUND STUDIO // UPLOAD YOUR OWN AUDIO")
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .foregroundColor(.white)
                        Text("Upload .WAV, .MP3, .AIFF, or .M4A sounds for any BitchBoy hardware or UI event")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(white: 0.68))
                    }

                    Spacer()

                    Button(action: {
                        engine.clearAllCustomSoundFiles()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("RESET ALL")
                        }
                        .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.22))
                        .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                            engine.showCustomSoundStudio = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                            Text("DONE")
                        }
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(engine.currentTheme.accentPrimary)
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }

                // Active Sound Pack Selector Row
                HStack(spacing: 6) {
                    Text("ACTIVE SOUND MODE:")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.headerText)

                    ForEach(SoundPack.allCases) { pack in
                        Button(action: {
                            engine.setSoundPack(pack)
                        }) {
                            Text(pack.rawValue)
                                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(engine.soundPack == pack ? engine.currentTheme.accentPrimary : Color.white.opacity(0.1))
                                .foregroundColor(engine.soundPack == pack ? .black : .white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // 6 Sound Event Slots
                VStack(spacing: 6) {
                    ForEach(SoundEffect.allCases) { sfx in
                        let uploadedName = CustomSoundBank.shared.fileName(for: sfx)
                        HStack(spacing: 10) {
                            Image(systemName: sfx.iconName)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(uploadedName != nil ? engine.currentTheme.accentPrimary : Color(white: 0.6))
                                .frame(width: 24, height: 24)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(sfx.displayName)
                                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                                    .foregroundColor(.white)
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(uploadedName != nil ? Color.green : Color.gray)
                                        .frame(width: 5, height: 5)
                                    Text(uploadedName != nil ? "CUSTOM FILE: \(uploadedName!)" : "Built-in Synth Default")
                                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                        .foregroundColor(uploadedName != nil ? Color(red: 0.35, green: 0.98, blue: 0.75) : Color(white: 0.55))
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            Button(action: {
                                sfx.play(with: uploadedName != nil ? .customUser : engine.soundPack)
                            }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "play.fill")
                                    Text("PREVIEW")
                                }
                                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.white.opacity(0.12))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                engine.uploadCustomSoundFile(for: sfx)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder.fill.badge.plus")
                                    Text(uploadedName != nil ? "CHANGE AUDIO..." : "UPLOAD AUDIO...")
                                }
                                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(engine.currentTheme.accentPrimary)
                                .foregroundColor(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)

                            if uploadedName != nil {
                                Button(action: {
                                    engine.clearCustomSoundFile(for: sfx)
                                }) {
                                    Image(systemName: "trash.fill")
                                        .font(.system(size: 8))
                                        .padding(5)
                                        .background(Color.red.opacity(0.25))
                                        .foregroundColor(Color(red: 1.0, green: 0.55, blue: 0.55))
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Delete custom sound for \(sfx.displayName)")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(uploadedName != nil ? engine.currentTheme.accentPrimary.opacity(0.12) : Color.black.opacity(0.48))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(uploadedName != nil ? engine.currentTheme.accentPrimary.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1)
                        )
                    }
                }
            }
            .padding(18)
            .frame(width: 560)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.03, green: 0.14, blue: 0.12).opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(engine.currentTheme.accentPrimary, lineWidth: 1.8)
            )
            .shadow(color: engine.currentTheme.accentPrimary.opacity(0.55), radius: 26, x: 0, y: 8)
            .shadow(color: Color.black.opacity(0.9), radius: 34, x: 0, y: 14)
        }
    }

    // ------------------------------------------------------------------------
    // CUSTOM THEME STUDIO OVERLAY (GLOW CYBER CHASSIS BUILDER)
    // ------------------------------------------------------------------------
    private var customThemeStudioOverlay: some View {
        ZStack {
            Color.black.opacity(0.62)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                        engine.showCustomThemeStudio = false
                    }
                }

            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(engine.currentTheme.accentPrimary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("CUSTOM THEME STUDIO // GLOW CYBER CHASSIS BUILDER")
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .foregroundColor(.white)
                        Text("Craft custom glowing PCB, bezel gradients, and neon silkscreen aesthetics")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(white: 0.68))
                    }

                    Spacer()

                    Button(action: {
                        engine.createNewCustomTheme()
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "plus.circle.fill")
                            Text("NEW THEME")
                        }
                        .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        engine.duplicateActiveCustomTheme()
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc.fill")
                            Text("DUPLICATE")
                        }
                        .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)

                    if engine.customThemes.count > 1 {
                        Button(action: {
                            engine.deleteActiveCustomTheme()
                        }) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 8.5))
                                .padding(5)
                                .background(Color.red.opacity(0.25))
                                .foregroundColor(Color(red: 1.0, green: 0.55, blue: 0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete active custom theme")
                    }

                    Button(action: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                            engine.showCustomThemeStudio = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                            Text("DONE")
                        }
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(engine.currentTheme.accentPrimary)
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }

                // Theme Name & Starter Presets Bar
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Text("THEME NAME:")
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)

                        TextField("Theme Name", text: Binding(
                            get: { engine.activeCustomTheme.name },
                            set: { engine.updateCustomThemeName($0) }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.6))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(engine.currentTheme.accentPrimary.opacity(0.4), lineWidth: 1))
                        .frame(width: 175)
                    }

                    Spacer()

                    Text("STARTER PRESETS:")
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))

                    HStack(spacing: 4) {
                        Button("NEO TOKYO") { engine.loadPresetToActiveTheme(.neoTokyo) }
                        Button("ACID OVERDRIVE") { engine.loadPresetToActiveTheme(.acidLime) }
                        Button("CYBER INFERNO") { engine.loadPresetToActiveTheme(.inferno) }
                        Button("VOID ICE") { engine.loadPresetToActiveTheme(.deepIce) }
                    }
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .buttonStyle(.plain)
                    .foregroundColor(engine.currentTheme.accentPrimary)
                }
                .padding(8)
                .background(Color.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Live Mini Hardware Preview
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIVE HARDWARE CHASSIS PREVIEW:")
                        .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.headerText)

                    ZStack {
                        // Outer bezel
                        RoundedRectangle(cornerRadius: 12)
                            .fill(
                                LinearGradient(
                                    colors: engine.activeCustomTheme.outerBezelColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(height: 70)
                            .shadow(color: engine.activeCustomTheme.accentPrimary.opacity(0.4), radius: 8)

                        // PCB
                        RoundedRectangle(cornerRadius: 8)
                            .fill(engine.activeCustomTheme.pcbBackground)
                            .padding(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(engine.activeCustomTheme.sectionOutline, lineWidth: 1.2)
                                    .padding(6)
                            )

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("BITCHBOY V1")
                                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                    .foregroundColor(engine.activeCustomTheme.accentPrimary)
                                    .shadow(color: engine.activeCustomTheme.accentPrimary.opacity(0.9), radius: 5)
                                Text("CUSTOM SILKSCREEN GLOW")
                                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(engine.activeCustomTheme.headerText)
                            }
                            .padding(.leading, 18)

                            Spacer()

                            // Mock LED Key Grid
                            HStack(spacing: 4) {
                                ForEach(0..<8, id: \.self) { i in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(i % 2 == 0 ? engine.activeCustomTheme.accentPrimary : Color(white: 0.18))
                                        .frame(width: 14, height: 14)
                                        .shadow(color: i % 2 == 0 ? engine.activeCustomTheme.accentPrimary.opacity(0.8) : .clear, radius: 4)
                                }
                            }
                            .padding(.trailing, 18)
                        }
                    }
                }

                // 6 Glow Color Pickers Grid
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        themeColorPickerCard(
                            title: "PCB INNER BACKPLANE",
                            subtitle: "Main circuit board surface",
                            hex: Binding(
                                get: { engine.activeCustomTheme.pcbHex },
                                set: { engine.activeCustomTheme.pcbHex = $0; engine.saveAndApplyActiveCustomTheme() }
                            )
                        )
                        themeColorPickerCard(
                            title: "BEZEL GRADIENT START",
                            subtitle: "Outer chassis metal rim",
                            hex: Binding(
                                get: { engine.activeCustomTheme.bezelStartHex },
                                set: { engine.activeCustomTheme.bezelStartHex = $0; engine.saveAndApplyActiveCustomTheme() }
                            )
                        )
                        themeColorPickerCard(
                            title: "BEZEL GRADIENT END",
                            subtitle: "Outer chassis bottom shadow",
                            hex: Binding(
                                get: { engine.activeCustomTheme.bezelEndHex },
                                set: { engine.activeCustomTheme.bezelEndHex = $0; engine.saveAndApplyActiveCustomTheme() }
                            )
                        )
                    }

                    HStack(spacing: 10) {
                        themeColorPickerCard(
                            title: "NEON ACCENT & GLOW",
                            subtitle: "Primary buttons, active status, badges",
                            hex: Binding(
                                get: { engine.activeCustomTheme.accentGlowHex },
                                set: { engine.activeCustomTheme.accentGlowHex = $0; engine.saveAndApplyActiveCustomTheme() }
                            )
                        )
                        themeColorPickerCard(
                            title: "SECTION OUTLINES",
                            subtitle: "Module frames & silkscreen dividers",
                            hex: Binding(
                                get: { engine.activeCustomTheme.outlineHex },
                                set: { engine.activeCustomTheme.outlineHex = $0; engine.saveAndApplyActiveCustomTheme() }
                            )
                        )
                        themeColorPickerCard(
                            title: "SILKSCREEN HEADERS",
                            subtitle: "Labels, legends & subheaders",
                            hex: Binding(
                                get: { engine.activeCustomTheme.headerTextHex },
                                set: { engine.activeCustomTheme.headerTextHex = $0; engine.saveAndApplyActiveCustomTheme() }
                            )
                        )
                    }
                }
            }
            .padding(18)
            .frame(width: 590)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.03, green: 0.14, blue: 0.12).opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(engine.currentTheme.accentPrimary, lineWidth: 1.8)
            )
            .shadow(color: engine.currentTheme.accentPrimary.opacity(0.55), radius: 26, x: 0, y: 8)
            .shadow(color: Color.black.opacity(0.9), radius: 34, x: 0, y: 14)
        }
    }

    private func themeColorPickerCard(title: String, subtitle: String, hex: Binding<String>) -> some View {
        let col = Color(hex: hex.wrappedValue)
        return HStack(spacing: 8) {
            ColorPicker("", selection: Binding<Color>(
                get: { col },
                set: { hex.wrappedValue = $0.toHex() }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(hex.wrappedValue)
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(engine.currentTheme.accentPrimary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(col.opacity(0.65), lineWidth: 1.2))
    }

    // ------------------------------------------------------------------------
    // GITHUB AUTO-UPDATER OVERLAY (Centered with Blurred Console Behind It)
    // ------------------------------------------------------------------------
    private var updateSheetOverlay: some View {
        ZStack {
            Color.black.opacity(0.65)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !engine.isDownloadingUpdate {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                            engine.showUpdateModal = false
                        }
                    }
                }

            VStack(alignment: .leading, spacing: 14) {
                // Header Bar
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(red: 0.98, green: 0.72, blue: 0.22))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("BITCHMANAGER GITHUB AUTO-UPDATER")
                                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                .foregroundColor(.white)

                            if let rel = engine.latestRelease {
                                Text("\(rel.tagName)")
                                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(red: 0.98, green: 0.72, blue: 0.22))
                                    .foregroundColor(.black)
                                    .clipShape(Capsule())
                            }
                        }

                        Text("Installed Version: v\(engine.currentAppVersion) • Repository: kookly/BitchManager")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(white: 0.68))
                    }

                    Spacer()

                    if !engine.isDownloadingUpdate {
                        Button(action: {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                                engine.showUpdateModal = false
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Color.white.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Release Title & Date Box
                if let release = engine.latestRelease {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(release.name ?? release.tagName)
                                .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                                .foregroundColor(engine.currentTheme.accentPrimary)
                            Spacer()
                            Text(release.formattedPublishDate)
                                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(white: 0.6))
                        }

                        if let asset = release.bestAsset {
                            HStack(spacing: 4) {
                                Image(systemName: "shippingbox.fill")
                                    .font(.system(size: 7.5))
                                Text("Asset: \(asset.name) (\(asset.formattedSize))")
                                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                                    .foregroundColor(Color(white: 0.7))
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Release Notes Body
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RELEASE NOTES & CHANGELOG:")
                            .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)

                        ScrollView([.vertical], showsIndicators: false) {
                            Text(release.body ?? "No release notes provided for this version.")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(Color(white: 0.88))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 120)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(engine.currentTheme.accentPrimary.opacity(0.3), lineWidth: 1))
                    }
                }

                // Download Progress / Status Bar
                if engine.isDownloadingUpdate {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(engine.updateStatusMessage)
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .foregroundColor(engine.currentTheme.accentPrimary)
                            Spacer()
                            Text("\(Int(engine.updateDownloadProgress * 100))%")
                                .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                                .foregroundColor(.white)
                        }

                        GeometryReader { pGeo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.white.opacity(0.12))
                                    .frame(height: 6)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color(red: 0.98, green: 0.72, blue: 0.22), engine.currentTheme.accentPrimary],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(0, pGeo.size.width * CGFloat(engine.updateDownloadProgress)), height: 6)
                                    .shadow(color: engine.currentTheme.accentPrimary.opacity(0.8), radius: 4)
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Error Display (if any)
                if let err = engine.updateError {
                    Text(err)
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                        .padding(6)
                        .background(Color.red.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Action Buttons Bar
                HStack(spacing: 8) {
                    if !engine.isDownloadingUpdate {
                        Button(action: {
                            engine.installUpdateFromGitHub()
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("⚡ UPDATE & RESTART NOW")
                            }
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 0.98, green: 0.72, blue: 0.22), Color(red: 0.95, green: 0.42, blue: 0.15)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundColor(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .shadow(color: Color.orange.opacity(0.6), radius: 6)
                        }
                        .buttonStyle(.plain)

                        if let rel = engine.latestRelease, let url = URL(string: rel.htmlURL) {
                            Button(action: {
                                NSWorkspace.shared.open(url)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "safari")
                                    Text("VIEW ON GITHUB")
                                }
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.12))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        Button(action: {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                                engine.showUpdateModal = false
                            }
                        }) {
                            Text("LATER")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.08))
                                .foregroundColor(Color(white: 0.7))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Spacer()
                        Button(action: {
                            engine.cancelUpdateDownload()
                        }) {
                            Text("CANCEL DOWNLOAD")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.25))
                                .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
            .frame(width: 520)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.03, green: 0.14, blue: 0.12).opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(engine.currentTheme.accentPrimary, lineWidth: 1.8)
            )
            .shadow(color: engine.currentTheme.accentPrimary.opacity(0.55), radius: 26, x: 0, y: 8)
            .shadow(color: Color.black.opacity(0.9), radius: 34, x: 0, y: 14)
        }
    }

    // ------------------------------------------------------------------------
    // LEFT WING (RED BOX #1): MIDI INPUT -> ANY PROGRAM / OUTPUT ROUTER & SCOPE
    // ------------------------------------------------------------------------
    private func leftWingStudioPanel(isSpotlight: Bool = false) -> some View {
        let scale: CGFloat = currentScale(for: .midiRouter, isSpotlight: isSpotlight)

        return VStack(alignment: .leading, spacing: 8) {
            if !isSpotlight {
                // Header (Uniform across all modules)
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)

                        Text("MIDI ROUTER")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Circle()
                            .fill(engine.midiThruEnabled ? Color.green : Color.orange)
                            .frame(width: 5, height: 5)
                            .shadow(color: engine.midiThruEnabled ? Color.green : Color.orange, radius: 2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        engine.toggleSpotlightModule(.midiRouter)
                    }

                    Spacer(minLength: 2)

                    moduleHeaderControls(for: .midiRouter)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            // Left Wing Tabs: ROUTER, SCOPE, MACROS
            HStack(spacing: 3) {
                wingTabButton(title: "ROUTER", active: engine.leftWingTab == "ROUTER" || engine.leftWingTab == "SHOWCONTROL", scale: scale) {
                    engine.leftWingTab = "ROUTER"
                }
                wingTabButton(title: "SCOPE", active: engine.leftWingTab == "TELEMETRY", scale: scale) {
                    engine.leftWingTab = "TELEMETRY"
                }
                wingTabButton(title: "MACROS", active: engine.leftWingTab == "MACROS", scale: scale) {
                    engine.leftWingTab = "MACROS"
                }
            }

            ScrollView([.vertical], showsIndicators: false) {
                if engine.leftWingTab == "TELEMETRY" {
                    leftWingTelemetryScopeContent
                } else if engine.leftWingTab == "MACROS" {
                    leftWingMacrosContent
                } else {
                    leftWingMIDIRouterContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(10)
        .background(isSpotlight ? Color.clear : Color.black.opacity(0.42))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSpotlight ? Color.clear : engine.currentTheme.sectionOutline.opacity(0.75), lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var leftWingMIDIRouterContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 1. Virtual MIDI Output Port Card (Appears in Ableton, Logic, QLab, Resolume, etc.)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundColor(engine.virtualOutEnabled ? Color(red: 0.2, green: 0.96, blue: 0.65) : .gray)
                    Text("VIRTUAL PORT (ALL DAWS)")
                        .font(.system(size: 13.0, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Toggle("", isOn: $engine.virtualOutEnabled)
                        .toggleStyle(.switch)
                        .scaleEffect(0.65)
                        .frame(width: 34, height: 16)
                }
                Text("Port Name: 'BitchBoy Virtual Out'")
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                Text("Select 'BitchBoy Virtual Out' in Ableton, Logic, QLab, Resolume, or any synth!")
                    .font(.system(size: 12.0, design: .monospaced))
                    .foregroundColor(Color(white: 0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(7)
            .background(Color(red: 0.04, green: 0.16, blue: 0.14).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(engine.currentTheme.accentPrimary.opacity(0.45), lineWidth: 1))

            // 2. Direct MIDI Output Destinations List
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("SEND TO PROGRAMS / PORTS:")
                        .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.headerText)
                    Spacer()
                    Button("ALL APPS") {
                        engine.selectAllExternalOutputs()
                    }
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .buttonStyle(.plain)

                    Button("↻") {
                        engine.scanForBitchBoy()
                    }
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .buttonStyle(.plain)
                }

                ScrollView([.vertical], showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        if engine.availableOutputTargets.isEmpty {
                            Text("No external MIDI ports detected. Use 'BitchBoy Virtual Out' or enable IAC Driver.")
                                .font(.system(size: 12.0, design: .monospaced))
                                .foregroundColor(Color(white: 0.55))
                                .padding(4)
                        } else {
                            ForEach(engine.availableOutputTargets) { target in
                                let isSelected = engine.selectedOutputNames.contains(target.name)
                                Button(action: {
                                    engine.toggleOutputTarget(target.name)
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 14.0))
                                            .foregroundColor(isSelected ? engine.currentTheme.accentPrimary : Color(white: 0.5))
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(target.name)
                                                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                                                .foregroundColor(.white)
                                                .lineLimit(1)
                                            Text(target.isHardwareBitchBoy ? "Hardware Controller Port" : "External App / Synth / Bus")
                                                .font(.system(size: 11.5, design: .monospaced))
                                                .foregroundColor(target.isHardwareBitchBoy ? Color.orange : Color(white: 0.55))
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(isSelected ? engine.currentTheme.accentPrimary.opacity(0.16) : Color.black.opacity(0.35))
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(height: 62)
                .padding(4)
                .background(Color.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 4) {
                    Button(action: {
                        engine.openAudioMIDISetupApp()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "slider.horizontal.below.rectangle")
                            Text("AUDIO MIDI SETUP")
                        }
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08))
                        .foregroundColor(Color(white: 0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Section("Set Custom Image for 'BitchBoy' in macOS MIDI Studio") {
                            Button(action: {
                                engine.applyBitchBoyMIDIStudioIcon(style: "MASCOT", silent: false)
                            }) {
                                Label("Apply BitchBoy Mascot Icon to MIDI Studio", systemImage: "person.crop.square.fill")
                            }
                            Button(action: {
                                engine.applyBitchBoyMIDIStudioIcon(style: "BADGE", silent: false)
                            }) {
                                Label("Apply BitchBoy Badge Icon to MIDI Studio", systemImage: "app.badge.fill")
                            }
                            Button(action: {
                                engine.applyBitchBoyMIDIStudioIcon(style: "LOGO", silent: false)
                            }) {
                                Label("Apply BitchBoy Word Logo to MIDI Studio", systemImage: "textformat")
                            }
                            Divider()
                            Button(action: {
                                engine.chooseCustomMIDIStudioIconFromDisk()
                            }) {
                                Label("Choose Any Custom Image File (.png / .jpg / .icns)...", systemImage: "folder.badge.plus")
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "photo.badge.checkmark")
                                .font(.system(size: 12.0))
                            Text("MIDI STUDIO ICON")
                                .font(.system(size: 11.0, weight: .heavy, design: .monospaced))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(engine.currentTheme.accentPrimary.opacity(0.22))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }

            // 3. Channel Remapper, Transpose & Velocity Curve
            VStack(alignment: .leading, spacing: 5) {
                Text("MIDI TRANSFORMER & FILTERS")
                    .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)

                // Output Channel Picker
                HStack {
                    Text("OUT CHANNEL:")
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Spacer()
                    Picker("", selection: $engine.remapChannel) {
                        Text("ORIG (CH 1)").tag(0)
                        ForEach(1...16, id: \.self) { ch in
                            Text("FORCE CH \(ch)").tag(ch)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .frame(width: 118)
                }

                // Transpose Semitones
                HStack(spacing: 4) {
                    Text("TRANSPOSE:")
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Spacer()
                    Button("-12") { engine.transposeSemitones = max(-24, engine.transposeSemitones - 12) }
                        .buttonStyle(.plain).font(.system(size: 12.0, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 2).background(Color.white.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 3))
                    Button("-") { engine.transposeSemitones = max(-24, engine.transposeSemitones - 1) }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Color.white.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(engine.transposeSemitones >= 0 ? "+\(engine.transposeSemitones)" : "\(engine.transposeSemitones)")
                        .font(.system(size: 13.0, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                        .frame(width: 28)
                    Button("+") { engine.transposeSemitones = min(24, engine.transposeSemitones + 1) }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Color.white.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 3))
                    Button("+12") { engine.transposeSemitones = min(24, engine.transposeSemitones + 12) }
                        .buttonStyle(.plain).font(.system(size: 12.0, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 2).background(Color.white.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 3))
                }

                // Velocity Curve
                HStack(spacing: 3) {
                    Text("CURVE:")
                        .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Spacer()
                    ForEach(MIDIVelocityCurve.allCases) { curve in
                        Button(curve.rawValue) {
                            engine.velocityCurve = curve
                        }
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(engine.velocityCurve == curve ? engine.currentTheme.accentPrimary : Color.white.opacity(0.08))
                        .foregroundColor(engine.velocityCurve == curve ? .black : .white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .buttonStyle(.plain)
                    }
                }

                // Filter Checkboxes
                HStack(spacing: 6) {
                    filterTogglePill(label: "KEYS", isOn: $engine.forwardNotes)
                    filterTogglePill(label: "FADERS/CC", isOn: $engine.forwardCCs)
                    filterTogglePill(label: "UI SIM", isOn: $engine.forwardUIInteractions)
                }
            }
            .padding(7)
            .background(Color.black.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // 4. Test Note & Panic Bar + Live Outgoing Telemetry
            HStack(spacing: 6) {
                Button(action: {
                    engine.sendTestNoteToOutputs()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "music.note.list")
                        Text("TEST CHORD")
                    }
                    .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.14, green: 0.45, blue: 0.36))
                    .foregroundColor(Color(red: 0.35, green: 0.98, blue: 0.78))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button(action: {
                    engine.sendPanicAllNotesOffToOutputs()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("PANIC OFF")
                    }
                    .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.55, green: 0.16, blue: 0.16))
                    .foregroundColor(Color(red: 1.0, green: 0.65, blue: 0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }

            // Live TX Packet Strip
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("TX OUT STREAM")
                        .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.5))
                    Spacer()
                    Text("PKTS: \(engine.txPacketCount)")
                        .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                }
                Text(engine.lastRoutedMessage)
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.3, green: 0.98, blue: 0.75))
                    .lineLimit(1)
            }
            .padding(6)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var leftWingTelemetryScopeContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("8 VERTICAL FADERS (CC 0–7)")
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<8, id: \.self) { i in
                    let val = engine.controls[49 + i].liveValue
                    VStack(spacing: 2) {
                        Text("\(val)")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 20, height: 42)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(engine.currentTheme.accentPrimary)
                                .frame(width: 20, height: max(3, CGFloat(val) / 127.0 * 42.0))
                        }
                        Text("VF\(i+1)")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.65))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(6)
            .background(Color.black.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("4 HORIZ FADERS & 8 KNOBS (CC 8–11, 20–27)")
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            VStack(spacing: 3) {
                ForEach(57..<69, id: \.self) { idx in
                    let item = engine.controls[idx]
                    HStack(spacing: 5) {
                        Text(item.label)
                            .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 26, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.1))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(red: 0.96, green: 0.72, blue: 0.28))
                                    .frame(width: max(3, geo.size.width * CGFloat(item.liveValue) / 127.0))
                            }
                        }
                        .frame(height: 6)
                        Text(String(format: "%03d", item.liveValue))
                            .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.96, green: 0.72, blue: 0.28))
                            .frame(width: 24, alignment: .trailing)
                    }
                }
            }
            .padding(6)
            .background(Color.black.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("LIVE MIDI HEX PACKET MONITOR")
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            ScrollView([.vertical], showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    if engine.routerPacketHistory.isEmpty {
                        Text("Waiting for MIDI packets...")
                            .font(.system(size: 12.0, design: .monospaced))
                            .foregroundColor(Color(white: 0.5))
                    } else {
                        ForEach(engine.routerPacketHistory, id: \.self) { pkt in
                            Text(pkt)
                                .font(.system(size: 12.0, design: .monospaced))
                                .foregroundColor(Color(red: 0.28, green: 0.96, blue: 0.74))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 54)
            .padding(6)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var leftWingMacrosContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tap Tempo BPM Clock
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MASTER CLOCK // TAP TEMPO")
                        .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.headerText)
                    Text("\(Int(engine.tapTempoBPM)) BPM (FX: \(String(format: "%.1fx", engine.fxSpeed)))")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                }
                Spacer()
                Button(action: {
                    engine.registerTapTempo()
                }) {
                    Text("🥁 TAP BPM")
                        .font(.system(size: 13.5, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(engine.currentTheme.accentPrimary)
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("8 INSTANT HARDWARE SCENE MACROS")
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                macroTriggerPad(title: "ZERO ALL FADERS", icon: "arrow.down.to.line") {
                    for i in 49..<61 { engine.setControlLiveValue(index: i, value: 0) }
                }
                macroTriggerPad(title: "MAX ALL FADERS", icon: "arrow.up.to.line") {
                    for i in 49..<61 { engine.setControlLiveValue(index: i, value: 127) }
                }
                macroTriggerPad(title: "CENTER 8 KNOBS", icon: "dial.medium.fill") {
                    for i in 61..<69 { engine.setControlLiveValue(index: i, value: 64) }
                }
                macroTriggerPad(title: "PARTY SPARK LEDS", icon: "sparkles") {
                    let pal: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 57, 3]
                    for i in 0..<49 {
                        let v = pal.randomElement() ?? 78
                        engine.controls[i].idleVelocity = v
                        engine.controls[i].currentLED = v
                        engine.sendNoteOn(note: engine.controls[i].number, velocity: v)
                    }
                    engine.saveCurrentSlot()
                }
                macroTriggerPad(title: "ALL 49 LEDS WHITE", icon: "sun.max.fill") {
                    engine.setZoneLEDs(range: 0..<49, velocity: 3)
                }
                macroTriggerPad(title: "BLACKOUT ALL 49", icon: "moon.fill") {
                    engine.blackoutPanic()
                }
                macroTriggerPad(title: "SEND C-MAJ9 CHORD", icon: "pianokeys") {
                    engine.sendTestNoteToOutputs()
                }
                macroTriggerPad(title: "ALL NOTES OFF", icon: "xmark.octagon.fill") {
                    engine.sendPanicAllNotesOffToOutputs()
                }
            }

            Text("⌨️ QUICK QWERTY KEYBOARD PROFILES")
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .foregroundColor(Color(red: 0.98, green: 0.78, blue: 0.25))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                macroTriggerPad(title: "DAW TRANSPORT", icon: "play.circle.fill") {
                    engine.controls[0].actionType = .qwerty
                    engine.controls[0].qwertySteps = [QwertyStep(key: "space")]
                    engine.controls[1].actionType = .qwerty
                    engine.controls[1].qwertySteps = [QwertyStep(key: "r")]
                    engine.controls[2].actionType = .qwerty
                    engine.controls[2].qwertySteps = [QwertyStep(key: "return")]
                    engine.saveCurrentSlot()
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }
                macroTriggerPad(title: "OBS STREAM DECK", icon: "video.fill") {
                    let fkeys = ["f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21"]
                    for (i, fk) in fkeys.enumerated() {
                        let idx = 40 + i
                        if idx < engine.controls.count {
                            engine.controls[idx].actionType = .qwerty
                            engine.controls[idx].qwertySteps = [QwertyStep(key: fk)]
                        }
                    }
                    engine.saveCurrentSlot()
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }
                macroTriggerPad(title: "VIDEO EDIT J/K/L", icon: "film.fill") {
                    let keys = ["j", "k", "l", "c", "v", "b", "z"]
                    for (i, k) in keys.enumerated() {
                        if i < engine.controls.count {
                            engine.controls[i].actionType = .qwerty
                            engine.controls[i].qwertySteps = [QwertyStep(key: k)]
                        }
                    }
                    engine.saveCurrentSlot()
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }
                macroTriggerPad(title: "CLEAR ALL TO MIDI", icon: "arrow.counterclockwise") {
                    for i in 0..<49 {
                        engine.controls[i].actionType = .passthrough
                        engine.controls[i].qwertySteps.removeAll()
                    }
                    engine.saveCurrentSlot()
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }
            }
        }
    }

    // ------------------------------------------------------------------------
    // SHOW CONTROL PROTOCOL STUDIO (SLOT 0 // RED BOX #1)
    // Control external show software (QLab, Resolume, grandMA, ETC EOS, TouchDesigner)
    // ------------------------------------------------------------------------
    private func showControlStudioPanel(isSpotlight: Bool = false) -> some View {
        let scale: CGFloat = currentScale(for: .showControl, isSpotlight: isSpotlight)

        return VStack(alignment: .leading, spacing: 7) {
            if !isSpotlight {
                // Header (Uniform across all modules)
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)

                        Text("SHOW CONTROL")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                            .shadow(color: Color.green, radius: 2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        engine.toggleSpotlightModule(.showControl)
                    }

                    Spacer(minLength: 2)

                    moduleHeaderControls(for: .showControl)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            // Sub-Tab Switcher: OSC STUDIO & HARDWARE FEEDBACK
            HStack(spacing: 3) {
                wingTabButton(title: "OSC STUDIO", active: engine.showControlSubTab != "FEEDBACK", scale: scale) {
                    engine.showControlSubTab = "OSC"
                }
                wingTabButton(title: "FEEDBACK", active: engine.showControlSubTab == "FEEDBACK", scale: scale) {
                    engine.showControlSubTab = "FEEDBACK"
                }
            }

            ScrollView([.vertical], showsIndicators: false) {
                if engine.showControlSubTab == "FEEDBACK" {
                    showControlFeedbackContent
                } else {
                    showControlUnifiedOSCContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(10)
        .background(isSpotlight ? Color.clear : Color.black.opacity(0.42))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSpotlight ? Color.clear : engine.currentTheme.sectionOutline.opacity(0.75), lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var showControlMSCContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Virtual Destination Status Box (Matching QLab Screenshot)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 14.0))
                    Text("Patch 1 - BitchBoy (BLOCK SYSTEM)")
                        .font(.system(size: 13.0, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Text("DEV: \(engine.mscDeviceID == 127 ? "ALL" : "\(engine.mscDeviceID)")")
                        .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                }

                Text("CoreMIDI destination online • Auto-discovered by QLab, EOS, and GrandMA")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))

                Toggle(isOn: $engine.mscAutoTriggerOnInbound) {
                    Text("Auto-Trigger Presets on Inbound MSC (GO / STOP / LOAD)")
                        .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.85))
                }
                .toggleStyle(.checkbox)
                .padding(.top, 2)
            }
            .padding(6)
            .background(Color(red: 0.04, green: 0.14, blue: 0.16).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cyan.opacity(0.4), lineWidth: 1))

            // MSC Transmitter Parameters
            VStack(alignment: .leading, spacing: 4) {
                Text("TRANSMIT MSC BROADCAST:")
                    .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)

                HStack(spacing: 6) {
                    // Device ID
                    VStack(alignment: .leading, spacing: 1) {
                        Text("DEVICE ID:")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                        Picker("", selection: $engine.mscDeviceID) {
                            Text("1 (Default)").tag(UInt8(1))
                            ForEach(0..<16) { id in
                                if id != 1 {
                                    Text("\(id)").tag(UInt8(id))
                                }
                            }
                            Text("127 (All Broadcast)").tag(UInt8(127))
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .scaleEffect(0.82, anchor: .leading)
                    }

                    // Format
                    VStack(alignment: .leading, spacing: 1) {
                        Text("FORMAT:")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                        Picker("", selection: $engine.mscCommandFormat) {
                            ForEach(MSCCommandFormat.allCases) { fmt in
                                Text(fmt.label).tag(fmt)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .scaleEffect(0.82, anchor: .leading)
                    }
                }

                HStack(spacing: 6) {
                    // Cue Number
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CUE #:")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                        TextField("e.g. 1.0", text: $engine.mscCueNumber)
                            .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    // Cue List
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CUE LIST (OPTIONAL):")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                        TextField("e.g. Main", text: $engine.mscCueList)
                            .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                // Transport Command Buttons Grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    mscTransportButton(title: "▶️ GO", color: .green) {
                        engine.sendMSCBroadcast(command: .go, cue: engine.mscCueNumber, cueList: engine.mscCueList, deviceID: engine.mscDeviceID, format: engine.mscCommandFormat)
                    }
                    mscTransportButton(title: "⏹️ STOP", color: .red) {
                        engine.sendMSCBroadcast(command: .stop, cue: engine.mscCueNumber, cueList: engine.mscCueList, deviceID: engine.mscDeviceID, format: engine.mscCommandFormat)
                    }
                    mscTransportButton(title: "⏯️ RESUME", color: .cyan) {
                        engine.sendMSCBroadcast(command: .resume, cue: engine.mscCueNumber, cueList: engine.mscCueList, deviceID: engine.mscDeviceID, format: engine.mscCommandFormat)
                    }
                    mscTransportButton(title: "🔄 RESET", color: .yellow) {
                        engine.sendMSCBroadcast(command: .reset, cue: engine.mscCueNumber, cueList: engine.mscCueList, deviceID: engine.mscDeviceID, format: engine.mscCommandFormat)
                    }
                    mscTransportButton(title: "🚨 PANIC", color: .orange) {
                        engine.sendMSCBroadcast(command: .allOff, cue: "", cueList: "", deviceID: engine.mscDeviceID, format: engine.mscCommandFormat)
                    }
                    mscTransportButton(title: "🔥 FIRE", color: .purple) {
                        engine.sendMSCBroadcast(command: .fire, cue: engine.mscCueNumber, cueList: engine.mscCueList, deviceID: engine.mscDeviceID, format: engine.mscCommandFormat)
                    }
                }
                .padding(.top, 2)
            }
            .padding(6)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Live Inbound/Outbound MSC Log Inspector
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("MSC PACKET MONITOR (TX / RX):")
                        .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Spacer()
                    Button("CLEAR") {
                        engine.clearMSCLogHistory()
                    }
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                    .buttonStyle(.plain)
                }

                ScrollView([.vertical], showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        if engine.mscLogHistory.isEmpty {
                            Text("Ready. Listening on 'BitchBoy (BLOCK SYSTEM)' and transmitting on GO / STOP.")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(Color(white: 0.5))
                                .padding(4)
                        } else {
                            ForEach(engine.mscLogHistory) { msg in
                                HStack(spacing: 4) {
                                    Text(msg.timeString)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundColor(Color(white: 0.5))
                                    Text(msg.summary)
                                        .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                                        .foregroundColor(msg.isOutbound ? Color.cyan : Color.green)
                                }
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1.5)
                                .background(Color.black.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
            .padding(6)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func mscTransportButton(title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(color.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.8), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var showControlUnifiedOSCContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            // OSC Mode Selector: [🎛️ KEY & FADER MAPPINGS] vs [📡 MANUAL TRANSMITTER]
            HStack(spacing: 4) {
                Button(action: {
                    engine.oscStudioMode = "MAPPINGS"
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.2.square.on.square")
                        Text("KEY & FADER MAPPINGS (65)")
                    }
                    .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(engine.oscStudioMode == "MAPPINGS" ? engine.currentTheme.accentPrimary : Color.white.opacity(0.06))
                    .foregroundColor(engine.oscStudioMode == "MAPPINGS" ? .black : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(engine.oscStudioMode == "MAPPINGS" ? engine.currentTheme.accentPrimary : Color.white.opacity(0.12), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .hoverGrow(1.04)

                Button(action: {
                    engine.oscStudioMode = "TRANSMITTER"
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill")
                        Text("MANUAL PACKET TESTER")
                    }
                    .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(engine.oscStudioMode == "TRANSMITTER" ? engine.currentTheme.accentPrimary : Color.white.opacity(0.06))
                    .foregroundColor(engine.oscStudioMode == "TRANSMITTER" ? .black : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(engine.oscStudioMode == "TRANSMITTER" ? engine.currentTheme.accentPrimary : Color.white.opacity(0.12), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .hoverGrow(1.04)

                Spacer()
            }
            .padding(.bottom, 2)

            if engine.oscStudioMode == "TRANSMITTER" {
                showControlOSCContent
            } else {
                midiToOSCStudioContent
            }
        }
    }

    private var showControlOSCContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CUSTOM OSC (OPEN SOUND CONTROL) TRANSMITTER:")
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("HOST IP:")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("127.0.0.1", text: $engine.customOSCHost)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("PORT:")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("53000", value: $engine.customOSCPort, formatter: NumberFormatter())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("OSC ADDRESS:")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                TextField("/cue/selected/start", text: $engine.customOSCAddress)
                    .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("ARG TYPE:")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    Picker("", selection: $engine.customOSCArgType) {
                        Text("NONE (Bang)").tag("NONE")
                        Text("FLOAT (,f)").tag("FLOAT")
                        Text("INT (,i)").tag("INT")
                        Text("STRING (,s)").tag("STRING")
                        Text("TRUE (,T)").tag("BOOLEAN_TRUE")
                        Text("FALSE (,F)").tag("BOOLEAN_FALSE")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .scaleEffect(0.82, anchor: .leading)
                }

                if engine.customOSCArgType != "NONE" && !engine.customOSCArgType.starts(with: "BOOLEAN") {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("ARG VALUE:")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                        TextField("Value", text: $engine.customOSCArgValue)
                            .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            Button(action: {
                engine.sendCustomOSC(
                    host: engine.customOSCHost,
                    port: engine.customOSCPort,
                    address: engine.customOSCAddress,
                    argType: engine.customOSCArgType,
                    argValue: engine.customOSCArgValue
                )
                SoundEffect.keyTap.play(with: engine.soundPack)
            }) {
                HStack {
                    Image(systemName: "paperplane.fill")
                    Text("TRANSMIT OSC UDP")
                }
                .font(.system(size: 13.0, weight: .heavy, design: .monospaced))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(engine.currentTheme.accentPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            // Quick Presets
            VStack(alignment: .leading, spacing: 3) {
                Text("QUICK APPLICATION PRESETS:")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.65))

                HStack(spacing: 3) {
                    Button("QLAB GO") {
                        engine.customOSCAddress = "/cue/selected/start"
                        engine.customOSCPort = 53000
                        engine.customOSCArgType = "NONE"
                        engine.sendCustomOSC(host: engine.customOSCHost, port: 53000, address: "/cue/selected/start", argType: "NONE", argValue: "")
                    }
                    Button("QLAB PANIC") {
                        engine.customOSCAddress = "/panic"
                        engine.customOSCPort = 53000
                        engine.customOSCArgType = "NONE"
                        engine.sendCustomOSC(host: engine.customOSCHost, port: 53000, address: "/panic", argType: "NONE", argValue: "")
                    }
                    Button("EOS GO") {
                        engine.customOSCAddress = "/eos/key/go_0"
                        engine.customOSCPort = 8000
                        engine.customOSCArgType = "NONE"
                        engine.sendCustomOSC(host: engine.customOSCHost, port: 8000, address: "/eos/key/go_0", argType: "NONE", argValue: "")
                    }
                }
                .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                .buttonStyle(.plain)
                .foregroundColor(engine.currentTheme.accentPrimary)
            }
            .padding(5)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            // Hardware Key & Fader Live OSC Broadcast
            Toggle(isOn: $engine.midiToOSCMappingActive) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("LIVE BITCHBOY OSC ENGINE (ACTIVE)")
                        .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.midiToOSCMappingActive ? Color.green : Color.white)
                    Text("Keys, Faders, & Encoders broadcast mapped OSC addresses via UDP")
                        .font(.system(size: 11.0, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                }
            }
            .toggleStyle(.checkbox)
            .padding(4)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(6)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // ------------------------------------------------------------------------
    // MIDI TO OSC CUSTOMIZATION STUDIO MATRIX VIEW (INDIVIDUAL KEYS & FADERS)
    // ------------------------------------------------------------------------
    private var midiToOSCStudioContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Master Header & Status
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.2.square.on.square")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MIDI ➔ OSC MAPPING MATRIX")
                        .font(.system(size: 13.0, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.headerText)
                    Text("Map any button or fader to send custom OSC messages")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                }
                Spacer()
                Toggle("", isOn: $engine.midiToOSCMappingActive)
                    .toggleStyle(SwitchToggleStyle(tint: engine.currentTheme.accentPrimary))
                    .labelsHidden()
                    .scaleEffect(0.7)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Quick Presets Bar
            VStack(alignment: .leading, spacing: 3) {
                Text("QUICK 1-CLICK TEMPLATES:")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.55))

                VStack(spacing: 3) {
                    HStack(spacing: 3) {
                        Button(action: { engine.applyOSCAutoMapTemplate() }) {
                            Text("⚡ AUTO-MAP")
                                .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.1))
                                .foregroundColor(engine.currentTheme.accentPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .hoverGrow(1.05)
                        .help("Auto-map all 65 controls to /bitchboy/...")

                        Button(action: { engine.applyOSCQLabTemplate() }) {
                            Text("🎭 QLAB")
                                .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.1))
                                .foregroundColor(.yellow)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .hoverGrow(1.05)
                        .help("Map cues 1..32, transport and volume faders for QLab")

                        Button(action: { engine.applyOSCResolumeTemplate() }) {
                            Text("🎬 RESOLUME")
                                .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.1))
                                .foregroundColor(.cyan)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .hoverGrow(1.05)
                        .help("Map layer clips and opacity faders for Resolume Arena")
                    }

                    HStack(spacing: 3) {
                        Button(action: { engine.applyOSCEosTemplate() }) {
                            Text("💡 ETC EOS")
                                .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.1))
                                .foregroundColor(.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .hoverGrow(1.05)
                        .help("Map submasters and keys for ETC EOS / nomad")

                        Button(action: { engine.clearAllOSCMappings() }) {
                            Text("🧹 CLEAR ALL")
                                .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3)
                                .background(Color.red.opacity(0.2))
                                .foregroundColor(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .hoverGrow(1.05)
                        .help("Disable all mappings")
                    }
                }
            }

            // Target Host & Port default strip
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("GLOBAL TARGET IP:")
                        .font(.system(size: 11.0, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("127.0.0.1", text: $engine.customOSCHost)
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2.5)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("PORT:")
                        .font(.system(size: 11.0, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("53000", value: $engine.customOSCPort, formatter: NumberFormatter())
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2.5)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("SEARCH / FILTER:")
                        .font(.system(size: 11.0, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("Search key/fader...", text: $engine.midiToOSCSearchText)
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2.5)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            // Section Filter Tabs (2 clean rows - never wraps or clips!)
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    oscFilterTabButton(title: "ALL", filterKey: "ALL")
                    oscFilterTabButton(title: "GRID", filterKey: "GRID")
                    oscFilterTabButton(title: "STRIP", filterKey: "STRIP")
                    oscFilterTabButton(title: "PAD", filterKey: "PAD")
                }
                HStack(spacing: 2) {
                    oscFilterTabButton(title: "V-FADERS", filterKey: "VFADERS")
                    oscFilterTabButton(title: "H-FADERS", filterKey: "HFADERS")
                    oscFilterTabButton(title: "KNOBS", filterKey: "MASTER_KNOBS")
                }
            }

            // Controls List
            let indices = engine.filteredControlIndices()
            if indices.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.4))
                    Text("No matching controls")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(Color(white: 0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(indices, id: \.self) { idx in
                        oscControlMappingCard(index: idx)
                    }
                }
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func oscFilterTabButton(title: String, filterKey: String) -> some View {
        let isActive = engine.midiToOSCFilter == filterKey
        return Button(action: {
            engine.midiToOSCFilter = filterKey
            SoundEffect.knobTick.play(with: engine.soundPack)
        }) {
            Text(title)
                .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(isActive ? engine.currentTheme.accentPrimary : Color.white.opacity(0.08))
                .foregroundColor(isActive ? .black : Color(white: 0.85))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private func oscControlMappingCard(index: Int) -> some View {
        let item = engine.controls[index]
        let isKey = item.kind == .key
        let isFader = item.kind == .vfader || item.kind == .hfader

        return VStack(alignment: .leading, spacing: 5) {
            // Header Row: Checkbox, Control Identifier & Number, Live Status, Test Trigger
            HStack(spacing: 6) {
                // Enabled Checkbox
                Button(action: {
                    engine.controls[index].oscEnabled.toggle()
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }) {
                    Image(systemName: engine.controls[index].oscEnabled ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(engine.controls[index].oscEnabled ? engine.currentTheme.accentPrimary : Color(white: 0.5))
                }
                .buttonStyle(.plain)

                // Kind Badge
                Text(isKey ? "KEY #\(item.number)" : (isFader ? "FADER CC\(item.number)" : "KNOB CC\(item.number)"))
                    .font(.system(size: 13.5, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(engine.controls[index].oscEnabled ? engine.currentTheme.accentPrimary.opacity(0.20) : Color.white.opacity(0.08))
                    .foregroundColor(engine.controls[index].oscEnabled ? engine.currentTheme.accentPrimary : Color(white: 0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                // Control Name / Label
                Text(item.label)
                    .font(.system(size: 14.0, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                // Live status pill
                if isKey {
                    if item.isPressed {
                        Text("PRESSED")
                            .font(.system(size: 13.0, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Color.green)
                            .foregroundColor(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                } else {
                    Text("\(item.liveValue)")
                        .font(.system(size: 13.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                }

                Spacer()

                // Test Trigger Button
                Button(action: {
                    engine.sendOSCForControl(index: index, isPress: true)
                    SoundEffect.keyTap.play(with: engine.soundPack)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 13.0))
                        Text("TEST")
                            .font(.system(size: 13.5, weight: .heavy, design: .monospaced))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.14))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .hoverGrow(1.05)
            }

            // Custom Name / Alias + OSC Address
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CUSTOM ALIAS:")
                        .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.82))
                    TextField(item.label, text: $engine.controls[index].customName)
                        .font(.system(size: 14.0, weight: .medium, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .frame(width: 95)

                VStack(alignment: .leading, spacing: 2) {
                    Text("OSC ADDRESS PATH:")
                        .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.82))
                    TextField(isKey ? "/bitchboy/key/\(index + 1)" : "/bitchboy/fader/\(max(1, index - 48))", text: $engine.controls[index].oscAddress)
                        .font(.system(size: 14.0, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            // OSC Parameters (Arg Type, Values, Scaling, Release)
            HStack(spacing: 6) {
                // Arg Type Picker
                VStack(alignment: .leading, spacing: 2) {
                    Text("ARG TYPE:")
                        .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.82))
                    Picker("", selection: $engine.controls[index].oscArgType) {
                        Text("FLOAT").tag("FLOAT")
                        Text("INT").tag("INT")
                        Text("BANG / NONE").tag("NONE")
                        Text("STRING").tag("STRING")
                        if isKey {
                            Text("BOOL").tag("BOOLEAN")
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                    .frame(height: 20)
                }
                .frame(width: 95)

                if isKey {
                    // Send on Release Checkbox & Release Value
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ON RELEASE:")
                            .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.82))
                        HStack(spacing: 4) {
                            Button(action: {
                                engine.controls[index].oscSendRelease.toggle()
                            }) {
                                Image(systemName: engine.controls[index].oscSendRelease ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 10))
                                    .foregroundColor(engine.controls[index].oscSendRelease ? .green : Color(white: 0.5))
                            }
                            .buttonStyle(.plain)

                            if engine.controls[index].oscSendRelease {
                                TextField("0.0", text: $engine.controls[index].oscReleaseVal)
                                    .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                                    .textFieldStyle(.plain)
                                    .frame(width: 40)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2.5)
                                    .background(Color.black.opacity(0.45))
                                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
                            }
                        }
                    }
                } else {
                    // Fader / Knob Min and Max Range
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MIN VAL:")
                            .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.82))
                        TextField("0.0", value: $engine.controls[index].oscMinVal, formatter: NumberFormatter())
                            .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                            .textFieldStyle(.plain)
                            .frame(width: 48)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2.5)
                            .background(Color.black.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MAX VAL:")
                            .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.82))
                        TextField("1.0", value: $engine.controls[index].oscMaxVal, formatter: NumberFormatter())
                            .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                            .textFieldStyle(.plain)
                            .frame(width: 48)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2.5)
                            .background(Color.black.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    }
                }

                Spacer()
            }
        }
        .padding(6)
        .background(engine.controls[index].oscEnabled ? Color.white.opacity(0.04) : Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(engine.controls[index].oscEnabled ? engine.currentTheme.accentPrimary.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var showControlArtNetContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ART-NET 4 DMX TRANSMITTER (UDP 6454):")
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("HOST / BROADCAST IP:")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("255.255.255.255", text: $engine.artNetHost)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("UNIVERSE (0-32767):")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("0", value: $engine.artNetUniverse, formatter: NumberFormatter())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            // Quick DMX Triggers
            HStack(spacing: 4) {
                Button("💡 FULL RIG 100%") {
                    engine.sendArtNetFullRig()
                    SoundEffect.presetSwitch.play(with: engine.soundPack)
                }
                .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                .foregroundColor(.black)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(Color.yellow)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .buttonStyle(.plain)

                Button("🌑 BLACKOUT") {
                    engine.sendArtNetBlackout()
                    SoundEffect.presetSwitch.play(with: engine.soundPack)
                }
                .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                .foregroundColor(.white)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .buttonStyle(.plain)

                Button("🌈 RGB CHASE") {
                    engine.sendArtNetRGBChase()
                    SoundEffect.presetSwitch.play(with: engine.soundPack)
                }
                .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                .foregroundColor(.black)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(Color.cyan)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .buttonStyle(.plain)
            }

            // Hardware Vertical Fader Mirroring Toggle
            Toggle(isOn: $engine.artNetMirrorHardwareFaders) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("MIRROR HARDWARE FADERS VF1–VF8 TO DMX CH 1–8")
                        .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.artNetMirrorHardwareFaders ? Color.green : Color.white)
                    Text("Moving physical sliders immediately broadcasts UDP DMX packets")
                        .font(.system(size: 11.0, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                }
            }
            .toggleStyle(.checkbox)
            .padding(4)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // 8 Direct DMX Channel Sliders
            VStack(alignment: .leading, spacing: 2) {
                Text("DMX CHANNELS 1–8 LIVE FADERS:")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.65))

                HStack(spacing: 4) {
                    ForEach(0..<8) { ch in
                        VStack(spacing: 1) {
                            Text("Ch\(ch+1)")
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(white: 0.6))
                            Text("\(engine.artNetChannels[ch])")
                                .font(.system(size: 11.0, weight: .heavy, design: .monospaced))
                                .foregroundColor(engine.currentTheme.accentPrimary)
                            Slider(
                                value: Binding(
                                    get: { Double(engine.artNetChannels[ch]) },
                                    set: { v in
                                        engine.artNetChannels[ch] = UInt8(v)
                                        engine.sendArtNetDMX(host: engine.artNetHost, universe: engine.artNetUniverse, channels: engine.artNetChannels)
                                    }
                                ),
                                in: 0...255,
                                step: 1
                            )
                            .labelsHidden()
                        }
                    }
                }
            }
            .padding(5)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .padding(6)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var showControlsACNContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ANSI E1.31 sACN TRANSMITTER (UDP 5568):")
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("UNIVERSE (1-63999):")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("1", value: $engine.sacnUniverse, formatter: NumberFormatter())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("PRIORITY (1-200):")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("100", value: $engine.sacnPriority, formatter: NumberFormatter())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("UNICAST IP (LEAVE EMPTY FOR MULTICAST):")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                TextField("Multicast 239.255.x.y", text: $engine.sacnHost)
                    .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            HStack(spacing: 4) {
                Button("🌟 FULL RIG 100%") {
                    engine.sendsACNFullRig()
                    SoundEffect.presetSwitch.play(with: engine.soundPack)
                }
                .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                .foregroundColor(.black)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(Color.green)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .buttonStyle(.plain)

                Button("🌑 BLACKOUT") {
                    engine.sendsACNBlackout()
                    SoundEffect.presetSwitch.play(with: engine.soundPack)
                }
                .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                .foregroundColor(.white)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(6)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var showControlFeedbackContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CUSTOMIZABLE HARDWARE MIDI FEEDBACK:")
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            Toggle(isOn: $engine.hardwareFeedbackEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("LOCAL HARDWARE LED FEEDBACK")
                        .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                    Text("When ON, pressing keys immediately updates BitchBoy LEDs locally based on feedback mode.")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                }
            }
            .toggleStyle(.checkbox)
            .padding(4)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Toggle(isOn: $engine.inboundMIDIEchoEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("DAW / INBOUND NOTE HARDWARE ECHO")
                        .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                    Text("When ON, incoming MIDI notes from QLab or DAWs light up the hardware key LEDs.")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                }
            }
            .toggleStyle(.checkbox)
            .padding(4)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Text("Selected Control: \(engine.controls[engine.selectedIndex].label)")
                .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                .foregroundColor(engine.currentTheme.accentPrimary)
                .padding(.top, 2)

            HStack(spacing: 4) {
                Text("MODE:")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                Picker("", selection: Binding(
                    get: { engine.controls[engine.selectedIndex].feedbackMode },
                    set: { mode in
                        let targets = engine.selectedIndices.count > 1 ? engine.selectedIndices : [engine.selectedIndex]
                        for idx in targets {
                            engine.controls[idx].feedbackMode = mode
                        }
                        engine.saveCurrentSlot()
                    }
                )) {
                    ForEach(FeedbackMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .scaleEffect(0.82, anchor: .leading)
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // ------------------------------------------------------------------------
    // PROTOCOL TERMINAL STUDIO PANEL (NETWORK, MIDI, OSC & DMX TRAFFIC MONITOR)
    // ------------------------------------------------------------------------
    private func protocolTerminalStudioPanel(isSpotlight: Bool = false) -> some View {
        let scale: CGFloat = currentScale(for: .terminal, isSpotlight: isSpotlight)

        return VStack(alignment: .leading, spacing: 6) {
            if !isSpotlight {
                // Header (Uniform across all modules - never truncates)
                HStack(spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "apple.terminal.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)

                        Text("PROTOCOL TERMINAL")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Circle()
                            .fill(engine.isProtocolPaused ? Color.orange : Color(red: 0.2, green: 0.95, blue: 0.45))
                            .frame(width: 5.5, height: 5.5)
                            .shadow(color: engine.isProtocolPaused ? Color.orange : Color.green, radius: 3)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        engine.toggleSpotlightModule(.terminal)
                    }

                    Spacer(minLength: 2)

                    moduleHeaderControls(for: .terminal)
                }
                .padding(.vertical, 2.5)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            // Top Primary Navigation Bar: [CONSOLE] [NETWORK] [SETTINGS]
            HStack(spacing: 4) {
                ForEach(TerminalTab.allCases) { tab in
                    Button(action: {
                        engine.terminalTab = tab
                        SoundEffect.keyTap.play(with: engine.soundPack)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11.0 * scale, weight: .bold))
                            Text(tab.rawValue)
                                .font(.system(size: 11.0 * scale, weight: .bold, design: .default))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(engine.terminalTab == tab ? engine.currentTheme.accentPrimary : Color.white.opacity(0.06))
                        .foregroundColor(engine.terminalTab == tab ? .black : Color(white: 0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2.5)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            // Body Switcher (Never clips; flexes & internally scrolls smoothly)
            Group {
                switch engine.terminalTab {
                case .console:
                    protocolTerminalConsoleContent(scale: scale)
                case .network:
                    protocolTerminalNetworkContent(scale: scale)
                case .settings:
                    protocolTerminalSettingsContent(scale: scale)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(9)
        .background(isSpotlight ? Color.clear : Color.black.opacity(0.42))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSpotlight ? Color.clear : engine.currentTheme.sectionOutline.opacity(0.75), lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // ------------------------------------------------------------------------
    // CONSOLE TAB CONTENT (LIVE PACKET FEED, FILTERS & PROMPT)
    // ------------------------------------------------------------------------
    private func protocolTerminalConsoleContent(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // Sub-Toolbar: Protocol Filter Pills & Actions (Row 1) + Telemetry & Sizing (Row 2)
            VStack(spacing: 3.5) {
                // ROW 1: Filter Tabs (Left) & Action Icons (Right)
                HStack(spacing: 4) {
                    // Filter Tabs: ALL, MIDI, OSC, DMX, SYS
                    HStack(spacing: 2) {
                        ForEach([ProtocolEvent.EventType.all, .midiIn, .oscIn, .dmx, .sys], id: \.self) { filterType in
                            Button(action: {
                                engine.protocolFilter = filterType
                                SoundEffect.keyTap.play(with: engine.soundPack)
                            }) {
                                Text(filterType == .all ? "ALL" : (filterType == .midiIn ? "MIDI" : (filterType == .oscIn ? "OSC" : filterType.rawValue)))
                                    .font(.system(size: 10.0 * scale, weight: .bold, design: .default))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2.5)
                                    .background(engine.protocolFilter == filterType ? engine.currentTheme.accentPrimary : Color.white.opacity(0.06))
                                    .foregroundColor(engine.protocolFilter == filterType ? .black : Color(white: 0.85))
                                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer(minLength: 4)

                    // Quick Actions (Pause, Clear, Copy, Mock Inject)
                    HStack(spacing: 5) {
                        // Pause / Resume Toggle
                        Button(action: { engine.toggleProtocolLoggingPaused() }) {
                            Image(systemName: engine.isProtocolPaused ? "play.circle.fill" : "pause.circle.fill")
                                .font(.system(size: 12.0 * scale, weight: .bold))
                                .foregroundColor(engine.isProtocolPaused ? Color.orange : Color(white: 0.85))
                                .padding(2)
                        }
                        .buttonStyle(.plain)
                        .help(engine.isProtocolPaused ? "Resume live packet stream" : "Pause live packet stream")

                        // Clear
                        Button(action: { engine.clearProtocolLogs() }) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 11.0 * scale))
                                .foregroundColor(Color(white: 0.75))
                                .padding(2)
                        }
                        .buttonStyle(.plain)
                        .help("Clear Terminal Logs")

                        // Copy
                        Button(action: { engine.exportProtocolLogsToClipboard() }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11.0 * scale))
                                .foregroundColor(Color(white: 0.75))
                                .padding(2)
                        }
                        .buttonStyle(.plain)
                        .help("Copy logs to Clipboard")

                        // Test Injection Menu
                        Menu {
                            Button("Inject MIDI Note On (C4)") { engine.injectTestProtocolPacket(type: .midiIn) }
                            Button("Inject MIDI CC #1 (Mod)") { engine.injectTestProtocolPacket(type: .midiOut) }
                            Button("Inject OSC In (/qlab/cue/1/start)") { engine.injectTestProtocolPacket(type: .oscIn) }
                            Button("Inject OSC Out (/live/volume)") { engine.injectTestProtocolPacket(type: .oscOut) }
                            Button("Inject Art-Net DMX Universe 0") { engine.injectTestProtocolPacket(type: .dmx) }
                            Button("Inject MSC Go Command") { engine.injectTestProtocolPacket(type: .msc) }
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 11.0 * scale))
                                .foregroundColor(engine.currentTheme.accentPrimary)
                                .padding(2)
                        }
                        .menuStyle(.borderlessButton)
                        .help("Inject mock protocol packet for testing")
                    }
                }

                // ROW 2: Status Telemetry Pill & Terminal Text Size Scaler
                HStack(spacing: 5) {
                    // Status pill
                    HStack(spacing: 3) {
                        Circle()
                            .fill(engine.isOSCListenerActive ? Color.green : Color.yellow)
                            .frame(width: 4.5, height: 4.5)
                        Text("UDP :\(engine.oscIncomingPort)")
                            .font(.system(size: 10 * scale, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.8))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 3.5))

                    Spacer(minLength: 4)

                    // Terminal Text Size Stepper & Preset Menu
                    HStack(spacing: 1.5) {
                        Button(action: {
                            engine.decreaseTerminalFontSize()
                            SoundEffect.knobTick.play(with: engine.soundPack)
                        }) {
                            Image(systemName: "textformat.size.smaller")
                                .font(.system(size: 9.5 * scale, weight: .bold))
                                .frame(width: 18 * scale, height: 17 * scale)
                                .background(Color.white.opacity(0.06))
                                .foregroundColor(engine.terminalFontSize <= 8.5 ? Color(white: 0.35) : Color(white: 0.85))
                        }
                        .buttonStyle(.plain)
                        .disabled(engine.terminalFontSize <= 8.5)
                        .help("Decrease terminal font size (⌥⌘-)")
                        .accessibilityLabel("Decrease terminal font size")

                        Menu {
                            Section("TERMINAL TEXT SIZE") {
                                Button("Tiny (8.5 pt)") { engine.setTerminalFontSize(8.5) }
                                Button("Compact (10 pt)") { engine.setTerminalFontSize(10.0) }
                                Button("Default (11.5 pt)") { engine.resetTerminalFontSize() }
                                Button("Medium (13 pt)") { engine.setTerminalFontSize(13.0) }
                                Button("Large (15 pt)") { engine.setTerminalFontSize(15.0) }
                                Button("Extra Large (18 pt)") { engine.setTerminalFontSize(18.0) }
                                Button("Huge (22 pt)") { engine.setTerminalFontSize(22.0) }
                            }
                            Divider()
                            Button("Reset to Default (11.5 pt)") { engine.resetTerminalFontSize() }
                        } label: {
                            HStack(spacing: 1.5) {
                                Text(String(format: "%.0fpt", engine.terminalFontSize))
                                    .font(.system(size: 9 * scale, weight: .bold, design: .monospaced))
                                    .foregroundColor(engine.currentTheme.accentPrimary)
                            }
                            .padding(.horizontal, 4)
                            .frame(height: 17 * scale)
                            .background(Color.white.opacity(0.08))
                        }
                        .menuStyle(.borderlessButton)
                        .help("Choose terminal text size")
                        .accessibilityLabel("Terminal text size menu, current \(Int(round(engine.terminalFontSize))) points")

                        Button(action: {
                            engine.increaseTerminalFontSize()
                            SoundEffect.knobTick.play(with: engine.soundPack)
                        }) {
                            Image(systemName: "textformat.size.larger")
                                .font(.system(size: 9.5 * scale, weight: .bold))
                                .frame(width: 18 * scale, height: 17 * scale)
                                .background(Color.white.opacity(0.06))
                                .foregroundColor(engine.terminalFontSize >= 22.0 ? Color(white: 0.35) : Color(white: 0.85))
                        }
                        .buttonStyle(.plain)
                        .disabled(engine.terminalFontSize >= 22.0)
                        .help("Increase terminal font size (⌥⌘+)")
                        .accessibilityLabel("Increase terminal text size")
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    .overlay(RoundedRectangle(cornerRadius: 3.5).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3.5)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            // Main Console Feed
            let filteredEvents = engine.protocolEvents.filter { event in
                switch engine.protocolFilter {
                case .all: return true
                case .midiIn, .midiOut: return event.type == .midiIn || event.type == .midiOut
                case .oscIn, .oscOut: return event.type == .oscIn || event.type == .oscOut
                case .dmx: return event.type == .dmx
                case .sys: return event.type == .sys || event.type == .msc
                case .msc: return event.type == .msc
                }
            }

            ZStack {
                Color.black.opacity(0.55)

                if filteredEvents.isEmpty {
                    VStack(spacing: 5) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: max(14, engine.terminalFontSize * 1.3) * scale))
                            .foregroundColor(engine.currentTheme.accentPrimary.opacity(0.5))
                        Text("LISTENING FOR PROTOCOL PACKETS...")
                            .font(.system(size: engine.terminalFontSize * scale, weight: .heavy, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                        Text("Send OSC to UDP :\(engine.oscIncomingPort) or trigger CoreMIDI")
                            .font(.system(size: max(8.5, (engine.terminalFontSize - 1.0)) * scale, design: .monospaced))
                            .foregroundColor(Color(white: 0.38))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.vertical], showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredEvents) { event in
                                protocolEventRow(for: event, scale: scale)
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 1))

            // Bottom Quick OSC Command / Packet Injector Bar
            HStack(spacing: 4) {
                Text("❯")
                    .font(.system(size: (engine.terminalFontSize + 1.0) * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.accentPrimary)

                TextField("/address [arg]...", text: $terminalQuickCommand)
                    .textFieldStyle(.plain)
                    .font(.system(size: engine.terminalFontSize * scale, design: .monospaced))
                    .foregroundColor(.white)
                    .onSubmit {
                        sendTerminalQuickCommand()
                    }

                Button("SEND") {
                    sendTerminalQuickCommand()
                }
                .font(.system(size: max(9, engine.terminalFontSize - 0.5) * scale, weight: .heavy, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(engine.currentTheme.accentPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 3.5))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(engine.currentTheme.accentPrimary.opacity(0.3), lineWidth: 0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // ------------------------------------------------------------------------
    // NETWORK TAB CONTENT (INTERFACES, ACTIVE RECEIVERS & TELEMETRY)
    // ------------------------------------------------------------------------
    private func protocolTerminalNetworkContent(scale: CGFloat) -> some View {
        ScrollView([.vertical], showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                networkInterfacesCard(scale: scale)
                activeReceiversCard(scale: scale)
                telemetryCountersRow(scale: scale)
                networkActionButtonsRow(scale: scale)
            }
            .padding(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .layoutPriority(1)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func networkInterfacesCard(scale: CGFloat) -> some View {
        let interfaces = getLocalNetworkInterfaces()

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 13.5 * scale, weight: .bold))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                Text("HOST NETWORK INTERFACES")
                    .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Text("TARGET IP ADDRESSES")
                    .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.5))
            }

            ForEach(interfaces) { iface in
                HStack {
                    Circle()
                        .fill(iface.isLoopback ? Color.blue : Color.green)
                        .frame(width: 5 * scale, height: 5 * scale)
                    Text(iface.name)
                        .font(.system(size: 12.0 * scale, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(white: 0.8))
                    Spacer()
                    Text(iface.ip)
                        .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(iface.ip, forType: .string)
                        SoundEffect.keyTap.play(with: engine.soundPack)
                        engine.log("📋 Copied \(iface.ip) to clipboard")
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11.5 * scale))
                            .foregroundColor(Color(white: 0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Copy IP to clipboard")
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background(Color.white.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 3.5))
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(engine.currentTheme.accentPrimary.opacity(0.25), lineWidth: 0.8))
    }

    private func activeReceiversCard(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 13.5 * scale, weight: .bold))
                    .foregroundColor(Color(red: 0.96, green: 0.76, blue: 0.18))
                Text("ACTIVE PROTOCOL RECEIVERS")
                    .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
            }

            networkProtocolStatusRow(
                title: "OSC UDP RECEIVER",
                badge: engine.isOSCListenerActive ? "ONLINE" : "READY",
                badgeColor: engine.isOSCListenerActive ? .green : .yellow,
                details: "IP: \(engine.oscIncomingHost) | Port: \(engine.oscIncomingPort)",
                packets: "\(engine.oscPacketsCount) pkts",
                scale: scale
            )

            networkProtocolStatusRow(
                title: "CORE MIDI RECEIVER",
                badge: engine.isConnected ? "HARDWARE ONLINE" : "LISTENING",
                badgeColor: engine.isConnected ? .green : Color(red: 0.2, green: 0.8, blue: 1.0),
                details: "Dev: \(engine.selectedMIDIInputDevice) | \(engine.selectedMIDIInputChannel == 0 ? "Omni (All Ch)" : "Ch \(engine.selectedMIDIInputChannel)")",
                packets: "\(engine.midiPacketsCount) msgs",
                scale: scale
            )

            networkProtocolStatusRow(
                title: "ART-NET 4 DMX",
                badge: engine.isArtNetListenerActive ? "ONLINE" : "READY",
                badgeColor: engine.isArtNetListenerActive ? .green : .yellow,
                details: "IP: \(engine.artNetIncomingHost) | Port: \(engine.artNetIncomingPort) | Univ: \(engine.artNetIncomingUniverse)",
                packets: "\(engine.dmxPacketsCount) frames",
                scale: scale
            )

            networkProtocolStatusRow(
                title: "sACN ANSI E1.31",
                badge: engine.issACNListenerActive ? "ONLINE" : "READY",
                badgeColor: engine.issACNListenerActive ? .green : .yellow,
                details: "Port: \(engine.sacnIncomingPort) | Univ: \(engine.sacnIncomingUniverse)",
                packets: "\(engine.dmxPacketsCount) frames",
                scale: scale
            )

            networkProtocolStatusRow(
                title: "MIDI SHOW CONTROL (MSC)",
                badge: "ACTIVE",
                badgeColor: Color(red: 0.85, green: 0.45, blue: 1.0),
                details: "Dev ID: \(engine.mscDeviceID) | Format: \(engine.mscCommandFormat.rawValue)",
                packets: "\(engine.mscPacketsCount) cues",
                scale: scale
            )
        }
        .padding(6)
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
    }

    private func telemetryCountersRow(scale: CGFloat) -> some View {
        HStack(spacing: 4) {
            telemetryCounterPill(title: "TOTAL RX", value: "\(engine.totalPacketsReceived)", color: engine.currentTheme.accentPrimary, scale: scale)
            telemetryCounterPill(title: "MIDI RX", value: "\(engine.midiPacketsCount)", color: Color(red: 0.2, green: 0.95, blue: 0.5), scale: scale)
            telemetryCounterPill(title: "OSC RX", value: "\(engine.oscPacketsCount)", color: Color(red: 1.0, green: 0.65, blue: 0.2), scale: scale)
            telemetryCounterPill(title: "DMX RX", value: "\(engine.dmxPacketsCount)", color: Color(red: 0.95, green: 0.85, blue: 0.25), scale: scale)
            telemetryCounterPill(title: "MSC RX", value: "\(engine.mscPacketsCount)", color: Color(red: 0.45, green: 0.75, blue: 1.0), scale: scale)
        }
    }

    private func networkActionButtonsRow(scale: CGFloat) -> some View {
        HStack(spacing: 4) {
            Button(action: {
                engine.terminalTab = .settings
                SoundEffect.keyTap.play(with: engine.soundPack)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12.5 * scale, weight: .bold))
                    Text("CONFIGURE RECEIVING PORTS & DEVICES")
                        .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(engine.currentTheme.accentPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)

            Button(action: {
                engine.scanForBitchBoy()
                SoundEffect.keyTap.play(with: engine.soundPack)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12.5 * scale, weight: .bold))
                    Text("RE-SCAN")
                        .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
    }

    private func networkProtocolStatusRow(title: String, badge: String, badgeColor: Color, details: String, packets: String, scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Text(badge)
                    .font(.system(size: 11.0 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(badgeColor)
                    .clipShape(RoundedRectangle(cornerRadius: 2.5))
            }
            HStack {
                Text(details)
                    .font(.system(size: 11.5 * scale, design: .monospaced))
                    .foregroundColor(Color(white: 0.7))
                Spacer()
                Text(packets)
                    .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                    .foregroundColor(badgeColor)
            }
        }
        .padding(4.5)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func telemetryCounterPill(title: String, value: String, color: Color, scale: CGFloat) -> some View {
        VStack(spacing: 1.5) {
            Text(title)
                .font(.system(size: 10.5 * scale, weight: .bold, design: .monospaced))
                .foregroundColor(Color(white: 0.55))
            Text(value)
                .font(.system(size: 13.5 * scale, weight: .heavy, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.35), lineWidth: 0.8))
    }

    // ------------------------------------------------------------------------
    // SETTINGS TAB CONTENT (DECOMPOSED CARDS FOR MAXIMUM COMPILER EFFICIENCY)
    // ------------------------------------------------------------------------
    private func protocolTerminalSettingsContent(scale: CGFloat) -> some View {
        ScrollView([.vertical], showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                settingsTopHeader(scale: scale)
                performanceAndRefreshSettingsCard(scale: scale)
                undoMemorySettingsCard(scale: scale)
                terminalDisplaySettingsCard(scale: scale)
                oscSettingsCard(scale: scale)
                midiSettingsCard(scale: scale)
                artNetSettingsCard(scale: scale)
                sacnSettingsCard(scale: scale)
                mscSettingsCard(scale: scale)
                settingsBottomSaveButton(scale: scale)
            }
            .padding(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .layoutPriority(1)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func performanceAndRefreshSettingsCard(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                Text("PROMOTION 120 FPS & GRAPHICS PERFORMANCE")
                    .font(.system(size: 11 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)
                Spacer()
                Text("\(engine.targetFPS) FPS")
                    .font(.system(size: 10 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.targetFPS == 120 ? Color(red: 0.2, green: 0.95, blue: 0.5) : Color.cyan)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Capsule())
            }

            Text("Ultra-smooth high refresh rate ProMotion rendering for reactive key shockwaves and procedural lighting, with intelligent USB MIDI rate-limiting to preserve hardware throughput.")
                .font(.system(size: 9.5 * scale, weight: .regular, design: .monospaced))
                .foregroundColor(Color(white: 0.70))

            HStack(spacing: 8) {
                Button(action: {
                    engine.setTargetFPS(120)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: engine.targetFPS == 120 ? "checkmark.circle.fill" : "circle")
                        Text("120 FPS // ProMotion Ultra")
                    }
                    .font(.system(size: 10.5 * scale, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(engine.targetFPS == 120 ? Color(red: 0.12, green: 0.35, blue: 0.20) : Color.white.opacity(0.08))
                    .foregroundColor(engine.targetFPS == 120 ? Color(red: 0.3, green: 0.98, blue: 0.6) : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)

                Button(action: {
                    engine.setTargetFPS(60)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: engine.targetFPS == 60 ? "checkmark.circle.fill" : "circle")
                        Text("60 FPS // Standard (Power Saver)")
                    }
                    .font(.system(size: 10.5 * scale, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(engine.targetFPS == 60 ? Color.cyan.opacity(0.25) : Color.white.opacity(0.08))
                    .foregroundColor(engine.targetFPS == 60 ? Color.cyan : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                    Text("LIVE FPS: \(String(format: "%.1f", engine.measuredFPS))")
                        .font(.system(size: 9 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.green)
                }
                HStack(spacing: 4) {
                    Text("FRAME LATENCY: \(String(format: "%.2f", engine.frameLatencyMs)) ms")
                        .font(.system(size: 9 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.65))
                }
                HStack(spacing: 4) {
                    Text("HARDWARE BUS: 60Hz THROTTLED")
                        .font(.system(size: 9 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.65))
                }
            }
            .padding(.top, 2)
        }
        .padding(8)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private func undoMemorySettingsCard(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                Text("UNDO STEPS MEMORY & RECOVERY")
                    .font(.system(size: 11 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)
                Spacer()
                Text("\(engine.undoStepsCount) / \(engine.maxUndoSteps) STEPS")
                    .font(.system(size: 10 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Capsule())
            }

            Text("Deep snapshot buffer allows rolling back any control customization, LED velocity, macro, or FX frame changes.")
                .font(.system(size: 9.5 * scale, weight: .regular, design: .monospaced))
                .foregroundColor(Color(white: 0.70))

            HStack(spacing: 8) {
                Text("BUFFER LIMIT:")
                    .font(.system(size: 10 * scale, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.75))

                Slider(value: Binding(
                    get: { Double(engine.maxUndoSteps) },
                    set: {
                        engine.maxUndoSteps = Int($0)
                        UserDefaults.standard.set(engine.maxUndoSteps, forKey: "BitchBoy_MaxUndoSteps_v1")
                    }
                ), in: 10...200, step: 10)
                .tint(engine.currentTheme.accentPrimary)

                Text("\(engine.maxUndoSteps)")
                    .font(.system(size: 11 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .frame(width: 35, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Button(action: {
                    engine.undo()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("UNDO (⌘Z)")
                    }
                    .font(.system(size: 10 * scale, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(engine.canUndo ? 0.12 : 0.04))
                    .foregroundColor(engine.canUndo ? .white : Color.white.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(!engine.canUndo)

                Button(action: {
                    engine.redo()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.forward")
                        Text("REDO (⇧⌘Z)")
                    }
                    .font(.system(size: 10 * scale, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(engine.canRedo ? 0.12 : 0.04))
                    .foregroundColor(engine.canRedo ? .white : Color.white.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(!engine.canRedo)

                Spacer()

                Button(action: {
                    engine.clearUndoHistory()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash.fill")
                        Text("CLEAR HISTORY")
                    }
                    .font(.system(size: 9.5 * scale, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.20))
                    .foregroundColor(Color(red: 1, green: 0.55, blue: 0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(!engine.canUndo && !engine.canRedo)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private func terminalDisplaySettingsCard(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "textformat.size")
                    .foregroundColor(Color(red: 0.98, green: 0.78, blue: 0.25))
                Text("TERMINAL TEXT & DISPLAY SETTINGS")
                    .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Text(String(format: "%.1f pt", engine.terminalFontSize))
                    .font(.system(size: 11.5 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
            }

            Text("Adjust font size of incoming protocol packets (MIDI, OSC, DMX, SYS) and outgoing prompt commands:")
                .font(.system(size: 10.5 * scale, design: .monospaced))
                .foregroundColor(Color(white: 0.65))

            HStack(spacing: 8) {
                Text("A").font(.system(size: 9.5 * scale, weight: .bold)).foregroundColor(Color(white: 0.6))
                Slider(value: Binding(
                    get: { engine.terminalFontSize },
                    set: { engine.setTerminalFontSize($0) }
                ), in: 8.5...22.0, step: 0.5)
                .tint(engine.currentTheme.accentPrimary)
                Text("A").font(.system(size: 16.0 * scale, weight: .bold)).foregroundColor(.white)

                Button("DEFAULT") {
                    engine.resetTerminalFontSize()
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }
                .font(.system(size: 10.0 * scale, weight: .heavy, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(engine.currentTheme.accentPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 3.5))
                .buttonStyle(.plain)
            }

            // Quick preset pills
            HStack(spacing: 3) {
                Text("PRESETS:")
                    .font(.system(size: 10.0 * scale, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.5))
                ForEach([(8.5, "Tiny 8.5pt"), (10.0, "Compact 10pt"), (11.5, "Default 11.5pt"), (13.5, "Medium 13.5pt"), (16.0, "Large 16pt"), (18.0, "X-Large 18pt")], id: \.0) { sizeVal, label in
                    Button(action: {
                        engine.setTerminalFontSize(CGFloat(sizeVal))
                        SoundEffect.keyTap.play(with: engine.soundPack)
                    }) {
                        Text(label)
                            .font(.system(size: 9.5 * scale, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(abs(engine.terminalFontSize - CGFloat(sizeVal)) < 0.25 ? engine.currentTheme.accentPrimary.opacity(0.3) : Color.white.opacity(0.06))
                            .foregroundColor(abs(engine.terminalFontSize - CGFloat(sizeVal)) < 0.25 ? engine.currentTheme.accentPrimary : Color(white: 0.75))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Live Preview Box
            VStack(alignment: .leading, spacing: 3) {
                Text("LIVE TERMINAL PREVIEW:")
                    .font(.system(size: 9.5 * scale, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.5))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("13:40:12.000")
                            .font(.system(size: max(8, engine.terminalFontSize - 0.5) * scale, design: .monospaced))
                            .foregroundColor(Color(white: 0.45))
                            .frame(width: max(58 * scale, engine.terminalFontSize * scale * 6.5), alignment: .leading)
                        Text("MIDI OUT")
                            .font(.system(size: max(8, engine.terminalFontSize - 0.5) * scale, weight: .heavy, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1)
                            .background(Color(red: 0.2, green: 0.95, blue: 0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 2.5))
                            .frame(width: max(48 * scale, engine.terminalFontSize * scale * 5.0), alignment: .leading)
                        Text("CC #5 Value: 127")
                            .font(.system(size: engine.terminalFontSize * scale, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.2, green: 0.95, blue: 0.85))
                        Spacer()
                        Text("B0 05 7F")
                            .font(.system(size: max(7.5, engine.terminalFontSize - 1.0) * scale, design: .monospaced))
                            .foregroundColor(Color(white: 0.38))
                    }
                    HStack(spacing: 4) {
                        Text("❯")
                            .font(.system(size: (engine.terminalFontSize + 1.0) * scale, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                        Text("/qlab/cue/1/start")
                            .font(.system(size: engine.terminalFontSize * scale, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
                .padding(5)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.1), lineWidth: 0.8))
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 0.98, green: 0.78, blue: 0.25).opacity(0.3), lineWidth: 0.8))
    }

    private func settingsTopHeader(scale: CGFloat) -> some View {
        HStack {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13.5 * scale, weight: .bold))
                .foregroundColor(Color(red: 0.96, green: 0.76, blue: 0.18))
            Text("PROTOCOL RECEIVING CONFIGURATION")
                .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                .foregroundColor(.white)
            Spacer()
            Button(action: {
                engine.terminalTab = .console
                SoundEffect.keyTap.play(with: engine.soundPack)
            }) {
                Text("DONE")
                    .font(.system(size: 11.5 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    private func oscSettingsCard(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "wave.3.forward.circle.fill")
                    .foregroundColor(Color(red: 1.0, green: 0.65, blue: 0.2))
                Text("1. OSC (OPEN SOUND CONTROL) RECEIVER")
                    .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Circle()
                    .fill(engine.isOSCListenerActive ? Color.green : Color.yellow)
                    .frame(width: 5, height: 5)
            }

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECEIVING PORT:")
                        .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("8000", value: Binding(get: { Int(engine.oscIncomingPort) }, set: { engine.oscIncomingPort = UInt16(clamping: $0) }), formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5 * scale, design: .monospaced))
                        .frame(width: 75 * scale)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("RECEIVING IP / BIND HOST:")
                        .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("0.0.0.0 (All Interfaces)", text: $engine.oscIncomingHost)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5 * scale, design: .monospaced))
                }
            }

            HStack(spacing: 3) {
                Text("PRESETS:")
                    .font(.system(size: 11.0 * scale, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.5))
                ForEach([(8000, "8000 (Default)"), (53000, "53000 (QLab)"), (9000, "9000 (Resolume)"), (7000, "7000 (TouchOSC)")], id: \.0) { portVal, label in
                    Button(action: {
                        engine.oscIncomingPort = UInt16(portVal)
                        engine.startOSCListener(port: UInt16(portVal), host: engine.oscIncomingHost)
                        SoundEffect.keyTap.play(with: engine.soundPack)
                    }) {
                        Text(label)
                            .font(.system(size: 11.0 * scale, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(engine.oscIncomingPort == UInt16(portVal) ? Color(red: 1.0, green: 0.65, blue: 0.2).opacity(0.3) : Color.white.opacity(0.06))
                            .foregroundColor(engine.oscIncomingPort == UInt16(portVal) ? Color(red: 1.0, green: 0.65, blue: 0.2) : Color(white: 0.75))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button(action: {
                engine.updateOSCReceiver(port: engine.oscIncomingPort, host: engine.oscIncomingHost)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                    Text("APPLY & RESTART OSC LISTENER")
                }
                .font(.system(size: 11.5 * scale, weight: .heavy, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(red: 1.0, green: 0.65, blue: 0.2))
                .clipShape(RoundedRectangle(cornerRadius: 3.5))
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 1.0, green: 0.65, blue: 0.2).opacity(0.3), lineWidth: 0.8))
    }

    private func midiSettingsCard(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "pianokeys.fill")
                    .foregroundColor(Color(red: 0.2, green: 0.95, blue: 0.5))
                Text("2. CORE MIDI RECEIVING DEVICE & CHANNEL")
                    .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Circle()
                    .fill(engine.isConnected ? Color.green : Color.yellow)
                    .frame(width: 5, height: 5)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("RECEIVING MIDI INPUT DEVICE:")
                    .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                Picker("", selection: $engine.selectedMIDIInputDevice) {
                    Text("OMNI // ALL CONNECTED MIDI DEVICES").tag("ALL")
                    Text("AUTO-DETECT (BITCHBOY HARDWARE ONLY)").tag("AUTO")
                    ForEach(engine.availableInputSources, id: \.self) { srcName in
                        Text(srcName).tag(srcName)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: engine.selectedMIDIInputDevice) { _, newDev in
                    engine.updateMIDIReceiver(device: newDev, channel: engine.selectedMIDIInputChannel)
                }
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECEIVING CHANNEL:")
                        .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    Picker("", selection: $engine.selectedMIDIInputChannel) {
                        Text("OMNI (ALL CHANNELS)").tag(0)
                        ForEach(1...16, id: \.self) { ch in
                            Text("CHANNEL \(ch)").tag(ch)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140 * scale)
                    .onChange(of: engine.selectedMIDIInputChannel) { _, newCh in
                        engine.updateMIDIReceiver(device: engine.selectedMIDIInputDevice, channel: newCh)
                    }
                }

                Spacer()

                Button(action: {
                    engine.scanForBitchBoy()
                    SoundEffect.keyTap.play(with: engine.soundPack)
                    engine.log("🔄 Scanned CoreMIDI: \(engine.availableInputSources.count) input sources available")
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("RE-SCAN MIDI")
                    }
                    .font(.system(size: 11.5 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.2, green: 0.95, blue: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 0.2, green: 0.95, blue: 0.5).opacity(0.3), lineWidth: 0.8))
    }

    private func artNetSettingsCard(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(Color(red: 0.95, green: 0.85, blue: 0.25))
                Text("3. ART-NET 4 DMX RECEIVER")
                    .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Toggle("", isOn: $engine.isArtNetListenerActive)
                    .toggleStyle(.switch)
                    .scaleEffect(0.65)
                    .onChange(of: engine.isArtNetListenerActive) { _, active in
                        if active {
                            engine.startArtNetListener(port: engine.artNetIncomingPort)
                        } else {
                            engine.stopArtNetListener()
                        }
                    }
            }

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECEIVING UDP PORT:")
                        .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("6454", value: Binding(get: { Int(engine.artNetIncomingPort) }, set: { engine.artNetIncomingPort = UInt16(clamping: $0) }), formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5 * scale, design: .monospaced))
                        .frame(width: 75 * scale)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("RECEIVING IP / BIND:")
                        .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("0.0.0.0", text: $engine.artNetIncomingHost)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5 * scale, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("UNIVERSE:")
                        .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("0", value: Binding(get: { Int(engine.artNetIncomingUniverse) }, set: { engine.artNetIncomingUniverse = UInt16(clamping: $0) }), formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5 * scale, design: .monospaced))
                        .frame(width: 50 * scale)
                }
            }

            Button(action: {
                engine.updateArtNetReceiver(port: engine.artNetIncomingPort, host: engine.artNetIncomingHost, universe: engine.artNetIncomingUniverse)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                    Text("APPLY & RESTART ART-NET LISTENER")
                }
                .font(.system(size: 11.5 * scale, weight: .heavy, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(red: 0.95, green: 0.85, blue: 0.25))
                .clipShape(RoundedRectangle(cornerRadius: 3.5))
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 0.95, green: 0.85, blue: 0.25).opacity(0.3), lineWidth: 0.8))
    }

    private func sacnSettingsCard(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(Color(red: 0.3, green: 0.85, blue: 1.0))
                Text("4. sACN (ANSI E1.31) RECEIVER")
                    .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Toggle("", isOn: $engine.issACNListenerActive)
                    .toggleStyle(.switch)
                    .scaleEffect(0.65)
                    .onChange(of: engine.issACNListenerActive) { _, active in
                        if active {
                            engine.startsACNListener(port: engine.sacnIncomingPort)
                        } else {
                            engine.stopsACNListener()
                        }
                    }
            }

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECEIVING UDP PORT:")
                        .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("5568", value: Binding(get: { Int(engine.sacnIncomingPort) }, set: { engine.sacnIncomingPort = UInt16(clamping: $0) }), formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5 * scale, design: .monospaced))
                        .frame(width: 75 * scale)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("MULTICAST / UNICAST IP:")
                        .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("0.0.0.0 (All Multicast)", text: $engine.sacnIncomingHost)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5 * scale, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("UNIVERSE:")
                        .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("1", value: Binding(get: { Int(engine.sacnIncomingUniverse) }, set: { engine.sacnIncomingUniverse = UInt16(clamping: $0) }), formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5 * scale, design: .monospaced))
                        .frame(width: 50 * scale)
                }
            }

            Button(action: {
                engine.updatesACNReceiver(port: engine.sacnIncomingPort, host: engine.sacnIncomingHost, universe: engine.sacnIncomingUniverse)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                    Text("APPLY & RESTART sACN LISTENER")
                }
                .font(.system(size: 11.5 * scale, weight: .heavy, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(red: 0.3, green: 0.85, blue: 1.0))
                .clipShape(RoundedRectangle(cornerRadius: 3.5))
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 0.3, green: 0.85, blue: 1.0).opacity(0.3), lineWidth: 0.8))
    }

    private func mscSettingsCard(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "theatermasks.fill")
                    .foregroundColor(Color(red: 0.85, green: 0.45, blue: 1.0))
                Text("5. MSC (MIDI SHOW CONTROL) RECEIVER")
                    .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECEIVING DEVICE ID (0..127):")
                        .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    Picker("", selection: $engine.mscDeviceID) {
                        Text("1 (Default)").tag(UInt8(1))
                        ForEach(0..<16) { id in
                            if id != 1 {
                                Text("\(id)").tag(UInt8(id))
                            }
                        }
                        Text("127 (All)").tag(UInt8(127))
                    }
                    .pickerStyle(.menu)
                    .frame(width: 90 * scale)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("COMMAND FORMAT:")
                        .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    Picker("", selection: $engine.mscCommandFormat) {
                        ForEach(MSCCommandFormat.allCases) { fmt in
                            Text(fmt.label).tag(fmt)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            Toggle(isOn: $engine.mscAutoTriggerOnInbound) {
                Text("Auto-Trigger Cues on Incoming MSC Commands")
                    .font(.system(size: 11.5 * scale, design: .monospaced))
                    .foregroundColor(Color(white: 0.8))
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 0.85, green: 0.45, blue: 1.0).opacity(0.3), lineWidth: 0.8))
    }

    private func settingsBottomSaveButton(scale: CGFloat) -> some View {
        Button(action: {
            engine.saveProtocolSettings()
            engine.terminalTab = .console
            SoundEffect.presetSwitch.play(with: engine.soundPack)
            engine.log("💾 All Protocol Receiving Settings Saved & Applied")
        }) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text("SAVE & APPLY ALL PROTOCOL SETTINGS")
            }
            .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(engine.currentTheme.accentPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 4.5))
        }
        .buttonStyle(.plain)
    }


    private static let protocolTimestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    private func protocolEventRow(for event: ProtocolEvent, scale: CGFloat) -> some View {
        let timeStr = Self.protocolTimestampFormatter.string(from: event.timestamp)
        let baseFontSize = engine.terminalFontSize * scale
        let timestampWidth = max(58 * scale, baseFontSize * 6.5)
        let badgeWidth = max(48 * scale, baseFontSize * 5.0)

        return HStack(alignment: .center, spacing: 4) {
            // Timestamp
            Text(timeStr)
                .font(.system(size: max(8, baseFontSize - 0.5), weight: .regular, design: .monospaced))
                .foregroundColor(Color(white: 0.45))
                .lineLimit(1)
                .frame(width: timestampWidth, alignment: .leading)

            // Protocol Type Badge
            Text(event.type.rawValue)
                .font(.system(size: max(8, baseFontSize - 0.5), weight: .heavy, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 3.5)
                .padding(.vertical, 1)
                .background(event.type.tagColor)
                .clipShape(RoundedRectangle(cornerRadius: 2.5))
                .frame(width: badgeWidth, alignment: .leading)

            // Command / Address
            Text(event.command)
                .font(.system(size: baseFontSize, weight: .bold, design: .monospaced))
                .foregroundColor(event.type.tagColor)
                .lineLimit(1)

            // Details / Args
            if !event.details.isEmpty {
                Text(event.details)
                    .font(.system(size: max(8, baseFontSize - 0.5), design: .monospaced))
                    .foregroundColor(Color(white: 0.72))
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            // Raw Hex preview
            if !event.rawHex.isEmpty {
                Text(event.rawHex)
                    .font(.system(size: max(7.5, baseFontSize - 1.0), weight: .medium, design: .monospaced))
                    .foregroundColor(Color(white: 0.38))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, max(1.5, (baseFontSize - 10) * 0.25))
        .padding(.horizontal, 3)
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func sendTerminalQuickCommand() {
        let trimmed = terminalQuickCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.starts(with: "/") {
            engine.sendOSC(host: engine.customOSCHost, port: engine.customOSCPort, address: trimmed)
        } else if trimmed.lowercased().starts(with: "note") {
            let parts = trimmed.split(separator: " ")
            let noteNum = parts.count > 1 ? (UInt8(parts[1]) ?? 60) : 60
            let vel = parts.count > 2 ? (UInt8(parts[2]) ?? 100) : 100
            engine.sendNoteOn(note: noteNum, velocity: vel)
        } else {
            engine.recordProtocolEvent(type: .sys, command: "USER COMMAND", details: trimmed, rawHex: "", channel: "Prompt")
        }
        terminalQuickCommand = ""
        SoundEffect.keyTap.play(with: engine.soundPack)
    }


    // ------------------------------------------------------------------------
    // HARDWARE STUDIO MODULE PANELS (BUTTONS, KNOBS, FADERS & COLOR PICKER HUD)
    // ------------------------------------------------------------------------

    private func keyGridStudioPanel(isSpotlight: Bool = false) -> some View {
        let scale: CGFloat = currentScale(for: .keyGrid8x4, isSpotlight: isSpotlight)
        return VStack(alignment: .leading, spacing: 6) {
            if !isSpotlight && standaloneModule == nil {
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.4x3.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                        Text("8X4 KEY GRID")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Circle()
                            .fill(engine.currentTheme.accentPrimary)
                            .frame(width: 5, height: 5)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { engine.toggleSpotlightModule(.keyGrid8x4) }

                    Spacer(minLength: 2)

                    moduleHeaderControls(for: .keyGrid8x4)
                }
                .padding(.vertical, 2.5)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            // Quick Actions Bar (Select All / Deselect / Color Swatches)
            HStack(spacing: 4) {
                Button(action: {
                    engine.selectedIndices = Set(0..<32)
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }) {
                    Text("SELECT ALL 32")
                        .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                }
                .buttonStyle(.plain)

                Button(action: {
                    engine.selectedIndices.removeAll()
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }) {
                    Text("DESELECT")
                        .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(Color(white: 0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 2)

                // Quick Color Swatches
                HStack(spacing: 3) {
                    ForEach([0, 3, 33, 41, 67, 72, 87, 57], id: \.self) { vel in
                        Circle()
                            .fill(ledColor(UInt8(vel)))
                            .frame(width: 10 * scale, height: 10 * scale)
                            .onTapGesture {
                                let targets = engine.selectedIndices.isEmpty ? Array(0..<32) : Array(engine.selectedIndices.filter { $0 < 32 })
                                for idx in targets {
                                    engine.controls[idx].activeVelocity = UInt8(vel)
                                    engine.controls[idx].idleVelocity = UInt8(vel)
                                    engine.controls[idx].currentLED = UInt8(vel)
                                    engine.sendNoteOn(note: engine.controls[idx].number, velocity: UInt8(vel))
                                }
                                engine.saveCurrentSlot()
                                SoundEffect.knobTick.play(with: engine.soundPack)
                            }
                    }
                }
            }
            .padding(.horizontal, 4)

            // The 8x4 Grid
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { r in
                        HStack(spacing: 4) {
                            ForEach(0..<8, id: \.self) { c in
                                let idx = r * 8 + c
                                HardwareKeyCap(
                                    item: engine.controls[idx],
                                    isSelected: engine.selectedIndices.contains(idx) || engine.selectedIndex == idx,
                                    color: ledColor(engine.controls[idx].currentLED),
                                    sectionBorder: engine.currentTheme.sectionOutline,
                                    onTap: {
                                        isEditingNameBox = false
                                        let isShift = NSEvent.modifierFlags.contains(.shift)
                                        engine.handleKeyPressWithModifiers(index: idx, isShiftDown: isShift)
                                    }
                                )
                                .equatable()
                                .contextMenu { controlContextMenu(for: idx) }
                            }
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Color(red: 0.08, green: 0.04, blue: 0.04).opacity(0.85))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(engine.currentTheme.sectionOutline.opacity(0.85), lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func keyStripStudioPanel(isSpotlight: Bool = false) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
            if !isSpotlight && standaloneModule == nil {
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.split.3x1.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                        Text("1X8 KEY STRIP")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Circle()
                            .fill(engine.currentTheme.accentPrimary)
                            .frame(width: 5, height: 5)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { engine.toggleSpotlightModule(.keyStrip1x8) }

                    Spacer(minLength: 2)

                    moduleHeaderControls(for: .keyStrip1x8)
                }
                .padding(.vertical, 2.5)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            ScrollView([.horizontal], showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(32..<40, id: \.self) { idx in
                        HardwareKeyCap(
                            item: engine.controls[idx],
                            isSelected: engine.selectedIndices.contains(idx) || engine.selectedIndex == idx,
                            color: ledColor(engine.controls[idx].currentLED),
                            sectionBorder: engine.currentTheme.sectionOutline,
                            onTap: {
                                isEditingNameBox = false
                                let isShift = NSEvent.modifierFlags.contains(.shift)
                                engine.handleKeyPressWithModifiers(index: idx, isShiftDown: isShift)
                            }
                        )
                        .equatable()
                                .contextMenu { controlContextMenu(for: idx) }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Color(red: 0.08, green: 0.04, blue: 0.04).opacity(0.85))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(engine.currentTheme.sectionOutline.opacity(0.85), lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func verticalFadersStudioPanel(isSpotlight: Bool = false) -> some View {
        let scale: CGFloat = currentScale(for: .verticalFaders, isSpotlight: isSpotlight)
        return VStack(alignment: .leading, spacing: 6) {
            if !isSpotlight && standaloneModule == nil {
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.vertical.3")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                        Text("8 VERTICAL FADERS")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Circle()
                            .fill(engine.currentTheme.accentPrimary)
                            .frame(width: 5, height: 5)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { engine.toggleSpotlightModule(.verticalFaders) }

                    Spacer(minLength: 2)

                    moduleHeaderControls(for: .verticalFaders)
                }
                .padding(.vertical, 2.5)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            // Quick Fader Actions: Zero All / Center All / Full / VU Meter
            HStack(spacing: 4) {
                Button(action: {
                    for idx in 49..<57 { engine.setControlLiveValue(index: idx, value: 0) }
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }) {
                    Text("ZERO ALL (0)")
                        .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                }
                .buttonStyle(.plain)

                Button(action: {
                    for idx in 49..<57 { engine.setControlLiveValue(index: idx, value: 64) }
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }) {
                    Text("CENTER (64)")
                        .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                }
                .buttonStyle(.plain)

                Button(action: {
                    for idx in 49..<57 { engine.setControlLiveValue(index: idx, value: 127) }
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }) {
                    Text("FULL (127)")
                        .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 2)

                Button(action: {
                    engine.vuMeterLEDsEnabled.toggle()
                    if engine.vuMeterLEDsEnabled {
                        engine.applyFXMode(.vuMeter)
                    } else {
                        engine.applyFXMode(.staticFX)
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "slider.vertical.3")
                        Text(engine.vuMeterLEDsEnabled ? "VU: ON" : "VU: OFF")
                    }
                    .font(.system(size: 12.0 * scale, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color.black.opacity(0.5))
                    .foregroundColor(engine.vuMeterLEDsEnabled ? Color(red: 0.22, green: 0.96, blue: 0.76) : Color(white: 0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)

            ScrollView([.horizontal], showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(49..<57, id: \.self) { idx in
                        HardwareVerticalFader(
                            item: engine.controls[idx],
                            isSelected: engine.selectedIndex == idx,
                            onSelect: { engine.selectedIndex = idx },
                            onValueChange: { val in engine.setControlLiveValue(index: idx, value: val) }
                        )
                        .equatable()
                                .contextMenu { controlContextMenu(for: idx) }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func horizontalFadersStudioPanel(isSpotlight: Bool = false) -> some View {
        let scale: CGFloat = currentScale(for: .horizontalFaders, isSpotlight: isSpotlight)
        return VStack(alignment: .leading, spacing: 6) {
            if !isSpotlight && standaloneModule == nil {
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.below.rectangle")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                        Text("4 HORIZONTAL FADERS")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Circle()
                            .fill(engine.currentTheme.accentPrimary)
                            .frame(width: 5, height: 5)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { engine.toggleSpotlightModule(.horizontalFaders) }

                    Spacer(minLength: 2)

                    moduleHeaderControls(for: .horizontalFaders)
                }
                .padding(.vertical, 2.5)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            HStack(spacing: 4) {
                Button("ZERO ALL (0)") {
                    for idx in 57..<61 { engine.setControlLiveValue(index: idx, value: 0) }
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Color.white.opacity(0.12))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 3.5))

                Button("CENTER (64)") {
                    for idx in 57..<61 { engine.setControlLiveValue(index: idx, value: 64) }
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Color.white.opacity(0.12))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 3.5))

                Spacer()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 3) {
                ForEach(57..<61, id: \.self) { idx in
                    HardwareHorizontalFader(
                        item: engine.controls[idx],
                        isSelected: engine.selectedIndex == idx,
                        onSelect: { engine.selectedIndex = idx },
                        onValueChange: { val in engine.setControlLiveValue(index: idx, value: val) }
                    )
                    .equatable()
                                .contextMenu { controlContextMenu(for: idx) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(engine.currentTheme.sectionOutline.opacity(0.85), lineWidth: 1.2)
            )
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func rotaryKnobsStudioPanel(isSpotlight: Bool = false) -> some View {
        let scale: CGFloat = currentScale(for: .rotaryKnobs, isSpotlight: isSpotlight)
        return VStack(alignment: .leading, spacing: 6) {
            if !isSpotlight && standaloneModule == nil {
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "dial.low.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                        Text("2X4 ROTARY KNOBS")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Circle()
                            .fill(engine.currentTheme.accentPrimary)
                            .frame(width: 5, height: 5)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { engine.toggleSpotlightModule(.rotaryKnobs) }

                    Spacer(minLength: 2)

                    moduleHeaderControls(for: .rotaryKnobs)
                }
                .padding(.vertical, 2.5)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            HStack(spacing: 4) {
                Button("CENTER ALL (64)") {
                    for idx in 61..<69 { engine.setControlLiveValue(index: idx, value: 64) }
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Color.white.opacity(0.12))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 3.5))

                Button("ZERO ALL (0)") {
                    for idx in 61..<69 { engine.setControlLiveValue(index: idx, value: 0) }
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Color.white.opacity(0.12))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 3.5))

                Spacer()
            }
            .padding(.horizontal, 4)

            ScrollView([.vertical], showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { r in
                        HStack(spacing: 8) {
                            ForEach(0..<2, id: \.self) { c in
                                let idx = 61 + r * 2 + c
                                HardwareKnob(
                                    item: engine.controls[idx],
                                    isSelected: engine.selectedIndex == idx,
                                    onSelect: { engine.selectedIndex = idx },
                                    onValueChange: { val in engine.setControlLiveValue(index: idx, value: val) }
                                )
                                .equatable()
                                .contextMenu { controlContextMenu(for: idx) }
                            }
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func keypadStudioPanel(isSpotlight: Bool = false) -> some View {
        let scale: CGFloat = currentScale(for: .keypad3x3, isSpotlight: isSpotlight)
        return VStack(alignment: .leading, spacing: 6) {
            if !isSpotlight && standaloneModule == nil {
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.grid.3x3.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                        Text("3X3 KEYPAD")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Circle()
                            .fill(engine.currentTheme.accentPrimary)
                            .frame(width: 5, height: 5)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { engine.toggleSpotlightModule(.keypad3x3) }

                    Spacer(minLength: 2)

                    moduleHeaderControls(for: .keypad3x3)
                }
                .padding(.vertical, 2.5)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            // Mascot & Speech bubble
            ZStack(alignment: .top) {
                if engine.mascotSpeechVisible {
                    Text(engine.mascotSpeech)
                        .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.85))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(engine.currentTheme.accentPrimary, lineWidth: 1))
                        .offset(y: -14)
                        .transition(.scale.combined(with: .opacity))
                }

                BitchBoyOfficialMascotView(auraColor: engine.currentTheme.accentPrimary) {
                    engine.triggerMascotTap()
                }
                .scaleEffect(engine.mascotScale)
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: engine.mascotScale)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            // 3x3 Grid
            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { c in
                            let idx = 40 + r * 3 + c
                            HardwareKeyCap(
                                item: engine.controls[idx],
                                isSelected: engine.selectedIndices.contains(idx) || engine.selectedIndex == idx,
                                color: ledColor(engine.controls[idx].currentLED),
                                sectionBorder: engine.currentTheme.sectionOutline,
                                onTap: {
                                    isEditingNameBox = false
                                    let isShift = NSEvent.modifierFlags.contains(.shift)
                                    engine.handleKeyPressWithModifiers(index: idx, isShiftDown: isShift)
                                }
                            )
                            .equatable()
                                .contextMenu { controlContextMenu(for: idx) }
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(Color(red: 0.08, green: 0.04, blue: 0.04).opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(engine.currentTheme.sectionOutline.opacity(0.85), lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func colorPickerStudioPanel(isSpotlight: Bool = false) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
            if !isSpotlight && standaloneModule == nil {
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "paintpalette.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                        Text("COLOR PICKER // HUD")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Circle()
                            .fill(engine.currentTheme.accentPrimary)
                            .frame(width: 5, height: 5)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { engine.toggleSpotlightModule(.colorPickerHUD) }

                    Spacer(minLength: 2)

                    moduleHeaderControls(for: .colorPickerHUD)
                }
                .padding(.vertical, 2.5)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            ScrollView([.vertical], showsIndicators: false) {
                centerInspectorHUD
                    .padding(4)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // ------------------------------------------------------------------------
    // HARDWARE MIDI SEND & MUTE ISOLATION ENGINE
    // ------------------------------------------------------------------------
    private func hardwareMIDIFilterStudioPanel(isSpotlight: Bool = false) -> some View {
        let scale: CGFloat = currentScale(for: .hardwareMIDIFilter, isSpotlight: isSpotlight)

        return VStack(alignment: .leading, spacing: 6) {
            if !isSpotlight && standaloneModule == nil {
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "switch.2")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(engine.hardwareMIDISendEnabled ? engine.currentTheme.accentPrimary : Color(red: 0.98, green: 0.38, blue: 0.38))
                        Text("HARDWARE MIDI & MUTE // I/O")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Circle()
                            .fill(engine.hardwareMIDISendEnabled ? Color(red: 0.22, green: 0.96, blue: 0.65) : Color(red: 0.98, green: 0.38, blue: 0.38))
                            .frame(width: 5, height: 5)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        engine.toggleSpotlightModule(.hardwareMIDIFilter)
                    }

                    Spacer(minLength: 2)

                    moduleHeaderControls(for: .hardwareMIDIFilter)
                }
                .padding(.vertical, 2.5)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            ScrollView([.vertical], showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    // MASTER HARDWARE MIDI TOGGLE BANNER
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Image(systemName: engine.hardwareMIDISendEnabled ? "cable.connector" : "cable.connector.slash")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(engine.hardwareMIDISendEnabled ? Color(red: 0.22, green: 0.96, blue: 0.65) : Color(red: 0.98, green: 0.38, blue: 0.38))
                                    Text("MASTER MIDI OUTPUT")
                                        .font(.system(size: 12 * scale, weight: .bold, design: .default))
                                        .foregroundColor(.white)
                                }
                                Text(engine.hardwareMIDISendEnabled ? "Hardware sends MIDI to DAW & OS" : "MUTED: Keys trigger Hotkeys ONLY with zero MIDI conflicts")
                                    .font(.system(size: 10 * scale, weight: .regular, design: .default))
                                    .foregroundColor(Color(white: 0.70))
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { engine.hardwareMIDISendEnabled },
                                set: { val in
                                    engine.hardwareMIDISendEnabled = val
                                    if val {
                                        engine.hardwareInputActionsEnabled = true
                                    }
                                    UserDefaults.standard.set(val, forKey: "bb_hw_midi_send_enabled")
                                    SoundEffect.knobTick.play(with: engine.soundPack)
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                    }
                    .padding(8)
                    .background(
                        engine.hardwareMIDISendEnabled
                            ? Color(red: 0.08, green: 0.22, blue: 0.16).opacity(0.85)
                            : Color(red: 0.28, green: 0.08, blue: 0.10).opacity(0.85)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(
                                engine.hardwareMIDISendEnabled
                                    ? Color(red: 0.22, green: 0.96, blue: 0.65).opacity(0.5)
                                    : Color(red: 0.98, green: 0.38, blue: 0.38).opacity(0.5),
                                lineWidth: 1.2
                            )
                    )

                    // QUICK SCENARIO PROFILES
                    VStack(alignment: .leading, spacing: 4) {
                        Text("QUICK WORKFLOW PROFILES")
                            .font(.system(size: 10.5 * scale, weight: .bold, design: .default))
                            .foregroundColor(engine.currentTheme.headerText.opacity(0.85))

                        Button(action: { engine.unmuteAllInputs() }) {
                            HStack(spacing: 5) {
                                Image(systemName: "speaker.wave.3.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("UNMUTE ALL INPUTS // RESTORE")
                                    .font(.system(size: 10 * scale, weight: .heavy, design: .monospaced))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color(red: 0.12, green: 0.35, blue: 0.22))
                            .foregroundColor(Color(red: 0.40, green: 1.0, blue: 0.70))
                            .clipShape(RoundedRectangle(cornerRadius: 4.5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4.5)
                                    .stroke(Color(red: 0.40, green: 1.0, blue: 0.70).opacity(0.6), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Instantly restores and unmutes all physical & software inputs, sliders, knobs, and routing")

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                            Button(action: { engine.applyProfileHotkeysOnly() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "keyboard.fill")
                                        .font(.system(size: 9.5))
                                    Text("HOTKEYS ONLY")
                                        .font(.system(size: 10 * scale, weight: .semibold, design: .default))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(Color.white.opacity(0.08))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4.5))
                            }
                            .buttonStyle(.plain)
                            .help("Mutes all MIDI out so BitchBoy only triggers hotkeys & keybinds")

                            Button(action: { engine.applyProfileDAWMIDIOnly() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "pianokeys")
                                        .font(.system(size: 9.5))
                                    Text("DAW MIDI ONLY")
                                        .font(.system(size: 10 * scale, weight: .semibold, design: .default))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(Color.white.opacity(0.08))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4.5))
                            }
                            .buttonStyle(.plain)
                            .help("Enables all MIDI and turns off OS keybinds for DAW work")

                            Button(action: { engine.applyProfileHybrid() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "slider.horizontal.2.square")
                                        .font(.system(size: 9.5))
                                    Text("HYBRID STUDIO")
                                        .font(.system(size: 10 * scale, weight: .semibold, design: .default))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(Color.white.opacity(0.08))
                                .foregroundColor(Color(red: 0.22, green: 0.96, blue: 0.76))
                                .clipShape(RoundedRectangle(cornerRadius: 4.5))
                            }
                            .buttonStyle(.plain)
                            .help("Default: MIDI enabled with section routing and keybinds")

                            Button(action: { engine.applyProfilePanicMute() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "speaker.slash.fill")
                                        .font(.system(size: 9.5))
                                    Text("PANIC MUTE ALL")
                                        .font(.system(size: 10 * scale, weight: .semibold, design: .default))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(Color.red.opacity(0.20))
                                .foregroundColor(Color(red: 0.98, green: 0.45, blue: 0.45))
                                .clipShape(RoundedRectangle(cornerRadius: 4.5))
                            }
                            .buttonStyle(.plain)
                            .help("Mutes all outgoing MIDI and hotkeys immediately")
                        }
                    }

                    // SECTION ISOLATION SWITCHES
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PER-SECTION MIDI ROUTING SWITCHES")
                            .font(.system(size: 10.5 * scale, weight: .bold, design: .default))
                            .foregroundColor(engine.currentTheme.headerText.opacity(0.85))

                        VStack(spacing: 3) {
                            sectionToggleRow(
                                title: "4x8 MAIN KEY GRID",
                                subtitle: "Notes 1-32",
                                icon: "square.grid.3x3.fill",
                                isOn: Binding(
                                    get: { engine.keyGridMIDISendEnabled },
                                    set: { val in
                                        engine.keyGridMIDISendEnabled = val
                                        UserDefaults.standard.set(val, forKey: "bb_keygrid_midi_send")
                                    }
                                ),
                                scale: scale
                            )

                            sectionToggleRow(
                                title: "VERTICAL FADERS (8-CH)",
                                subtitle: "CC 0-7",
                                icon: "slider.vertical.3",
                                isOn: Binding(
                                    get: { engine.verticalFadersMIDISendEnabled },
                                    set: { val in
                                        engine.verticalFadersMIDISendEnabled = val
                                        UserDefaults.standard.set(val, forKey: "bb_vfaders_midi_send")
                                    }
                                ),
                                scale: scale
                            )

                            sectionToggleRow(
                                title: "HORIZONTAL CROSSFADERS (4-CH)",
                                subtitle: "CC 8-11",
                                icon: "slider.horizontal.below.rectangle",
                                isOn: Binding(
                                    get: { engine.horizontalFadersMIDISendEnabled },
                                    set: { val in
                                        engine.horizontalFadersMIDISendEnabled = val
                                        UserDefaults.standard.set(val, forKey: "bb_hfaders_midi_send")
                                    }
                                ),
                                scale: scale
                            )

                            sectionToggleRow(
                                title: "ROTARY KNOBS (8 ENCODERS)",
                                subtitle: "CC 20-27",
                                icon: "dial.low.fill",
                                isOn: Binding(
                                    get: { engine.rotaryKnobsMIDISendEnabled },
                                    set: { val in
                                        engine.rotaryKnobsMIDISendEnabled = val
                                        UserDefaults.standard.set(val, forKey: "bb_knobs_midi_send")
                                    }
                                ),
                                scale: scale
                            )

                            sectionToggleRow(
                                title: "MACRO KEY STRIP",
                                subtitle: "Notes 33-40",
                                icon: "rectangle.split.3x1.fill",
                                isOn: Binding(
                                    get: { engine.keyStripMIDISendEnabled },
                                    set: { val in
                                        engine.keyStripMIDISendEnabled = val
                                        UserDefaults.standard.set(val, forKey: "bb_keystrip_midi_send")
                                    }
                                ),
                                scale: scale
                            )

                            sectionToggleRow(
                                title: "3x3 KEYPAD DECK",
                                subtitle: "Notes 41-49",
                                icon: "circle.grid.3x3.fill",
                                isOn: Binding(
                                    get: { engine.keypadMIDISendEnabled },
                                    set: { val in
                                        engine.keypadMIDISendEnabled = val
                                        UserDefaults.standard.set(val, forKey: "bb_keypad_midi_send")
                                    }
                                ),
                                scale: scale
                            )
                        }
                        .padding(5)
                        .background(Color.black.opacity(0.40))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    // PROTOCOL & ENGINE BROADCAST SWITCHES
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PROTOCOL & ENGINE BROADCAST")
                            .font(.system(size: 10 * scale, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText.opacity(0.85))

                        VStack(spacing: 3) {
                            sectionToggleRow(
                                title: "HARDWARE INPUT INGESTION",
                                subtitle: "Accepts & processes incoming MIDI messages",
                                icon: "arrow.down.right.and.arrow.up.left",
                                isOn: Binding(
                                    get: { engine.hardwareInputActionsEnabled },
                                    set: { val in
                                        engine.hardwareInputActionsEnabled = val
                                        UserDefaults.standard.set(val, forKey: "bb_hw_input_actions_enabled")
                                    }
                                ),
                                scale: scale
                            )

                            sectionToggleRow(
                                title: "HARDWARE LED FEEDBACK SYNC",
                                subtitle: "Sends color velocities back to hardware LEDs",
                                icon: "lightbulb.fill",
                                isOn: Binding(
                                    get: { engine.hardwareLEDSyncEnabled },
                                    set: { val in
                                        engine.hardwareLEDSyncEnabled = val
                                        UserDefaults.standard.set(val, forKey: "bb_hw_led_sync_enabled")
                                    }
                                ),
                                scale: scale
                            )

                            sectionToggleRow(
                                title: "OS KEYBOARD SHORTCUTS / MACROS",
                                subtitle: "Executes QWERTY keybinds on button press",
                                icon: "command.square.fill",
                                isOn: Binding(
                                    get: { engine.qwertyKeybindsEnabled },
                                    set: { val in
                                        engine.qwertyKeybindsEnabled = val
                                        UserDefaults.standard.set(val, forKey: "bb_hw_qwerty_enabled")
                                    }
                                ),
                                scale: scale
                            )

                            sectionToggleRow(
                                title: "NETWORK OSC TRANSMISSION",
                                subtitle: "Broadcasts OSC commands to QLab / DAWs",
                                icon: "antenna.radiowaves.left.and.right",
                                isOn: $engine.oscSendEnabled,
                                scale: scale
                            )

                            sectionToggleRow(
                                title: "STUDIO UI AUDIO CLICKS",
                                subtitle: "Mechanical feedback sound effects",
                                icon: "speaker.wave.2.fill",
                                isOn: $engine.uiClickSoundEnabled,
                                scale: scale
                            )
                        }
                        .padding(5)
                        .background(Color.black.opacity(0.40))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    // REAL-TIME PACKET COUNTERS
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("ROUTED")
                                .font(.system(size: 8.5 * scale, weight: .heavy, design: .monospaced))
                                .foregroundColor(Color(white: 0.6))
                            Text("\(engine.routedMIDIPacketsCount)")
                                .font(.system(size: 13 * scale, weight: .heavy, design: .monospaced))
                                .foregroundColor(Color(red: 0.22, green: 0.96, blue: 0.65))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 4.5))

                        VStack(alignment: .leading, spacing: 1) {
                            Text("MUTED / BLOCKED")
                                .font(.system(size: 8.5 * scale, weight: .heavy, design: .monospaced))
                                .foregroundColor(Color(white: 0.6))
                            Text("\(engine.blockedMIDIPacketsCount)")
                                .font(.system(size: 13 * scale, weight: .heavy, design: .monospaced))
                                .foregroundColor(Color(red: 0.98, green: 0.45, blue: 0.45))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 4.5))

                        Button(action: {
                            engine.routedMIDIPacketsCount = 0
                            engine.blockedMIDIPacketsCount = 0
                            SoundEffect.knobTick.play(with: engine.soundPack)
                        }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .bold))
                                .padding(8)
                                .background(Color.white.opacity(0.08))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4.5))
                        }
                        .buttonStyle(.plain)
                        .help("Reset Packet Diagnostics")
                    }
                }
                .padding(4)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func sectionToggleRow(title: String, subtitle: String, icon: String, isOn: Binding<Bool>, scale: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11 * scale, weight: .bold))
                .foregroundColor(isOn.wrappedValue ? engine.currentTheme.accentPrimary : Color.white.opacity(0.35))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5 * scale, weight: .semibold, design: .default))
                    .foregroundColor(isOn.wrappedValue ? .white : Color.white.opacity(0.55))
                Text(subtitle)
                    .font(.system(size: 9.5 * scale, weight: .regular, design: .default))
                    .foregroundColor(Color.white.opacity(0.40))
            }

            Spacer(minLength: 4)

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.75)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(isOn.wrappedValue ? Color.white.opacity(0.04) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // ------------------------------------------------------------------------
    // LEFT WING (RED BOX #3): HARDWARE MEMORY SLOTS & CUSTOM PRESET BANK DECK
    // ------------------------------------------------------------------------
    private func leftWingMemorySlotsPanel(isSpotlight: Bool = false) -> some View {
        let slotLetters = ["A", "B", "C", "D", "E", "F", "G", "H"]
        let bankRange: Range<Int> = activeMemoryBank == 0 ? (0..<min(4, engine.slots.count)) : (min(4, engine.slots.count)..<min(8, engine.slots.count))
        let activeIdx = min(max(0, engine.activeSlot), max(0, engine.slots.count - 1))
        let activeSlotColor = engine.slots.indices.contains(activeIdx) ? ledColor(engine.slots[activeIdx].accentVelocity) : engine.currentTheme.accentPrimary
        let scale: CGFloat = currentScale(for: .memorySlots, isSpotlight: isSpotlight)
        let isExp = isExpanded(module: .memorySlots, isSpotlight: isSpotlight)

        return VStack(alignment: .leading, spacing: 6) {
            if !isSpotlight {
                // Header (Uniform across all modules - never truncates)
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "memorychip.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(activeSlotColor)
                            .shadow(color: activeSlotColor.opacity(0.8), radius: 4)

                        Text("MEMORY SLOTS")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Circle()
                            .fill(activeSlotColor)
                            .frame(width: 5, height: 5)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        engine.toggleSpotlightModule(.memorySlots)
                    }

                    Spacer(minLength: 2)

                    moduleHeaderControls(for: .memorySlots)
                }
                .padding(.vertical, 2.5)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            // Dedicated Bank Switcher Bar (Always readable, never squished!)
            HStack(spacing: 4) {
                Button(action: {
                    activeMemoryBank = 0
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }) {
                    Text("BANK A–D")
                        .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3.5 * scale)
                        .background(activeMemoryBank == 0 ? engine.currentTheme.accentPrimary : Color.white.opacity(0.08))
                        .foregroundColor(activeMemoryBank == 0 ? .black : Color(white: 0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)

                if engine.slots.count > 4 {
                    Button(action: {
                        activeMemoryBank = 1
                        SoundEffect.knobTick.play(with: engine.soundPack)
                    }) {
                        Text("BANK E–H")
                            .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3.5 * scale)
                            .background(activeMemoryBank == 1 ? engine.currentTheme.accentPrimary : Color.white.opacity(0.08))
                            .foregroundColor(activeMemoryBank == 1 ? .black : Color(white: 0.75))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
            ScrollView([.vertical], showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    // 2x2 Tactile Illuminated Memory Slot Pads (doubles in size when expanded!)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6 * scale), GridItem(.flexible(), spacing: 6 * scale)], spacing: 6 * scale) {
                ForEach(Array(bankRange), id: \.self) { idx in
                    let slot = engine.slots[idx]
                    let isSelected = (engine.activeSlot == idx)
                    let slotAccent = ledColor(slot.accentVelocity)
                    let sourceControls = isSelected ? engine.controls : slot.controls
                    let litCount = sourceControls.prefix(49).filter { $0.idleVelocity > 0 }.count
                    let macroCount = sourceControls.filter { $0.actionType != .passthrough }.count
                    let shortTitle = slot.name
                        .replacingOccurrences(of: "SLOT \(slotLetters[idx % 8]) // ", with: "")
                        .replacingOccurrences(of: "SLOT \(slotLetters[idx % 8]) ", with: "")

                    Button(action: {
                        engine.selectSlot(idx)
                    }) {
                        VStack(alignment: .leading, spacing: 3 * scale) {
                            HStack(spacing: 4 * scale) {
                                Text("SLOT \(slotLetters[idx % 8])")
                                    .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                                    .padding(.horizontal, 4.5 * scale)
                                    .padding(.vertical, 1.5 * scale)
                                    .background(isSelected ? slotAccent : Color.white.opacity(0.12))
                                    .foregroundColor(isSelected ? .black : slotAccent)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))

                                Image(systemName: slot.iconName)
                                    .font(.system(size: 13.5 * scale, weight: .bold))
                                    .foregroundColor(isSelected ? .white : slotAccent)

                                Spacer(minLength: 0)

                                Circle()
                                    .fill(isSelected ? Color.green : slotAccent.opacity(0.45))
                                    .frame(width: 6 * scale, height: 6 * scale)
                                    .shadow(color: isSelected ? Color.green : .clear, radius: 3)
                            }

                            Text(shortTitle.isEmpty ? slot.name : shortTitle)
                                .font(.system(size: 12.5 * scale, weight: .heavy, design: .monospaced))
                                .foregroundColor(isSelected ? .white : Color(white: 0.85))
                                .lineLimit(1)

                            HStack(spacing: 4 * scale) {
                                Text("\(litCount) LED")
                                    .font(.system(size: 11.0 * scale, weight: .bold, design: .monospaced))
                                    .foregroundColor(isSelected ? slotAccent : Color(white: 0.55))
                                Text("•")
                                    .font(.system(size: 11.0 * scale, weight: .bold))
                                    .foregroundColor(Color(white: 0.4))
                                Text("\(macroCount) ACT")
                                    .font(.system(size: 11.0 * scale, weight: .bold, design: .monospaced))
                                    .foregroundColor(macroCount > 0 ? Color.yellow.opacity(0.9) : Color(white: 0.55))
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(6 * scale)
                        .frame(minHeight: isExp ? 74 : 36)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isSelected ? slotAccent.opacity(0.22) : Color.black.opacity(0.5))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(isSelected ? slotAccent : Color.white.opacity(0.14), lineWidth: isSelected ? 1.5 : 0.8)
                        )
                        .shadow(color: isSelected ? slotAccent.opacity(0.45) : .clear, radius: 5)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Customizer Row: Inline Rename + Icon & Accent Color Swatches for Active Slot
            if engine.slots.indices.contains(activeIdx) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        // Cycle Icon Button / Menu
                        Menu {
                            let icons = [
                                ("music.mic", "LIVE / VOCAL"),
                                ("slider.horizontal.3", "DAW MIXER"),
                                ("sparkles", "LIGHT SHOW / DMX"),
                                ("square.grid.3x3.fill", "STREAM DECK"),
                                ("pianokeys", "SYNTH / KEYS"),
                                ("waveform.path.ecg", "DRUMS / FX"),
                                ("tv.fill", "VJ / RESOLUME"),
                                ("cpu.fill", "HARDWARE MACRO"),
                                ("bolt.fill", "HIGH ENERGY"),
                                ("flame.fill", "FIRE SET")
                            ]
                            ForEach(icons, id: \.0) { ic in
                                Button(action: {
                                    engine.slots[activeIdx].iconName = ic.0
                                    engine.saveCurrentSlot()
                                }) {
                                    Label(ic.1, systemImage: ic.0)
                                }
                            }
                        } label: {
                            Image(systemName: engine.slots[activeIdx].iconName)
                                .font(.system(size: 14.0, weight: .bold))
                                .foregroundColor(activeSlotColor)
                                .frame(width: 20, height: 20)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 22)

                        // Click-to-edit Slot Name to ensure keystrokes never get trapped
                        if isEditingSlotName {
                            HStack(spacing: 3) {
                                TextField(
                                    "SLOT NAME",
                                    text: Binding(
                                        get: { engine.slots[activeIdx].name },
                                        set: { newVal in
                                            engine.slots[activeIdx].name = newVal
                                            engine.saveCurrentSlot()
                                        }
                                    ),
                                    onCommit: {
                                        isEditingSlotName = false
                                        NSApp.keyWindow?.makeFirstResponder(nil)
                                    }
                                )
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                                .foregroundColor(.white)

                                Button(action: {
                                    isEditingSlotName = false
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                }) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(activeSlotColor)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3.5)
                            .background(Color.black.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(activeSlotColor, lineWidth: 1.2))
                        } else {
                            Button(action: {
                                isEditingSlotName = true
                            }) {
                                HStack(spacing: 4) {
                                    Text(engine.slots[activeIdx].name)
                                        .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Image(systemName: "pencil")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundColor(Color.white.opacity(0.40))
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(activeSlotColor.opacity(0.45), lineWidth: 0.8))
                            }
                            .buttonStyle(.plain)
                            .help("Click to rename memory slot")
                        }

                        // Toggle Color Swatch Bar
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showSlotCustomizer.toggle()
                            }
                        }) {
                            Image(systemName: showSlotCustomizer ? "paintpalette.fill" : "paintpalette")
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundColor(showSlotCustomizer ? .black : activeSlotColor)
                                .frame(width: 20, height: 20)
                                .background(showSlotCustomizer ? activeSlotColor : Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }

                    if showSlotCustomizer {
                        HStack(spacing: 4) {
                            Text("COLOR: \(BitchBoyHardwareColor.formattedLabel(for: engine.slots[activeIdx].accentVelocity))")
                                .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                                .foregroundColor(activeSlotColor)
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 4) {
                            let swatches: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 57, 83, 3]
                            ForEach(swatches, id: \.self) { vel in
                                Circle()
                                    .fill(ledColor(vel))
                                    .frame(width: 13, height: 13)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white, lineWidth: engine.slots[activeIdx].accentVelocity == vel ? 1.8 : 0)
                                    )
                                    .shadow(color: engine.slots[activeIdx].accentVelocity == vel ? ledColor(vel) : .clear, radius: 3)
                                    .onTapGesture {
                                        engine.slots[activeIdx].accentVelocity = vel
                                        engine.saveCurrentSlot()
                                        SoundEffect.knobTick.play(with: engine.soundPack)
                                    }
                            }
                            Spacer()
                            Button("SYNC 49 LEDS") {
                                engine.setZoneLEDs(range: 0..<49, velocity: engine.slots[activeIdx].accentVelocity)
                            }
                            .font(.system(size: 11.0, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(activeSlotColor.opacity(0.25))
                            .foregroundColor(activeSlotColor)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(5)
                .background(Color.black.opacity(0.38))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // 1-Click Memory Deck Action Bar (Save, Clone To..., JSON Copy/Paste, Reset, Blackout)
            HStack(spacing: 4) {
                Button(action: {
                    engine.saveCurrentSlot()
                    SoundEffect.presetSwitch.play(with: engine.soundPack)
                    engine.log("💾 Saved \(engine.slots[activeIdx].name) to internal memory.")
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                        Text("SAVE")
                    }
                    .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4.5)
                    .background(Color(red: 0.12, green: 0.46, blue: 0.36))
                    .foregroundColor(Color(red: 0.35, green: 0.98, blue: 0.78))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(0..<engine.slots.count, id: \.self) { targetIdx in
                        if targetIdx != activeIdx {
                            Button("Clone into Slot \(slotLetters[targetIdx % 8]) (\(engine.slots[targetIdx].name))") {
                                engine.cloneCurrentSlotTo(targetIdx)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 12.0))
                        Text("CLONE")
                            .font(.system(size: 11.0, weight: .heavy, design: .monospaced))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4.5)
                    .background(Color.white.opacity(0.1))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)

                Button(action: {
                    _ = engine.exportPresetToJSON()
                    SoundEffect.keyTap.play(with: engine.soundPack)
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.doc.fill")
                        Text("EXP")
                    }
                    .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4.5)
                    .background(Color.white.opacity(0.1))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)

                Button(action: {
                    engine.importPresetFromClipboard()
                    SoundEffect.presetSwitch.play(with: engine.soundPack)
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down.doc.fill")
                        Text("IMP")
                    }
                    .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4.5)
                    .background(Color.white.opacity(0.1))
                    .foregroundColor(Color.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)

                Button(action: {
                    engine.resetCurrentSlotToDefault()
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12.5, weight: .heavy))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4.5)
                        .background(Color(red: 0.48, green: 0.16, blue: 0.16))
                        .foregroundColor(Color(red: 1.0, green: 0.65, blue: 0.65))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(9)
        .background(isSpotlight ? Color.clear : Color.black.opacity(0.46))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSpotlight ? Color.clear : activeSlotColor.opacity(0.75), lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // ------------------------------------------------------------------------
    // RIGHT WING (RED BOX #2): GROUND-UP CUSTOM LIGHTING FX STUDIO
    // ------------------------------------------------------------------------
    private func rightWingStudioPanel(isSpotlight: Bool = false) -> some View {
        let scale: CGFloat = currentScale(for: .customFXStudio, isSpotlight: isSpotlight)

        return VStack(alignment: .leading, spacing: 7) {
            if !isSpotlight {
                // Header (Uniform across all modules)
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)

                        Text("CUSTOM FX")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Circle()
                            .fill(engine.isPlayingCustomFX ? Color.green : Color(white: 0.4))
                            .frame(width: 5, height: 5)
                            .shadow(color: engine.isPlayingCustomFX ? Color.green : .clear, radius: 2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        engine.toggleSpotlightModule(.customFXStudio)
                    }

                    Spacer(minLength: 2)

                    moduleHeaderControls(for: .customFXStudio)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            // 3-Tab Switcher: Frame Sequencer / Procedural Wave Synth / Saved Shows
            HStack(spacing: 4) {
                wingTabButton(title: "SEQUENCER", active: engine.rightWingTab == "SEQUENCER", scale: scale) {
                    engine.editingCustomFX.isProcedural = false
                    engine.rightWingTab = "SEQUENCER"
                }
                wingTabButton(title: "WAVE SYNTH", active: engine.rightWingTab == "WAVESYNTH", scale: scale) {
                    engine.editingCustomFX.isProcedural = true
                    engine.rightWingTab = "WAVESYNTH"
                }
                wingTabButton(title: "MY SHOWS (\(engine.customEffects.count))", active: engine.rightWingTab == "LIBRARY", scale: scale) {
                    engine.rightWingTab = "LIBRARY"
                }
            }

            ScrollView([.vertical], showsIndicators: false) {
                if engine.rightWingTab == "SEQUENCER" {
                    rightWingFrameSequencerContent
                } else if engine.rightWingTab == "WAVESYNTH" {
                    rightWingWaveSynthContent
                } else {
                    rightWingSavedLibraryContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(10)
        .background(isSpotlight ? Color.clear : Color.black.opacity(0.42))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSpotlight ? Color.clear : engine.currentTheme.sectionOutline.opacity(0.75), lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var rightWingFrameSequencerContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Show Name + Play/Save Row (Clean layout that never overflows or truncates)
            HStack(spacing: 5) {
                if isEditingShowName {
                    HStack(spacing: 4) {
                        TextField("Show Name", text: $engine.editingCustomFX.name, onCommit: {
                            isEditingShowName = false
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        })
                        .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        Button(action: {
                            isEditingShowName = false
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(engine.currentTheme.accentPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(engine.currentTheme.accentPrimary, lineWidth: 1.2))
                    .layoutPriority(1)
                } else {
                    Button(action: {
                        isEditingShowName = true
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "pencil")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(Color.white.opacity(0.45))
                            Text(engine.editingCustomFX.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Click to Name Show..." : engine.editingCustomFX.name)
                                .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                                .foregroundColor(engine.editingCustomFX.name.trimmingCharacters(in: .whitespaces).isEmpty ? Color.white.opacity(0.40) : Color.white)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4.5)
                        .background(Color.black.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Click to rename show")
                    .layoutPriority(1)
                }

                Button(action: {
                    if engine.isPlayingCustomFX {
                        engine.stopCustomEffect()
                    } else {
                        engine.editingCustomFX.isProcedural = false
                        engine.playCustomEffect(engine.editingCustomFX)
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: engine.isPlayingCustomFX ? "stop.fill" : "play.fill")
                        Text(engine.isPlayingCustomFX ? "STOP" : "PLAY")
                    }
                    .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(engine.isPlayingCustomFX ? Color.red : engine.currentTheme.accentPrimary)
                    .foregroundColor(engine.isPlayingCustomFX ? .white : .black)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)

                Button(action: {
                    engine.saveEditingCustomFXToLibrary()
                }) {
                    Text("💾 SAVE")
                        .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Color(red: 0.16, green: 0.45, blue: 0.34))
                        .foregroundColor(Color(red: 0.4, green: 0.98, blue: 0.78))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
            }

            // Sub-row: ON-CONNECT Quick Action + Main 49 Keys Canvas Paint Toggle
            HStack(spacing: 5) {
                let isCurrentConnectFX = (engine.connectCustomFXName == engine.editingCustomFX.name && engine.connectEffectEnabled)
                Button(action: {
                    engine.saveEditingCustomFXToLibrary()
                    engine.setAsOnConnectFX(engine.editingCustomFX)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: isCurrentConnectFX ? "bolt.circle.fill" : "bolt.fill")
                        Text(isCurrentConnectFX ? "ON-CONNECT FX" : "SET AS ON-CONNECT")
                    }
                    .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4.5)
                    .background(isCurrentConnectFX ? Color(red: 0.96, green: 0.76, blue: 0.18) : Color.white.opacity(0.12))
                    .foregroundColor(isCurrentConnectFX ? .black : Color(red: 0.96, green: 0.78, blue: 0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)

                Button(action: {
                    engine.paintOnMainChassis.toggle()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: engine.paintOnMainChassis ? "paintbrush.pointed.fill" : "paintbrush")
                        Text(engine.paintOnMainChassis ? "PAINTING: ON" : "PAINT ON 49 KEYS")
                    }
                    .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4.5)
                    .background(engine.paintOnMainChassis ? Color(red: 0.95, green: 0.50, blue: 0.15) : Color.white.opacity(0.08))
                    .foregroundColor(engine.paintOnMainChassis ? .black : engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }

            // Interactive 49-Key Mini Canvas Preview & Painter
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    let safeFrame = min(max(0, engine.editingFrameIndex), max(0, engine.editingCustomFX.frames.count - 1))
                    Text("FRAME \(safeFrame + 1)/\(engine.editingCustomFX.frames.count) CANVAS (CLICK TO PAINT)")
                        .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color(white: 0.65))
                    Spacer()
                    HStack(spacing: 3) {
                        Text("BRUSH: \(BitchBoyHardwareColor.formattedLabel(for: engine.customBrushVelocity))")
                            .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                            .foregroundColor(ledColor(engine.customBrushVelocity))
                        HStack(spacing: 1.5) {
                            Text("V:")
                                .font(.system(size: 11.0, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(white: 0.5))
                            TextField("78", text: Binding(
                                get: { String(engine.customBrushVelocity) },
                                set: { val in
                                    if let num = Int(val.filter { $0.isNumber }) {
                                        engine.customBrushVelocity = UInt8(min(max(num, 0), 127))
                                    }
                                }
                            ))
                            .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                            .frame(width: 24, height: 13)
                            .background(Color.black.opacity(0.6))
                            .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(Color.white.opacity(0.2), lineWidth: 0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 2.5))
                        }
                    }
                }

                HStack(alignment: .center, spacing: 18) {
                    Spacer()
                    // Mini 8x4 + 1x8
                    VStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { r in
                            HStack(spacing: 2) {
                                ForEach(0..<8, id: \.self) { c in
                                    let kIdx = r * 8 + c
                                    miniCanvasKey(keyIndex: kIdx)
                                }
                            }
                        }
                        Divider().background(Color.white.opacity(0.2))
                        HStack(spacing: 2) {
                            ForEach(32..<40, id: \.self) { kIdx in
                                miniCanvasKey(keyIndex: kIdx)
                            }
                        }
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1, height: 75)

                    // Mini 3x3 Keypad
                    VStack(spacing: 2) {
                        Text("3x3")
                            .font(.system(size: 11.0, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.5))
                        ForEach(0..<3, id: \.self) { r in
                            HStack(spacing: 2) {
                                ForEach(0..<3, id: \.self) { c in
                                    let kIdx = 40 + r * 3 + c
                                    miniCanvasKey(keyIndex: kIdx)
                                }
                            }
                        }
                    }
                    Spacer()
                }
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
            }

            // 13 Authentic BitchBoy Hardware Color Swatches
            VStack(alignment: .leading, spacing: 3) {
                Text("AUTHENTIC HARDWARE COLOR PALETTE")
                    .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)

                let swatches: [(String, UInt8)] = [
                    ("OFF", 0), ("WHT", 3), ("TRQ", 33), ("BLU", 41),
                    ("ORG", 61), ("PRP", 67), ("RED", 72), ("YLW", 74),
                    ("CYN", 78), ("BRN", 83), ("GRN", 87), ("PNK", 57), ("AMB", 96)
                ]
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                    ForEach(swatches, id: \.1) { item in
                        let isSel = (engine.customBrushVelocity == item.1)
                        Button(action: {
                            engine.customBrushVelocity = item.1
                        }) {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(item.1 == 0 ? Color(white: 0.35) : ledColor(item.1))
                                    .frame(width: 7, height: 7)
                                Text(item.0)
                                    .font(.system(size: 13.5, weight: .heavy, design: .monospaced))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(isSel ? Color.white.opacity(0.24) : Color.black.opacity(0.45))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isSel ? engine.currentTheme.accentPrimary : Color.white.opacity(0.1), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Keyframe Timeline Strip
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("TIMELINE FRAMES")
                        .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.headerText)
                    Spacer()
                    Button("+ ADD") { engine.addCustomFXFrame() }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2).background(engine.currentTheme.accentPrimary.opacity(0.25)).foregroundColor(engine.currentTheme.accentPrimary).clipShape(RoundedRectangle(cornerRadius: 3))
                    Button("📋 DUP") { engine.duplicateCustomFXFrame() }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Color.white.opacity(0.12)).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 3))
                    Button("📋 COPY") { engine.copyCurrentFXFrame() }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Color.white.opacity(0.12)).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 3))
                        .help("Copy current frame LEDs")
                    Button("📥 PASTE") { engine.pasteFXFrame() }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(engine.hasCopiedFXFrame ? engine.currentTheme.accentPrimary.opacity(0.25) : Color.white.opacity(0.05))
                        .foregroundColor(engine.hasCopiedFXFrame ? engine.currentTheme.accentPrimary : Color.white.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .disabled(!engine.hasCopiedFXFrame)
                        .help("Paste copied frame LEDs")
                    Button("🗑️ DEL") { engine.deleteCustomFXFrame() }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Color.red.opacity(0.25)).foregroundColor(Color(red: 1, green: 0.5, blue: 0.5)).clipShape(RoundedRectangle(cornerRadius: 3))
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(0..<engine.editingCustomFX.frames.count, id: \.self) { fIdx in
                            let isCur = (engine.editingFrameIndex == fIdx)
                            Button(action: {
                                engine.editingFrameIndex = fIdx
                                engine.previewCurrentCustomFrameOnHardware()
                            }) {
                                Text("F\(fIdx + 1)")
                                    .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(isCur ? engine.currentTheme.accentPrimary : Color.black.opacity(0.5))
                                    .foregroundColor(isCur ? .black : .white)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // 1-Click Pattern Shifters & Frame Tools
            VStack(alignment: .leading, spacing: 3) {
                Text("PATTERN SHIFTERS & GENERATORS")
                    .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)

                HStack(spacing: 3) {
                    miniToolBtn("◀ L") { engine.shiftCurrentFrame(dx: -1, dy: 0) }
                    miniToolBtn("R ▶") { engine.shiftCurrentFrame(dx: 1, dy: 0) }
                    miniToolBtn("▲ U") { engine.shiftCurrentFrame(dx: 0, dy: -1) }
                    miniToolBtn("▼ D") { engine.shiftCurrentFrame(dx: 0, dy: 1) }
                    miniToolBtn("🪞 MIR") { engine.mirrorCurrentFrameHorizontal() }
                }
                HStack(spacing: 3) {
                    miniToolBtn("🌈 WAVE") { engine.applyRainbowToCurrentFrame() }
                    miniToolBtn("🎲 SPARK") { engine.randomizeCurrentFrameSparks() }
                    miniToolBtn("🔄 INV") { engine.invertCurrentFrame() }
                    miniToolBtn("⬛ FILL") { engine.fillCurrentCustomFXFrame(with: engine.customBrushVelocity) }
                    miniToolBtn("🧹 CLR") { engine.clearCurrentCustomFXFrame() }
                }
            }

            // FPS & Loop Behavior
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("SPEED: \(Int(engine.editingCustomFX.fps)) FPS")
                        .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Slider(value: $engine.editingCustomFX.fps, in: 1...24, step: 1) { _ in
                        if engine.isPlayingCustomFX {
                            engine.playCustomEffect(engine.editingCustomFX)
                        }
                    }
                    .tint(engine.currentTheme.accentPrimary)
                }

                HStack(spacing: 4) {
                    Text("MODE:")
                        .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Spacer()
                    ForEach(CustomFXLoopMode.allCases) { lm in
                        Button(lm.rawValue) {
                            engine.editingCustomFX.loopMode = lm
                        }
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(engine.editingCustomFX.loopMode == lm ? engine.currentTheme.accentPrimary : Color.white.opacity(0.08))
                        .foregroundColor(engine.editingCustomFX.loopMode == lm ? .black : .white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(5)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var rightWingWaveSynthContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("PROCEDURAL LIGHTING SYNTHESIZER")
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            if isEditingSynthName {
                HStack(spacing: 4) {
                    TextField("Synth Show Name", text: $engine.editingCustomFX.name, onCommit: {
                        isEditingSynthName = false
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    })
                    .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                    .textFieldStyle(.plain)
                    Button(action: {
                        isEditingSynthName = false
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(5)
                .background(Color.black.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(engine.currentTheme.accentPrimary, lineWidth: 1.2))
            } else {
                Button(action: {
                    isEditingSynthName = true
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(Color.white.opacity(0.45))
                        Text(engine.editingCustomFX.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Click to Name Synth Show..." : engine.editingCustomFX.name)
                            .font(.system(size: 13.0, weight: .bold, design: .monospaced))
                            .foregroundColor(engine.editingCustomFX.name.trimmingCharacters(in: .whitespaces).isEmpty ? Color.white.opacity(0.40) : Color.white)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Click to rename synth show")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("WAVEFORM FORMULA:")
                    .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.7))
                Picker("", selection: $engine.editingCustomFX.waveShape) {
                    ForEach(CustomWaveShape.allCases) { ws in
                        Text(ws.rawValue).tag(ws)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))

                Text("VECTOR DIRECTION:")
                    .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.7))
                Picker("", selection: $engine.editingCustomFX.waveDirection) {
                    ForEach(CustomWaveDirection.allCases) { wd in
                        Text(wd.rawValue).tag(wd)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))

                HStack {
                    Text("DENSITY:")
                        .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Slider(value: $engine.editingCustomFX.waveFrequency, in: 0.3...3.0, step: 0.1)
                        .tint(engine.currentTheme.accentPrimary)
                    Text(String(format: "%.1fx", engine.editingCustomFX.waveFrequency))
                        .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                }

                HStack {
                    Text("SPEED FPS:")
                        .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Slider(value: $engine.editingCustomFX.fps, in: 2...25, step: 1)
                        .tint(engine.currentTheme.accentPrimary)
                    Text("\(Int(engine.editingCustomFX.fps))")
                        .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                }

                HStack {
                    Text("MIN COLOR: \(BitchBoyHardwareColor.formattedLabel(for: engine.editingCustomFX.minVelocity))")
                        .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                        .foregroundColor(ledColor(engine.editingCustomFX.minVelocity))
                    Slider(
                        value: Binding(
                            get: { Double(engine.editingCustomFX.minVelocity) },
                            set: { engine.editingCustomFX.minVelocity = UInt8($0) }
                        ),
                        in: 0...127,
                        step: 1
                    )
                }

                HStack {
                    Text("MAX COLOR: \(BitchBoyHardwareColor.formattedLabel(for: engine.editingCustomFX.maxVelocity))")
                        .font(.system(size: 12.0, weight: .bold, design: .monospaced))
                        .foregroundColor(ledColor(engine.editingCustomFX.maxVelocity))
                    Slider(
                        value: Binding(
                            get: { Double(engine.editingCustomFX.maxVelocity) },
                            set: { engine.editingCustomFX.maxVelocity = UInt8($0) }
                        ),
                        in: 0...127,
                        step: 1
                    )
                }
            }
            .padding(6)
            .background(Color.black.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button(action: {
                engine.editingCustomFX.isProcedural = true
                engine.playCustomEffect(engine.editingCustomFX)
            }) {
                HStack {
                    Image(systemName: "play.circle.fill")
                    Text("▶️ STREAM LIVE SYNTH TO BITCHBOY")
                }
                .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(engine.currentTheme.accentPrimary)
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Button(action: {
                engine.bakeProceduralWaveToFrames()
            }) {
                HStack {
                    Image(systemName: "film.stack")
                    Text("⚡ BAKE INTO 12 KEYFRAMES FOR EDITING")
                }
                .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color(red: 0.92, green: 0.52, blue: 0.16))
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Button(action: {
                engine.editingCustomFX.isProcedural = true
                engine.saveEditingCustomFXToLibrary()
            }) {
                Text("💾 SAVE PROCEDURAL SHOW TO MY SHOWS")
                    .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.16, green: 0.45, blue: 0.34))
                    .foregroundColor(Color(red: 0.4, green: 0.98, blue: 0.78))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }

    private var rightWingSavedLibraryContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("+ NEW BLANK SHOW") {
                    engine.createNewBlankCustomFX()
                    engine.rightWingTab = "SEQUENCER"
                }
                .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(engine.currentTheme.accentPrimary)
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .buttonStyle(.plain)

                Button("⚡ TEST CONNECT FX") {
                    engine.triggerBitchBoyConnectedNotificationFX(isManualTest: true)
                }
                .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color(red: 0.96, green: 0.76, blue: 0.18).opacity(0.25))
                .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.25))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .buttonStyle(.plain)

                Spacer()

                Button("⤓ EXPORT") { engine.exportCustomFXToClipboard() }
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 4)
                    .background(Color.white.opacity(0.1)).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 4)).buttonStyle(.plain)

                Button("⤒ IMPORT") { engine.importCustomFXFromClipboard() }
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 4)
                    .background(Color.white.opacity(0.1)).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 4)).buttonStyle(.plain)
            }

            ScrollView([.vertical], showsIndicators: false) {
                VStack(spacing: 5) {
                    ForEach(engine.customEffects) { fx in
                        let isRunning = engine.isPlayingCustomFX && engine.activeCustomFXName == fx.name
                        let isConnectFX = engine.connectEffectEnabled && engine.connectCustomFXName == fx.name
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(fx.name)
                                        .font(.system(size: 13.0, weight: .heavy, design: .monospaced))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    if isConnectFX {
                                        Text("ON-CONNECT")
                                            .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color(red: 0.96, green: 0.76, blue: 0.18))
                                            .foregroundColor(.black)
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(fx.isProcedural ? "WAVE SYNTH // \(fx.waveShape.rawValue)" : "\(fx.frames.count) FRAMES // \(Int(fx.fps)) FPS // \(fx.loopMode.rawValue)")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundColor(Color(white: 0.6))
                            }
                            Spacer()
                            Button(action: {
                                engine.setAsOnConnectFX(fx)
                            }) {
                                Image(systemName: isConnectFX ? "bolt.circle.fill" : "bolt.fill")
                                    .font(.system(size: 13.0))
                                    .padding(4)
                                    .background(isConnectFX ? Color(red: 0.96, green: 0.76, blue: 0.18) : Color.white.opacity(0.12))
                                    .foregroundColor(isConnectFX ? .black : Color(red: 0.96, green: 0.78, blue: 0.25))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)

                            Button(isRunning ? "⏹" : "▶️ RUN") {
                                if isRunning {
                                    engine.stopCustomEffect()
                                } else {
                                    engine.playCustomEffect(fx)
                                }
                            }
                            .font(.system(size: 12.0, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(isRunning ? Color.red : engine.currentTheme.accentPrimary)
                            .foregroundColor(isRunning ? .white : .black)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .buttonStyle(.plain)

                            Button("✏️") {
                                engine.selectCustomFXForEditing(fx)
                            }
                            .font(.system(size: 12.0, design: .monospaced))
                            .padding(4)
                            .background(Color.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .buttonStyle(.plain)

                            Button("🗑️") {
                                engine.deleteSavedCustomFX(fx)
                            }
                            .font(.system(size: 12.0, design: .monospaced))
                            .padding(4)
                            .background(Color.red.opacity(0.22))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .buttonStyle(.plain)
                        }
                        .padding(7)
                        .background(isRunning ? engine.currentTheme.accentPrimary.opacity(0.18) : Color.black.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isRunning ? engine.currentTheme.accentPrimary : Color.white.opacity(0.1), lineWidth: 1))
                    }
                }
            }
            .frame(height: 196)
        }
    }

    // ------------------------------------------------------------------------
    // RIGHT WING (RED BOX #4): REACTIVE MECHANICAL KEYBOARD KEY-PRESS FX ENGINE
    // ------------------------------------------------------------------------
    private func rightWingReactiveKeyFXPanel(isSpotlight: Bool = false) -> some View {
        let isEnabled = (engine.reactiveKeyFXMode != .off)
        let activeColor = engine.reactiveFXRainbowColor ? engine.currentTheme.accentPrimary : ledColor(engine.reactiveFXColorVelocity)
        let scale: CGFloat = currentScale(for: .reactiveKeyFX, isSpotlight: isSpotlight)
        let isExp = isExpanded(module: .reactiveKeyFX, isSpotlight: isSpotlight)

        return VStack(alignment: .leading, spacing: 6) {
            if !isSpotlight {
                // Header (Uniform across all modules - never truncates)
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(isEnabled ? activeColor : Color(white: 0.5))
                            .shadow(color: isEnabled ? activeColor.opacity(0.85) : .clear, radius: 4)

                        Text("REACTIVE FX")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Circle()
                            .fill(isEnabled ? Color.green : Color(white: 0.4))
                            .frame(width: 5, height: 5)
                            .shadow(color: isEnabled ? Color.green : .clear, radius: 3)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        engine.toggleSpotlightModule(.reactiveKeyFX)
                    }

                    Spacer(minLength: 2)

                    moduleHeaderControls(for: .reactiveKeyFX)
                }
                .padding(.vertical, 2.5)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            // Dedicated FX Status & Speed Bar (Always readable, never squished!)
            HStack(spacing: 4) {
                Button(action: {
                    if engine.reactiveKeyFXMode == .off {
                        engine.reactiveKeyFXMode = .ripple
                    } else {
                        engine.reactiveKeyFXMode = .off
                        engine.clearReactiveKeyFX()
                    }
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }) {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(isEnabled ? Color.green : Color(white: 0.4))
                            .frame(width: 5, height: 5)
                        Text(isEnabled ? "FX ACTIVE" : "FX OFF")
                            .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                    }
                    .padding(.horizontal, 5 * scale)
                    .padding(.vertical, 3 * scale)
                    .background(isEnabled ? Color.green.opacity(0.18) : Color.white.opacity(0.08))
                    .foregroundColor(isEnabled ? Color.green : Color(white: 0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 3) {
                    Text("SPEED:")
                        .font(.system(size: 11.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Slider(value: $engine.reactiveFXSpeed, in: 0.4...3.0, step: 0.1)
                        .frame(width: 50 * scale)
                        .tint(activeColor)
                    Text(String(format: "%.1fx", engine.reactiveFXSpeed))
                        .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                        .foregroundColor(activeColor)
                }
            }

            ScrollView([.vertical], showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    // 6 Interactive Mechanical Keyboard FX Mode Pads (2x3 Grid)
                    let modes: [ReactiveKeyFXMode] = [.ripple, .crossLaser, .supernova, .heatTrail, .meteorRain, .arcLightning]
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 5 * scale), GridItem(.flexible(), spacing: 5 * scale), GridItem(.flexible(), spacing: 5 * scale)], spacing: 5 * scale) {
                        ForEach(modes) { mode in
                            let isSel = (engine.reactiveKeyFXMode == mode)
                            Button(action: {
                                engine.reactiveKeyFXMode = mode
                                engine.triggerRandomDemoReactiveFX()
                            }) {
                                VStack(spacing: 3 * scale) {
                                    Image(systemName: mode.icon)
                                        .font(.system(size: 12 * scale, weight: .bold))
                                        .foregroundColor(isSel ? .black : activeColor)
                                    Text(mode.rawValue)
                                        .font(.system(size: 13.5 * scale, weight: .heavy, design: .monospaced))
                                        .foregroundColor(isSel ? .black : .white)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: isExp ? 48 : 34)
                                .padding(.vertical, 5.5 * scale)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isSel ? activeColor : Color.black.opacity(0.5))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(isSel ? Color.white.opacity(0.75) : activeColor.opacity(0.28), lineWidth: isSel ? 1.3 : 0.8)
                                )
                                .shadow(color: isSel ? activeColor.opacity(0.55) : .clear, radius: 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Clean 2-Row PRISM & Color Palette Box (Never wraps or squishes!)
                    VStack(alignment: .leading, spacing: 4 * scale) {
                        HStack {
                            Button(action: {
                                engine.reactiveFXRainbowColor = true
                                engine.triggerRandomDemoReactiveFX()
                                SoundEffect.knobTick.play(with: engine.soundPack)
                            }) {
                                HStack(spacing: 3) {
                                    Text("🌈")
                                        .font(.system(size: 12.5 * scale))
                                    Text("PRISM RAINBOW")
                                        .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 6 * scale)
                                .padding(.vertical, 2.5 * scale)
                                .background(engine.reactiveFXRainbowColor ? engine.currentTheme.accentPrimary : Color.white.opacity(0.1))
                                .foregroundColor(engine.reactiveFXRainbowColor ? .black : .white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .fixedSize(horizontal: true, vertical: false)

                            Spacer()

                            if !engine.reactiveFXRainbowColor {
                                HStack(spacing: 3) {
                                    Text(BitchBoyHardwareColor.formattedLabel(for: engine.reactiveFXColorVelocity))
                                        .font(.system(size: 12.0 * scale, weight: .bold, design: .monospaced))
                                        .foregroundColor(ledColor(engine.reactiveFXColorVelocity))
                                    HStack(spacing: 1.5) {
                                        Text("V:")
                                            .font(.system(size: 11.0 * scale, weight: .bold, design: .monospaced))
                                            .foregroundColor(Color(white: 0.5))
                                        TextField("78", text: Binding(
                                            get: { String(engine.reactiveFXColorVelocity) },
                                            set: { val in
                                                if let num = Int(val.filter { $0.isNumber }) {
                                                    engine.reactiveFXColorVelocity = UInt8(min(max(num, 0), 127))
                                                }
                                            }
                                        ))
                                        .font(.system(size: 11.5 * scale, weight: .heavy, design: .monospaced))
                                        .textFieldStyle(.plain)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 24 * scale, height: 13 * scale)
                                        .background(Color.black.opacity(0.6))
                                        .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(Color.white.opacity(0.2), lineWidth: 0.8))
                                        .clipShape(RoundedRectangle(cornerRadius: 2.5))
                                    }
                                }
                            } else {
                                Text("MULTI-COLOR")
                                    .font(.system(size: 12.0 * scale, weight: .bold, design: .monospaced))
                                    .foregroundColor(engine.currentTheme.accentPrimary)
                            }
                        }

                        // 12 Color Swatches
                        HStack(spacing: 4 * scale) {
                            let colorSwatches: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 57, 83, 3]
                            ForEach(colorSwatches, id: \.self) { vel in
                                let isPicked = (!engine.reactiveFXRainbowColor && engine.reactiveFXColorVelocity == vel)
                                Circle()
                                    .fill(ledColor(vel))
                                    .frame(width: 13 * scale, height: 13 * scale)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white, lineWidth: isPicked ? 1.6 : 0)
                                    )
                                    .shadow(color: isPicked ? ledColor(vel) : .clear, radius: 3)
                                    .onTapGesture {
                                        engine.reactiveFXRainbowColor = false
                                        engine.reactiveFXColorVelocity = vel
                                        engine.triggerRandomDemoReactiveFX()
                                        SoundEffect.knobTick.play(with: engine.soundPack)
                                    }
                            }
                        }
                    }
                    .padding(5 * scale)
                    .background(Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    // Interactive Test Pulse Button + Live Active Wave Counter (doubles in size when expanded)
                    HStack(spacing: 6) {
                        Button(action: {
                            engine.triggerRandomDemoReactiveFX()
                        }) {
                            HStack(spacing: 4 * scale) {
                                Image(systemName: "hand.tap.fill")
                                    .font(.system(size: 13.0 * scale))
                                Text("TEST RIPPLE PULSE")
                                    .font(.system(size: 12.0 * scale, weight: .heavy, design: .monospaced))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5 * scale)
                            .background(activeColor.opacity(0.24))
                            .foregroundColor(activeColor)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(activeColor.opacity(0.55), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        Text(engine.reactiveWaveCount == 0 ? "PRESS ANY KEY" : "⚡ \(engine.reactiveWaveCount) WAVES")
                            .font(.system(size: 11.5 * scale, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.reactiveWaveCount == 0 ? Color(white: 0.55) : Color.yellow)
                            .padding(.horizontal, 6 * scale)
                            .padding(.vertical, 5 * scale)
                            .background(Color.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(9)
        .background(isSpotlight ? Color.clear : Color.black.opacity(0.46))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSpotlight ? Color.clear : (isEnabled ? activeColor.opacity(0.75) : engine.currentTheme.sectionOutline.opacity(0.5)), lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // --- WING HELPER VIEWS ---
    private func wingTabButton(title: String, active: Bool, scale: CGFloat = 1.0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12 * scale, weight: .heavy, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6.5 * scale)
                .background(active ? engine.currentTheme.accentPrimary : Color.white.opacity(0.08))
                .foregroundColor(active ? .black : Color(white: 0.88))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .hoverGrow(1.05)
    }

    private func filterTogglePill(label: String, isOn: Binding<Bool>, scale: CGFloat = 1.0) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            HStack(spacing: 3 * scale) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11 * scale))
                Text(label)
                    .font(.system(size: 11.5 * scale, weight: .heavy, design: .monospaced))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4 * scale)
            .background(isOn.wrappedValue ? engine.currentTheme.accentPrimary.opacity(0.24) : Color.white.opacity(0.08))
            .foregroundColor(isOn.wrappedValue ? engine.currentTheme.accentPrimary : Color(white: 0.78))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .hoverGrow(1.04)
    }

    private func macroTriggerPad(title: String, icon: String, scale: CGFloat = 1.0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4 * scale) {
                Image(systemName: icon)
                    .font(.system(size: 13 * scale, weight: .bold))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                Text(title)
                    .font(.system(size: 13.5 * scale, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10 * scale)
            .padding(.horizontal, 4)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(engine.currentTheme.accentPrimary.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .hoverGrow(1.06)
    }

    private func miniCanvasKey(keyIndex: Int) -> some View {
        let safeFrame = min(max(0, engine.editingFrameIndex), max(0, engine.editingCustomFX.frames.count - 1))
        let vel: UInt8 = (!engine.editingCustomFX.frames.isEmpty && keyIndex < engine.editingCustomFX.frames[safeFrame].count)
            ? engine.editingCustomFX.frames[safeFrame][keyIndex]
            : 0
        return Button(action: {
            engine.paintCustomFXKey(keyIndex: keyIndex, velocity: engine.customBrushVelocity)
        }) {
            RoundedRectangle(cornerRadius: 3)
                .fill(vel == 0 ? Color(white: 0.14) : ledColor(vel))
                .frame(width: 17, height: 15)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(vel > 0 ? Color.white.opacity(0.6) : Color.white.opacity(0.15), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .hoverGrow(1.15)
    }

    private func miniToolBtn(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .heavy, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .hoverGrow(1.06)
    }

    // ------------------------------------------------------------------------
    // SECTION 1: TOP-LEFT 8X4 KEY GRID (32 KEYS)
    // ------------------------------------------------------------------------
    private var section1KeyGrid8x4: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("1. 8X4 KEY GRID")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)
                    .lineLimit(1)

                Text("32 KEYS")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.15, green: 0.85, blue: 0.95))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color(red: 0.15, green: 0.85, blue: 0.95).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Spacer(minLength: 4)

                if engine.detachedModules.contains(.keyGrid8x4) {
                    Text("POPPED OUT")
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color.cyan)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.cyan.opacity(0.15))
                        .clipShape(Capsule())
                }
                Button(action: {
                    engine.popOutModuleToWindow(.keyGrid8x4)
                }) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                        .frame(width: 28, height: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4.5))
                }
                .buttonStyle(.plain)
                .hoverGrow(1.08)
                .help("Pop Out 8x4 Key Grid into Floating Window")
            }
            .frame(width: 486)

            VStack(spacing: 7) {
                ForEach(0..<4, id: \.self) { r in
                    HStack(spacing: 7) {
                        ForEach(0..<8, id: \.self) { c in
                            let idx = r * 8 + c
                            HardwareKeyCap(
                                item: engine.controls[idx],
                                isSelected: engine.selectedIndices.contains(idx) || engine.selectedIndex == idx,
                                color: ledColor(engine.controls[idx].currentLED),
                                sectionBorder: engine.currentTheme.sectionOutline,
                                keyWidth: 52,
                                keyHeight: 45,
                                onTap: {
                                    isEditingNameBox = false
                                    let isShift = NSEvent.modifierFlags.contains(.shift)
                                    engine.handleKeyPressWithModifiers(index: idx, isShiftDown: isShift)
                                }
                            )
                            .equatable()
                            .contextMenu { controlContextMenu(for: idx) }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(red: 0.08, green: 0.04, blue: 0.04).opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(engine.currentTheme.sectionOutline.opacity(0.85), lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .allowsHitTesting(engine.isSectionEnabled(for: 0))
            .overlay {
                if !engine.isSectionEnabled(for: 0) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black)
                        VStack(spacing: 5) {
                            Image(systemName: "poweroff")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(Color.white.opacity(0.22))
                            Text("KEY GRID // BLACKOUT")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.30))
                        }
                    }
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .transition(.opacity)
                }
            }
        }
        .frame(width: 486)
    }

    // ------------------------------------------------------------------------
    // SECTION 2: MIDDLE 1X8 KEY STRIP (8 KEYS)
    // ------------------------------------------------------------------------
    private var section2KeyStrip1x8: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("2. 1X8 KEY STRIP")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)
                    .lineLimit(1)

                Text("8 KEYS")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.35))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color(red: 0.96, green: 0.78, blue: 0.35).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Spacer(minLength: 4)

                if engine.detachedModules.contains(.keyStrip1x8) {
                    Text("POPPED OUT")
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color.cyan)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.cyan.opacity(0.15))
                        .clipShape(Capsule())
                }
                Button(action: {
                    engine.popOutModuleToWindow(.keyStrip1x8)
                }) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                        .frame(width: 28, height: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4.5))
                }
                .buttonStyle(.plain)
                .hoverGrow(1.08)
                .help("Pop Out 1x8 Key Strip into Floating Window")
            }
            .frame(width: 486)

            HStack(spacing: 7) {
                ForEach(32..<40, id: \.self) { idx in
                    HardwareKeyCap(
                        item: engine.controls[idx],
                        isSelected: engine.selectedIndices.contains(idx) || engine.selectedIndex == idx,
                        color: ledColor(engine.controls[idx].currentLED),
                        sectionBorder: engine.currentTheme.sectionOutline,
                        keyWidth: 52,
                        keyHeight: 45,
                        onTap: {
                            let isShift = NSEvent.modifierFlags.contains(.shift)
                            engine.handleKeyPressWithModifiers(index: idx, isShiftDown: isShift)
                        }
                    )
                    .equatable()
                    .contextMenu { controlContextMenu(for: idx) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(red: 0.08, green: 0.04, blue: 0.04).opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(engine.currentTheme.sectionOutline.opacity(0.85), lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .allowsHitTesting(engine.isSectionEnabled(for: 32))
            .overlay {
                if !engine.isSectionEnabled(for: 32) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black)
                        HStack(spacing: 6) {
                            Image(systemName: "poweroff")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Color.white.opacity(0.22))
                            Text("KEY STRIP // BLACKOUT")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.30))
                        }
                    }
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .transition(.opacity)
                }
            }
        }
        .frame(width: 486)
    }

    // ------------------------------------------------------------------------
    // SECTION 4: BOTTOM-LEFT 8 VERTICAL FADERS (CC 0–7)
    // ------------------------------------------------------------------------
    private var section4VerticalFaders: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("4. 8 V-FADERS")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)
                    .lineLimit(1)

                Text("CC 0–7")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.22, green: 0.96, blue: 0.76))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color(red: 0.22, green: 0.96, blue: 0.76).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Spacer(minLength: 4)

                if engine.detachedModules.contains(.verticalFaders) {
                    Text("POPPED OUT")
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color.cyan)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.cyan.opacity(0.15))
                        .clipShape(Capsule())
                }
                Button(action: {
                    engine.vuMeterLEDsEnabled.toggle()
                    if engine.vuMeterLEDsEnabled {
                        engine.applyFXMode(.vuMeter)
                    } else {
                        engine.applyFXMode(.staticFX)
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "slider.vertical.3")
                        Text(engine.vuMeterLEDsEnabled ? "VU LEDS: ON" : "VU LEDS: OFF")
                            .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                            .lineLimit(1)
                    }
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.5))
                    .foregroundColor(engine.vuMeterLEDsEnabled ? Color(red: 0.22, green: 0.96, blue: 0.76) : Color(white: 0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(red: 0.22, green: 0.96, blue: 0.76).opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(action: {
                    engine.popOutModuleToWindow(.verticalFaders)
                }) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                        .frame(width: 28, height: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4.5))
                }
                .buttonStyle(.plain)
                .hoverGrow(1.08)
                .help("Pop Out Vertical Faders into Floating Window")
            }
            .frame(width: 486)

            HStack(spacing: 7) {
                ForEach(49..<57, id: \.self) { idx in
                    HardwareVerticalFader(
                        item: engine.controls[idx],
                        isSelected: engine.selectedIndex == idx,
                        faderWidth: 52,
                        faderHeight: 210,
                        onSelect: { engine.selectedIndex = idx },
                        onValueChange: { val in engine.setControlLiveValue(index: idx, value: val) }
                    )
                    .equatable()
                                .contextMenu { controlContextMenu(for: idx) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .allowsHitTesting(engine.isSectionEnabled(for: 49))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(engine.currentTheme.sectionOutline.opacity(0.85), lineWidth: 1.2)
            )
            .overlay {
                if !engine.isSectionEnabled(for: 49) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black)
                        VStack(spacing: 6) {
                            Image(systemName: "poweroff")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(Color.white.opacity(0.22))
                            Text("V-FADERS // BLACKOUT")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.30))
                        }
                    }
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .transition(.opacity)
                }
            }
        }
        .frame(width: 486)
    }

    // ------------------------------------------------------------------------
    // SECTION 5: 4 HORIZONTAL FADERS (CC 8-11)
    // ------------------------------------------------------------------------
    private var section5HorizontalFaders: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("5. 4 H-FADERS")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)
                    .lineLimit(1)

                Text("CC 8–11")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.55))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Spacer(minLength: 4)

                if engine.detachedModules.contains(.horizontalFaders) {
                    Text("POPPED OUT")
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color.cyan)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.cyan.opacity(0.15))
                        .clipShape(Capsule())
                }
                Button(action: {
                    engine.popOutModuleToWindow(.horizontalFaders)
                }) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                        .frame(width: 28, height: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4.5))
                }
                .buttonStyle(.plain)
                .hoverGrow(1.08)
                .help("Pop Out Horizontal Faders into Floating Window")
            }
            .frame(width: 280)

            VStack(spacing: 3) {
                ForEach(57..<61, id: \.self) { idx in
                    HardwareHorizontalFader(
                        item: engine.controls[idx],
                        isSelected: engine.selectedIndex == idx,
                        onSelect: { engine.selectedIndex = idx },
                        onValueChange: { val in engine.setControlLiveValue(index: idx, value: val) }
                    )
                    .equatable()
                                .contextMenu { controlContextMenu(for: idx) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .allowsHitTesting(engine.isSectionEnabled(for: 57))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(engine.currentTheme.sectionOutline.opacity(0.85), lineWidth: 1.2)
            )
            .overlay {
                if !engine.isSectionEnabled(for: 57) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black)
                        VStack(spacing: 5) {
                            Image(systemName: "poweroff")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Color.white.opacity(0.22))
                            Text("H-FADERS // BLACKOUT")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.30))
                        }
                    }
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .transition(.opacity)
                }
            }
        }
    }

    // ----------------------------–-------------------------------------------
    // SECTION 6: 2X4 ROTARY KNOBS (CC 20–27)
    // ------------------------------------------------------------------------
    private var section6RotaryKnobs: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("6. 2X4 KNOBS")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)
                    .lineLimit(1)

                Text("CC 20–27")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.55))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Spacer(minLength: 4)

                if engine.detachedModules.contains(.rotaryKnobs) {
                    Text("POPPED OUT")
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color.cyan)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.cyan.opacity(0.15))
                        .clipShape(Capsule())
                }
                Button(action: {
                    engine.popOutModuleToWindow(.rotaryKnobs)
                }) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                        .frame(width: 28, height: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4.5))
                }
                .buttonStyle(.plain)
                .hoverGrow(1.08)
                .help("Pop Out Rotary Knobs into Floating Window")
            }
            .frame(width: 226)

            VStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { r in
                    HStack(spacing: 20) {
                        ForEach(0..<2, id: \.self) { c in
                            let idx = 61 + r * 2 + c
                            HardwareKnob(
                                item: engine.controls[idx],
                                isSelected: engine.selectedIndex == idx,
                                onSelect: { engine.selectedIndex = idx },
                                onValueChange: { val in engine.setControlLiveValue(index: idx, value: val) }
                            )
                            .equatable()
                                .contextMenu { controlContextMenu(for: idx) }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 226)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .allowsHitTesting(engine.isSectionEnabled(for: 61))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(engine.currentTheme.sectionOutline.opacity(0.85), lineWidth: 1.2)
            )
            .overlay {
                if !engine.isSectionEnabled(for: 61) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black)
                        VStack(spacing: 6) {
                            Image(systemName: "poweroff")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(Color.white.opacity(0.22))
                            Text("KNOBS // BLACKOUT")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.30))
                        }
                    }
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .transition(.opacity)
                }
            }
        }
        .frame(width: 226)
    }

    @ViewBuilder
    private func controlContextMenu(for index: Int) -> some View {
        if index >= 0 && index < engine.controls.count {
            let item = engine.controls[index]
            Button(action: {
                mappingEditorTarget = ControlMappingTarget(id: index)
            }) {
                Label("Edit Mapping & Assignment…", systemImage: "slider.horizontal.3")
            }

            Divider()

            Button(action: {
                engine.copyControl(index: index)
            }) {
                Label("Copy Configuration (⌘C)", systemImage: "doc.on.doc")
            }

            Button(action: {
                engine.pasteControl(to: index)
            }) {
                Label("Paste Configuration (⌘V)", systemImage: "doc.badge.arrow.up")
            }
            .disabled(!engine.hasCopiedConfig)

            Button(action: {
                engine.duplicateControl(index: index)
            }) {
                Label("Duplicate to Adjacent Key", systemImage: "plus.square.on.square")
            }

            if item.hasLED {
                Divider()
                Button(action: {
                    engine.copySelectedColor(index: index)
                }) {
                    Label("Copy LED Color", systemImage: "paintpalette")
                }

                Button(action: {
                    engine.pasteColor(to: index)
                }) {
                    Label("Paste LED Color (⌥⌘V)", systemImage: "paintbrush.pointed")
                }
                .disabled(!engine.hasCopiedColor)

                Menu("Set Authentic Hardware Color") {
                    let swatches: [(String, UInt8)] = [
                        ("OFF", 0), ("WHITE", 3), ("TURQUOISE", 33), ("BLUE", 41),
                        ("ORANGE", 61), ("PURPLE", 67), ("RED", 72), ("YELLOW", 74),
                        ("CYAN", 78), ("BROWN", 83), ("GREEN", 87), ("PINK", 57), ("AMBER", 96)
                    ]
                    ForEach(swatches, id: \.1) { swatch in
                        Button(action: {
                            engine.recordUndoSnapshot(actionName: "Set Color \(swatch.0)")
                            engine.controls[index].activeVelocity = swatch.1
                            engine.controls[index].idleVelocity = swatch.1
                            engine.controls[index].currentLED = swatch.1
                            engine.sendNoteOn(note: engine.controls[index].number, velocity: swatch.1)
                            engine.saveCurrentSlot()
                            SoundEffect.knobTick.play(with: engine.soundPack)
                        }) {
                            HStack {
                                Text(swatch.0)
                                if item.activeVelocity == swatch.1 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            Button(action: {
                engine.resetControl(index: index)
            }) {
                Label("Reset to Factory Default", systemImage: "arrow.counterclockwise")
            }

            Divider()

            Button(action: {
                if engine.selectedIndices.contains(index) {
                    engine.selectedIndices.remove(index)
                } else {
                    engine.selectedIndices.insert(index)
                    engine.selectedIndex = index
                }
            }) {
                Label(engine.selectedIndices.contains(index) ? "Deselect Control" : "Select Control (Multi-Select)",
                      systemImage: engine.selectedIndices.contains(index) ? "checkmark.circle.fill" : "circle")
            }

            if engine.selectedIndices.count > 1 {
                Button(action: {
                    engine.pasteControlToSelected()
                }) {
                    Label("Paste Config to All \(engine.selectedIndices.count) Selected", systemImage: "square.on.square")
                }
                .disabled(!engine.hasCopiedConfig)

                if item.hasLED {
                    Button(action: {
                        engine.pasteColorToSelected()
                    }) {
                        Label("Paste Color to All \(engine.selectedIndices.count) Selected", systemImage: "paintbrush")
                    }
                    .disabled(!engine.hasCopiedColor)
                }
            }

            Button(action: {
                engine.selectAllOfKind(item.kind)
            }) {
                Label("Select All \(item.kind.rawValue)s", systemImage: "square.grid.2x2")
            }

            Divider()

            Button(action: {
                engine.simulateKeyPress(at: index)
            }) {
                Label("Trigger / Test Control", systemImage: "bolt.fill")
            }
        }
    }

    // ------------------------------------------------------------------------
    // CENTER INSPECTOR HUD
    // ------------------------------------------------------------------------
    private var centerInspectorHUD: some View {
        ZStack {
            // Inspector Bezel: Sleek dark milled slate chassis with chamfered inner bevel
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.08, green: 0.11, blue: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.35), Color.white.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(engine.currentTheme.accentPrimary.opacity(0.30), lineWidth: 1)
                        .padding(1)
                )
                .shadow(color: Color.black.opacity(0.55), radius: 8, x: 0, y: 3)

            // Precision Corner Screw Rivets
            VStack {
                HStack {
                    ScrewRivetView(size: 9)
                    Spacer()
                    ScrewRivetView(size: 9)
                }
                Spacer()
                HStack {
                    ScrewRivetView(size: 9)
                    Spacer()
                    ScrewRivetView(size: 9)
                }
            }
            .padding(5)

            // Inspector Content
            VStack(alignment: .leading, spacing: 6) {
                // Header badge with Stepper and Pop-Out
                HStack(spacing: 5) {
                    HStack(spacing: 3) {
                        Button(action: {
                            if engine.selectedIndex > 0 {
                                engine.selectedIndex -= 1
                                SoundEffect.knobTick.play(with: engine.soundPack)
                            }
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 20, height: 22)
                                .background(Color.white.opacity(0.14))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help("Previous Key/Control")

                        Text("\(selectedControl.label) // N\(selectedControl.number)")
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(engine.currentTheme.accentPrimary)
                            .foregroundColor(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 4.5))

                        Button(action: {
                            if engine.selectedIndex < engine.controls.count - 1 {
                                engine.selectedIndex += 1
                                SoundEffect.knobTick.play(with: engine.soundPack)
                            }
                        }) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 20, height: 22)
                                .background(Color.white.opacity(0.14))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help("Next Key/Control")
                    }

                    Spacer()

                    if engine.detachedModules.contains(.colorPickerHUD) {
                        Text("POPPED OUT")
                            .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                            .foregroundColor(Color.cyan)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.cyan.opacity(0.15))
                            .clipShape(Capsule())
                    }

                    Button(action: {
                        engine.popOutModuleToWindow(.colorPickerHUD)
                    }) {
                        Image(systemName: "macwindow.badge.plus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                            .frame(width: 28, height: 22)
                            .background(Color.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4.5))
                    }
                    .buttonStyle(.plain)
                    .hoverGrow(1.08)
                    .help("Pop Out Color Picker / HUD into Floating Window")

                    // Multi-select indicator badge
                    if engine.selectedIndices.count > 1 {
                        Text("\(engine.selectedIndices.count) SEL")
                            .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2.5)
                            .background(Color.cyan)
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                    }

                    // Key color swatch preview & formatted label
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3.5)
                            .fill(ledColor(selectedControl.currentLED))
                            .frame(width: 15, height: 15)
                            .overlay(RoundedRectangle(cornerRadius: 3.5).stroke(Color.white.opacity(0.4), lineWidth: 1))
                        Text(BitchBoyHardwareColor.formattedLabel(for: selectedControl.currentLED))
                            .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                            .foregroundColor(ledColor(selectedControl.currentLED))
                            .lineLimit(1)
                    }
                }

                // Quick Actions Toolbar: Copy, Paste, Paste Color, Undo, Redo, Reset
                HStack(spacing: 3) {
                    Button(action: {
                        engine.copyControl(index: engine.selectedIndex)
                    }) {
                        HStack(spacing: 2.5) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9.5, weight: .bold))
                            Text("COPY")
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.10))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    }
                    .buttonStyle(.plain)
                    .help("Copy control settings (⌘C)")

                    Button(action: {
                        engine.pasteControlToSelected()
                    }) {
                        HStack(spacing: 2.5) {
                            Image(systemName: "doc.badge.arrow.up")
                                .font(.system(size: 9.5, weight: .bold))
                            Text(engine.selectedIndices.count > 1 ? "PASTE (\(engine.selectedIndices.count))" : "PASTE")
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(engine.hasCopiedConfig ? engine.currentTheme.accentPrimary.opacity(0.25) : Color.white.opacity(0.04))
                        .foregroundColor(engine.hasCopiedConfig ? engine.currentTheme.accentPrimary : Color.white.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                        .overlay(RoundedRectangle(cornerRadius: 3.5).stroke(engine.hasCopiedConfig ? engine.currentTheme.accentPrimary.opacity(0.4) : Color.clear, lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                    .disabled(!engine.hasCopiedConfig)
                    .help("Paste control settings (⌘V)")

                    if selectedControl.hasLED {
                        Button(action: {
                            engine.pasteColorToSelected()
                        }) {
                            HStack(spacing: 2) {
                                Image(systemName: "paintbrush.fill")
                                    .font(.system(size: 9, weight: .bold))
                                Text("COLOR")
                                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            }
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 3)
                            .background(engine.hasCopiedColor ? Color.orange.opacity(0.22) : Color.white.opacity(0.04))
                            .foregroundColor(engine.hasCopiedColor ? Color.orange : Color.white.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                        }
                        .buttonStyle(.plain)
                        .disabled(!engine.hasCopiedColor)
                        .help("Paste copied color velocity (⌥⌘V)")
                    }

                    Spacer(minLength: 2)

                    Button(action: {
                        engine.undo()
                    }) {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 9.5, weight: .bold))
                            if engine.undoStepsCount > 0 {
                                Text("\(engine.undoStepsCount)")
                                    .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(engine.canUndo ? 0.10 : 0.04))
                        .foregroundColor(engine.canUndo ? engine.currentTheme.accentPrimary : Color.white.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!engine.canUndo)
                    .help("Undo (⌘Z) - \(engine.lastUndoActionName.isEmpty ? "None" : engine.lastUndoActionName)")

                    Button(action: {
                        engine.redo()
                    }) {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.system(size: 9.5, weight: .bold))
                            if engine.redoStepsCount > 0 {
                                Text("\(engine.redoStepsCount)")
                                    .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(engine.canRedo ? 0.10 : 0.04))
                        .foregroundColor(engine.canRedo ? engine.currentTheme.accentPrimary : Color.white.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!engine.canRedo)
                    .help("Redo (⇧⌘Z) - \(engine.lastRedoActionName.isEmpty ? "None" : engine.lastRedoActionName)")

                    Button(action: {
                        engine.resetSelectedControls()
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .background(Color.red.opacity(0.18))
                            .foregroundColor(Color(red: 1, green: 0.5, blue: 0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    }
                    .buttonStyle(.plain)
                    .help("Reset selected control to factory default")
                }
                .padding(.vertical, 2)

                // Custom Name Editor
                HStack(spacing: 5) {
                    Text("NAME:")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color(white: 0.70))

                    if isEditingNameBox {
                        TextField("Custom Name", text: $engine.controls[engine.selectedIndex].customName, onCommit: {
                            isEditingNameBox = false
                            engine.saveCurrentSlot()
                        })
                        .focused($isNameFieldFocused)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.85))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(engine.currentTheme.accentPrimary, lineWidth: 1.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        Button(action: {
                            isEditingNameBox = false
                            engine.saveCurrentSlot()
                        }) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9.5, weight: .heavy))
                                .padding(4)
                                .background(engine.currentTheme.accentPrimary)
                                .foregroundColor(.black)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack(spacing: 5) {
                            let custom = engine.controls[engine.selectedIndex].customName
                            Text(custom.isEmpty ? selectedControl.label : custom)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(custom.isEmpty ? Color(white: 0.55) : .white)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "pencil")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(Color(white: 0.55))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isEditingNameBox = true
                            isNameFieldFocused = true
                        }
                    }
                }

                // Subtitle: Zone Location & Feedback Mode
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(selectedControl.zone)
                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer()
                    }
                    HStack {
                        Text("MODE: \(selectedControl.feedbackMode.rawValue) // \(selectedControl.actionType.rawValue)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.35))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer()
                    }
                }

                if selectedControl.hasLED {
                    // Sub-Tab Switcher: LED Colors vs MIDI -> QWERTY Keyboard
                    HStack(spacing: 4) {
                        Button(action: {
                            inspectorTab = 0
                            SoundEffect.knobTick.play(with: engine.soundPack)
                        }) {
                            Text("💡 LED COLORS")
                                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(inspectorTab == 0 ? engine.currentTheme.accentPrimary : Color.white.opacity(0.08))
                                .foregroundColor(inspectorTab == 0 ? .black : Color(white: 0.80))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            inspectorTab = 1
                            SoundEffect.knobTick.play(with: engine.soundPack)
                        }) {
                            HStack(spacing: 3) {
                                Text("⌨️ QWERTY KEY")
                                if selectedControl.actionType == .qwerty {
                                    Circle().fill(Color(red: 0.98, green: 0.78, blue: 0.25)).frame(width: 5, height: 5)
                                }
                            }
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(inspectorTab == 1 ? Color(red: 0.98, green: 0.78, blue: 0.25) : Color.white.opacity(0.08))
                            .foregroundColor(inspectorTab == 1 ? .black : Color(white: 0.80))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }

                    if inspectorTab == 0 {
                        // TAB 1: LED VELOCITIES & PALETTE
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(engine.selectedIndices.count > 1 ? "IDLE LED (BATCH):" : "IDLE LED:")
                                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                    .foregroundColor(Color(white: 0.80))
                                Spacer()

                                // Direct Velocity Number Input Box
                                HStack(spacing: 3) {
                                    Text("VEL:")
                                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                        .foregroundColor(Color(white: 0.60))
                                    TextField("0", text: Binding(
                                        get: { String(engine.controls[engine.selectedIndex].idleVelocity) },
                                        set: { val in
                                            let digits = val.filter { $0.isNumber }
                                            if let num = Int(digits) {
                                                let clamped = UInt8(min(max(num, 0), 127))
                                                let targets = engine.selectedIndices.count > 1 ? engine.selectedIndices : [engine.selectedIndex]
                                                for idx in targets where engine.controls[idx].hasLED {
                                                    engine.controls[idx].idleVelocity = clamped
                                                    engine.controls[idx].currentLED = clamped
                                                    engine.sendNoteOn(note: engine.controls[idx].number, velocity: clamped)
                                                }
                                                engine.saveCurrentSlot()
                                            }
                                        }
                                    ))
                                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 34, height: 18)
                                    .background(Color.black.opacity(0.7))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3.5)
                                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
                                }

                                Circle()
                                    .fill(ledColor(engine.controls[engine.selectedIndex].idleVelocity))
                                    .frame(width: 9, height: 9)
                                Text(BitchBoyHardwareColor.formattedLabel(for: engine.controls[engine.selectedIndex].idleVelocity))
                                    .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                                    .foregroundColor(ledColor(engine.controls[engine.selectedIndex].idleVelocity))
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(engine.controls[engine.selectedIndex].idleVelocity) },
                                    set: { v in
                                        let u = UInt8(v)
                                        let targets = engine.selectedIndices.count > 1 ? engine.selectedIndices : [engine.selectedIndex]
                                        for idx in targets where engine.controls[idx].hasLED {
                                            engine.controls[idx].idleVelocity = u
                                            engine.controls[idx].currentLED = u
                                            engine.sendNoteOn(note: engine.controls[idx].number, velocity: u)
                                        }
                                        engine.saveCurrentSlot()
                                    }
                                ),
                                in: 0...127,
                                step: 1
                            )
                            .tint(Color(red: 0.85, green: 0.35, blue: 0.30))
                        }

                        // Pressed Velocity Slider
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(engine.selectedIndices.count > 1 ? "PRESSED LED (BATCH):" : "PRESSED LED:")
                                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                    .foregroundColor(Color(white: 0.80))
                                Spacer()

                                // Direct Velocity Number Input Box
                                HStack(spacing: 3) {
                                    Text("VEL:")
                                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                        .foregroundColor(Color(white: 0.60))
                                    TextField("0", text: Binding(
                                        get: { String(engine.controls[engine.selectedIndex].activeVelocity) },
                                        set: { val in
                                            let digits = val.filter { $0.isNumber }
                                            if let num = Int(digits) {
                                                let clamped = UInt8(min(max(num, 0), 127))
                                                let targets = engine.selectedIndices.count > 1 ? engine.selectedIndices : [engine.selectedIndex]
                                                for idx in targets where engine.controls[idx].hasLED {
                                                    engine.controls[idx].activeVelocity = clamped
                                                }
                                                engine.saveCurrentSlot()
                                            }
                                        }
                                    ))
                                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 34, height: 18)
                                    .background(Color.black.opacity(0.7))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3.5)
                                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
                                }

                                Circle()
                                    .fill(ledColor(engine.controls[engine.selectedIndex].activeVelocity))
                                    .frame(width: 9, height: 9)
                                Text(BitchBoyHardwareColor.formattedLabel(for: engine.controls[engine.selectedIndex].activeVelocity))
                                    .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                                    .foregroundColor(ledColor(engine.controls[engine.selectedIndex].activeVelocity))
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(engine.controls[engine.selectedIndex].activeVelocity) },
                                    set: { v in
                                        let u = UInt8(v)
                                        let targets = engine.selectedIndices.count > 1 ? engine.selectedIndices : [engine.selectedIndex]
                                        for idx in targets where engine.controls[idx].hasLED {
                                            engine.controls[idx].activeVelocity = u
                                        }
                                        engine.saveCurrentSlot()
                                    }
                                ),
                                in: 0...127,
                                step: 1
                            )
                            .tint(Color(red: 0.85, green: 0.35, blue: 0.30))
                        }

                        // 13 Hardware Colors
                        VStack(alignment: .leading, spacing: 3) {
                            Text("QUICK COLOR PALETTE:")
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                .foregroundColor(Color(white: 0.65))
                            HStack(spacing: 4) {
                                let quickColors: [UInt8] = [0, 3, 33, 41, 57, 61, 67, 72, 74, 78, 83, 87, 96]
                                ForEach(quickColors, id: \.self) { vel in
                                    Circle()
                                        .fill(ledColor(vel))
                                        .frame(width: 14, height: 14)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white, lineWidth: engine.controls[engine.selectedIndex].activeVelocity == vel ? 2.0 : 0)
                                        )
                                        .shadow(color: engine.controls[engine.selectedIndex].activeVelocity == vel ? ledColor(vel) : .clear, radius: 3)
                                        .onTapGesture {
                                            let targets = engine.selectedIndices.count > 1 ? engine.selectedIndices : [engine.selectedIndex]
                                            for idx in targets where engine.controls[idx].hasLED {
                                                engine.controls[idx].activeVelocity = vel
                                            }
                                            engine.saveCurrentSlot()
                                            SoundEffect.knobTick.play(with: engine.soundPack)
                                        }
                                }
                            }
                        }
                        .padding(.top, 2)

                        // Large Fill Buttons
                        HStack(spacing: 5) {
                            Button("FILL 8x4") { engine.setZoneLEDs(range: 0..<32, velocity: selectedControl.idleVelocity) }
                            Button("FILL 1x8") { engine.setZoneLEDs(range: 32..<40, velocity: selectedControl.idleVelocity) }
                            Button("FILL 3x3") { engine.setZoneLEDs(range: 40..<49, velocity: selectedControl.idleVelocity) }
                            Button("ALL 49") { engine.setZoneLEDs(range: 0..<49, velocity: selectedControl.idleVelocity) }
                        }
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .buttonStyle(.plain)
                        .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.35))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .background(Color.black.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    } else {
                        // TAB 2: MIDI -> QWERTY KEYBOARD MAPPING
                        VStack(alignment: .leading, spacing: 5) {
                            // Mode Toggle: MIDI Only vs QWERTY Active
                            HStack {
                                Text("KEY MODE:")
                                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                    .foregroundColor(Color(white: 0.70))

                                Spacer()

                                Button(action: {
                                    let targets = engine.selectedIndices.count > 1 ? Array(engine.selectedIndices) : [engine.selectedIndex]
                                    let newType: ActionType = (engine.controls[engine.selectedIndex].actionType == .qwerty) ? .passthrough : .qwerty
                                    for idx in targets where engine.controls[idx].hasLED {
                                        engine.controls[idx].actionType = newType
                                        if newType == .qwerty && engine.controls[idx].qwertySteps.isEmpty {
                                            engine.controls[idx].qwertySteps = [QwertyStep(key: "space")]
                                        }
                                    }
                                    engine.saveCurrentSlot()
                                    SoundEffect.knobTick.play(with: engine.soundPack)
                                }) {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(engine.controls[engine.selectedIndex].actionType == .qwerty ? Color(red: 0.98, green: 0.78, blue: 0.25) : Color(white: 0.4))
                                            .frame(width: 6, height: 6)
                                        Text(engine.controls[engine.selectedIndex].actionType == .qwerty ? "QWERTY ACTIVE" : "MIDI PASS-THRU")
                                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3.5)
                                    .background(engine.controls[engine.selectedIndex].actionType == .qwerty ? Color(red: 0.98, green: 0.78, blue: 0.25).opacity(0.2) : Color.white.opacity(0.08))
                                    .foregroundColor(engine.controls[engine.selectedIndex].actionType == .qwerty ? Color(red: 0.98, green: 0.78, blue: 0.25) : Color(white: 0.70))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                            }

                            if engine.controls[engine.selectedIndex].actionType == .qwerty {
                                let curStep = engine.controls[engine.selectedIndex].qwertySteps.first ?? QwertyStep(key: "space")
                                let curKey = curStep.key

                                // Key Picker & Live Test
                                HStack(spacing: 5) {
                                    Text("KEY:")
                                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                        .foregroundColor(Color(white: 0.70))

                                    // Quick Pick Menu
                                    Menu {
                                        Section("COMMON KEYS") {
                                            ForEach(["space", "return", "escape", "tab", "delete", "up", "down", "left", "right"], id: \.self) { k in
                                                Button(k.uppercased()) {
                                                    setQwertyKeyForSelection(k)
                                                }
                                            }
                                        }
                                        Section("FUNCTION KEYS (F1–F24)") {
                                            ForEach((1...24).map { "f\($0)" }, id: \.self) { k in
                                                Button(k.uppercased()) {
                                                    setQwertyKeyForSelection(k)
                                                }
                                            }
                                        }
                                        Section("LETTERS (A–Z)") {
                                            ForEach(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"], id: \.self) { k in
                                                Button(k.uppercased()) {
                                                    setQwertyKeyForSelection(k)
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 3) {
                                            Text(curKey.uppercased())
                                                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                                .foregroundColor(Color(red: 0.98, green: 0.78, blue: 0.25))
                                            Image(systemName: "chevron.up.chevron.down")
                                                .font(.system(size: 8))
                                                .foregroundColor(Color(white: 0.7))
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3.5)
                                        .background(Color.black.opacity(0.65))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    .menuStyle(.borderlessButton)

                                    // Custom input field
                                    TextField("Key", text: Binding(
                                        get: { engine.controls[engine.selectedIndex].qwertySteps.first?.key ?? "" },
                                        set: { val in
                                            let clean = val.lowercased().trimmingCharacters(in: .whitespaces)
                                            setQwertyKeyForSelection(clean)
                                        }
                                    ))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .textFieldStyle(.plain)
                                    .frame(width: 48)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2.5)
                                    .background(Color.black.opacity(0.65))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                    Spacer()

                                    // Direct sub-millisecond CGEvent Test Button
                                    Button(action: {
                                        if let step = engine.controls[engine.selectedIndex].qwertySteps.first {
                                            engine.triggerSingleQwerty(key: step.key, cmd: step.cmd, shift: step.shift, alt: step.alt, ctrl: step.ctrl)
                                        }
                                    }) {
                                        HStack(spacing: 3) {
                                            Image(systemName: "play.fill")
                                                .font(.system(size: 8))
                                            Text("TEST")
                                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.green.opacity(0.25))
                                        .foregroundColor(.green)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    .buttonStyle(.plain)
                                }

                                // Modifiers Row
                                HStack(spacing: 4) {
                                    Text("MODS:")
                                        .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                                        .foregroundColor(Color(white: 0.70))
                                    Button(action: { toggleQwertyModifierForSelection { $0.cmd.toggle() } }) {
                                        Text("⌘ CMD")
                                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2.5)
                                            .background(curStep.cmd ? Color(red: 0.98, green: 0.78, blue: 0.25) : Color.white.opacity(0.08))
                                            .foregroundColor(curStep.cmd ? .black : Color(white: 0.80))
                                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: { toggleQwertyModifierForSelection { $0.shift.toggle() } }) {
                                        Text("⇧ SHIFT")
                                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2.5)
                                            .background(curStep.shift ? Color(red: 0.98, green: 0.78, blue: 0.25) : Color.white.opacity(0.08))
                                            .foregroundColor(curStep.shift ? .black : Color(white: 0.80))
                                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: { toggleQwertyModifierForSelection { $0.alt.toggle() } }) {
                                        Text("⌥ OPT")
                                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2.5)
                                            .background(curStep.alt ? Color(red: 0.98, green: 0.78, blue: 0.25) : Color.white.opacity(0.08))
                                            .foregroundColor(curStep.alt ? .black : Color(white: 0.80))
                                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: { toggleQwertyModifierForSelection { $0.ctrl.toggle() } }) {
                                        Text("⌃ CTRL")
                                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2.5)
                                            .background(curStep.ctrl ? Color(red: 0.98, green: 0.78, blue: 0.25) : Color.white.opacity(0.08))
                                            .foregroundColor(curStep.ctrl ? .black : Color(white: 0.80))
                                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                                    }
                                    .buttonStyle(.plain)
                                }

                                // Quick Shortcut Templates Row
                                HStack(spacing: 4) {
                                    Button("SPACE") { setQwertyKeyForSelection("space") }
                                    Button("RETURN") { setQwertyKeyForSelection("return") }
                                    Button("ESC") { setQwertyKeyForSelection("escape") }
                                    Button("⌘C") {
                                        setQwertyKeyForSelection("c")
                                        toggleQwertyModifierForSelection { $0.cmd = true }
                                    }
                                    Button("⌘V") {
                                        setQwertyKeyForSelection("v")
                                        toggleQwertyModifierForSelection { $0.cmd = true }
                                    }
                                    Button("⌘Z") {
                                        setQwertyKeyForSelection("z")
                                        toggleQwertyModifierForSelection { $0.cmd = true }
                                    }
                                }
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                .buttonStyle(.plain)
                                .foregroundColor(Color(red: 0.98, green: 0.78, blue: 0.25))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
                                Text("Key acts as standard physical MIDI Note On / Off message.")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(Color(white: 0.70))
                                    .padding(.vertical, 6)
                            }
                        }
                        .padding(6)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                } else {
                    Text("ANALOG CC VALUE: \(selectedControl.liveValue)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.35))
                        .padding(.vertical, 10)
                }

                Spacer(minLength: 0)

                // RX Stream Telemetry
                HStack {
                    Text("RX STREAM:")
                        .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color(white: 0.80))
                        .lineLimit(1)
                    Spacer()
                    Text(engine.lastStreamMessage)
                        .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .onChange(of: engine.selectedIndex) {
            isEditingNameBox = false
        }
        .onChange(of: isNameFieldFocused) {
            if !isNameFieldFocused && isEditingNameBox {
                isEditingNameBox = false
                engine.saveCurrentSlot()
            }
        }
    }

    // SECTION 3: 3X3 KEYPAD & OFFICIAL MASCOT (9 KEYS)
    // ------------------------------------------------------------------------
    private var section3KeypadAndMascot: some View {
        VStack(spacing: 6) {
            // Interactive Official Mascot (bitchboy.png) with Speech Bubble
            VStack(spacing: 3) {
                // Speech Bubble Clearance Zone (Dedicated clearance above mascot so it never clips knobs)
                ZStack(alignment: .bottom) {
                    if engine.mascotSpeechVisible {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8, weight: .bold))
                            Text(engine.mascotSpeech)
                                .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Color(red: 0.05, green: 0.08, blue: 0.10).opacity(0.95))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(engine.currentTheme.accentPrimary.opacity(0.8), lineWidth: 1)
                        )
                        .shadow(color: engine.currentTheme.accentPrimary.opacity(0.35), radius: 4)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .frame(width: 226, height: engine.mascotSpeechVisible ? 24 : 0)

                BitchBoyOfficialMascotView(auraColor: engine.currentTheme.accentPrimary) {
                    engine.triggerMascotTap()
                }
                .scaleEffect(engine.mascotScale)
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: engine.mascotScale)
            }

            HStack(spacing: 5) {
                Text("3. 3X3 KEYPAD")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)
                    .lineLimit(1)

                Text("9 KEYS")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.55))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Spacer(minLength: 4)

                if engine.detachedModules.contains(.keypad3x3) {
                    Text("POPPED OUT")
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color.cyan)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.cyan.opacity(0.15))
                        .clipShape(Capsule())
                }
                Button(action: {
                    engine.popOutModuleToWindow(.keypad3x3)
                }) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                        .frame(width: 28, height: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4.5))
                }
                .buttonStyle(.plain)
                .hoverGrow(1.08)
                .help("Pop Out 3x3 Keypad into Floating Window")
            }
            .frame(width: 226)

            // 3x3 Grid with Spaced Tactile Keycaps
            VStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: 7) {
                        ForEach(0..<3, id: \.self) { c in
                            let idx = 40 + r * 3 + c
                            HardwareKeyCap(
                                item: engine.controls[idx],
                                isSelected: engine.selectedIndices.contains(idx) || engine.selectedIndex == idx,
                                color: ledColor(engine.controls[idx].currentLED),
                                sectionBorder: engine.currentTheme.sectionOutline,
                                keyWidth: 58,
                                keyHeight: 44,
                                onTap: {
                                    isEditingNameBox = false
                                    let isShift = NSEvent.modifierFlags.contains(.shift)
                                    engine.handleKeyPressWithModifiers(index: idx, isShiftDown: isShift)
                                }
                            )
                            .equatable()
                            .contextMenu { controlContextMenu(for: idx) }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(red: 0.08, green: 0.04, blue: 0.04).opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(engine.currentTheme.sectionOutline.opacity(0.85), lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .allowsHitTesting(engine.isSectionEnabled(for: 40))
            .overlay {
                if !engine.isSectionEnabled(for: 40) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black)
                        VStack(spacing: 5) {
                            Image(systemName: "poweroff")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(Color.white.opacity(0.22))
                            Text("KEYPAD // BLACKOUT")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.30))
                        }
                    }
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .transition(.opacity)
                }
            }

            // Footer branding
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text("CE")
                        .font(.system(size: 8.0, weight: .heavy, design: .monospaced))
                    Image(systemName: "trash.fill")
                        .font(.system(size: 7.5, weight: .bold))
                    Text("•")
                        .font(.system(size: 8.0))
                    Text("BitchBoy")
                        .font(.system(size: 8.0, weight: .heavy, design: .monospaced))
                }
                .foregroundColor(Color(white: 0.65))

                Text("BLOCK SYSTEM HARDWARE")
                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(Color(white: 0.50))
            }
            .padding(.top, 4)
        }
    }
}

// ============================================================================
// 5. APP ENTRYPOINT & MENUBAR COMPANION
// ============================================================================

@main
struct BitchBoyNativeApp: App {
    @State private var engine = BitchBoyEngine()

    var body: some Scene {
        WindowGroup("BitchManager") {
            ContentView(engine: engine)
                .frame(minWidth: 1538 * 0.25, minHeight: 760 * 0.15)
        }
        .defaultSize(width: 1540, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About BitchManager...") {
                    let creditsText = """
                    BitchBoy Hardware Controller Manager & Studio Console
                    Release 3.0 • Created by Taylor Fossen

                    • 49-Pad LED Matrix & Reactive FX Engine
                    • Right-Click Mapping & Assignment Editor for every control
                    • Undo / Redo, Copy / Paste & Hardware MIDI Isolation Profiles
                    • Pop-out Standalone Floating Modules (⌘W auto re-dock)
                    • Protocol Terminal & Network Traffic Monitor:
                      - Live MIDI IN/OUT, OSC IN/OUT, Art-Net & sACN (E1.31) packet sniffer
                      - Interactive CLI for instant MIDI, OSC & Panic command injection
                      - Real-time network interface telemetry & throughput meters
                    • Modular Expansion Bays & Wing Racks
                    • Custom Sound & Theme Studio (featuring Prism Rainbow 🌈)
                    • High-Speed MIDI, OSC & CGEvent QWERTY Injection
                    • Direct LED Velocity Control & Slot Memory Banks
                    """
                    let attrString = NSAttributedString(
                        string: creditsText,
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 11),
                            .foregroundColor: NSColor.secondaryLabelColor
                        ]
                    )
                    var options: [NSApplication.AboutPanelOptionKey: Any] = [
                        .applicationName: "BitchManager",
                        .applicationVersion: "3.0.0",
                        .version: "Version 3.0.0 (5)",
                        .credits: attrString
                    ]
                    if let icon = NSImage(named: "AppIcon") ?? NSImage(named: "BitchBoyBadgeIcon") {
                        options[.applicationIcon] = icon
                    }
                    NSApplication.shared.orderFrontStandardAboutPanel(options: options)
                }
                Button("Check for Updates on GitHub...") {
                    engine.checkForUpdates(showModalIfCurrent: true)
                }
                Divider()
            }

            CommandGroup(replacing: .undoRedo) {
                Button(engine.lastUndoActionName.isEmpty ? "Undo" : "Undo \(engine.lastUndoActionName)") {
                    engine.undo()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!engine.canUndo)

                Button(engine.lastRedoActionName.isEmpty ? "Redo" : "Redo \(engine.lastRedoActionName)") {
                    engine.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!engine.canRedo)
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    engine.copyControl(index: engine.selectedIndex)
                    engine.resetControl(index: engine.selectedIndex)
                }
                .keyboardShortcut("x", modifiers: [.command])

                Button("Copy Control Configuration") {
                    engine.copyControl(index: engine.selectedIndex)
                }
                .keyboardShortcut("c", modifiers: [.command])

                Button("Paste Control Configuration") {
                    engine.pasteControlToSelected()
                }
                .keyboardShortcut("v", modifiers: [.command])
                .disabled(!engine.hasCopiedConfig)

                Button("Paste Color Only") {
                    engine.pasteColorToSelected()
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!engine.hasCopiedColor)

                Button("Duplicate Control Configuration") {
                    engine.duplicateControl(index: engine.selectedIndex)
                }
                .keyboardShortcut("d", modifiers: [.command])

                Divider()

                Button("Select All Controls") {
                    engine.selectedIndices = Set(0..<engine.controls.count)
                }
                .keyboardShortcut("a", modifiers: [.command])

                Button("Deselect All") {
                    engine.selectedIndices.removeAll()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Divider()

                Button("Clear Undo History") {
                    engine.clearUndoHistory()
                }
                .disabled(!engine.canUndo && !engine.canRedo)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save Preset Slot to Internal Memory") {
                    engine.saveCurrentSlot()
                    engine.log("💾 Preset saved to internal memory.")
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Clone Current Preset to Next Slot") {
                    engine.cloneCurrentSlot()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Export Preset JSON to Clipboard") {
                    _ = engine.exportPresetToJSON()
                }
                .keyboardShortcut("e", modifiers: [.command])

                Button("Import Preset JSON from Clipboard") {
                    engine.importPresetFromClipboard()
                }
                .keyboardShortcut("i", modifiers: [.command])

                Divider()

                Button("🚨 Panic Blackout (Kill All LEDs)") {
                    engine.blackoutPanic()
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button("Rescan BitchBoy Hardware") {
                    engine.scanForBitchBoy()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            CommandGroup(after: .toolbar) {
                Button("Zoom In (+10%)") {
                    engine.zoomInUI()
                }
                .keyboardShortcut("+", modifiers: [.command])

                Button("Zoom Out (-10%)") {
                    engine.zoomOutUI()
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button("Auto-Fit to Window") {
                    engine.enableAutoFitWindow()
                }
                .keyboardShortcut("0", modifiers: [.command])

                Menu("Fixed Scale Presets") {
                    Button("Scale 50%") { engine.setManualZoom(0.50) }
                    Button("Scale 75%") { engine.setManualZoom(0.75) }
                    Button("Scale 100% (Native)") { engine.setManualZoom(1.00) }
                    Button("Scale 125%") { engine.setManualZoom(1.25) }
                    Button("Scale 150%") { engine.setManualZoom(1.50) }
                    Button("Scale 200%") { engine.setManualZoom(2.00) }
                }

                Divider()

                Button(engine.isRearrangingModules ? "✓ Exit Rearrange Mode (Lock Layout)" : "Rearrange & Dynamic Layout Mode") {
                    engine.toggleRearrangeModulesMode()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("Reset Module Positions to Defaults") {
                    engine.resetModuleLayout()
                }

                Button("Compact Layout All Modules (210px)") {
                    for m in StudioModuleID.allCases {
                        engine.setModuleHeight(m, height: 210, save: false)
                    }
                    engine.saveModuleSizes()
                }

                Button("Standard Layout All Modules (340px)") {
                    for m in StudioModuleID.allCases {
                        engine.setModuleHeight(m, height: 340, save: false)
                    }
                    engine.saveModuleSizes()
                }

                Divider()

                Button("✨ Rainbow Refresh Wave") {
                    engine.runRainbowWaveRefresh()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                Menu("Chassis Glow Themes") {
                    ForEach(ChassisTheme.allCases.filter { $0 != .customUser }) { th in
                        Button(action: {
                            engine.currentTheme = th
                            UserDefaults.standard.set(th.rawValue, forKey: "BitchBoy_ChassisTheme_v2")
                            SoundEffect.presetSwitch.play(with: engine.soundPack)
                        }) {
                            HStack {
                                Text(th.rawValue)
                                if engine.currentTheme == th {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    if !engine.customThemes.isEmpty {
                        Divider()
                        ForEach(engine.customThemes) { customTh in
                            Button("★ " + customTh.name) {
                                engine.applyCustomTheme(customTh)
                            }
                        }
                    }
                }

                Menu("Audio Feedback Sounds") {
                    ForEach(SoundPack.allCases) { pack in
                        Button(action: { engine.setSoundPack(pack) }) {
                            HStack {
                                Text(pack.rawValue)
                                if engine.soundPack == pack {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            CommandMenu("Modules") {
                Button(engine.spotlightModule == .terminal ? "✓ Dismiss Protocol Terminal" : "Protocol Terminal & Packet Inspector") {
                    engine.toggleSpotlightModule(.terminal)
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button("Pop Out Terminal into Floating Window") {
                    engine.popOutModuleToWindow(.terminal)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("Spotlight: MIDI Router") { engine.toggleSpotlightModule(.midiRouter) }
                Button("Spotlight: Memory Slots") { engine.toggleSpotlightModule(.memorySlots) }
                Button("Spotlight: Custom FX Studio") { engine.toggleSpotlightModule(.customFXStudio) }
                Button("Spotlight: Reactive Key FX") { engine.toggleSpotlightModule(.reactiveKeyFX) }
                Button("Spotlight: Show Control (OSC/DMX)") { engine.toggleSpotlightModule(.showControl) }

                Divider()

                Button("Pop Out: MIDI Router Window") { engine.popOutModuleToWindow(.midiRouter) }
                Button("Pop Out: Memory Slots Window") { engine.popOutModuleToWindow(.memorySlots) }
                Button("Pop Out: Custom FX Window") { engine.popOutModuleToWindow(.customFXStudio) }
                Button("Pop Out: Reactive Key FX Window") { engine.popOutModuleToWindow(.reactiveKeyFX) }
                Button("Pop Out: Show Control Window") { engine.popOutModuleToWindow(.showControl) }

                Divider()

                Button("↙ Dock All Floating Windows Back to Console") {
                    engine.dockAllModules()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Clear Protocol Terminal Logs") {
                    engine.clearProtocolLogs()
                }
                .keyboardShortcut("l", modifiers: [.command])

                Button("Copy Protocol Logs to Clipboard") {
                    engine.exportProtocolLogsToClipboard()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Inject Mock Test Protocol Packets") {
                    engine.injectTestProtocolPacket()
                }

                Divider()

                Button("Increase Terminal Text Size") {
                    engine.increaseTerminalFontSize()
                }
                .keyboardShortcut("=", modifiers: [.command, .option])

                Button("Decrease Terminal Text Size") {
                    engine.decreaseTerminalFontSize()
                }
                .keyboardShortcut("-", modifiers: [.command, .option])

                Button("Reset Terminal Text Size to Default") {
                    engine.resetTerminalFontSize()
                }
                .keyboardShortcut("0", modifiers: [.command, .option])

                Divider()

                Button("Unmute & Enable All Inputs") {
                    engine.unmuteAllInputs()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }

            CommandMenu("Presets") {
                Button("Slot A (Bank 1)") { engine.selectSlot(0) }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Slot B (Bank 1)") { engine.selectSlot(1) }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Slot C (Bank 1)") { engine.selectSlot(2) }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("Slot D (Bank 1)") { engine.selectSlot(3) }
                    .keyboardShortcut("4", modifiers: [.command])
                Button("Slot E (Bank 2)") { engine.selectSlot(4) }
                    .keyboardShortcut("5", modifiers: [.command])
                Button("Slot F (Bank 2)") { engine.selectSlot(5) }
                    .keyboardShortcut("6", modifiers: [.command])
                Button("Slot G (Bank 2)") { engine.selectSlot(6) }
                    .keyboardShortcut("7", modifiers: [.command])
                Button("Slot H (Bank 2)") { engine.selectSlot(7) }
                    .keyboardShortcut("8", modifiers: [.command])

                Divider()

                Button("Next Preset Slot") {
                    let next = (engine.activeSlot + 1) % engine.slots.count
                    engine.selectSlot(next)
                }
                .keyboardShortcut("]", modifiers: [.command])

                Button("Previous Preset Slot") {
                    let prev = (engine.activeSlot - 1 + engine.slots.count) % engine.slots.count
                    engine.selectSlot(prev)
                }
                .keyboardShortcut("[", modifiers: [.command])
            }

            CommandMenu("Lighting & FX") {
                ForEach(LEDFXMode.allCases) { mode in
                    Button(action: { engine.applyFXMode(mode) }) {
                        HStack {
                            Text(mode.rawValue)
                            if engine.currentFXMode == mode && !engine.isPlayingCustomFX {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                if !engine.customEffects.isEmpty {
                    Divider()
                    Menu("Custom Light Shows") {
                        ForEach(engine.customEffects) { cfx in
                            Button("★ " + cfx.name) {
                                engine.playCustomEffect(cfx)
                            }
                        }
                    }
                }

                Divider()

                Button("⏹ Stop FX & Restore Preset LEDs") {
                    engine.stopCustomEffect()
                    engine.applyFXMode(.staticFX)
                }
                .keyboardShortcut(".", modifiers: [.command])
            }

            CommandGroup(after: .windowArrangement) {
                Divider()

                Button(engine.isWindowAlwaysOnTop ? "✓ Keep Window Always On Top" : "Keep Window Always On Top") {
                    engine.toggleWindowAlwaysOnTop()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

                Button("Auto-Fit Window Scale") {
                    engine.enableAutoFitWindow()
                }
                .keyboardShortcut("0", modifiers: [.command])

                Button("↙ Dock All Popped-Out Modules") {
                    engine.dockAllModules()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
        MenuBarExtra {
            Text(engine.isConnected ? "ONLINE: \(engine.deviceName)" : "OFFLINE // UNPLUGGED")
            Divider()
            if engine.updateAvailable, let rel = engine.latestRelease {
                Button("★ Update Available (\(rel.tagName))...") {
                    engine.showUpdateModal = true
                }
                Divider()
            }
            Button(engine.spotlightModule == .terminal ? "Hide Terminal" : "Show Terminal Protocol Monitor") {
                engine.toggleSpotlightModule(.terminal)
            }
            Button("Pop Out Terminal Window") {
                engine.popOutModuleToWindow(.terminal)
            }
            Divider()
            Button(engine.isWindowAlwaysOnTop ? "📌 Unpin Always On Top" : "📌 Pin Window Always On Top") {
                engine.toggleWindowAlwaysOnTop()
            }
            Button("✨ Trigger Rainbow Refresh") { engine.runRainbowWaveRefresh() }
            Button("🚨 Panic Blackout") { engine.blackoutPanic() }
            Divider()
            Menu("Load Preset Slot") {
                ForEach(0..<engine.slots.count, id: \.self) { idx in
                    Button("Load \(engine.slots[idx].name)") { engine.selectSlot(idx) }
                }
            }
            Menu("Cyber Themes") {
                ForEach(ChassisTheme.allCases.filter { $0 != .customUser }) { th in
                    Button(th.rawValue) {
                        engine.currentTheme = th
                        UserDefaults.standard.set(th.rawValue, forKey: "BitchBoy_ChassisTheme_v2")
                        SoundEffect.presetSwitch.play(with: engine.soundPack)
                    }
                }
            }
            Divider()
            Button("Check for Updates on GitHub...") {
                engine.checkForUpdates(showModalIfCurrent: true)
            }
            Button("Quit BitchManager") { NSApplication.shared.terminate(nil) }
        } label: {
            Image("BitchBoyMenuBarIcon")
                .renderingMode(.template)
        }
    }
}

// ============================================================================
// 6. XCODE CANVAS PREVIEW
// ============================================================================

#Preview("Full Console UI") {
    ContentView(engine: BitchBoyEngine())
        .frame(width: 1538, height: 760)
}

