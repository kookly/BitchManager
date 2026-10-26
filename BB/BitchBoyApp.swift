import SwiftUI
import AppKit
import CoreMIDI
import Network
import Combine
import UniformTypeIdentifiers

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
}

enum StudioModuleID: String, CaseIterable, Codable, Identifiable {
    case midiRouter = "MIDI ROUTER // OUT"
    case memorySlots = "MEMORY SLOTS // BANK"
    case customFXStudio = "CUSTOM FX STUDIO"
    case reactiveKeyFX = "REACTIVE KEY FX // LIVE"
    case showControl = "SHOW CONTROL // OSC STUDIO"

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
        }
    }

    var iconName: String {
        switch self {
        case .midiRouter: return "point.3.connected.trianglepath.dotted"
        case .memorySlots: return "memorychip.fill"
        case .customFXStudio: return "wand.and.stars"
        case .reactiveKeyFX: return "waveform.circle.fill"
        case .showControl: return "dot.radiowaves.left.and.right"
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
        }
    }

    var minWindowSize: NSSize {
        switch self {
        case .midiRouter: return NSSize(width: 320, height: 420)
        case .memorySlots: return NSSize(width: 320, height: 245)
        case .customFXStudio: return NSSize(width: 320, height: 450)
        case .reactiveKeyFX: return NSSize(width: 320, height: 225)
        case .showControl: return NSSize(width: 340, height: 460)
        }
    }

    var defaultSlotHeight: CGFloat {
        return 210
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

    func clearCustomSound(for effect: SoundEffect) {
        soundPaths.removeValue(forKey: effect.rawValue)
        UserDefaults.standard.set(soundPaths, forKey: storageKey)
    }

    func clearAllCustomSounds() {
        soundPaths.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    func playCustomIfAvailable(for effect: SoundEffect) -> Bool {
        guard let p = path(for: effect),
              let snd = NSSound(contentsOfFile: p, byReference: true) else {
            return false
        }
        snd.stop()
        snd.play()
        return true
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
    case customUser = "CUSTOM THEME"

    var id: String { rawValue }

    var pcbBackground: Color {
        switch self {
        case .petrolTeal: return Color(red: 0.04, green: 0.24, blue: 0.21)
        case .retroMatrix: return Color(red: 0.02, green: 0.16, blue: 0.08)
        case .neonCyber: return Color(red: 0.08, green: 0.02, blue: 0.18)
        case .royalGold: return Color(red: 0.18, green: 0.12, blue: 0.04)
        case .stealthBlack: return Color(red: 0.06, green: 0.06, blue: 0.07)
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
    // Purple 67, Brown 83, Off 0, White 3, Pink 95, Amber 96, Turqoise 33
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
        Item(name: "PINK", shortName: "PNK", velocity: 95, color: pink),
        Item(name: "AMBER", shortName: "AMB", velocity: 96, color: amber)
    ]

    static let knownVelocities: [UInt8] = [0, 3, 33, 41, 61, 67, 72, 74, 78, 83, 87, 95, 96]

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
        case 95: return pink
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
        case 95: return "PINK"
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
    var htmlUrl: String
    var publishedAt: String?
    var assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
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
    var browserDownloadUrl: String
    var size: Int
    var contentType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case browserDownloadUrl = "browser_download_url"
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

struct QwertyStep: Codable, Identifiable {
    var id = UUID()
    var key: String
    var cmd: Bool = false
    var shift: Bool = false
    var alt: Bool = false
    var ctrl: Bool = false
    var delayMs: Int = 10
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
// SHOW CONTROL PROTOCOL ENGINES: MSC (MIDI SHOW CONTROL), ART-NET 4 & sACN E1.31
// ============================================================================

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

struct ArtNetPacketBuilder {
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

struct SACNPacketBuilder {
    static let senderCID: [UInt8] = [
        0x42, 0x42, 0x4D, 0x41, 0x4E, 0x41, 0x47, 0x45,
        0x52, 0x2D, 0x53, 0x41, 0x43, 0x4E, 0x30, 0x31
    ]

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
        let sweepPalette: [UInt8] = [78, 87, 74, 95, 41, 67, 3]
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
                heartF1[k] = 95 // Pink
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
        let pal: [UInt8] = [78, 41, 67, 95, 74, 87]
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
        let barColors: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 95, 3]
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
    var lightningTargets: [Int] = []
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

// ============================================================================
// 2. HARDWARE ENGINE // COREMIDI & TELEMETRY
// ============================================================================

@MainActor
final class BitchBoyEngine: ObservableObject {
    private var lastStreamUpdateTime: Double = 0
    @Published var controls: [ControlItem] = []
    @Published var selectedIndex: Int = 0
    @Published var selectedIndices: Set<Int> = []
    @Published var slots: [PresetSlot] = []
    @Published var activeSlot: Int = 0

    // Hardware status
    @Published var isConnected: Bool = false
    @Published var deviceName: String = "BitchBoy V1 (Hardware)"
    @Published var lastStreamMessage: String = "IDLE // READY"
    @Published var midiLogs: [String] = []

    // Customization & Themes
    @Published var currentTheme: ChassisTheme = .petrolTeal
    @Published var ledPalette: LEDPaletteMode = .multiVelocity
    @Published var soundPack: SoundPack = .arcade8Bit
    @Published var currentFXMode: LEDFXMode = .staticFX
    @Published var fxSpeed: Double = 1.0
    @Published var vuMeterLEDsEnabled: Bool = false
    @Published var isRainbowRunning: Bool = false

    // Mascot
    @Published var mascotScale: CGFloat = 1.0
    @Published var mascotSpeech: String = "ALL 69 HARDWARE CONTROLS LIVE!"
    @Published var mascotSpeechVisible: Bool = false

    // In-Chassis Drawer
    @Published var inChassisTab: String = "NOTES"
    @Published var userNotesText: String = "Show notes: Slot A configured for live Ableton clip triggers."

    // CoreMIDI internals
    private var midiClient = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var bitchBoyDestination: MIDIEndpointRef = 0

    private var fxTimer: AnyCancellable?
    private var watchdogTimer: AnyCancellable?
    // --- LEFT WING: MIDI ROUTER & OUTPUT MATRIX STATE ---
    @Published var leftWingTab: String = "ROUTER" // "ROUTER", "TELEMETRY", "MACROS"
    @Published var midiThruEnabled: Bool = true
    @Published var virtualOutEnabled: Bool = true
    @Published var forwardUIInteractions: Bool = true
    @Published var forwardNotes: Bool = true
    @Published var forwardCCs: Bool = true
    @Published var remapChannel: Int = 0 // 0 = Original Ch 1, 1..16 = Forced Ch 1..16
    @Published var transposeSemitones: Int = 0 // -24 .. +24
    @Published var velocityCurve: MIDIVelocityCurve = .linear
    @Published var availableOutputTargets: [MIDIOutputTarget] = []
    @Published var selectedOutputNames: Set<String> = []
    @Published var txPacketCount: Int = 0
    @Published var lastRoutedMessage: String = "READY // NO TX YET"
    @Published var routerPacketHistory: [String] = []
    @Published var tapTempoBPM: Double = 120.0
    private var lastTapTimes: [Date] = []
    private var virtualSourceEndpoint = MIDIEndpointRef()
    private var virtualDestinationEndpoint = MIDIEndpointRef()

    // --- PRO SHOW CONTROL: MSC, OSC, ART-NET & sACN BROADCAST STATE ---
    @Published var mscBroadcastEnabled: Bool = true
    @Published var mscDeviceID: UInt8 = 1
    @Published var mscCommandFormat: MSCCommandFormat = .allTypes
    @Published var mscCueNumber: String = "1.0"
    @Published var mscCueList: String = ""
    @Published var mscAutoTriggerOnInbound: Bool = true
    @Published var mscLogHistory: [MSCMessage] = []
    private var inboundSysExBuffer: [UInt8] = []

    // Custom OSC Transmitter
    @Published var customOSCHost: String = "127.0.0.1"
    @Published var customOSCPort: UInt16 = 53000 // Default QLab / DAW port
    @Published var customOSCAddress: String = "/cue/selected/start"
    @Published var customOSCArgType: String = "NONE" // NONE, FLOAT, INT, STRING, BOOLEAN_TRUE, BOOLEAN_FALSE
    @Published var customOSCArgValue: String = "1.0"

    // Art-Net 4 Transmitter
    @Published var artNetHost: String = "127.0.0.1"
    @Published var artNetPort: UInt16 = 6454
    @Published var artNetUniverse: UInt16 = 0
    @Published var artNetChannels: [UInt8] = Array(repeating: 0, count: 512)
    @Published var artNetSequence: UInt8 = 0
    @Published var artNetMirrorLEDs: Bool = false

    // ANSI E1.31 sACN Transmitter
    @Published var sacnHost: String = "" // Empty = standard Multicast 239.255.x.y
    @Published var sacnPort: UInt16 = 5568
    @Published var sacnUniverse: UInt16 = 1
    @Published var sacnPriority: UInt8 = 100
    @Published var sacnChannels: [UInt8] = Array(repeating: 0, count: 512)
    @Published var sacnSequence: UInt8 = 0

    // Customizable Show Control & MIDI Feedback Engine
    @Published var hardwareFeedbackEnabled: Bool = true
    @Published var inboundMIDIEchoEnabled: Bool = true
    @Published var showControlSubTab: String = "OSC" // "OSC", "MSC", "ARTNET", "SACN", "FEEDBACK"
    @Published var oscStudioMode: String = "MAPPINGS" // "MAPPINGS", "TRANSMITTER"
    @Published var oscHardwareBroadcastEnabled: Bool = false
    @Published var artNetMirrorHardwareFaders: Bool = false
    @Published var grandMasterLevel: Double = 1.0
    @Published var isBlackoutActive: Bool = false

    // --- MIDI TO OSC CUSTOMIZATION MATRIX ---
    @Published var midiToOSCMappingActive: Bool = true
    @Published var midiToOSCFilter: String = "ALL" // "ALL", "GRID", "STRIP", "PAD", "VFADERS", "HFADERS", "MASTER_KNOBS"
    @Published var midiToOSCSearchText: String = ""

    // --- RIGHT WING: CUSTOM LIGHTING FX STUDIO STATE ---
    @Published var rightWingTab: String = "SEQUENCER" // "SEQUENCER", "WAVESYNTH", "LIBRARY"
    @Published var customEffects: [CustomLightEffect] = []
    @Published var editingCustomFX: CustomLightEffect = CustomLightEffect.buildStarterEffects()[0]
    @Published var editingFrameIndex: Int = 0
    @Published var customBrushVelocity: UInt8 = 78
    @Published var paintOnMainChassis: Bool = false
    @Published var isPlayingCustomFX: Bool = false
    @Published var activeCustomFXName: String = ""
    private var customFXStep: Int = 0
    private var customFXDirection: Int = 1

    // --- RIGHT WING BOTTOM: REACTIVE MECHANICAL KEYBOARD FX ENGINE STATE ---
    @Published var reactiveKeyFXMode: ReactiveKeyFXMode = .ripple
    @Published var reactiveFXSpeed: Double = 1.4
    @Published var reactiveFXColorVelocity: UInt8 = 78 // 0 = Rainbow Dynamic, >0 = Specific Neon Color
    @Published var reactiveFXRainbowColor: Bool = true
    @Published var activeReactivePulses: [ReactivePulseEvent] = []
    @Published var lastReactiveOriginKey: Int = -1
    private var reactiveFXTimer: AnyCancellable?
    private var lastSentReactiveLEDs: [UInt8] = Array(repeating: 255, count: 49)

    // --- UI SCALING / ZOOM & CUSTOM APP ICON STATE ---
    // --- ALWAYS ON TOP (FLOATING WINDOW) STATE ---
    @Published var isWindowAlwaysOnTop: Bool = false
    private let alwaysOnTopStorageKey = "BitchBoy_AlwaysOnTop_v1"

    @Published var uiScale: CGFloat = 1.15
    @Published var autoFitWindow: Bool = true
    @Published var lastComputedFitScale: CGFloat = 1.0
    private let uiScaleStorageKey = "BitchBoy_UIScale_v1"
    private let uiAutoFitStorageKey = "BitchBoy_UIAutoFit_v1"

    private let customFXStorageKey = "BitchBoy_CustomLightFX_v1"
    private let connectFXEnabledStorageKey = "BitchBoy_ConnectFXEnabled_v1"
    private let connectFXNameStorageKey = "BitchBoy_ConnectFXName_v1"

    // --- ON-CONNECT BITCHBOY HARDWARE NOTIFICATION & CUSTOM FX STATE ---
    @Published var connectEffectEnabled: Bool = true
    @Published var connectCustomFXName: String = "BITCHBOY CONNECT IGNITION"
    @Published var showConnectionBanner: Bool = false
    @Published var connectionBannerTitle: String = "🔌 BITCHBOY CONTROLLER CONNECTED & READY"
    @Published var connectionBannerSubtitle: String = "Hardware Recognized // Playing On-Connect FX"

    // --- CUSTOM SOUND UPLOAD STUDIO & MODULE WINDOW / SPOTLIGHT / REARRANGE STATE ---
    @Published var showCustomSoundStudio: Bool = false
    @Published var customSoundUpdateToken: Int = 0
    @Published var spotlightModule: StudioModuleID? = nil
    @Published var moduleOrder: [StudioModuleID] = [.showControl, .memorySlots, .midiRouter, .customFXStudio, .reactiveKeyFX]
    @Published var isRearrangingModules: Bool = false
    @Published var draggingModule: StudioModuleID? = nil
    @Published var detachedModules: Set<StudioModuleID> = []
    fileprivate var moduleWindows: [StudioModuleID: NSWindow] = [:]
    fileprivate var moduleWindowDelegates: [StudioModuleID: ModuleWindowCloseDelegate] = [:]
    @Published var pinnedModuleWindows: Set<StudioModuleID> = []
    private let moduleOrderStorageKey = "BitchBoy_ModuleOrder_v1"
    private let soundPackStorageKey = "BitchBoy_SoundPack_v1"

    // --- DYNAMIC MODULE PLACEMENT & RESIZING ENGINE ---
    @Published var leftWingModules: [StudioModuleID] = [.showControl, .memorySlots]
    @Published var rightWingModules: [StudioModuleID] = [.midiRouter, .customFXStudio]
    @Published var bottomRackModules: [StudioModuleID] = [.reactiveKeyFX]
    @Published var moduleCustomHeights: [StudioModuleID: CGFloat] = [:]
    @Published var moduleCustomWidths: [StudioModuleID: CGFloat] = [:]
    @Published var leftWingWidth: CGFloat = 274
    @Published var rightWingWidth: CGFloat = 274
    private let leftWingStorageKey = "BitchBoy_LeftWingModules_v2"
    private let rightWingStorageKey = "BitchBoy_RightWingModules_v2"
    private let bottomRackStorageKey = "BitchBoy_BottomRackModules_v2"
    private let moduleHeightsStorageKey = "BitchBoy_ModuleHeights_v2"
    private let moduleWidthsStorageKey = "BitchBoy_ModuleWidths_v2"

    // --- CUSTOM THEMES STATE ---
    static var activeCustomThemeStatic: CustomChassisTheme = CustomChassisTheme.defaultCustom()
    @Published var customThemes: [CustomChassisTheme] = []
    @Published var activeCustomTheme: CustomChassisTheme = CustomChassisTheme.defaultCustom() {
        didSet {
            Self.activeCustomThemeStatic = activeCustomTheme
        }
    }
    @Published var showCustomThemeStudio: Bool = false
    private let customThemesStorageKey = "BitchBoy_CustomThemes_v1"
    private let activeCustomThemeIdStorageKey = "BitchBoy_ActiveCustomThemeID_v1"
    private let themeStorageKey = "BitchBoy_ChassisTheme_v2"

    // --- GITHUB RELEASES AUTO-UPDATER STATE ---
    @Published var isCheckingForUpdates: Bool = false
    @Published var updateAvailable: Bool = false
    @Published var latestRelease: GitHubReleaseInfo? = nil
    @Published var showUpdateModal: Bool = false
    @Published var isDownloadingUpdate: Bool = false
    @Published var updateDownloadProgress: Double = 0.0
    @Published var updateStatusMessage: String = ""
    @Published var updateError: String? = nil
    @Published var lastUpdateCheckDate: Date? = nil
    @Published var showUpToDateNotice: Bool = false
    @Published var updateCheckResultNotice: String = ""
    private var periodicUpdateCheckTimer: AnyCancellable?
    private var activeDownloadTask: URLSessionDownloadTask?

    var currentAppVersion: String {
        let bundleVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        if !bundleVer.isEmpty && bundleVer != "1.0" && bundleVer != "1.0.0" {
            return bundleVer
        }
        return "1.1.1"
    }

    private let storageKey = "BitchBoy_SavedSlots_v5"

    init() {
        self.controls = Self.buildDefault69Map()
        self.slots = Self.buildDefault8MemorySlots()
        loadFromDisk()
        loadCustomEffectsFromDisk()
        loadModuleOrderAndSoundSettings()
        loadUISettingsAndAppIcon()
        setupCoreMIDI()
        startHardwareWatchdog()

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
            PresetSlot(name: "SLOT C // VISUALS & DMX", controls: Self.buildDefault69Map(), iconName: "sparkles", accentVelocity: 95),
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
        var status = MIDIClientCreateWithBlock("BitchBoyClient" as CFString, &midiClient) { [weak self] notifyPtr in
            let msg = notifyPtr.pointee
            switch msg.messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged:
                Task { @MainActor [weak self] in
                    self?.scanForBitchBoy()
                }
            default:
                break
            }
        }
        guard status == noErr else { return }

        status = MIDIInputPortCreateWithProtocol(
            midiClient,
            "BitchBoyInput" as CFString,
            ._1_0,
            &inputPort
        ) { [weak self] eventList, _ in
            let packets = eventList.pointee
            var curPacket = packets.packet
            for _ in 0..<packets.numPackets {
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
                    Task { @MainActor [weak self] in
                        self?.handleIncomingSysExBytes(slice)
                    }
                } else if msgType == 0x2 || statusByte >= 0x80 {
                    Task { @MainActor [weak self] in
                        self?.handleMIDIMessage(status: statusByte, data1: data1, data2: data2)
                    }
                }

                if packets.numPackets > 1 {
                    curPacket = MIDIEventPacketNext(&curPacket).pointee
                }
            }
        }

        MIDIOutputPortCreate(midiClient, "BitchBoyOutput" as CFString, &outputPort)
        MIDISourceCreate(midiClient, "BitchBoy Virtual Out" as CFString, &virtualSourceEndpoint)

        // Virtual Destination Endpoint: Named "BitchBoy Virtual In" to allow QLab / DAWs to send MSC & notes directly into BitchManager
        status = MIDIDestinationCreateWithBlock(
            midiClient,
            "BitchBoy Virtual In" as CFString,
            &virtualDestinationEndpoint
        ) { [weak self] packetList, _ in
            let packets = packetList.pointee
            var curPacket = packets.packet
            for _ in 0..<packets.numPackets {
                let length = Int(curPacket.length)
                if length >= 3 {
                    withUnsafePointer(to: &curPacket.data) { dataPtr in
                        dataPtr.withMemoryRebound(to: UInt8.self, capacity: length) { bytes in
                            if bytes[0] == 0xF0 {
                                let sysEx = Array(UnsafeBufferPointer(start: bytes, count: length))
                                Task { @MainActor [weak self] in
                                    self?.handleIncomingSysExBytes(sysEx)
                                }
                            } else {
                                let statusByte = bytes[0]
                                let data1 = bytes[1]
                                let data2 = bytes[2]
                                Task { @MainActor [weak self] in
                                    self?.handleInboundExternalMIDI(status: statusByte, data1: data1, data2: data2)
                                }
                            }
                        }
                    }
                }
                if packets.numPackets > 1 {
                    curPacket = MIDIPacketNext(&curPacket).pointee
                }
            }
        }

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

        // 2. Connect inputPort ONLY to real BitchBoy hardware sources; disconnect any other MIDI programs!
        let srcCount = MIDIGetNumberOfSources()
        for i in 0..<srcCount {
            let src = MIDIGetSource(i)
            let sName = getEndpointName(src)
            if src == virtualSourceEndpoint || sName.lowercased().contains("bitchboy virtual out") {
                MIDIPortDisconnectSource(inputPort, src)
                continue
            }
            if isRealBitchBoyEndpoint(src) {
                MIDIPortConnectSource(inputPort, src, nil)
                if !found {
                    targetName = sName
                    found = true
                }
            } else {
                MIDIPortDisconnectSource(inputPort, src)
            }
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
        if prevEmpty {
            // Auto-select any non-BitchBoy external DAW / IAC / Synth targets on first launch
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

        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
            showConnectionBanner = true
            mascotSpeech = "🔌 BITCHBOY CONTROLLER ONLINE & READY!"
            mascotSpeechVisible = true
            mascotScale = 1.18
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
    func sendNoteOn(note: UInt8, velocity: UInt8) {
        guard isConnected, bitchBoyDestination != 0 else { return }
        var packetList = MIDIPacketList()
        var curPacket = MIDIPacketListInit(&packetList)
        let data: [UInt8] = [0x90, note, velocity]
        curPacket = MIDIPacketListAdd(&packetList, 1024, curPacket, 0, 3, data)
        if velocity == 0 {
            let noteOff: [UInt8] = [0x80, note, 0]
            curPacket = MIDIPacketListAdd(&packetList, 1024, curPacket, 0, 3, noteOff)
        }
        MIDISend(outputPort, bitchBoyDestination, &packetList)
    }

    func sendCC(cc: UInt8, value: UInt8) {
        guard isConnected, bitchBoyDestination != 0 else { return }
        var packetList = MIDIPacketList()
        var curPacket = MIDIPacketListInit(&packetList)
        var data: [UInt8] = [0xB0, cc, value]
        curPacket = MIDIPacketListAdd(&packetList, 1024, curPacket, 0, 3, &data)
        MIDISend(outputPort, bitchBoyDestination, &packetList)
    }

    // High-performance batch NoteOn sender for zero-lag keyboard effects
    func sendBatchNoteOn(notesAndVelocities: [(note: UInt8, velocity: UInt8)]) {
        guard isConnected, bitchBoyDestination != 0, !notesAndVelocities.isEmpty else { return }
        var buffer = [UInt8](repeating: 0, count: 2048)
        buffer.withUnsafeMutableBytes { rawBuf in
            guard let pktListPtr = rawBuf.baseAddress?.assumingMemoryBound(to: MIDIPacketList.self) else { return }
            var curPacket = MIDIPacketListInit(pktListPtr)
            for item in notesAndVelocities {
                var data: [UInt8] = [0x90, item.note, item.velocity]
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
            var packetList = MIDIPacketList()
            var curPacket = MIDIPacketListInit(&packetList)
            curPacket = MIDIPacketListAdd(&packetList, 1024, curPacket, 0, bytes.count, &bytes)
            MIDISend(outputPort, bitchBoyDestination, &packetList)
        }

        // 2. Send to virtual source endpoint so QLab / DAWs receive it
        if virtualOutEnabled, virtualSourceEndpoint != 0 {
            var packetList = MIDIPacketList()
            var curPacket = MIDIPacketListInit(&packetList)
            curPacket = MIDIPacketListAdd(&packetList, 1024, curPacket, 0, bytes.count, &bytes)
            MIDIReceived(virtualSourceEndpoint, &packetList)
        }

        // 3. Send to all selected external MIDI outputs in MIDI Router
        for target in availableOutputTargets where selectedOutputNames.contains(target.name) {
            if target.endpoint == bitchBoyDestination { continue }
            var packetList = MIDIPacketList()
            var curPacket = MIDIPacketListInit(&packetList)
            curPacket = MIDIPacketListAdd(&packetList, 1024, curPacket, 0, bytes.count, &bytes)
            MIDISend(outputPort, target.endpoint, &packetList)
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
            activeReactivePulses.removeAll()
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
        let packet = ArtNetPacketBuilder.buildDMXPacket(universe: universe, channels: channels, sequence: artNetSequence)
        artNetSequence = (artNetSequence &+ 1)
        guard let nwPort = NWEndpoint.Port(rawValue: artNetPort) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        conn.start(queue: .global())
        let targetPort = artNetPort
        conn.send(content: packet, completion: .contentProcessed { [weak self] err in
            conn.cancel()
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let err = err {
                    self.log("❌ Art-Net send error: \(err.localizedDescription)")
                } else {
                    self.log("💡 Art-Net DMX -> \(host):\(targetPort) Univ:\(universe) (512 Ch)")
                }
            }
        })
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
    func sendsACNDMX(
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

        guard let nwPort = NWEndpoint.Port(rawValue: sacnPort) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(targetHost), port: nwPort, using: .udp)
        conn.start(queue: .global())
        let currentSacnPort = sacnPort
        conn.send(content: packet, completion: .contentProcessed { [weak self] err in
            conn.cancel()
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let err = err {
                    self.log("❌ sACN send error: \(err.localizedDescription)")
                } else {
                    self.log("🌟 sACN E1.31 -> \(targetHost):\(currentSacnPort) Univ:\(universe) Pri:\(priority) (512 Ch)")
                }
            }
        })
    }

    func sendsACNFullRig() {
        let chs = Array(repeating: UInt8(255), count: 512)
        sendsACNDMX(host: sacnHost, universe: sacnUniverse, priority: sacnPriority, channels: chs)
    }

    func sendsACNBlackout() {
        let chs = Array(repeating: UInt8(0), count: 512)
        sendsACNDMX(host: sacnHost, universe: sacnUniverse, priority: sacnPriority, channels: chs)
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
        let packet = OSCPacketBuilder.buildMessage(address: address, argType: argType, argValue: argValue)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        conn.start(queue: .global())
        conn.send(content: packet, completion: .contentProcessed { [weak self] err in
            conn.cancel()
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let err = err {
                    self.log("❌ OSC send error: \(err.localizedDescription)")
                } else {
                    let valStr = argType == "NONE" ? "" : " [\(argType): \(argValue)]"
                    self.log("📡 OSC UDP -> \(host):\(port) \(address)\(valStr)")
                }
            }
        })
    }

    // ------------------------------------------------------------------------
    // MIDI TO OSC CUSTOM MAPPING ENGINE (INDIVIDUAL KEYS & FADERS)
    // ------------------------------------------------------------------------
    func filteredControlIndices() -> [Int] {
        var indices = Array(0..<controls.count)
        switch midiToOSCFilter {
        case "GRID":
            indices = indices.filter { $0 < 32 }
        case "STRIP":
            indices = indices.filter { $0 >= 32 && $0 < 40 }
        case "PAD":
            indices = indices.filter { $0 >= 40 && $0 < 49 }
        case "VFADERS":
            indices = indices.filter { $0 >= 49 && $0 < 57 }
        case "HFADERS":
            indices = indices.filter { $0 >= 57 && $0 < 61 }
        case "MASTER_KNOBS":
            indices = indices.filter { $0 >= 61 }
        default:
            break
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
        guard midiToOSCMappingActive, index >= 0, index < controls.count else { return }
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
        sendsACNBlackout()
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
            sendsACNFullRig()
            SoundEffect.presetSwitch.play(with: soundPack)
            log("💡 Blackout Disengaged — Restored Rig Levels")
        }
    }

    func flashRigMomentary() {
        SoundEffect.presetSwitch.play(with: soundPack)
        let savedGM = grandMasterLevel
        grandMasterLevel = 1.0
        sendArtNetFullRig()
        sendsACNFullRig()
        setZoneLEDs(range: 0..<49, velocity: 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.grandMasterLevel = savedGM
            if self.isBlackoutActive {
                self.sendArtNetBlackout()
                self.sendsACNBlackout()
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
        sendArtNetDMX(host: artNetHost, universe: artNetUniverse, channels: artNetChannels)
    }

    // ------------------------------------------------------------------------
    // INBOUND EXTERNAL MIDI (DAWs, QLab, Virtual Endpoint) & FEEDBACK ECHO
    // ------------------------------------------------------------------------
    func handleInboundExternalMIDI(status: UInt8, data1: UInt8, data2: UInt8) {
        let msgType = status & 0xF0
        let isNoteOn = (msgType == 0x90) && (data2 > 0)
        let isNoteOff = (msgType == 0x80) || ((msgType == 0x90) && (data2 == 0))
        let isCC = (msgType == 0xB0)

        guard let idx = controls.firstIndex(where: {
            if isCC { return ($0.kind == .vfader || $0.kind == .hfader || $0.kind == .knob) && $0.number == data1 }
            else { return $0.kind == .key && $0.number == data1 }
        }) else { return }

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
        guard index < controls.count else { return }
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
        let palette: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 95, 3]
        let chosenVel: UInt8 = reactiveFXRainbowColor
            ? palette[(keyIndex * 3 + activeReactivePulses.count * 2) % palette.count]
            : reactiveFXColorVelocity

        var targets: [Int] = []
        if reactiveKeyFXMode == .arcLightning {
            var pool = Array(0..<49).filter { $0 != keyIndex }
            pool.shuffle()
            targets = Array(pool.prefix(8))
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
        if activeReactivePulses.count > 12 {
            activeReactivePulses.removeFirst(activeReactivePulses.count - 12)
        }

        if reactiveFXTimer == nil {
            lastSentReactiveLEDs = Array(repeating: 255, count: 49)
            // Ultra-smooth 40 FPS timer
            reactiveFXTimer = Timer.publish(every: 0.025, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    self?.stepReactiveKeyFX()
                }
        }
        stepReactiveKeyFX()
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
        let dt = 0.025 * max(0.3, reactiveFXSpeed)
        for i in activeReactivePulses.indices {
            activeReactivePulses[i].age += dt
        }
        activeReactivePulses.removeAll { $0.age > 1.05 }

        let palette: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 95, 3]

        var batch = controls
        var didChange = false
        var batchNotes: [(note: UInt8, velocity: UInt8)] = []

        for k in 0..<49 {
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
                // Zero-cost precomputed distance lookup matrix
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
                didChange = true
            }
            if lastSentReactiveLEDs[k] != finalVel {
                lastSentReactiveLEDs[k] = finalVel
                batchNotes.append((note: batch[k].number, velocity: finalVel))
            }
        }

        if didChange {
            controls = batch
        }

        // Send all changed LEDs in a single batch MIDI packet list
        if !batchNotes.isEmpty {
            sendBatchNoteOn(notesAndVelocities: batchNotes)
        }

        if activeReactivePulses.isEmpty {
            reactiveFXTimer?.cancel()
            reactiveFXTimer = nil
        }
    }

    func setControlLiveValue(index: Int, value: UInt8) {
        guard index < controls.count else { return }
        selectedIndex = index
        controls[index].liveValue = value
        sendCC(cc: controls[index].number, value: value)
        if forwardUIInteractions {
            routeIncomingMIDIToTargets(status: 0xB0, data1: controls[index].number, data2: value, isFromHardware: false)
        }
        sendOSCForControl(index: index, isPress: true, liveVal: value)
        lastStreamMessage = "[\(controls[index].label)] CC #\(controls[index].number) VAL: \(value)"
        SoundEffect.faderSlide.play(with: soundPack)
        if currentFXMode == .vuMeter && index >= 49 && index < 57 {
            updateVUMeterFaders()
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
        for i in 0..<49 {
            let vel = controls[i].idleVelocity
            controls[i].currentLED = vel
            sendNoteOn(note: controls[i].number, velocity: vel)
        }
    }

    // 1. Authentic Rainbow Wave Refresh Sweep (sweeps 11 columns and restores presets)
    func runRainbowWaveRefresh() {
        guard !isRainbowRunning else { return }
        isRainbowRunning = true
        log("✨ Sweeping Rainbow Wave Hardware LED Refresh...")

        Task { @MainActor in
            let rainbowVelocities: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 95, 3]
            let totalSteps = 22
            for step in 0..<totalSteps {
                for k in 0..<49 {
                    let col = BitchBoyKeyMap.keyPositions[k].col
                    let wavePos = step - col
                    if wavePos >= 0 && wavePos < rainbowVelocities.count {
                        let vel = rainbowVelocities[wavePos]
                        self.controls[k].currentLED = vel
                        self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                    } else if wavePos >= rainbowVelocities.count {
                        let vel = self.controls[k].idleVelocity
                        self.controls[k].currentLED = vel
                        self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                    }
                }
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
        let rainbowVelocities: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 95, 3]
        var step = 0
        let interval = 0.07 / max(0.2, fxSpeed)
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                step += 1
                for k in 0..<49 {
                    let col = BitchBoyKeyMap.keyPositions[k].col
                    let vel = rainbowVelocities[(step + col) % rainbowVelocities.count]
                    self.controls[k].currentLED = vel
                    self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                }
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
                for k in 0..<49 {
                    let col = BitchBoyKeyMap.keyPositions[k].col
                    let dist = abs(col - activeCol)
                    let vel: UInt8 = dist == 0 ? 72 : (dist == 1 ? 61 : (dist == 2 ? 83 : 0))
                    self.controls[k].currentLED = vel
                    self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                }
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
                for k in 0..<49 {
                    let col = BitchBoyKeyMap.keyPositions[k].col
                    let row = BitchBoyKeyMap.keyPositions[k].row
                    let dropRow = (step + col * 3) % 7
                    let vel: UInt8 = (row == dropRow) ? 3 : (row == (dropRow - 1 + 7) % 7 ? 87 : (row == (dropRow - 2 + 7) % 7 ? 33 : 0))
                    self.controls[k].currentLED = vel
                    self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                }
            }
    }

    // 5. Cyberpunk Pulse (Smooth breathing through neon velocities)
    private func startCyberPulseFX() {
        var phase: Double = 0
        let interval = 0.04 / max(0.2, fxSpeed)
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                phase += 0.12
                let normalized = (sin(phase) + 1.0) * 0.5
                let vel = UInt8(normalized * 115.0 + 12.0)
                for k in 0..<49 {
                    self.controls[k].currentLED = vel
                    self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                }
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
        for col in 0..<8 {
            let faderVal = Double(controls[49 + col].liveValue)
            let colKeyIndices = [32 + col, 24 + col, 16 + col, 8 + col, 0 + col]
            let thresholds: [Double] = [15, 40, 65, 90, 115]
            let colors: [UInt8] = [87, 87, 74, 61, 72]
            for seg in 0..<5 {
                let kIdx = colKeyIndices[seg]
                let isLit = faderVal >= thresholds[seg]
                let vel: UInt8 = isLit ? colors[seg] : 0
                if controls[kIdx].currentLED != vel {
                    controls[kIdx].currentLED = vel
                    sendNoteOn(note: controls[kIdx].number, velocity: vel)
                }
            }
        }
        let padWave = UInt8(((sin(Double(bgTick) * 0.2) + 1.0) * 0.5) * 40.0 + 10.0)
        for p in 40..<49 {
            if controls[p].currentLED != padWave {
                controls[p].currentLED = padWave
                sendNoteOn(note: controls[p].number, velocity: padWave)
            }
        }
    }

    // 7. Fire & Embers (Organic flame simulation with flickering coals)
    private func startFireEmbersFX() {
        let interval = 0.08 / max(0.2, fxSpeed)
        let firePal: [UInt8] = [0, 83, 72, 61, 96, 74, 3]
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                for k in 0..<49 {
                    let row = BitchBoyKeyMap.keyPositions[k].row
                    let heatIdx = min(firePal.count - 1, max(0, (4 - row) + Int.random(in: -1...1)))
                    let vel = firePal[heatIdx]
                    self.controls[k].currentLED = vel
                    self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                }
            }
    }

    // 8. Center Ripple (Concentric shockwaves expanding outward)
    private func startWaterRippleFX() {
        var phase: Double = 0
        let interval = 0.05 / max(0.2, fxSpeed)
        let waterPal: [UInt8] = [0, 41, 33, 78, 3]
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                phase += 0.25
                let centerCol = 3.5
                let centerRow = 2.0
                for k in 0..<49 {
                    let col = Double(BitchBoyKeyMap.keyPositions[k].col)
                    let row = Double(BitchBoyKeyMap.keyPositions[k].row)
                    let dist = sqrt(pow(col - centerCol, 2) + pow(row - centerRow, 2))
                    let wave = sin(dist * 1.6 - phase)
                    let norm = max(0.0, wave)
                    let pIdx = Int(norm * Double(waterPal.count - 1))
                    let vel = waterPal[min(waterPal.count - 1, max(0, pIdx))]
                    self.controls[k].currentLED = vel
                    self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                }
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
                    starBrightness[rIdx] = [3, 78, 33, 41, 74, 95].randomElement() ?? 3
                }
                for k in 0..<49 {
                    let vel = starBrightness[k]
                    self.controls[k].currentLED = vel
                    self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                }
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
                for k in 0..<49 {
                    self.controls[k].currentLED = vel
                    self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                }
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
                for k in 0..<49 {
                    self.controls[k].currentLED = vel
                    self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                }
            }
    }

    // 12. Plasma Field (Trigonometric 2D undulating field)
    private func startPlasmaWaveFX() {
        var t: Double = 0
        let interval = 0.06 / max(0.2, fxSpeed)
        let plasmaPal: [UInt8] = [41, 67, 95, 78, 33, 87, 74, 61, 72]
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                t += 0.16
                for k in 0..<49 {
                    let c = Double(BitchBoyKeyMap.keyPositions[k].col)
                    let r = Double(BitchBoyKeyMap.keyPositions[k].row)
                    let v1 = sin(c * 0.7 + t)
                    let v2 = cos(r * 0.8 + t * 0.9)
                    let v3 = sin((c + r) * 0.5 + t * 1.1)
                    let norm = (v1 + v2 + v3 + 3.0) / 6.0
                    let pIdx = Int(norm * Double(plasmaPal.count - 1))
                    let vel = plasmaPal[min(plasmaPal.count - 1, max(0, pIdx))]
                    self.controls[k].currentLED = vel
                    self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                }
            }
    }

    // 13. Spiral Vortex (Rotating light beam around center)
    private func startSpiralVortexFX() {
        var angle: Double = 0
        let interval = 0.06 / max(0.2, fxSpeed)
        let vortexPal: [UInt8] = [0, 41, 67, 78, 33, 3]
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                angle += 0.32
                let centerCol = 4.0
                let centerRow = 2.0
                for k in 0..<49 {
                    let dx = Double(BitchBoyKeyMap.keyPositions[k].col) - centerCol
                    let dy = Double(BitchBoyKeyMap.keyPositions[k].row) - centerRow
                    let keyAngle = atan2(dy, dx)
                    let diff = fmod(keyAngle - angle + .pi * 4, .pi * 2)
                    let norm = max(0.0, 1.0 - diff / (.pi * 2))
                    let pIdx = Int(norm * Double(vortexPal.count - 1))
                    let vel = vortexPal[min(vortexPal.count - 1, max(0, pIdx))]
                    self.controls[k].currentLED = vel
                    self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                }
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
                for k in 0..<49 {
                    let col = BitchBoyKeyMap.keyPositions[k].col
                    let row = BitchBoyKeyMap.keyPositions[k].row
                    if col < 8 {
                        let activeLevel = 4 - row
                        let isLit = activeLevel < colHeights[col]
                        let vel: UInt8 = isLit ? UInt8(40 + activeLevel * 20) : 0
                        self.controls[k].currentLED = vel
                        self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                    } else {
                        let padVel = UInt8.random(in: 20...70)
                        self.controls[k].currentLED = padVel
                        self.sendNoteOn(note: self.controls[k].number, velocity: padVel)
                    }
                }
            }
    }

    // 15. Color Runner (Snake head chasing with fading tail)
    private func startColorChaseFX() {
        var head = 0
        let trailColors: [UInt8] = [3, 78, 87, 74, 61, 72, 95]
        let interval = 0.05 / max(0.2, fxSpeed)
        fxTimer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                head = (head + 1) % 49
                for k in 0..<49 {
                    let dist = (head - k + 49) % 49
                    let vel: UInt8 = dist < trailColors.count ? trailColors[dist] : 0
                    self.controls[k].currentLED = vel
                    self.sendNoteOn(note: self.controls[k].number, velocity: vel)
                }
            }
    }

    // ------------------------------------------------------------------------
    // MASCOT & ACTIONS
    // ------------------------------------------------------------------------
    func triggerMascotTap() {
        mascotScale = 1.5
        SoundEffect.mascotSqueak.play(with: soundPack)
        let quotes = [
            "\"DON'T SQUEEZE THE BITCHBOY!\"",
            "\"YOU BITCH!\"",
            "\"MIDI PIPES ARE PURRING SMOOTH!\"",
            "\"CRANK THAT FADER TO 127!\"",
            "\"PRESS SHIFT FOR MULTI-SELECT!\"",
            "\"BEEPS, BOOPS, AND HEAVY BASS!\"",
            "\"TAYLOR FOSSEN APPROVED! 👑\"",
            "\"STANDING BY\"",
            "\"FART\"",
            "\"MY FAVORITE WORD IS BITCH\"",
            "\"NEON GLOW AT MAXIMUM WATTAGE!\""
        ]
        mascotSpeech = quotes.randomElement() ?? quotes[0]
        mascotSpeechVisible = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 850_000_000)
            self.mascotScale = 1.5
            try? await Task.sleep(nanoseconds: 5_500_000_000)
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
        slots[activeSlot] = decoded
        controls = decoded.controls
        saveCurrentSlot()
        restorePresetLEDs()
        log("⤒ Imported Preset into Slot \(activeSlot)")
    }

    // ------------------------------------------------------------------------
    // INCOMING MIDI PARSER
    // ------------------------------------------------------------------------
    private func handleMIDIMessage(status: UInt8, data1: UInt8, data2: UInt8) {
        // Forward physical BitchBoy MIDI input to Virtual Out & selected external programs!
        routeIncomingMIDIToTargets(status: status, data1: data1, data2: data2, isFromHardware: true)

        let msgType = status & 0xF0
        let isNoteOn = (msgType == 0x90) && (data2 > 0)
        let isNoteOff = (msgType == 0x80) || ((msgType == 0x90) && (data2 == 0))
        let isCC = (msgType == 0xB0)

        guard let idx = controls.firstIndex(where: {
            if isCC { return ($0.kind == .vfader || $0.kind == .hfader || $0.kind == .knob) && $0.number == data1 }
            else { return $0.kind == .key && $0.number == data1 }
        }) else { return }

        selectedIndex = idx

        if isNoteOn || isNoteOff {
            if isNoteOn {
                controls[idx].isPressed = true
                lastStreamMessage = "[\(controls[idx].label)] ON #\(data1) V:\(data2)"
                SoundEffect.keyTap.play(with: soundPack)

                if hardwareFeedbackEnabled {
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
                sendOSCForControl(index: idx, isPress: true, liveVal: data2)
            } else if isNoteOff {
                controls[idx].isPressed = false
                lastStreamMessage = "[\(controls[idx].label)] OFF #\(data1) V:0"
                sendOSCForControl(index: idx, isPress: false, liveVal: 0)
                if hardwareFeedbackEnabled && activeReactivePulses.isEmpty {
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
                sendArtNetDMX(host: artNetHost, universe: artNetUniverse, channels: artNetChannels)
            }
            sendOSCForControl(index: idx, isPress: true, liveVal: data2)
        }
    }

    // ------------------------------------------------------------------------
    // MIDI ROUTER & MULTI-PROGRAM OUTPUT ENGINE
    // ------------------------------------------------------------------------
    func routeIncomingMIDIToTargets(status: UInt8, data1: UInt8, data2: UInt8, isFromHardware: Bool) {
        guard midiThruEnabled else { return }
        let msgType = status & 0xF0
        let isNote = (msgType == 0x90 || msgType == 0x80)
        let isCC = (msgType == 0xB0)

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

        var packetList = MIDIPacketList()
        var curPacket = MIDIPacketListInit(&packetList)
        let bytes: [UInt8] = [outStatus, outData1, outData2]
        curPacket = MIDIPacketListAdd(&packetList, 1024, curPacket, 0, 3, bytes)

        // 1. Broadcast to macOS Virtual MIDI Source ("BitchBoy Virtual Out")
        if virtualOutEnabled && virtualSourceEndpoint != 0 {
            MIDIReceived(virtualSourceEndpoint, &packetList)
        }

        // 2. Send to all checked external MIDI Destinations (DAWs, IAC Driver, Synths, QLab, etc.)
        for target in availableOutputTargets where selectedOutputNames.contains(target.name) {
            // Avoid echoing back into the physical BitchBoy LED port when routing from hardware
            if isFromHardware && target.endpoint == bitchBoyDestination { continue }
            MIDISend(outputPort, target.endpoint, &packetList)
        }

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

    var leftWingContentHeight: CGFloat {
        guard !leftWingModules.isEmpty || isRearrangingModules else { return 0 }
        let modsH = leftWingModules.reduce(CGFloat(0)) { $0 + (moduleCustomHeights[$1] ?? $1.defaultSlotHeight) + 10 }
        return modsH + (isRearrangingModules ? 60 : 0)
    }

    var rightWingContentHeight: CGFloat {
        guard !rightWingModules.isEmpty || isRearrangingModules else { return 0 }
        let modsH = rightWingModules.reduce(CGFloat(0)) { $0 + (moduleCustomHeights[$1] ?? $1.defaultSlotHeight) + 10 }
        return modsH + (isRearrangingModules ? 60 : 0)
    }

    var centerDeckHeight: CGFloat {
        530
    }

    var bottomRackContentHeight: CGFloat {
        guard !bottomRackModules.isEmpty || isRearrangingModules else { return 0 }
        let maxRackH = bottomRackModules.map { moduleCustomHeights[$0] ?? $0.defaultSlotHeight }.max() ?? 240
        return maxRackH + 52
    }

    var centerTotalHeight: CGFloat {
        centerDeckHeight + bottomRackContentHeight
    }

    // Exact physical content height of the faceplate columns (encompassing all wings, deck, and bottom expansion rack)
    var chassisContentHeight: CGFloat {
        let maxColumnH = max(centerTotalHeight, max(leftWingContentHeight, rightWingContentHeight))
        return max(530, maxColumnH)
    }

    var effectiveConsoleHeight: CGFloat {
        let faceplateTotalH = chassisContentHeight + 36 // 18px top & 18px bottom padding inside chassis
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

        if let savedThemeID = UserDefaults.standard.string(forKey: activeCustomThemeIdStorageKey),
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
        let minW = Self.consoleBaseWidth * 0.15
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
            window.contentAspectRatio = NSSize(width: Self.consoleBaseWidth, height: effectiveConsoleHeight)
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
        UserDefaults.standard.set(theme.id.uuidString, forKey: activeCustomThemeIdStorageKey)
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
            tagName: "v2.0.0",
            name: "BitchManager v2.0.0 // Next-Gen Cyber Release",
            body: """
            ### 🚀 BitchManager v2.0.0 Release Notes

            - **Custom Cyber Chassis Themes**: Built-in Theme Studio with full 6-point glow color palette.
            - **Custom Sound Bank**: Upload custom .WAV, .MP3, and .AIFF audio for any hardware or app action.
            - **Center Spotlight & Module Rearrange**: Pop out windows, center modules, and iOS-style jiggle rearrangement.
            - **Tailored Floating Windows**: Aspect-ratio locked, non-clipping, and pin to top-most window level.
            - **Automatic GitHub Updates**: In-app one-click update detection and background installation!
            """,
            htmlUrl: "https://github.com/kookly/BitchManager/releases",
            publishedAt: "2026-10-24T12:00:00Z",
            assets: [
                GitHubReleaseAsset(
                    id: 101,
                    name: "BitchManager.zip",
                    browserDownloadUrl: "https://github.com/kookly/BitchManager/releases",
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

        guard let asset = release.bestAsset, let assetUrl = URL(string: asset.browserDownloadUrl), assetUrl.scheme?.hasPrefix("http") == true else {
            if let webUrl = URL(string: release.htmlUrl) {
                NSWorkspace.shared.open(webUrl)
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

        let task = session.downloadTask(with: assetUrl) { [weak self] localURL, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    self.isDownloadingUpdate = false
                    self.updateError = "Download failed: \(error.localizedDescription)"
                    self.updateStatusMessage = ""
                    return
                }

                guard let localURL = localURL else {
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

                    let archiveDest = tempBase.appendingPathComponent(asset.name)
                    try? FileManager.default.removeItem(at: archiveDest)
                    try? FileManager.default.moveItem(at: localURL, to: archiveDest)

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
                            if let webUrl = URL(string: release.htmlUrl) {
                                NSWorkspace.shared.open(webUrl)
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
    }

    func resizeMainWindowToScale(_ scale: CGFloat) {
        let clamped = min(2.2, max(0.15, scale))
        let targetW = round(Self.consoleBaseWidth * clamped)
        let targetH = round(effectiveConsoleHeight * clamped)
        DispatchQueue.main.async {
            let detachedWinSet = Set(self.moduleWindows.values)
            for window in NSApplication.shared.windows {
                if detachedWinSet.contains(window) { continue }
                let className = String(describing: type(of: window))
                if className.contains("StatusBar") || className.contains("Menu") { continue }
                window.contentMinSize = NSSize(width: Self.consoleBaseWidth * 0.15, height: self.effectiveConsoleHeight * 0.15)
                window.contentAspectRatio = NSSize(width: Self.consoleBaseWidth, height: self.effectiveConsoleHeight)
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

        // Ensure all 5 modules are accounted for without duplicates
        var placed = Set(leftWingModules + rightWingModules + bottomRackModules)
        for m in StudioModuleID.allCases where !placed.contains(m) {
            bottomRackModules.append(m)
            placed.insert(m)
        }

        // Load Custom Heights
        if let hData = UserDefaults.standard.data(forKey: moduleHeightsStorageKey),
           let decodedHeights = try? JSONDecoder().decode([String: Double].self, from: hData) {
            for (key, val) in decodedHeights {
                if let mod = StudioModuleID(rawValue: key) {
                    moduleCustomHeights[mod] = CGFloat(val)
                }
            }
        }

        // Load Custom Widths
        if let wData = UserDefaults.standard.data(forKey: moduleWidthsStorageKey),
           let decodedWidths = try? JSONDecoder().decode([String: Double].self, from: wData) {
            for (key, val) in decodedWidths {
                if let mod = StudioModuleID(rawValue: key) {
                    moduleCustomWidths[mod] = CGFloat(val)
                }
            }
        }

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
        if leftWingModules.contains(module) { return .leftWing }
        if rightWingModules.contains(module) { return .rightWing }
        if bottomRackModules.contains(module) { return .bottomRack }
        return .leftWing
    }

    func moveModuleToZone(_ module: StudioModuleID, zone: ModuleZone, atIndex: Int? = nil) {
        if spotlightModule == module {
            withAnimation { spotlightModule = nil }
        }
        leftWingModules.removeAll(where: { $0 == module })
        rightWingModules.removeAll(where: { $0 == module })
        bottomRackModules.removeAll(where: { $0 == module })

        switch zone {
        case .floating:
            popOutModuleToWindow(module)
        case .leftWing:
            detachedModules.remove(module)
            dockModuleBackFromWindow(module)
            let idx = min(atIndex ?? leftWingModules.count, leftWingModules.count)
            leftWingModules.insert(module, at: idx)
        case .rightWing:
            detachedModules.remove(module)
            dockModuleBackFromWindow(module)
            let idx = min(atIndex ?? rightWingModules.count, rightWingModules.count)
            rightWingModules.insert(module, at: idx)
        case .bottomRack:
            detachedModules.remove(module)
            dockModuleBackFromWindow(module)
            let idx = min(atIndex ?? bottomRackModules.count, bottomRackModules.count)
            bottomRackModules.insert(module, at: idx)
        }
        moduleOrder = leftWingModules + rightWingModules + bottomRackModules
        saveModuleLayout()
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
        if currentH < 240 {
            nextH = 340
        } else if currentH < 380 {
            nextH = 480
        } else {
            nextH = 210
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            moduleCustomHeights[module] = nextH
        }
        saveModuleSizes()
        SoundEffect.knobTick.play(with: soundPack)
    }

    func moduleSizePresetLabel(_ module: StudioModuleID) -> String {
        let h = moduleCustomHeights[module] ?? module.defaultSlotHeight
        if h <= 235 { return "COMPACT" }
        if h <= 375 { return "STANDARD" }
        return "EXPANDED"
    }

    func isModuleExpanded(_ module: StudioModuleID, isSpotlight: Bool = false) -> Bool {
        if isSpotlight { return true }
        let h = moduleCustomHeights[module] ?? module.defaultSlotHeight
        return h >= 375
    }

    func moduleTextScale(_ module: StudioModuleID, isSpotlight: Bool = false) -> CGFloat {
        return isModuleExpanded(module, isSpotlight: isSpotlight) ? 2.0 : 1.0
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
        if currentW < 360 {
            nextW = 435 // Half rack
        } else if currentW < 520 {
            nextW = 620 // Wide
        } else if currentW < 750 {
            nextW = 894 // Full rack
        } else {
            nextW = 320 // Compact
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            moduleCustomWidths[module] = nextW
        }
        saveModuleSizes()
        SoundEffect.knobTick.play(with: soundPack)
    }

    func moduleWidthPresetLabel(_ module: StudioModuleID) -> String {
        guard let w = moduleCustomWidths[module] else { return "HALF" }
        if w <= 340 { return "COMPACT" }
        if w <= 480 { return "HALF" }
        if w <= 700 { return "WIDE" }
        return "FULL"
    }

    func resetModuleLayout() {
        SoundEffect.presetSwitch.play(with: soundPack)
        withAnimation(.spring(response: 0.36, dampingFraction: 0.75)) {
            leftWingModules = [.showControl, .memorySlots]
            rightWingModules = [.midiRouter, .customFXStudio]
            bottomRackModules = [.reactiveKeyFX]
            moduleOrder = leftWingModules + rightWingModules + bottomRackModules
            moduleCustomHeights.removeAll()
            moduleCustomWidths.removeAll()
            leftWingWidth = 274
            rightWingWidth = 274
        }
        saveModuleLayout()
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
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultSize.width, height: defaultSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "BitchManager // \(module.rawValue)"
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(calibratedRed: 0.02, green: 0.06, blue: 0.05, alpha: 1.0)
        win.isReleasedWhenClosed = false
        win.level = isModuleWindowTopMost(module) ? .floating : .normal
        win.contentMinSize = module.minWindowSize
        win.contentAspectRatio = defaultSize
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
        }
        SoundEffect.knobTick.play(with: soundPack)
        log("↙ Docked '\(module.rawValue)' back into main console")
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
        let newFrame = CustomLightEffect.emptyFrame(fill: 0)
        editingCustomFX.frames.append(newFrame)
        editingFrameIndex = editingCustomFX.frames.count - 1
        previewCurrentCustomFrameOnHardware()
        SoundEffect.knobTick.play(with: soundPack)
    }

    func duplicateCustomFXFrame() {
        guard !editingCustomFX.frames.isEmpty else { return }
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
        let palette: [UInt8] = [0, 0, 72, 61, 96, 74, 87, 33, 78, 41, 67, 95, 3]
        for k in 0..<49 {
            editingCustomFX.frames[safeIdx][k] = palette.randomElement() ?? 0
        }
        previewCurrentCustomFrameOnHardware()
    }

    func applyRainbowToCurrentFrame() {
        guard !editingCustomFX.frames.isEmpty else { return }
        let safeIdx = min(max(0, editingFrameIndex), editingCustomFX.frames.count - 1)
        let rainbow: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 95, 3]
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
                    var batch = self.controls
                    var didChange = false
                    for k in 0..<49 {
                        let v = self.evaluateProceduralWave(fx: activeFX, keyIndex: k, phase: phase)
                        if batch[k].currentLED != v {
                            batch[k].currentLED = v
                            didChange = true
                            self.sendNoteOn(note: batch[k].number, velocity: v)
                        }
                    }
                    if didChange {
                        self.controls = batch
                    }
                } else {
                    let count = activeFX.frames.count
                    guard count > 0 else { return }
                    let idx = min(max(0, self.customFXStep), count - 1)
                    if self.editingFrameIndex != idx {
                        self.editingFrameIndex = idx
                    }
                    let frame = activeFX.frames[idx]
                    var batch = self.controls
                    var didChange = false
                    for k in 0..<min(49, frame.count) {
                        let v = frame[k]
                        if batch[k].currentLED != v {
                            batch[k].currentLED = v
                            didChange = true
                            self.sendNoteOn(note: batch[k].number, velocity: v)
                        }
                    }
                    if didChange {
                        self.controls = batch
                    }

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
        switch item.actionType {
        case .passthrough: break
        case .qwerty:
            var totalDelay = 0.0
            for step in item.qwertySteps {
                totalDelay += Double(step.delayMs) / 1000.0
                let delay = totalDelay
                Task { @MainActor in
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                    self.triggerSingleQwerty(key: step.key, cmd: step.cmd, shift: step.shift, alt: step.alt, ctrl: step.ctrl)
                }
            }
        case .osc:
            // Unified handling with range scaling, release, and live values in sendOSCForControl
            break
        case .applescript:
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", item.appleScript]
            try? task.run()
        case .msc:
            let cmd = MSCCommand(rawValue: item.mscCommand) ?? .go
            sendMSCBroadcast(command: cmd, cue: item.mscCueNumber, deviceID: mscDeviceID, format: mscCommandFormat)
        case .artnet:
            sendArtNetFullRig()
        case .sacn:
            sendsACNFullRig()
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
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        conn.start(queue: .global())
        var data = Data(address.utf8)
        let pad = 4 - (data.count % 4)
        data.append(contentsOf: repeatElement(0, count: pad))
        data.append(contentsOf: [0x2C, 0x00, 0x00, 0x00])
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
        log("📡 OSC UDP -> \(host):\(port) \(address)")
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
        if let encoded = try? JSONEncoder().encode(slots) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
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

    func log(_ msg: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let ts = formatter.string(from: Date())
        midiLogs.insert("[\(ts)] \(msg)", at: 0)
        if midiLogs.count > 40 { midiLogs.removeLast() }
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

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? scale : 1.0)
            .offset(y: isHovered ? -lift : 0)
            .brightness(isHovered ? brightnessBoost : 0.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isHovered)
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
    }
}

struct BitchBoyOfficialMascotView: View {
    var auraColor: Color = .cyan
    var onTap: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isPressed = false

    var mascotNSImage: NSImage? {
        if let img = NSImage(named: "BitchBoyMascot") { return img }
        if let img = NSImage(contentsOfFile: "/Users/taylorfossen/Documents/BB/BB/Assets.xcassets/BitchBoyMascot.imageset/bitchboy.png") { return img }
        if let img = NSImage(contentsOfFile: "/Users/taylorfossen/Downloads/DRAFT BITCHBOY_files/bitchboy.png") { return img }
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
                        .frame(width: 160, height: 160) // 2x bigger than the old 80x80 fit!
                        .blendMode(.screen) // Melts any dark background into the PCB
                        .shadow(color: auraColor.opacity(isHovered ? 1.0 : 0.85), radius: isHovered ? 10 : 8)
                        .shadow(color: auraColor.opacity(isHovered ? 0.75 : 0.45), radius: isHovered ? 22 : 18)
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 64))
                        .foregroundColor(auraColor)
                        .shadow(color: auraColor.opacity(0.85), radius: 8)
                }
            }
            .frame(width: 186, height: 96)
            .scaleEffect(isPressed ? 0.94 : (isHovered ? 1.06 : 1.0))
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPressed)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .onHover { h in isHovered = h }
        }
        .buttonStyle(.plain)
    }
}

struct BitchBoyGlowingLogoView: View {
    var auraColor: Color = .cyan
    var onTap: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isPressed = false

    var logoNSImage: NSImage? {
        if let img = NSImage(named: "BitchBoyWordLogo") { return img }
        if let img = NSImage(contentsOfFile: "/Users/taylorfossen/Documents/BB/BB/Assets.xcassets/BitchBoyWordLogo.imageset/bitchboy_logo.png") { return img }
        if let img = NSImage(contentsOfFile: "/Users/taylorfossen/Downloads/Bitchboy23.png") { return img }
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
                        .blendMode(.screen)
                        .shadow(color: auraColor.opacity(isHovered ? 1.0 : 0.85), radius: isHovered ? 10 : 8)
                        .shadow(color: auraColor.opacity(isHovered ? 0.75 : 0.45), radius: isHovered ? 22 : 18)
                } else {
                    Text("BiTCHBOY")
                        .font(.system(size: 24, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                        .shadow(color: auraColor.opacity(0.85), radius: 8)
                }
            }
            .scaleEffect(isPressed ? 0.94 : (isHovered ? 1.06 : 1.0))
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPressed)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .onHover { h in isHovered = h }
        }
        .buttonStyle(.plain)
    }
}

struct HardwareKeyCap: View, Equatable {
    let item: ControlItem
    let isSelected: Bool
    let color: Color
    let sectionBorder: Color
    let onTap: () -> Void

    @State private var isHovered = false

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
               lhs.sectionBorder == rhs.sectionBorder
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Base background
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: isLit
                                ? [color.opacity(0.85), color.opacity(0.40)]
                                : [Color(red: 0.18, green: 0.08, blue: 0.08), Color(red: 0.12, green: 0.05, blue: 0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Key face bezel
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected
                            ? Color(red: 0.22, green: 0.96, blue: 0.76)
                            : (isHovered ? Color.white.opacity(0.9) : sectionBorder.opacity(0.85)),
                        lineWidth: (isSelected || isHovered) ? 2.0 : 1.0
                    )
                    .shadow(color: isHovered ? (isLit ? color.opacity(0.95) : Color.white.opacity(0.4)) : (isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76).opacity(0.8) : (isLit ? color.opacity(0.6) : .clear)), radius: isHovered ? 7 : (isLit ? 6 : 2))

                // Labels & Center Action Cross / QWERTY Shortcut Badge
                VStack(spacing: 0) {
                    Text(item.customName.isEmpty ? item.label : item.customName)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(isLit ? .white : Color(white: 0.88))
                        .padding(.top, 2)
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
                                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                                .foregroundColor(.black)
                                .lineLimit(1)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1.5)
                                .background(Color(red: 0.98, green: 0.78, blue: 0.25))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        } else {
                            Circle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                .frame(width: 14, height: 14)

                            Image(systemName: actionIconName(item.actionType))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(isLit ? .white : Color(white: 0.75))
                        }
                    }

                    Spacer(minLength: 0)

                    Text("N\(item.number)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(isLit ? .white.opacity(0.95) : Color(white: 0.78))
                        .padding(.bottom, 2)
                }
            }
            .frame(width: 44, height: 40)
            .scaleEffect(item.isPressed ? 0.92 : (isHovered ? 1.08 : 1.0))
            .animation(.spring(response: 0.18, dampingFraction: 0.65), value: isHovered)
            .animation(.spring(response: 0.15, dampingFraction: 0.6), value: item.isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .buttonStyle(.plain)
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
    let onSelect: () -> Void
    let onValueChange: (UInt8) -> Void

    static func == (lhs: HardwareVerticalFader, rhs: HardwareVerticalFader) -> Bool {
        return lhs.item.number == rhs.item.number &&
               lhs.item.liveValue == rhs.item.liveValue &&
               lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(item.label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(isSelected ? Color(red: 0.38, green: 0.94, blue: 0.78) : Color(white: 0.85))

            // Vertical Track & Cap
            GeometryReader { geo in
                let trackHeight = geo.size.height - 20
                let normalizedVal = CGFloat(item.liveValue) / 127.0
                let capY = (1.0 - normalizedVal) * trackHeight

                ZStack(alignment: .top) {
                    // Recessed slot
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0.02, green: 0.04, blue: 0.04))
                        .frame(width: 6, height: geo.size.height)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.14), lineWidth: 1))

                    // Coral Rectangular Fader Cap
                    ZStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.98, green: 0.52, blue: 0.44),
                                        Color(red: 0.85, green: 0.32, blue: 0.28)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 22, height: 18)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.35), lineWidth: 1))
                            .shadow(color: .black.opacity(0.8), radius: 3, x: 1, y: 1)

                        // Center white notch line
                        Rectangle()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: 14, height: 1.5)
                    }
                    .offset(y: capY)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            onSelect()
                            let clampedY = min(max(0, gesture.location.y - 9), trackHeight)
                            let inverted = 1.0 - (clampedY / trackHeight)
                            let newVal = UInt8(inverted * 127.0)
                            onValueChange(newVal)
                        }
                )
            }
            .frame(width: 42, height: 110)

            Text("CC\(item.number)")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.38))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .background(isSelected ? Color.white.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture { onSelect() }
    }
}

