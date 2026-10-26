<p align="center">
  <img src="assets/header.png" alt="BitchManager" width="100%" style="border-radius: 10px;" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014.0+-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Platform" />
  <img src="https://img.shields.io/badge/Release-v2.0.0-00E5FF?style=for-the-badge&logo=github&logoColor=black" alt="Release" />
  <img src="https://img.shields.io/badge/Swift-5.9%20%2F%20SwiftUI-FA7343?style=for-the-badge&logo=swift&logoColor=white" alt="Swift" />
  <img src="https://img.shields.io/badge/Protocols-MIDI%20%E2%80%A2%20OSC-00E676?style=for-the-badge" alt="Protocols" />
</p>

<p align="center">
  <strong>BitchManager</strong> is the official high-performance macOS companion, lighting engine, and MIDI/OSC command station for the <strong>BitchBoy V1</strong> 69-control hardware console.
</p>

---

## 💿 Quick Install

### 1-Click DMG Installer
1. Download **[BitchManager-Installer.dmg](BitchManager-Installer.dmg)** or grab the latest build from [GitHub Releases](https://github.com/kookly/BitchManager/releases/latest).
2. Double-click **`BitchManager-Installer.dmg`** to mount the disk image.
3. Drag **`BitchManager.app`** into your **`Applications`** folder.
4. Launch and connect your hardware!

> **Automatic GitHub Updates**: BitchManager includes an in-app updater that automatically detects new releases on this repository and updates seamlessly with 1 click.

---

## 🌟 Key Features

### 🎛️ Show Control // Full OSC Studio
- **65-Control MIDI ➔ OSC Matrix**: Independently map every single hardware key, pad, fader, and encoder to custom OSC address paths and network targets.
- **1-Click Industry Templates**: Instant auto-configuration presets for **QLab**, **Resolume Arena**, and **ETC Eos**.
- **Flexible Argument Types**: Transmit `Bang (Trigger)`, `Float (0.0 – 1.0)`, `Integer (0 – 127)`, or `String` arguments with configurable on-release reset values.
- **Manual UDP Packet Tester**: Transmit custom OSC packets directly to any target IP and port with live payload inspection.
- **Hardware Feedback**: Bidirectional LED key illumination and inbound MIDI echo monitoring.

### 🧩 Dynamic Modular Workspace
- **Drag, Drop & Dock Anywhere**: Freely arrange modules across the **Left Wing**, **Right Wing**, and **Bottom Rack**.
- **Dynamic Resizing**: Resize any module on the fly with live drag handles or cycle between presets (`COMPACT`, `STANDARD`, `TALL`, `EXPANDED`).
- **Spotlight Mode**: Click any module title bar to bring it front-and-center in an isolated spotlight overlay with background defocusing.
- **Tactile Hover Magnification**: Subtle visual feedback and hover-scaling across all interactive buttons, faders, and keys.

### ⚡ Reactive Key-Press FX Engine
- **Spatial 2D Physics Animations**: Live visual wave propagation triggered by physical BitchBoy key presses or software clicks.
- **6 FX Modes**: **Ripple Ring**, **Laser Cross**, **Supernova**, **Heat Trail**, **Meteor Drop**, and **Arc Lightning**.
- **Prism Color Dispersion**: Full rainbow spectrum dynamics, adjustable propagation speed, wave decay, and custom neon palettes.

### 💡 Chassis Lighting Studio & Sequencer
- **49-Key RGB Chassis Painter**: Set per-key RGB colors across the 8×4 Grid, 1×8 Strip, and 3×3 Keypad.
- **Multi-Frame Keyframe Sequencer**: Design custom animations, frame delays, and loop playback.
- **15+ Built-in Light Shows**: Wave Synthesizer, Plasma Flow, Matrix Rain, Audio Reactive Pulse, Neon Strobe, Breathing, and Rainbow Cycle.

### 🧠 8-Slot Memory Bank Engine
- **Instant Bank Switching**: Store full hardware setups across 8 memory slots (`SLOT A` through `SLOT H`) split into `BANK A–D` and `BANK E–H`.
- **1-Click Management**: Clone, lock, and customize slot badges and neon themes.
- **JSON Clipboard Export/Import**: Backup, share, or version-control your entire configuration as clean JSON.

### 🎚️ Virtual MIDI Patchbay & Macro Sequencer
- **Virtual MIDI Source (`BitchBoy Virtual Out`)**: Seamless driverless connectivity into Ableton Live, Logic Pro, FL Studio, Reaper, QLab, and Resolume.
- **Real-Time Telemetry & Scope**: Live incoming MIDI log, note velocity curves, and channel transpose (-24 to +24 semitones).
- **Macro Action Engine**: Fire complex QWERTY keystroke chords, text sequences, timed delays, or AppleScript automation from hardware buttons.

---

## 🎹 Hardware Control Layout (69 Controls)

| Section | Controls | Description |
| :--- | :---: | :--- |
| **Top Grid** | `32 Keys` | 8×4 Matrix of RGB/Velocity-sensitive mechanical keys |
| **Middle Strip** | `8 Keys` | 1×8 Row for hotkeys, bank triggers, and navigation |
| **Numeric Keypad** | `9 Keys` | 3×3 Right-hand keypad for direct cue and slot access |
| **Vertical Faders** | `8 Faders` | Smooth 100mm-style continuous controllers |
| **Horizontal Crossfaders** | `4 Faders` | Left/Right transition and blend crossfaders |
| **Rotary Encoders** | `8 Knobs` | 360° continuous rotary parameter dials |

---

## 🛠️ Building from Source

```bash
# Clone the repository
git clone https://github.com/kookly/BitchManager.git
cd BitchManager

# Build Debug version
xcodebuild -scheme BB -configuration Debug build

# Build Release version
xcodebuild -scheme BB -configuration Release build
```

---

## 💬 Community & Support

Have questions, suggestions, or want to share your custom profiles?
- **Discord**: `@Kooklys`
- **GitHub Issues**: [Open an issue or feature request](https://github.com/kookly/BitchManager/issues)