struct HardwareHorizontalFader: View, Equatable {
    let item: ControlItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onValueChange: (UInt8) -> Void

    static func == (lhs: HardwareHorizontalFader, rhs: HardwareHorizontalFader) -> Bool {
        return lhs.item.number == rhs.item.number &&
               lhs.item.liveValue == rhs.item.liveValue &&
               lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(item.label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(isSelected ? Color(red: 0.38, green: 0.94, blue: 0.78) : Color(white: 0.85))
                .frame(width: 28, alignment: .leading)

            GeometryReader { geo in
                let trackWidth = geo.size.width - 20
                let normalizedVal = CGFloat(item.liveValue) / 127.0
                let capX = normalizedVal * trackWidth

                ZStack(alignment: .leading) {
                    // Recessed track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0.02, green: 0.04, blue: 0.04))
                        .frame(height: 6)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.12), lineWidth: 1))

                    // Coral Rectangular Fader Cap
                    ZStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.98, green: 0.52, blue: 0.44),
                                        Color(red: 0.85, green: 0.32, blue: 0.28)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 18, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.35), lineWidth: 1))
                            .shadow(color: .black.opacity(0.8), radius: 3, x: 1, y: 1)

                        // Center black notch line
                        Rectangle()
                            .fill(Color.black.opacity(0.75))
                            .frame(width: 1.5, height: 16)
                    }
                    .offset(x: capX)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            onSelect()
                            let clampedX = min(max(0, gesture.location.x - 9), trackWidth)
                            let newVal = UInt8((clampedX / trackWidth) * 127.0)
                            onValueChange(newVal)
                        }
                )
            }
            .frame(height: 24)

            Text("CC\(item.number)")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.38))
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.white.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture { onSelect() }
    }
}

struct HardwareKnob: View, Equatable {
    let item: ControlItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onValueChange: (UInt8) -> Void

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
                    .frame(width: 32, height: 32)
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
                        onSelect()
                        let delta = -gesture.translation.height / 100.0
                        let current = Double(item.liveValue) / 127.0
                        let clamped = min(max(0.0, current + delta * 0.05), 1.0)
                        onValueChange(UInt8(clamped * 127.0))
                    }
            )

            HStack(spacing: 3) {
                Text(item.label)
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? Color(red: 0.22, green: 0.96, blue: 0.76) : Color(red: 0.45, green: 0.88, blue: 0.75))
                Text("CC\(item.number)")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.38))
            }
        }
        .frame(width: 58)
        .padding(2)
        .onTapGesture { onSelect() }
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
        DispatchQueue.main.async {
            configureWindow(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let win = nsView.window {
            let targetLevel: NSWindow.Level = isAlwaysOnTop ? .floating : .normal
            if win.level != targetLevel {
                win.level = targetLevel
            }
            if win.contentAspectRatio != baseSize {
                win.contentAspectRatio = baseSize
                let minContentW = baseSize.width * minScale
                let minContentH = baseSize.height * minScale
                win.contentMinSize = NSSize(width: minContentW, height: minContentH)
            }
        }
    }

    private func configureWindow(_ window: NSWindow?) {
        guard let window = window else { return }
        window.level = isAlwaysOnTop ? .floating : .normal
        let minContentW = baseSize.width * minScale
        let minContentH = baseSize.height * minScale
        window.contentMinSize = NSSize(width: minContentW, height: minContentH)
        window.contentAspectRatio = baseSize
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
        if let dragged = engine.draggingModule, dragged != targetModule {
            engine.swapModules(dragged, targetModule)
        }
        engine.draggingModule = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = engine.draggingModule, dragged != targetModule else { return }
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
        if let dragged = engine.draggingModule {
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
    @ObservedObject var engine: BitchBoyEngine
    let module: StudioModuleID

    var body: some View {
        ContentView(engine: engine, standaloneModule: module)
    }
}

struct ContentView: View {
    @ObservedObject var engine: BitchBoyEngine
    var standaloneModule: StudioModuleID? = nil

    @State private var isHoveringLoveBadge: Bool = false
    @State private var isHoveringTitleLogo: Bool = false
    @State private var activeMemoryBank: Int = 0 // 0 = BANK 1 (A-D), 1 = BANK 2 (E-H)
    @State private var showSlotCustomizer: Bool = false
    @State private var inspectorTab: Int = 0 // 0 = LEDs, 1 = QWERTY
    @State private var jigglePhase: Bool = false
    @State private var resizingModule: StudioModuleID? = nil
        @State private var dragInitialHeight: CGFloat = 0

    func currentScale(for module: StudioModuleID, isSpotlight: Bool = false) -> CGFloat {
        engine.moduleTextScale(module, isSpotlight: isSpotlight || engine.spotlightModule == module || standaloneModule == module)
    }

    func isExpanded(module: StudioModuleID, isSpotlight: Bool = false) -> Bool {
        engine.isModuleExpanded(module, isSpotlight: isSpotlight || engine.spotlightModule == module || standaloneModule == module)
    }

    private func setQwertyKeyForSelection(_ key: String) {
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
        if let detachedMod = standaloneModule {
            standaloneModuleWindowBody(for: detachedMod)
                .preferredColorScheme(.dark)
        } else {
            mainConsoleWindowBody
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
                                Text("DOCK")
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
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6))
                    .overlay(Rectangle().frame(height: 1).foregroundColor(engine.currentTheme.accentPrimary.opacity(0.4)), alignment: .bottom)

                    moduleContentView(for: module, isSpotlight: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    private var mainConsoleWindowBody: some View {
        GeometryReader { windowGeo in
            let baseWidth: CGFloat = BitchBoyEngine.consoleBaseWidth
            let baseHeight: CGFloat = engine.effectiveConsoleHeight
            // ALWAYS fit inside windowGeo.size so the window NEVER clips any controls at any size!
            let fitW = max(0.15, windowGeo.size.width / baseWidth)
            let fitH = max(0.15, windowGeo.size.height / baseHeight)
            let fitScale = min(2.4, min(fitW, fitH))
            let isOverlayActive = (engine.spotlightModule != nil || engine.showCustomSoundStudio || engine.showCustomThemeStudio || engine.showUpdateModal)

            ZStack {
                // Lock NSWindow aspect ratio & minimum size (15% of controller) so dragging the window scales the whole controller proportionally with zero clipping
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
                            topNavigationBar
                            mainHardwareFaceplate
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

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
                .frame(width: baseWidth, height: baseHeight, alignment: .top)
                .scaleEffect(fitScale, anchor: .center)
                .frame(width: windowGeo.size.width, height: windowGeo.size.height, alignment: .center)

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
                                        Text("RETURN TO DOCK")
                                    }
                                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(engine.currentTheme.accentPrimary)
                                    .foregroundColor(.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
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
                engine.lastComputedFitScale = fitScale
            }
            .onChange(of: engine.isRearrangingModules) {
                if engine.isRearrangingModules {
                    withAnimation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true)) {
                        jigglePhase = true
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        jigglePhase = false
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------------
    // TOP NAVIGATION & SYSTEM BAR
    // ------------------------------------------------------------------------
    private var topNavigationBar: some View {
        HStack(spacing: 12) {
            // Logo & OS Title (Neon Glowing BITCHMANAGER Header)
            HStack(spacing: 10) {
                Image("BitchBoyBadgeIcon")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .shadow(color: engine.currentTheme.accentPrimary.opacity(isHoveringTitleLogo ? 0.95 : 0.65), radius: isHoveringTitleLogo ? 9 : 5, x: 0, y: 0)
                    .shadow(color: engine.currentTheme.accentPrimary.opacity(isHoveringTitleLogo ? 0.65 : 0.35), radius: isHoveringTitleLogo ? 16 : 10, x: 0, y: 0)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("BITCHMANAGER")
                            .font(.system(size: 15, weight: .heavy, design: .monospaced))
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
                            .tracking(1.1)
                            .shadow(color: engine.currentTheme.accentPrimary.opacity(0.95), radius: isHoveringTitleLogo ? 6 : 4, x: 0, y: 0)
                            .shadow(color: engine.currentTheme.accentPrimary.opacity(isHoveringTitleLogo ? 0.90 : 0.68), radius: isHoveringTitleLogo ? 12 : 9, x: 0, y: 0)
                            .shadow(color: engine.currentTheme.accentPrimary.opacity(isHoveringTitleLogo ? 0.65 : 0.42), radius: isHoveringTitleLogo ? 22 : 16, x: 0, y: 0)
                            .scaleEffect(isHoveringTitleLogo ? 1.03 : 1.0)
                            .animation(.easeInOut(duration: 0.2), value: isHoveringTitleLogo)
                    }

                    Text("BLOCK SYSTEM HARDWARE // LED & ACTION ENGINE")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(engine.currentTheme.headerText)
                        .tracking(0.6)
                        .shadow(color: engine.currentTheme.accentPrimary.opacity(0.35), radius: 4, x: 0, y: 0)
                }
            }
            .onHover { hovering in
                isHoveringTitleLogo = hovering
            }

            Spacer(minLength: 8)

            // Status Pill (Online / Offline — Strictly ONLY BitchBoy Hardware Controller)
            Menu {
                Section("BitchBoy Hardware Status (Strict BitchBoy Only)") {
                    Button(action: {
                        engine.scanForBitchBoy()
                    }) {
                        Label("Rescan for BitchBoy Hardware Now", systemImage: "arrow.clockwise")
                    }
                }
                Section("On-Connect Notification FX (When BitchBoy Plugs In)") {
                    Button(action: {
                        engine.toggleConnectEffectEnabled()
                    }) {
                        Label(
                            engine.connectEffectEnabled ? "On-Connect FX: ENABLED" : "On-Connect FX: DISABLED",
                            systemImage: engine.connectEffectEnabled ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    ForEach(engine.customEffects) { fx in
                        Button(action: {
                            engine.setAsOnConnectFX(fx)
                        }) {
                            Label(
                                fx.name == engine.connectCustomFXName ? "★ \(fx.name) (Active Connect FX)" : "Set '\(fx.name)' as Connect FX",
                                systemImage: fx.name == engine.connectCustomFXName ? "bolt.fill" : "sparkles"
                            )
                        }
                    }
                    Divider()
                    Button(action: {
                        engine.triggerBitchBoyConnectedNotificationFX(isManualTest: true)
                    }) {
                        Label("Preview On-Connect FX Now", systemImage: "play.fill")
                    }
                }
                Section("BitchManager Updates & GitHub Release") {
                    Text("Installed Version: v\(engine.currentAppVersion)")
                    if let rel = engine.latestRelease {
                        Text("Latest on GitHub: \(rel.tagName)")
                    }
                    Button(action: {
                        engine.checkForUpdates(showModalIfCurrent: true)
                    }) {
                        Label(engine.isCheckingForUpdates ? "Checking GitHub..." : "Check for Updates on GitHub...", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(engine.isCheckingForUpdates)
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(engine.isConnected ? Color(red: 0.2, green: 0.95, blue: 0.45) : Color(red: 0.98, green: 0.25, blue: 0.25))
                        .frame(width: 8, height: 8)
                        .shadow(color: engine.isConnected ? Color.green : Color.red, radius: 4)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(engine.isConnected ? "ONLINE // CONNECTED" : "OFFLINE // DISCONNECTED")
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.isConnected ? Color(red: 0.2, green: 0.95, blue: 0.45) : Color(red: 0.98, green: 0.35, blue: 0.35))

                        Text(engine.isConnected ? "\(engine.deviceName) // Ready" : "Unplugged // Waiting for BitchBoy...")
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(white: 0.65))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(engine.isConnected ? Color(red: 0.2, green: 0.95, blue: 0.45).opacity(0.6) : Color(red: 0.98, green: 0.35, blue: 0.35).opacity(0.6), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .menuStyle(.borderlessButton)
            .hoverGrow(1.05)

            // GITHUB AUTO-UPDATE DETECTED PILL
            if engine.updateAvailable, let rel = engine.latestRelease {
                Button(action: {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                        engine.showUpdateModal = true
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .bold))
                        Text("★ UPDATE: \(rel.tagName)")
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 9))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.98, green: 0.72, blue: 0.22), Color(red: 0.95, green: 0.42, blue: 0.15)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: Color.orange.opacity(0.85), radius: 8)
                }
                .buttonStyle(.plain)
                .hoverGrow(1.06)
            }

            Spacer(minLength: 8)

            // Right Customization & Quick Actions + Made with Love
            HStack(spacing: 8) {
                // Made with Love Signature (Glows brightly when the mouse hovers over it!)
                HStack(spacing: 4) {
                    Text("❤️ Made with love - Taylor Fossen")
                        .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(isHoveringLoveBadge ? Color.white : Color.pink.opacity(0.92))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(
                            isHoveringLoveBadge
                                ? Color.pink.opacity(0.42)
                                : Color.black.opacity(0.48)
                        )
                )
                .overlay(
                    Capsule()
                        .stroke(
                            isHoveringLoveBadge ? Color.pink : Color.pink.opacity(0.45),
                            lineWidth: isHoveringLoveBadge ? 1.6 : 1.0
                        )
                )
                .shadow(
                    color: isHoveringLoveBadge ? Color.pink.opacity(0.95) : Color.clear,
                    radius: isHoveringLoveBadge ? 10 : 0
                )
                .shadow(
                    color: isHoveringLoveBadge ? Color(red: 1.0, green: 0.35, blue: 0.75).opacity(0.75) : Color.clear,
                    radius: isHoveringLoveBadge ? 18 : 0
                )
                .scaleEffect(isHoveringLoveBadge ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.18), value: isHoveringLoveBadge)
                .onHover { hovering in
                    isHoveringLoveBadge = hovering
                }

                // ALWAYS ON TOP (TOP-MOST WINDOW PIN BUTTON)
                Button(action: {
                    engine.toggleWindowAlwaysOnTop()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: engine.isWindowAlwaysOnTop ? "pin.fill" : "pin")
                            .font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(engine.isWindowAlwaysOnTop ? 0 : 45))
                        Text(engine.isWindowAlwaysOnTop ? "PINNED TOP" : "TOP MOST")
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(engine.isWindowAlwaysOnTop ? engine.currentTheme.accentPrimary : Color.white.opacity(0.08))
                    .foregroundColor(engine.isWindowAlwaysOnTop ? .black : engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(engine.isWindowAlwaysOnTop ? Color.white.opacity(0.6) : Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: engine.isWindowAlwaysOnTop ? engine.currentTheme.accentPrimary.opacity(0.6) : .clear, radius: 6)
                }
                .buttonStyle(.plain)
                .hoverGrow(1.06)

                // UI SCALE / ZOOM CONTROLLER + APP ICON MENU
                HStack(spacing: 3) {
                    Button(action: {
                        engine.zoomOutUI()
                    }) {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.1))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .hoverGrow(1.10)

                    Menu {
                        Button(action: {
                            engine.enableAutoFitWindow()
                        }) {
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
                            Button(action: {
                                engine.setManualZoom(CGFloat(pct) / 100.0)
                            }) {
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
                        Text("SCALE \(displayPct)%")
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                            .background(engine.autoFitWindow ? engine.currentTheme.accentPrimary.opacity(0.22) : Color.white.opacity(0.1))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton)
                    .hoverGrow(1.06)

                    Button(action: {
                        engine.zoomInUI()
                    }) {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.1))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .hoverGrow(1.10)
                }
                .padding(2)
                .background(Color.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.18), lineWidth: 1))

                // Preset Slot Menu
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
                    Button("💾 Save Slot to Memory") {
                        engine.saveCurrentSlot()
                        engine.log("💾 Presets saved to internal memory.")
                    }
                    Button("📋 Clone to Next Slot") {
                        engine.cloneCurrentSlot()
                    }
                    Button("⤓ Export Slot JSON") {
                        _ = engine.exportPresetToJSON()
                    }
                    Button("⤒ Import Slot JSON") {
                        engine.importPresetFromClipboard()
                    }
                    Divider()
                    Button("🚨 Panic Blackout") {
                        engine.blackoutPanic()
                    }
                } label: {
                    let slotLetters = ["SLOT A", "SLOT B", "SLOT C", "SLOT D", "SLOT E", "SLOT F", "SLOT G", "SLOT H"]
                    HStack(spacing: 4) {
                        Image(systemName: engine.slots.indices.contains(engine.activeSlot) ? engine.slots[engine.activeSlot].iconName : "folder.fill")
                        Text(slotLetters[engine.activeSlot % slotLetters.count])
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.18), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .hoverGrow(1.06)

                // Theme Picker Menu
                Menu {
                    Section("Built-in Cyber Chassis Themes") {
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
                    }

                    Section("Custom Glow Themes") {
                        ForEach(engine.customThemes) { customTh in
                            Button(action: {
                                engine.applyCustomTheme(customTh)
                            }) {
                                HStack {
                                    Text(customTh.name)
                                    if engine.currentTheme == .customUser && engine.activeCustomTheme.id == customTh.id {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }

                        Divider()

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
                } label: {
                    let displayName = engine.currentTheme == .customUser ? engine.activeCustomTheme.name : engine.currentTheme.rawValue
                    HStack(spacing: 4) {
                        Text("🎨")
                        Text(displayName)
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.18), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .hoverGrow(1.06)

                // Sound Pack & Custom Sound Upload Menu
                Menu {
                    Button(action: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                            engine.spotlightModule = nil
                            engine.showCustomSoundStudio = true
                        }
                    }) {
                        Label("🎛️ Upload / Manage Custom Sounds...", systemImage: "waveform.badge.plus")
                    }
                    Divider()
                    ForEach(SoundPack.allCases) { pack in
                        Button(action: {
                            engine.setSoundPack(pack)
                        }) {
                            HStack {
                                Text(pack.rawValue)
                                if engine.soundPack == pack {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Divider()
                    Text("Quick Upload Custom Audio:")
                    ForEach(SoundEffect.allCases) { sfx in
                        Button(action: {
                            engine.uploadCustomSoundFile(for: sfx)
                        }) {
                            let currentFile = CustomSoundBank.shared.fileName(for: sfx)
                            Label(
                                currentFile != nil ? "\(sfx.displayName) (\(currentFile!))" : "Upload \(sfx.displayName)...",
                                systemImage: sfx.iconName
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: engine.soundPack == .mute ? "speaker.slash.fill" : (engine.soundPack == .customUser ? "waveform.badge.mic" : "speaker.wave.2.fill"))
                        Text(engine.soundPack.rawValue)
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(engine.soundPack == .customUser ? engine.currentTheme.accentPrimary.opacity(0.22) : Color.white.opacity(0.08))
                    .foregroundColor(engine.soundPack == .customUser ? engine.currentTheme.accentPrimary : Color(white: 0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(engine.soundPack == .customUser ? engine.currentTheme.accentPrimary.opacity(0.6) : Color.white.opacity(0.18), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .hoverGrow(1.06)

                // iOS-Style Module Rearrange / Jiggle & Pop-Out Window Button
                HStack(spacing: 3) {
                    Button(action: {
                        engine.toggleRearrangeModulesMode()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: engine.isRearrangingModules ? "checkmark.circle.fill" : "square.grid.2x2.fill")
                                .font(.system(size: 8.5, weight: .bold))
                            Text(engine.isRearrangingModules ? "DONE" : "MODULES")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(engine.isRearrangingModules ? Color(red: 0.96, green: 0.76, blue: 0.18) : Color.white.opacity(0.08))
                        .foregroundColor(engine.isRearrangingModules ? .black : engine.currentTheme.accentPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(engine.isRearrangingModules ? Color.white : Color.white.opacity(0.18), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .hoverGrow(1.06)
                    .help("Toggle Rearrange & Dynamic Resizing Mode (Drag cards into spaces or resize)")

                    Menu {
                        Button(action: { engine.toggleRearrangeModulesMode() }) {
                            Label(engine.isRearrangingModules ? "Lock Layout (Exit Rearrange Mode)" : "Rearrange Mode (Drag into Spaces)", systemImage: engine.isRearrangingModules ? "lock.fill" : "hand.draw.fill")
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
                                    engine.setModuleHeight(m, height: 340, save: false)
                                }
                                engine.saveModuleSizes()
                            }) {
                                Label("Standard Size All Modules (340px)", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.08))
                            .foregroundColor(engine.currentTheme.accentPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton)
                    .hoverGrow(1.10)
                    .help("Layout Options & Quick Presets")
                }

                // Rainbow Refresh
                Button(action: {
                    engine.runRainbowWaveRefresh()
                }) {
                    HStack(spacing: 4) {
                        Text("✨🌈")
                        Text("RAINBOW REFRESH")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.45, green: 0.25, blue: 0.75), Color(red: 0.25, green: 0.65, blue: 0.75)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .hoverGrow(1.06)
                .disabled(engine.isRainbowRunning)

                // FX Light Show Menu
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
                    HStack(spacing: 4) {
                        Image(systemName: engine.isPlayingCustomFX ? "wand.and.stars" : (engine.currentFXMode == .staticFX ? "sparkles" : engine.currentFXMode.icon))
                        Text(engine.isPlayingCustomFX ? "CUSTOM: \(engine.activeCustomFXName)" : "FX: \(engine.currentFXMode.rawValue)")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background((engine.currentFXMode == .staticFX && !engine.isPlayingCustomFX) ? Color(red: 0.08, green: 0.25, blue: 0.24) : Color(red: 0.92, green: 0.45, blue: 0.15).opacity(0.88))
                    .foregroundColor((engine.currentFXMode == .staticFX && !engine.isPlayingCustomFX) ? Color(red: 0.22, green: 0.96, blue: 0.76) : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.22, green: 0.96, blue: 0.76).opacity(0.6), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .hoverGrow(1.06)

                if engine.currentFXMode != .staticFX || engine.isPlayingCustomFX {
                    Button(action: {
                        engine.stopCustomEffect()
                        engine.applyFXMode(.staticFX)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "stop.fill")
                            Text("STOP FX")
                        }
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(Color.red.opacity(0.85))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .hoverGrow(1.06)
                }
            }
        }
    }

    // ------------------------------------------------------------------------
    // MAIN HARDWARE FACEPLATE (THE AUTHENTIC CONSOLE LAYOUT)
    // ------------------------------------------------------------------------
    private var mainHardwareFaceplate: some View {
        ZStack(alignment: .top) {
            // Chassis Surface
            RoundedRectangle(cornerRadius: 20)
                .fill(engine.currentTheme.pcbBackground)

            // Metallic Bezel
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    LinearGradient(
                        colors: engine.currentTheme.outerBezelColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 5.5
                )

            // Metallic Screws in Bezel Corners & Centers
            VStack {
                HStack {
                    ScrewRivetView(size: 13)
                    Spacer()
                    ScrewRivetView(size: 13)
                    Spacer()
                    ScrewRivetView(size: 13)
                }
                Spacer()
                HStack {
                    ScrewRivetView(size: 13)
                    Spacer()
                    ScrewRivetView(size: 13)
                    Spacer()
                    ScrewRivetView(size: 13)
                }
            }
            .padding(7)

            // FULL-CHASSIS HARDWARE CONSOLE: LEFT WING + CENTER BITCHBOY MATRIX + RIGHT WING
            HStack(alignment: .top, spacing: 20) {
                // LEFT WING (Modules placed in Left Wing)
                if !engine.leftWingModules.isEmpty || engine.isRearrangingModules {
                    ScrollView([.vertical], showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(engine.leftWingModules) { mod in
                                dynamicModuleContainer(for: mod, in: .leftWing)
                            }
                            if engine.isRearrangingModules {
                                dropTargetCard(forZone: .leftWing)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(width: engine.leftWingWidth)
                    .frame(height: engine.chassisContentHeight)
                    .clipped()
                }

                // CENTER HARDWARE CONSOLE: 8x4 Grid + 1x8 Strip + 8 VFaders + 4 HFaders + Logo + HUD + Knobs + 3x3 Keypad + OPTIONAL BOTTOM RACK
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 18) {
                        // LEFT COLUMN: 8x4 Grid + 1x8 Strip + 8 Vertical Faders (Width: 414)
                        VStack(alignment: .leading, spacing: 8) {
                            section1KeyGrid8x4
                            section2KeyStrip1x8
                            section4VerticalFaders
                        }
                        .frame(width: 414)

                        // RIGHT SECTION: Middle Column (Faders + Glowing Logo + HUD) & Far-Right Column (Knobs + Mascot + Keypad)
                        HStack(alignment: .top, spacing: 14) {
                            // Middle Column: 4 Horizontal Faders + Glowing BitchBoy Logo + Center Inspector HUD (Width: 254)
                            VStack(alignment: .leading, spacing: 10) {
                                section5HorizontalFaders
                                    .frame(width: 254)

                                // Glowing BitchBoy Mascot Logo (Style and glow of BitchBoy Mascot)
                                BitchBoyGlowingLogoView(auraColor: engine.currentTheme.accentPrimary) {
                                    SoundEffect.mascotSqueak.play(with: engine.soundPack)
                                    engine.log("✨ BITCHBOY LOGO ACTIVATED")
                                }
                                .frame(width: 254, height: 68)

                                centerInspectorHUD
                                    .frame(width: 254, height: 256)
                            }
                            .frame(width: 254)

                            // Far-Right Column: 2x4 Knobs + Official Mascot & 3x3 Keypad (Width: 194)
                            VStack(alignment: .center, spacing: 10) {
                                section6RotaryKnobs
                                    .frame(width: 194)

                                section3KeypadAndMascot
                                    .frame(width: 194)
                            }
                            .frame(width: 194)
                        }
                        .frame(width: 462)
                    }

                    // BOTTOM CONSOLE RACK (Expansion Bay for modules placed in bottom rack!)
                    if !engine.bottomRackModules.isEmpty || engine.isRearrangingModules {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 5) {
                                Image(systemName: "rectangle.bottomthird.inset.filled")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(engine.currentTheme.accentPrimary)
                                Text("CONSOLE EXPANSION BAY // BOTTOM RACK")
                                    .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                                    .foregroundColor(engine.currentTheme.headerText)
                                Spacer()
                            }
                            .padding(.horizontal, 4)

                            ScrollView([.horizontal], showsIndicators: true) {
                                HStack(alignment: .top, spacing: 12) {
                                    ForEach(engine.bottomRackModules) { mod in
                                        dynamicModuleContainer(for: mod, in: .bottomRack)
                                            .frame(width: engine.moduleCustomWidths[mod] ?? 435)
                                    }
                                    if engine.isRearrangingModules {
                                        dropTargetCard(forZone: .bottomRack)
                                            .frame(width: 220)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .frame(maxWidth: 894)
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(engine.currentTheme.sectionOutline.opacity(0.4), lineWidth: 1))
                        .onDrop(of: [.plainText], delegate: ZoneDropDelegate(targetZone: .bottomRack, engine: engine))
                    } else if engine.chassisContentHeight > 560 {
                        bottomRackEmptyShelf
                    }
                }
                .frame(height: engine.chassisContentHeight, alignment: .top)

                // RIGHT WING (Modules placed in Right Wing)
                if !engine.rightWingModules.isEmpty || engine.isRearrangingModules {
                    ScrollView([.vertical], showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(engine.rightWingModules) { mod in
                                dynamicModuleContainer(for: mod, in: .rightWing)
                            }
                            if engine.isRearrangingModules {
                                dropTargetCard(forZone: .rightWing)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(width: engine.rightWingWidth)
                    .frame(height: engine.chassisContentHeight)
                    .clipped()
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
        .frame(height: engine.chassisContentHeight + 36)
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
                    ForEach(StudioModuleID.allCases) { m in
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
                        .font(.system(size: 7.5, weight: .bold))
                    Text(engine.moduleSizePresetLabel(module))
                        .font(.system(size: 7.2, weight: .heavy, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundColor(engine.currentTheme.accentPrimary)
                .frame(width: 64, height: 18)
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
                            .font(.system(size: 7.5, weight: .bold))
                        Text(engine.moduleWidthPresetLabel(module))
                            .font(.system(size: 7.2, weight: .heavy, design: .monospaced))
                            .lineLimit(1)
                    }
                    .foregroundColor(Color(red: 0.96, green: 0.76, blue: 0.18))
                    .frame(width: 58, height: 19)
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
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Color(white: 0.85))
                    .frame(width: 17, height: 19)
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
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(engine.spotlightModule == module ? .black : engine.currentTheme.accentPrimary)
                    .frame(width: 17, height: 19)
                    .background(engine.spotlightModule == module ? engine.currentTheme.accentPrimary : Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
            }
            .buttonStyle(.plain)
            .hoverGrow(1.08)
            .help("Center Module on Screen with Blurred Background")
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)

            // Pop Out Into Standalone Floating Window
            if standaloneModule == nil {
                Button(action: {
                    engine.popOutModuleToWindow(module)
                }) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color(white: 0.85))
                        .frame(width: 17, height: 19)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                }
                .buttonStyle(.plain)
                .hoverGrow(1.08)
                .help("Pop Out Module Into Its Own Window")
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
    }

    private func dynamicModuleContainer(for mod: StudioModuleID, in zone: ModuleZone) -> some View {
        let isDetached = engine.detachedModules.contains(mod)
        let jiggleAngle: Double = engine.isRearrangingModules ? (jigglePhase ? -1.1 : 1.1) : 0.0
        let targetHeight = engine.moduleCustomHeights[mod] ?? mod.defaultSlotHeight

        return VStack(spacing: 0) {
            // If in Rearrange Mode, show the Quick Move / Zone Transfer pill bar above card
            if engine.isRearrangingModules {
                moduleRearrangeActionBar(for: mod, currentZone: zone)
                    .padding(.bottom, 3)
            }

            if isDetached {
                detachedModulePlaceholderCard(for: mod)
            } else {
                VStack(spacing: 0) {
                    // Module Content (Internally scrollable so NOTHING ever cuts off!)
                    moduleContentView(for: mod)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    // Interactive Bottom Drag-to-Resize Handle Bar
                    moduleResizeHandleBar(for: mod, currentHeight: targetHeight, zone: zone)
                }
                .frame(height: targetHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            engine.isRearrangingModules ? Color(red: 0.96, green: 0.76, blue: 0.18) : Color.clear,
                            style: StrokeStyle(lineWidth: engine.isRearrangingModules ? 1.8 : 0, dash: [6, 4])
                        )
                )
            }
        }
        .rotationEffect(.degrees(jiggleAngle))
        .onDrag {
            engine.draggingModule = mod
            return NSItemProvider(object: mod.rawValue as NSString)
        }
        .onDrop(of: [.plainText], delegate: ModuleSlotDropDelegate(targetModule: mod, engine: engine))
        .contextMenu {
            moduleContextMenu(for: mod, zone: zone)
        }
    }

    private func moduleResizeHandleBar(for mod: StudioModuleID, currentHeight: CGFloat, zone: ModuleZone) -> some View {
        HStack(spacing: 4) {
            Text("↕ RESIZE")
                .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
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
                        .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
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
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(engine.currentTheme.accentPrimary.opacity(0.95))

            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 8.5, weight: .bold))
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
                .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.22))

            Spacer(minLength: 2)

            Button("⇦ LW") { engine.moveModuleToZone(mod, zone: .leftWing) }
                .buttonStyle(.plain)
                .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 4.5)
                .padding(.vertical, 2)
                .background(currentZone == .leftWing ? Color(red: 0.96, green: 0.76, blue: 0.18) : Color.white.opacity(0.12))
                .foregroundColor(currentZone == .leftWing ? .black : .white)
                .clipShape(RoundedRectangle(cornerRadius: 3))

            Button("⇨ RW") { engine.moveModuleToZone(mod, zone: .rightWing) }
                .buttonStyle(.plain)
                .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 4.5)
                .padding(.vertical, 2)
                .background(currentZone == .rightWing ? Color(red: 0.96, green: 0.76, blue: 0.18) : Color.white.opacity(0.12))
                .foregroundColor(currentZone == .rightWing ? .black : .white)
                .clipShape(RoundedRectangle(cornerRadius: 3))

            Button("⇩ RACK") { engine.moveModuleToZone(mod, zone: .bottomRack) }
                .buttonStyle(.plain)
                .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 4.5)
                .padding(.vertical, 2)
                .background(currentZone == .bottomRack ? Color(red: 0.96, green: 0.76, blue: 0.18) : Color.white.opacity(0.12))
                .foregroundColor(currentZone == .bottomRack ? .black : .white)
                .clipShape(RoundedRectangle(cornerRadius: 3))

            Button(action: { engine.popOutModuleToWindow(mod) }) {
                Image(systemName: "macwindow.badge.plus")
                    .font(.system(size: 8.5, weight: .bold))
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 2)
                    .background(engine.currentTheme.accentPrimary.opacity(0.28))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
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
                    .font(.system(size: 14))
                    .foregroundColor(Color(red: 0.96, green: 0.76, blue: 0.18).opacity(0.7))
                Text("+ PLACE MODULE IN \(zone.displayName)")
                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(Color(red: 0.96, green: 0.76, blue: 0.18))
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.28))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    .foregroundColor(Color(red: 0.96, green: 0.76, blue: 0.18).opacity(0.65))
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

                        ScrollView {
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

                        if let rel = engine.latestRelease, let url = URL(string: rel.htmlUrl) {
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
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)

                        Text("MIDI ROUTER")
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 2)

                        HStack(spacing: 3) {
                            Circle()
                                .fill(engine.midiThruEnabled ? Color.green : Color.orange)
                                .frame(width: 5, height: 5)
                            Text(engine.midiThruEnabled ? "THRU ON" : "MUTED")
                                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                                .foregroundColor(engine.midiThruEnabled ? Color.green : Color.orange)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        engine.toggleSpotlightModule(.midiRouter)
                    }

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

            ScrollView([.vertical], showsIndicators: true) {
                if engine.leftWingTab == "TELEMETRY" {
                    leftWingTelemetryScopeContent
                } else if engine.leftWingTab == "MACROS" {
                    leftWingMacrosContent
                } else {
                    leftWingMIDIRouterContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Toggle("", isOn: $engine.virtualOutEnabled)
                        .toggleStyle(.switch)
                        .scaleEffect(0.65)
                        .frame(width: 34, height: 16)
                }
                Text("Port Name: 'BitchBoy Virtual Out'")
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                Text("Select 'BitchBoy Virtual Out' in Ableton, Logic, QLab, Resolume, or any synth!")
                    .font(.system(size: 7, design: .monospaced))
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
                        .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.headerText)
                    Spacer()
                    Button("ALL APPS") {
                        engine.selectAllExternalOutputs()
                    }
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .buttonStyle(.plain)

                    Button("↻") {
                        engine.scanForBitchBoy()
                    }
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(engine.currentTheme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .buttonStyle(.plain)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        if engine.availableOutputTargets.isEmpty {
                            Text("No external MIDI ports detected. Use 'BitchBoy Virtual Out' or enable IAC Driver.")
                                .font(.system(size: 7, design: .monospaced))
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
                                            .font(.system(size: 9))
                                            .foregroundColor(isSelected ? engine.currentTheme.accentPrimary : Color(white: 0.5))
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(target.name)
                                                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                                .foregroundColor(.white)
                                                .lineLimit(1)
                                            Text(target.isHardwareBitchBoy ? "Hardware Controller Port" : "External App / Synth / Bus")
                                                .font(.system(size: 6.5, design: .monospaced))
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
                        .font(.system(size: 6.5, weight: .bold, design: .monospaced))
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
                                .font(.system(size: 7))
                            Text("MIDI STUDIO ICON")
                                .font(.system(size: 6, weight: .heavy, design: .monospaced))
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
                    .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)

                // Output Channel Picker
                HStack {
                    Text("OUT CHANNEL:")
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Spacer()
                    Picker("", selection: $engine.remapChannel) {
                        Text("ORIG (CH 1)").tag(0)
                        ForEach(1...16, id: \.self) { ch in
                            Text("FORCE CH \(ch)").tag(ch)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .frame(width: 118)
                }

                // Transpose Semitones
                HStack(spacing: 4) {
                    Text("TRANSPOSE:")
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Spacer()
                    Button("-12") { engine.transposeSemitones = max(-24, engine.transposeSemitones - 12) }
                        .buttonStyle(.plain).font(.system(size: 7, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 2).background(Color.white.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 3))
                    Button("-") { engine.transposeSemitones = max(-24, engine.transposeSemitones - 1) }
                        .buttonStyle(.plain).font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Color.white.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(engine.transposeSemitones >= 0 ? "+\(engine.transposeSemitones)" : "\(engine.transposeSemitones)")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                        .frame(width: 28)
                    Button("+") { engine.transposeSemitones = min(24, engine.transposeSemitones + 1) }
                        .buttonStyle(.plain).font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Color.white.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 3))
                    Button("+12") { engine.transposeSemitones = min(24, engine.transposeSemitones + 12) }
                        .buttonStyle(.plain).font(.system(size: 7, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 2).background(Color.white.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 3))
                }

                // Velocity Curve
                HStack(spacing: 3) {
                    Text("CURVE:")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Spacer()
                    ForEach(MIDIVelocityCurve.allCases) { curve in
                        Button(curve.rawValue) {
                            engine.velocityCurve = curve
                        }
                        .font(.system(size: 6.5, weight: .bold, design: .monospaced))
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
                    .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
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
                    .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
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
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.5))
                    Spacer()
                    Text("PKTS: \(engine.txPacketCount)")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                }
                Text(engine.lastRoutedMessage)
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
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
                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<8, id: \.self) { i in
                    let val = engine.controls[49 + i].liveValue
                    VStack(spacing: 2) {
                        Text("\(val)")
                            .font(.system(size: 6.5, weight: .bold, design: .monospaced))
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
                            .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.65))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(6)
            .background(Color.black.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("4 HORIZ FADERS & 8 KNOBS (CC 8–11, 20–27)")
                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            VStack(spacing: 3) {
                ForEach(57..<69, id: \.self) { idx in
                    let item = engine.controls[idx]
                    HStack(spacing: 5) {
                        Text(item.label)
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
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
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.96, green: 0.72, blue: 0.28))
                            .frame(width: 24, alignment: .trailing)
                    }
                }
            }
            .padding(6)
            .background(Color.black.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("LIVE MIDI HEX PACKET MONITOR")
                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if engine.routerPacketHistory.isEmpty {
                        Text("Waiting for MIDI packets...")
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundColor(Color(white: 0.5))
                    } else {
                        ForEach(engine.routerPacketHistory, id: \.self) { pkt in
                            Text(pkt)
                                .font(.system(size: 7, design: .monospaced))
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
                        .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
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
                        .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
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
                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
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
                    let pal: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 95, 3]
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
                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
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
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)

                        Text("SHOW CONTROL")
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 2)

                        HStack(spacing: 3) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 5, height: 5)
                            Text("LIVE")
                                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                                .foregroundColor(Color.green)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        engine.toggleSpotlightModule(.showControl)
                    }

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

            ScrollView([.vertical], showsIndicators: true) {
                if engine.showControlSubTab == "FEEDBACK" {
                    showControlFeedbackContent
                } else {
                    showControlUnifiedOSCContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                        .font(.system(size: 9))
                    Text("Patch 1 - BitchBoy (BLOCK SYSTEM)")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Text("DEV: \(engine.mscDeviceID == 127 ? "ALL" : "\(engine.mscDeviceID)")")
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                }

                Text("CoreMIDI destination online • Auto-discovered by QLab, EOS, and GrandMA")
                    .font(.system(size: 6.8, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))

                Toggle(isOn: $engine.mscAutoTriggerOnInbound) {
                    Text("Auto-Trigger Presets on Inbound MSC (GO / STOP / LOAD)")
                        .font(.system(size: 7.2, weight: .bold, design: .monospaced))
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
                    .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)

                HStack(spacing: 6) {
                    // Device ID
                    VStack(alignment: .leading, spacing: 1) {
                        Text("DEVICE ID:")
                            .font(.system(size: 6.5, weight: .bold, design: .monospaced))
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
                            .font(.system(size: 6.5, weight: .bold, design: .monospaced))
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
                            .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                        TextField("e.g. 1.0", text: $engine.mscCueNumber)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    // Cue List
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CUE LIST (OPTIONAL):")
                            .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                        TextField("e.g. Main", text: $engine.mscCueList)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
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
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Spacer()
                    Button("CLEAR") {
                        engine.clearMSCLogHistory()
                    }
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                    .buttonStyle(.plain)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if engine.mscLogHistory.isEmpty {
                            Text("Ready. Listening on 'BitchBoy (BLOCK SYSTEM)' and transmitting on GO / STOP.")
                                .font(.system(size: 6.8, design: .monospaced))
                                .foregroundColor(Color(white: 0.5))
                                .padding(4)
                        } else {
                            ForEach(engine.mscLogHistory) { msg in
                                HStack(spacing: 4) {
                                    Text(msg.timeString)
                                        .font(.system(size: 6.5, design: .monospaced))
                                        .foregroundColor(Color(white: 0.5))
                                    Text(msg.summary)
                                        .font(.system(size: 7, weight: .bold, design: .monospaced))
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
                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
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
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
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
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
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
                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("HOST IP:")
                        .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("127.0.0.1", text: $engine.customOSCHost)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("PORT:")
                        .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("53000", value: $engine.customOSCPort, formatter: NumberFormatter())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("OSC ADDRESS:")
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                TextField("/cue/selected/start", text: $engine.customOSCAddress)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("ARG TYPE:")
                        .font(.system(size: 6.5, weight: .bold, design: .monospaced))
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
                            .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                        TextField("Value", text: $engine.customOSCArgValue)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
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
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
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
                    .font(.system(size: 6.8, weight: .bold, design: .monospaced))
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
                .font(.system(size: 7, weight: .bold, design: .monospaced))
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
                        .font(.system(size: 7.2, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.midiToOSCMappingActive ? Color.green : Color.white)
                    Text("Keys, Faders, & Encoders broadcast mapped OSC addresses via UDP")
                        .font(.system(size: 6.2, design: .monospaced))
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
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.headerText)
                    Text("Map any button or fader to send custom OSC messages")
                        .font(.system(size: 6.5, design: .monospaced))
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
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.55))

                HStack(spacing: 3) {
                    Button(action: { engine.applyOSCAutoMapTemplate() }) {
                        Text("⚡ AUTO-MAP")
                            .font(.system(size: 7, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 5)
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
                            .font(.system(size: 7, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 5)
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
                            .font(.system(size: 7, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.1))
                            .foregroundColor(.cyan)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .hoverGrow(1.05)
                    .help("Map layer clips and opacity faders for Resolume Arena")

                    Button(action: { engine.applyOSCEosTemplate() }) {
                        Text("💡 ETC EOS")
                            .font(.system(size: 7, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.1))
                            .foregroundColor(.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .hoverGrow(1.05)
                    .help("Map submasters and keys for ETC EOS / nomad")

                    Button(action: { engine.clearAllOSCMappings() }) {
                        Text("🧹 CLEAR")
                            .font(.system(size: 7, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 5)
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

            // Target Host & Port default strip
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("GLOBAL TARGET IP:")
                        .font(.system(size: 6, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("127.0.0.1", text: $engine.customOSCHost)
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2.5)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("PORT:")
                        .font(.system(size: 6, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("53000", value: $engine.customOSCPort, formatter: NumberFormatter())
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2.5)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("SEARCH / FILTER:")
                        .font(.system(size: 6, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("Search key/fader...", text: $engine.midiToOSCSearchText)
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2.5)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            // Section Filter Tabs
            HStack(spacing: 2) {
                oscFilterTabButton(title: "ALL", filterKey: "ALL")
                oscFilterTabButton(title: "GRID", filterKey: "GRID")
                oscFilterTabButton(title: "STRIP", filterKey: "STRIP")
                oscFilterTabButton(title: "PAD", filterKey: "PAD")
                oscFilterTabButton(title: "V-FADERS", filterKey: "VFADERS")
                oscFilterTabButton(title: "H-FADERS", filterKey: "HFADERS")
                oscFilterTabButton(title: "MASTER/KNOBS", filterKey: "MASTER_KNOBS")
            }

            // Controls List
            let indices = engine.filteredControlIndices()
            if indices.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.4))
                    Text("No matching controls")
                        .font(.system(size: 7.5, design: .monospaced))
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
                .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 5)
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
                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(engine.controls[index].oscEnabled ? engine.currentTheme.accentPrimary.opacity(0.20) : Color.white.opacity(0.08))
                    .foregroundColor(engine.controls[index].oscEnabled ? engine.currentTheme.accentPrimary : Color(white: 0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                // Control Name / Label
                Text(item.label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                // Live status pill
                if isKey {
                    if item.isPressed {
                        Text("PRESSED")
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Color.green)
                            .foregroundColor(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                } else {
                    Text("\(item.liveValue)")
                        .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
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
                            .font(.system(size: 8))
                        Text("TEST")
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
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
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.82))
                    TextField(item.label, text: $engine.controls[index].customName)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .frame(width: 95)

                VStack(alignment: .leading, spacing: 2) {
                    Text("OSC ADDRESS PATH:")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.82))
                    TextField(isKey ? "/bitchboy/key/\(index + 1)" : "/bitchboy/fader/\(max(1, index - 48))", text: $engine.controls[index].oscAddress)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
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
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
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
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .frame(height: 20)
                }
                .frame(width: 95)

                if isKey {
                    // Send on Release Checkbox & Release Value
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ON RELEASE:")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
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
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
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
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.82))
                        TextField("0.0", value: $engine.controls[index].oscMinVal, formatter: NumberFormatter())
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .textFieldStyle(.plain)
                            .frame(width: 48)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2.5)
                            .background(Color.black.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MAX VAL:")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.82))
                        TextField("1.0", value: $engine.controls[index].oscMaxVal, formatter: NumberFormatter())
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
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
                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("HOST / BROADCAST IP:")
                        .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("255.255.255.255", text: $engine.artNetHost)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("UNIVERSE (0-32767):")
                        .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("0", value: $engine.artNetUniverse, formatter: NumberFormatter())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
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
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
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
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
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
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
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
                        .font(.system(size: 7.2, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.artNetMirrorHardwareFaders ? Color.green : Color.white)
                    Text("Moving physical sliders immediately broadcasts UDP DMX packets")
                        .font(.system(size: 6.2, design: .monospaced))
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
                    .font(.system(size: 6.8, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.65))

                HStack(spacing: 4) {
                    ForEach(0..<8) { ch in
                        VStack(spacing: 1) {
                            Text("Ch\(ch+1)")
                                .font(.system(size: 5.5, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(white: 0.6))
                            Text("\(engine.artNetChannels[ch])")
                                .font(.system(size: 6, weight: .heavy, design: .monospaced))
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
                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("UNIVERSE (1-63999):")
                        .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("1", value: $engine.sacnUniverse, formatter: NumberFormatter())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("PRIORITY (1-200):")
                        .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("100", value: $engine.sacnPriority, formatter: NumberFormatter())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("UNICAST IP (LEAVE EMPTY FOR MULTICAST):")
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                TextField("Multicast 239.255.x.y", text: $engine.sacnHost)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
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
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
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
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
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
                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            Toggle(isOn: $engine.hardwareFeedbackEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("LOCAL HARDWARE LED FEEDBACK")
                        .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                    Text("When ON, pressing keys immediately updates BitchBoy LEDs locally based on feedback mode.")
                        .font(.system(size: 6.8, design: .monospaced))
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
                        .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                    Text("When ON, incoming MIDI notes from QLab or DAWs light up the hardware key LEDs.")
                        .font(.system(size: 6.8, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                }
            }
            .toggleStyle(.checkbox)
            .padding(4)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Text("Selected Control: \(engine.controls[engine.selectedIndex].label)")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(engine.currentTheme.accentPrimary)
                .padding(.top, 2)

            HStack(spacing: 4) {
                Text("MODE:")
                    .font(.system(size: 6.8, weight: .bold, design: .monospaced))
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
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(activeSlotColor)
                            .shadow(color: activeSlotColor.opacity(0.8), radius: 4)

                        Text("MEMORY SLOTS")
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
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
                        .font(.system(size: 7.5 * scale, weight: .heavy, design: .monospaced))
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
                            .font(.system(size: 7.5 * scale, weight: .heavy, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3.5 * scale)
                            .background(activeMemoryBank == 1 ? engine.currentTheme.accentPrimary : Color.white.opacity(0.08))
                            .foregroundColor(activeMemoryBank == 1 ? .black : Color(white: 0.75))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
            ScrollView([.vertical], showsIndicators: true) {
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
                                    .font(.system(size: 7 * scale, weight: .heavy, design: .monospaced))
                                    .padding(.horizontal, 4.5 * scale)
                                    .padding(.vertical, 1.5 * scale)
                                    .background(isSelected ? slotAccent : Color.white.opacity(0.12))
                                    .foregroundColor(isSelected ? .black : slotAccent)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))

                                Image(systemName: slot.iconName)
                                    .font(.system(size: 8.5 * scale, weight: .bold))
                                    .foregroundColor(isSelected ? .white : slotAccent)

                                Spacer(minLength: 0)

                                Circle()
                                    .fill(isSelected ? Color.green : slotAccent.opacity(0.45))
                                    .frame(width: 6 * scale, height: 6 * scale)
                                    .shadow(color: isSelected ? Color.green : .clear, radius: 3)
                            }

                            Text(shortTitle.isEmpty ? slot.name : shortTitle)
                                .font(.system(size: 7.5 * scale, weight: .heavy, design: .monospaced))
                                .foregroundColor(isSelected ? .white : Color(white: 0.85))
                                .lineLimit(1)

                            HStack(spacing: 4 * scale) {
                                Text("\(litCount) LED")
                                    .font(.system(size: 6 * scale, weight: .bold, design: .monospaced))
                                    .foregroundColor(isSelected ? slotAccent : Color(white: 0.55))
                                Text("•")
                                    .font(.system(size: 6 * scale, weight: .bold))
                                    .foregroundColor(Color(white: 0.4))
                                Text("\(macroCount) ACT")
                                    .font(.system(size: 6 * scale, weight: .bold, design: .monospaced))
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
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(activeSlotColor)
                                .frame(width: 20, height: 20)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 22)

                        // Editable Slot Name TextField
                        TextField(
                            "SLOT NAME",
                            text: Binding(
                                get: { engine.slots[activeIdx].name },
                                set: { newVal in
                                    engine.slots[activeIdx].name = newVal
                                    engine.saveCurrentSlot()
                                }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .background(Color.black.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(activeSlotColor.opacity(0.45), lineWidth: 0.8))

                        // Toggle Color Swatch Bar
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showSlotCustomizer.toggle()
                            }
                        }) {
                            Image(systemName: showSlotCustomizer ? "paintpalette.fill" : "paintpalette")
                                .font(.system(size: 8.5, weight: .bold))
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
                                .font(.system(size: 6.5, weight: .heavy, design: .monospaced))
                                .foregroundColor(activeSlotColor)
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 4) {
                            let swatches: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 95, 83, 3]
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
                            .font(.system(size: 6, weight: .heavy, design: .monospaced))
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
                    .font(.system(size: 6.5, weight: .heavy, design: .monospaced))
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
                            .font(.system(size: 7))
                        Text("CLONE")
                            .font(.system(size: 6, weight: .heavy, design: .monospaced))
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
                    .font(.system(size: 6.5, weight: .heavy, design: .monospaced))
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
                    .font(.system(size: 6.5, weight: .heavy, design: .monospaced))
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
                        .font(.system(size: 7.5, weight: .heavy))
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
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(engine.currentTheme.accentPrimary)

                        Text("CUSTOM FX")
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.currentTheme.headerText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 2)

                        if engine.isPlayingCustomFX {
                            HStack(spacing: 3) {
                                Circle().fill(Color.green).frame(width: 5, height: 5)
                                Text("LIVE")
                                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                                    .foregroundColor(.green)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        engine.toggleSpotlightModule(.customFXStudio)
                    }

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

            ScrollView([.vertical], showsIndicators: true) {
                if engine.rightWingTab == "SEQUENCER" {
                    rightWingFrameSequencerContent
                } else if engine.rightWingTab == "WAVESYNTH" {
                    rightWingWaveSynthContent
                } else {
                    rightWingSavedLibraryContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            // Show Name + Play/Save Row
            HStack(spacing: 4) {
                TextField("Show Name", text: $engine.editingCustomFX.name)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.15), lineWidth: 1))

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
                    .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(engine.isPlayingCustomFX ? Color.red : engine.currentTheme.accentPrimary)
                    .foregroundColor(engine.isPlayingCustomFX ? .white : .black)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)

                Button(action: {
                    engine.saveEditingCustomFXToLibrary()
                }) {
                    Text("💾 SAVE")
                        .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Color(red: 0.16, green: 0.45, blue: 0.34))
                        .foregroundColor(Color(red: 0.4, green: 0.98, blue: 0.78))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)

                let isCurrentConnectFX = (engine.connectCustomFXName == engine.editingCustomFX.name && engine.connectEffectEnabled)
                Button(action: {
                    engine.saveEditingCustomFXToLibrary()
                    engine.setAsOnConnectFX(engine.editingCustomFX)
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: isCurrentConnectFX ? "bolt.circle.fill" : "bolt.fill")
                        Text(isCurrentConnectFX ? "ON-CONNECT" : "SET CONNECT")
                    }
                    .font(.system(size: 6.5, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(isCurrentConnectFX ? Color(red: 0.96, green: 0.76, blue: 0.18) : Color.white.opacity(0.12))
                    .foregroundColor(isCurrentConnectFX ? .black : Color(red: 0.96, green: 0.78, blue: 0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }

            // Toggle to paint directly on the big 49-key BitchBoy console!
            Button(action: {
                engine.paintOnMainChassis.toggle()
            }) {
                HStack(spacing: 5) {
                    Image(systemName: engine.paintOnMainChassis ? "paintbrush.pointed.fill" : "paintbrush")
                    Text(engine.paintOnMainChassis ? "PAINTING ON MAIN 49 KEYS: ON" : "CLICK TO PAINT ON MAIN 49 KEYS")
                        .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(engine.paintOnMainChassis ? Color(red: 0.95, green: 0.50, blue: 0.15) : Color.white.opacity(0.08))
                .foregroundColor(engine.paintOnMainChassis ? .black : engine.currentTheme.accentPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            // Interactive 49-Key Mini Canvas Preview & Painter
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    let safeFrame = min(max(0, engine.editingFrameIndex), max(0, engine.editingCustomFX.frames.count - 1))
                    Text("FRAME \(safeFrame + 1)/\(engine.editingCustomFX.frames.count) CANVAS (CLICK TO PAINT)")
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color(white: 0.65))
                    Spacer()
                    Text("BRUSH: \(BitchBoyHardwareColor.formattedLabel(for: engine.customBrushVelocity))")
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .foregroundColor(ledColor(engine.customBrushVelocity))
                }

                HStack(alignment: .top, spacing: 6) {
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

                    // Mini 3x3 Keypad
                    VStack(spacing: 2) {
                        Text("3x3")
                            .font(.system(size: 6, weight: .bold, design: .monospaced))
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
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)

                let swatches: [(String, UInt8)] = [
                    ("OFF", 0), ("WHT", 3), ("TRQ", 33), ("BLU", 41),
                    ("ORG", 61), ("PRP", 67), ("RED", 72), ("YLW", 74),
                    ("CYN", 78), ("BRN", 83), ("GRN", 87), ("PNK", 95), ("AMB", 96)
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
                                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
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
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .foregroundColor(engine.currentTheme.headerText)
                    Spacer()
                    Button("+ ADD") { engine.addCustomFXFrame() }
                        .buttonStyle(.plain).font(.system(size: 6.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2).background(engine.currentTheme.accentPrimary.opacity(0.25)).foregroundColor(engine.currentTheme.accentPrimary).clipShape(RoundedRectangle(cornerRadius: 3))
                    Button("📋 DUP") { engine.duplicateCustomFXFrame() }
                        .buttonStyle(.plain).font(.system(size: 6.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Color.white.opacity(0.12)).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 3))
                    Button("🗑️ DEL") { engine.deleteCustomFXFrame() }
                        .buttonStyle(.plain).font(.system(size: 6.5, weight: .bold, design: .monospaced))
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
                                    .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
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
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
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
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Slider(value: $engine.editingCustomFX.fps, in: 1...24, step: 1) { _ in
                        if engine.isPlayingCustomFX {
                            engine.playCustomEffect(engine.editingCustomFX)
                        }
                    }
                    .accentColor(engine.currentTheme.accentPrimary)
                }

                HStack(spacing: 4) {
                    Text("MODE:")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Spacer()
                    ForEach(CustomFXLoopMode.allCases) { lm in
                        Button(lm.rawValue) {
                            engine.editingCustomFX.loopMode = lm
                        }
                        .font(.system(size: 6.5, weight: .bold, design: .monospaced))
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
                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            TextField("Synth Show Name", text: $engine.editingCustomFX.name)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .textFieldStyle(.plain)
                .padding(5)
                .background(Color.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 4) {
                Text("WAVEFORM FORMULA:")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.7))
                Picker("", selection: $engine.editingCustomFX.waveShape) {
                    ForEach(CustomWaveShape.allCases) { ws in
                        Text(ws.rawValue).tag(ws)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))

                Text("VECTOR DIRECTION:")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.7))
                Picker("", selection: $engine.editingCustomFX.waveDirection) {
                    ForEach(CustomWaveDirection.allCases) { wd in
                        Text(wd.rawValue).tag(wd)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))

                HStack {
                    Text("DENSITY:")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Slider(value: $engine.editingCustomFX.waveFrequency, in: 0.3...3.0, step: 0.1)
                        .accentColor(engine.currentTheme.accentPrimary)
                    Text(String(format: "%.1fx", engine.editingCustomFX.waveFrequency))
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                }

                HStack {
                    Text("SPEED FPS:")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Slider(value: $engine.editingCustomFX.fps, in: 2...25, step: 1)
                        .accentColor(engine.currentTheme.accentPrimary)
                    Text("\(Int(engine.editingCustomFX.fps))")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                }

                HStack {
                    Text("MIN COLOR: \(BitchBoyHardwareColor.formattedLabel(for: engine.editingCustomFX.minVelocity))")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
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
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
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
                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
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
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
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
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
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
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(engine.currentTheme.accentPrimary)
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .buttonStyle(.plain)

                Button("⚡ TEST CONNECT FX") {
                    engine.triggerBitchBoyConnectedNotificationFX(isManualTest: true)
                }
                .font(.system(size: 6.5, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color(red: 0.96, green: 0.76, blue: 0.18).opacity(0.25))
                .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.25))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .buttonStyle(.plain)

                Spacer()

                Button("⤓ EXPORT") { engine.exportCustomFXToClipboard() }
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 4)
                    .background(Color.white.opacity(0.1)).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 4)).buttonStyle(.plain)

                Button("⤒ IMPORT") { engine.importCustomFXFromClipboard() }
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 4)
                    .background(Color.white.opacity(0.1)).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 4)).buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(engine.customEffects) { fx in
                        let isRunning = engine.isPlayingCustomFX && engine.activeCustomFXName == fx.name
                        let isConnectFX = engine.connectEffectEnabled && engine.connectCustomFXName == fx.name
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(fx.name)
                                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    if isConnectFX {
                                        Text("ON-CONNECT")
                                            .font(.system(size: 5.5, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color(red: 0.96, green: 0.76, blue: 0.18))
                                            .foregroundColor(.black)
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(fx.isProcedural ? "WAVE SYNTH // \(fx.waveShape.rawValue)" : "\(fx.frames.count) FRAMES // \(Int(fx.fps)) FPS // \(fx.loopMode.rawValue)")
                                    .font(.system(size: 6.5, design: .monospaced))
                                    .foregroundColor(Color(white: 0.6))
                            }
                            Spacer()
                            Button(action: {
                                engine.setAsOnConnectFX(fx)
                            }) {
                                Image(systemName: isConnectFX ? "bolt.circle.fill" : "bolt.fill")
                                    .font(.system(size: 8))
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
                            .font(.system(size: 7, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(isRunning ? Color.red : engine.currentTheme.accentPrimary)
                            .foregroundColor(isRunning ? .white : .black)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .buttonStyle(.plain)

                            Button("✏️") {
                                engine.selectCustomFXForEditing(fx)
                            }
                            .font(.system(size: 7, design: .monospaced))
                            .padding(4)
                            .background(Color.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .buttonStyle(.plain)

                            Button("🗑️") {
                                engine.deleteSavedCustomFX(fx)
                            }
                            .font(.system(size: 7, design: .monospaced))
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
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(isEnabled ? activeColor : Color(white: 0.5))
                            .shadow(color: isEnabled ? activeColor.opacity(0.85) : .clear, radius: 4)

                        Text("REACTIVE FX")
                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
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
                        engine.activeReactivePulses.removeAll()
                        engine.restorePresetLEDs()
                    }
                    SoundEffect.knobTick.play(with: engine.soundPack)
                }) {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(isEnabled ? Color.green : Color(white: 0.4))
                            .frame(width: 5, height: 5)
                        Text(isEnabled ? "FX ACTIVE" : "FX OFF")
                            .font(.system(size: 7.2 * scale, weight: .heavy, design: .monospaced))
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
                        .font(.system(size: 6.5 * scale, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    Slider(value: $engine.reactiveFXSpeed, in: 0.4...3.0, step: 0.1)
                        .frame(width: 50 * scale)
                        .accentColor(activeColor)
                    Text(String(format: "%.1fx", engine.reactiveFXSpeed))
                        .font(.system(size: 7 * scale, weight: .heavy, design: .monospaced))
                        .foregroundColor(activeColor)
                }
            }

            ScrollView([.vertical], showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    // 6 Interactive Mechanical Keyboard FX Mode Pads (2x3 Grid - doubles in size when expanded!)
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
                                        .font(.system(size: 8.5 * scale, weight: .heavy, design: .monospaced))
                                        .foregroundColor(isSel ? .black : .white)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: isExp ? 74 : 36)
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
                                        .font(.system(size: 7.5 * scale))
                                    Text("PRISM RAINBOW")
                                        .font(.system(size: 7 * scale, weight: .heavy, design: .monospaced))
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
                                Text(BitchBoyHardwareColor.formattedLabel(for: engine.reactiveFXColorVelocity))
                                    .font(.system(size: 7 * scale, weight: .bold, design: .monospaced))
                                    .foregroundColor(ledColor(engine.reactiveFXColorVelocity))
                            } else {
                                Text("MULTI-COLOR")
                                    .font(.system(size: 7 * scale, weight: .bold, design: .monospaced))
                                    .foregroundColor(engine.currentTheme.accentPrimary)
                            }
                        }

                        // 12 Color Swatches
                        HStack(spacing: 4 * scale) {
                            let colorSwatches: [UInt8] = [72, 61, 96, 74, 87, 33, 78, 41, 67, 95, 83, 3]
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
                                    .font(.system(size: 8 * scale))
                                Text("TEST RIPPLE PULSE")
                                    .font(.system(size: 7 * scale, weight: .heavy, design: .monospaced))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5 * scale)
                            .background(activeColor.opacity(0.24))
                            .foregroundColor(activeColor)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(activeColor.opacity(0.55), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        Text(engine.activeReactivePulses.isEmpty ? "PRESS ANY KEY" : "⚡ \(engine.activeReactivePulses.count) WAVES")
                            .font(.system(size: 6.5 * scale, weight: .heavy, design: .monospaced))
                            .foregroundColor(engine.activeReactivePulses.isEmpty ? Color(white: 0.55) : Color.yellow)
                            .padding(.horizontal, 6 * scale)
                            .padding(.vertical, 5 * scale)
                            .background(Color.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                .font(.system(size: 9.5 * scale, weight: .heavy, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5 * scale)
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
                    .font(.system(size: 9 * scale))
                Text(label)
                    .font(.system(size: 8.5 * scale, weight: .heavy, design: .monospaced))
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
                    .font(.system(size: 8.5 * scale, weight: .heavy, design: .monospaced))
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
                .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
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
            HStack {
                Text("1. TOP-LEFT 8X4 KEY GRID (32 KEYS)")
                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)
                Spacer()
                Text("CLICK KEY OR PRESS BITCHBOY")
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.15, green: 0.85, blue: 0.95))
            }
            .frame(width: 410)

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
                                    let isShift = NSEvent.modifierFlags.contains(.shift)
                                    engine.handleKeyPressWithModifiers(index: idx, isShiftDown: isShift)
                                }
                            )
                            .equatable()
                        }
                    }
                }
            }
            .padding(6)
            .background(Color(red: 0.08, green: 0.04, blue: 0.04).opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(engine.currentTheme.sectionOutline.opacity(0.85), lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .frame(width: 410)
    }

    // ------------------------------------------------------------------------
    // SECTION 2: MIDDLE 1X8 KEY STRIP (8 KEYS)
    // ------------------------------------------------------------------------
    private var section2KeyStrip1x8: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("2. MIDDLE 1X8 KEY STRIP (8 KEYS)")
                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)
                Spacer()
                Text("ICON SHOWS MAPPED ACTION")
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.35))
            }
            .frame(width: 410)

            HStack(spacing: 4) {
                ForEach(32..<40, id: \.self) { idx in
                    HardwareKeyCap(
                        item: engine.controls[idx],
                        isSelected: engine.selectedIndices.contains(idx) || engine.selectedIndex == idx,
                        color: ledColor(engine.controls[idx].currentLED),
                        sectionBorder: engine.currentTheme.sectionOutline,
                        onTap: {
                            let isShift = NSEvent.modifierFlags.contains(.shift)
                            engine.handleKeyPressWithModifiers(index: idx, isShiftDown: isShift)
                        }
                    )
                    .equatable()
                }
            }
            .padding(6)
            .background(Color(red: 0.08, green: 0.04, blue: 0.04).opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(engine.currentTheme.sectionOutline.opacity(0.85), lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .frame(width: 410)
    }

    // ------------------------------------------------------------------------
    // SECTION 4: BOTTOM-LEFT 8 VERTICAL FADERS (CC 0–7)
    // ------------------------------------------------------------------------
    private var section4VerticalFaders: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("4. BOTTOM-LEFT 8 VERTICAL FADERS (CC 0–7)")
                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)
                Spacer()
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
                        Text(engine.vuMeterLEDsEnabled ? "VU METER LEDS: ON" : "VU METER LEDS: OFF")
                    }
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.5))
                    .foregroundColor(engine.vuMeterLEDsEnabled ? Color(red: 0.22, green: 0.96, blue: 0.76) : Color(white: 0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(red: 0.22, green: 0.96, blue: 0.76).opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .frame(width: 410)

            HStack(spacing: 4) {
                ForEach(49..<57, id: \.self) { idx in
                    HardwareVerticalFader(
                        item: engine.controls[idx],
                        isSelected: engine.selectedIndex == idx,
                        onSelect: { engine.selectedIndex = idx },
                        onValueChange: { val in engine.setControlLiveValue(index: idx, value: val) }
                    )
                    .equatable()
                }
            }
            .padding(6)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .frame(width: 410)
    }

    // ------------------------------------------------------------------------
    // SECTION 5: 4 HORIZONTAL FADERS (CC 8-11)
    // ------------------------------------------------------------------------
    private var section5HorizontalFaders: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("5. 4 HORIZONTAL FADERS (CC 8–11)")
                .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

            VStack(spacing: 3) {
                ForEach(57..<61, id: \.self) { idx in
                    HardwareHorizontalFader(
                        item: engine.controls[idx],
                        isSelected: engine.selectedIndex == idx,
                        onSelect: { engine.selectedIndex = idx },
                        onValueChange: { val in engine.setControlLiveValue(index: idx, value: val) }
                    )
                    .equatable()
                }
            }
            .padding(6)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // ------------------------------------------------------------------------
    // SECTION 6: 2X4 ROTARY KNOBS (CC 20–27)
    // ------------------------------------------------------------------------
    private var section6RotaryKnobs: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("6. 2X4 KNOBS (CC 20–27)")
                .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

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
                        }
                    }
                }
            }
            .padding(6)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // ------------------------------------------------------------------------
    // CENTER INSPECTOR HUD
    // ------------------------------------------------------------------------
    private var centerInspectorHUD: some View {
        ZStack {
            // Inspector Bezel with screws
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.05, green: 0.10, blue: 0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            LinearGradient(
                                colors: [Color(white: 0.95), Color(white: 0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                )

            // 4 corner screws
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
            .padding(4)

            // Inspector Content
            VStack(alignment: .leading, spacing: 6) {
                // Header badge
                HStack {
                    Text("\(selectedControl.label) // N\(selectedControl.number)")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(engine.currentTheme.accentPrimary)
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Spacer()

                    // Multi-select indicator badge
                    if engine.selectedIndices.count > 1 {
                        Text("\(engine.selectedIndices.count) SELECTED")
                            .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.cyan)
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                    }

                    // Key color swatch preview & formatted label
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(ledColor(selectedControl.currentLED))
                            .frame(width: 14, height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.4), lineWidth: 1))
                        Text(BitchBoyHardwareColor.formattedLabel(for: selectedControl.currentLED))
                            .font(.system(size: 7, weight: .heavy, design: .monospaced))
                            .foregroundColor(ledColor(selectedControl.currentLED))
                    }
                }

                // Custom Name Editor
                HStack(spacing: 4) {
                    Text("NAME:")
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.6))
                    TextField("Custom Name", text: $engine.controls[engine.selectedIndex].customName)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                // Subtitle
                Text(selectedControl.zone)
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundColor(engine.currentTheme.headerText)

                // Feedback Mode Row
                HStack {
                    Text("Mode: \(selectedControl.feedbackMode.rawValue) // \(selectedControl.actionType.rawValue)")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.35))
                    Spacer()
                }

                if selectedControl.hasLED {
                    // Sub-Tab Switcher: LED Colors vs MIDI -> QWERTY Keyboard
                    HStack(spacing: 3) {
                        Button(action: {
                            inspectorTab = 0
                            SoundEffect.knobTick.play(with: engine.soundPack)
                        }) {
                            Text("💡 LED COLORS")
                                .font(.system(size: 7.2, weight: .heavy, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2.5)
                                .background(inspectorTab == 0 ? engine.currentTheme.accentPrimary : Color.white.opacity(0.08))
                                .foregroundColor(inspectorTab == 0 ? .black : Color(white: 0.75))
                                .clipShape(RoundedRectangle(cornerRadius: 3.5))
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            inspectorTab = 1
                            SoundEffect.knobTick.play(with: engine.soundPack)
                        }) {
                            HStack(spacing: 2) {
                                Text("⌨️ QWERTY KEY")
                                if selectedControl.actionType == .qwerty {
                                    Circle().fill(Color(red: 0.98, green: 0.78, blue: 0.25)).frame(width: 4, height: 4)
                                }
                            }
                            .font(.system(size: 7.2, weight: .heavy, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2.5)
                            .background(inspectorTab == 1 ? Color(red: 0.98, green: 0.78, blue: 0.25) : Color.white.opacity(0.08))
                            .foregroundColor(inspectorTab == 1 ? .black : Color(white: 0.75))
                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                        }
                        .buttonStyle(.plain)
                    }

                    if inspectorTab == 0 {
                        // TAB 1: LED VELOCITIES & PALETTE
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(engine.selectedIndices.count > 1 ? "IDLE LED (BATCH):" : "IDLE LED:")
                                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(white: 0.7))
                                Spacer()
                                Circle()
                                    .fill(ledColor(engine.controls[engine.selectedIndex].idleVelocity))
                                    .frame(width: 7, height: 7)
                                Text(BitchBoyHardwareColor.formattedLabel(for: engine.controls[engine.selectedIndex].idleVelocity))
                                    .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
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
                            .accentColor(Color(red: 0.85, green: 0.35, blue: 0.30))
                        }

                        // Pressed Velocity Slider
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(engine.selectedIndices.count > 1 ? "PRESSED LED (BATCH):" : "PRESSED LED:")
                                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(white: 0.7))
                                Spacer()
                                Circle()
                                    .fill(ledColor(engine.controls[engine.selectedIndex].activeVelocity))
                                    .frame(width: 7, height: 7)
                                Text(BitchBoyHardwareColor.formattedLabel(for: engine.controls[engine.selectedIndex].activeVelocity))
                                    .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
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
                            .accentColor(Color(red: 0.85, green: 0.35, blue: 0.30))
                        }

                        // 13 Hardware Colors
                        VStack(alignment: .leading, spacing: 2) {
                            Text("QUICK COLOR PALETTE:")
                                .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(white: 0.55))
                            HStack(spacing: 3) {
                                let quickColors: [UInt8] = [0, 3, 33, 41, 61, 67, 72, 74, 78, 83, 87, 95, 96]
                                ForEach(quickColors, id: \.self) { vel in
                                    Circle()
                                        .fill(ledColor(vel))
                                        .frame(width: 12, height: 12)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white, lineWidth: engine.controls[engine.selectedIndex].activeVelocity == vel ? 1.5 : 0)
                                        )
                                        .shadow(color: engine.controls[engine.selectedIndex].activeVelocity == vel ? ledColor(vel) : .clear, radius: 2)
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
                        .padding(.top, 1)

                        // Large Fill Buttons
                        HStack(spacing: 4) {
                            Button("FILL 8x4") { engine.setZoneLEDs(range: 0..<32, velocity: selectedControl.idleVelocity) }
                            Button("FILL 1x8") { engine.setZoneLEDs(range: 32..<40, velocity: selectedControl.idleVelocity) }
                            Button("FILL 3x3") { engine.setZoneLEDs(range: 40..<49, velocity: selectedControl.idleVelocity) }
                            Button("ALL 49") { engine.setZoneLEDs(range: 0..<49, velocity: selectedControl.idleVelocity) }
                        }
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .buttonStyle(.plain)
                        .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.35))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    } else {
                        // TAB 2: MIDI -> QWERTY KEYBOARD MAPPING
                        VStack(alignment: .leading, spacing: 4) {
                            // Mode Toggle: MIDI Only vs QWERTY Active
                            HStack {
                                Text("KEY MODE:")
                                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(white: 0.6))

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
                                    HStack(spacing: 3) {
                                        Circle()
                                            .fill(engine.controls[engine.selectedIndex].actionType == .qwerty ? Color(red: 0.98, green: 0.78, blue: 0.25) : Color(white: 0.4))
                                            .frame(width: 5, height: 5)
                                        Text(engine.controls[engine.selectedIndex].actionType == .qwerty ? "QWERTY ACTIVE" : "MIDI PASS-THRU")
                                            .font(.system(size: 7.2, weight: .heavy, design: .monospaced))
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2.5)
                                    .background(engine.controls[engine.selectedIndex].actionType == .qwerty ? Color(red: 0.98, green: 0.78, blue: 0.25).opacity(0.2) : Color.white.opacity(0.08))
                                    .foregroundColor(engine.controls[engine.selectedIndex].actionType == .qwerty ? Color(red: 0.98, green: 0.78, blue: 0.25) : Color(white: 0.6))
                                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
                                }
                                .buttonStyle(.plain)
                            }

                            if engine.controls[engine.selectedIndex].actionType == .qwerty {
                                let curStep = engine.controls[engine.selectedIndex].qwertySteps.first ?? QwertyStep(key: "space")
                                let curKey = curStep.key

                                // Key Picker & Live Test
                                HStack(spacing: 4) {
                                    Text("KEY:")
                                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                        .foregroundColor(Color(white: 0.6))

                                    // Quick Pick Menu
                                    Menu {
                                        Section("COMMON KEYS") {
                                            ForEach(["space", "return", "escape", "tab", "delete", "up", "down", "left", "right"], id: \.self) { k in
                                                Button(k.uppercased()) {
                                                    setQwertyKeyForSelection(k)
                                                }
                                            }
                                        }
                                        Section("FUNCTION KEYS") {
                                            ForEach(["f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"], id: \.self) { k in
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
                                        HStack(spacing: 2) {
                                            Text(curKey.uppercased())
                                                .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                                                .foregroundColor(Color(red: 0.98, green: 0.78, blue: 0.25))
                                            Image(systemName: "chevron.up.chevron.down")
                                                .font(.system(size: 5.5))
                                                .foregroundColor(Color(white: 0.6))
                                        }
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2.5)
                                        .background(Color.black.opacity(0.6))
                                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
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
                                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                    .textFieldStyle(.plain)
                                    .frame(width: 44)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.black.opacity(0.6))
                                    .clipShape(RoundedRectangle(cornerRadius: 3.5))

                                    Spacer()

                                    // Direct sub-millisecond CGEvent Test Button
                                    Button(action: {
                                        if let step = engine.controls[engine.selectedIndex].qwertySteps.first {
                                            engine.triggerSingleQwerty(key: step.key, cmd: step.cmd, shift: step.shift, alt: step.alt, ctrl: step.ctrl)
                                        }
                                    }) {
                                        HStack(spacing: 2) {
                                            Image(systemName: "play.fill")
                                                .font(.system(size: 6))
                                            Text("TEST")
                                                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                                        }
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2.5)
                                        .background(Color.green.opacity(0.2))
                                        .foregroundColor(.green)
                                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                                    }
                                    .buttonStyle(.plain)
                                }

                                // Modifiers Row
                                HStack(spacing: 3) {
                                    Text("MODS:")
                                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                                        .foregroundColor(Color(white: 0.6))
                                    Button(action: { toggleQwertyModifierForSelection { $0.cmd.toggle() } }) {
                                        Text("⌘ CMD")
                                            .font(.system(size: 6.8, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(curStep.cmd ? Color(red: 0.98, green: 0.78, blue: 0.25) : Color.white.opacity(0.08))
                                            .foregroundColor(curStep.cmd ? .black : Color(white: 0.75))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: { toggleQwertyModifierForSelection { $0.shift.toggle() } }) {
                                        Text("⇧ SHIFT")
                                            .font(.system(size: 6.8, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(curStep.shift ? Color(red: 0.98, green: 0.78, blue: 0.25) : Color.white.opacity(0.08))
                                            .foregroundColor(curStep.shift ? .black : Color(white: 0.75))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: { toggleQwertyModifierForSelection { $0.alt.toggle() } }) {
                                        Text("⌥ OPT")
                                            .font(.system(size: 6.8, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(curStep.alt ? Color(red: 0.98, green: 0.78, blue: 0.25) : Color.white.opacity(0.08))
                                            .foregroundColor(curStep.alt ? .black : Color(white: 0.75))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                    .buttonStyle(.plain)

                                    Button(action: { toggleQwertyModifierForSelection { $0.ctrl.toggle() } }) {
                                        Text("⌃ CTRL")
                                            .font(.system(size: 6.8, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(curStep.ctrl ? Color(red: 0.98, green: 0.78, blue: 0.25) : Color.white.opacity(0.08))
                                            .foregroundColor(curStep.ctrl ? .black : Color(white: 0.75))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                    .buttonStyle(.plain)
                                }

                                // Quick Shortcut Templates Row
                                HStack(spacing: 3) {
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
                                .font(.system(size: 6.5, weight: .heavy, design: .monospaced))
                                .buttonStyle(.plain)
                                .foregroundColor(Color(red: 0.98, green: 0.78, blue: 0.25))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: 3.5))
                            } else {
                                Text("Key acts as standard physical MIDI Note On / Off message.")
                                    .font(.system(size: 7.2, weight: .medium, design: .monospaced))
                                    .foregroundColor(Color(white: 0.6))
                                    .padding(.vertical, 6)
                            }
                        }
                        .padding(5)
                        .background(Color.white.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                } else {                    Text("ANALOG CC VALUE: \(selectedControl.liveValue)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.96, green: 0.78, blue: 0.35))
                        .padding(.vertical, 10)
                }

                Spacer(minLength: 0)

                // RX Stream Telemetry
                HStack {
                    Text("RX STREAM:")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.72))
                    Spacer()
                    Text(engine.lastStreamMessage)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                }
            }
            .padding(10)
        }
    }

    // ------------------------------------------------------------------------
    // SECTION 3: 3X3 KEYPAD & OFFICIAL MASCOT (9 KEYS)
    // ------------------------------------------------------------------------
    private var section3KeypadAndMascot: some View {
        VStack(spacing: 5) {
            // Interactive Official Mascot (bitchboy.png) with Speech Bubble
            ZStack(alignment: .top) {
                // Speech Bubble
                if engine.mascotSpeechVisible {
                    Text(engine.mascotSpeech)
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.85))
                        .foregroundColor(engine.currentTheme.accentPrimary)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(engine.currentTheme.accentPrimary, lineWidth: 1))
                        .offset(y: -18)
                        .transition(.scale.combined(with: .opacity))
                }

                BitchBoyOfficialMascotView(auraColor: engine.currentTheme.accentPrimary) {
                    engine.triggerMascotTap()
                }
                .scaleEffect(engine.mascotScale)
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: engine.mascotScale)
            }
            .padding(.top, 12)

            Text("3. 3X3 KEYPAD (9 KEYS)")
                .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                .foregroundColor(engine.currentTheme.headerText)

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
                                    let isShift = NSEvent.modifierFlags.contains(.shift)
                                    engine.handleKeyPressWithModifiers(index: idx, isShiftDown: isShift)
                                }
                            )
                            .equatable()
                        }
                    }
                }
            }
            .padding(6)
            .background(Color(red: 0.08, green: 0.04, blue: 0.04).opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(engine.currentTheme.sectionOutline.opacity(0.85), lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Footer branding
            VStack(spacing: 1) {
                Text("CE 🗑")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Color(white: 0.5))
                Text("BitchBoy")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                Text("BLOCK SYSTEM HARDWARE")
                    .font(.system(size: 6, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
            }
        }
    }
}

// ============================================================================
// 5. APP ENTRYPOINT & MENUBAR COMPANION
// ============================================================================

@main
struct BitchBoyNativeApp: App {
    @StateObject private var engine = BitchBoyEngine()

    var body: some Scene {
        WindowGroup("BitchManager") {
            ContentView(engine: engine)
                .frame(minWidth: 1538 * 0.25, minHeight: 760 * 0.15)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About BitchManager...") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
                Button("Check for Updates on GitHub...") {
                    engine.checkForUpdates(showModalIfCurrent: true)
                }
                Divider()
            }
            CommandMenu("UI Zoom & Window") {
                Button(engine.isWindowAlwaysOnTop ? "✓ Keep Window Always On Top" : "Keep Window Always On Top") {
                    engine.toggleWindowAlwaysOnTop()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

                Divider()

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
            Button(engine.isWindowAlwaysOnTop ? "📌 Unpin Always On Top" : "📌 Pin Window Always On Top") {
                engine.toggleWindowAlwaysOnTop()
            }
            Button("✨ Trigger Rainbow Refresh") { engine.runRainbowWaveRefresh() }
            Button("🚨 Panic Blackout") { engine.blackoutPanic() }
            Divider()
            ForEach(0..<4, id: \.self) { idx in
                Button("Load \(engine.slots[idx].name)") { engine.selectSlot(idx) }
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

