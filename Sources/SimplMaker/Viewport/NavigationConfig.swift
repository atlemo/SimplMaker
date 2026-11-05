// How the mouse, trackpad and wheel move the camera: which input does what, which way, and how fast.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if os(macOS)
import AppKit
#endif

/// What a navigation input does to the camera.
enum NavAction: String, Codable, CaseIterable, Identifiable {
    case orbit, pan, zoom
    /// Turns the picture about the line of sight, as when one turns a sheet of paper. Only a sketch's view does it.
    case roll
    case none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .orbit: return "Orbit"
        case .pan: return "Pan"
        case .zoom: return "Zoom"
        case .roll: return "Roll (sketch)"
        case .none: return "Off"
        }
    }
}

/// The modifier key held with an input. When several are held, ⇧ wins over ⌃, and ⌃ over ⌥.
enum NavModifier: String, CaseIterable, Identifiable {
    case plain, shift, control, option
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .plain: return "None"
        case .shift: return "⇧"
        case .control: return "⌃"
        case .option: return "⌥"
        }
    }

    #if os(macOS)
    init(_ flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift) { self = .shift }
        else if flags.contains(.control) { self = .control }
        else if flags.contains(.option) { self = .option }
        else { self = .plain }
    }
    #endif
}

/// What one input (a mouse button, the trackpad's scroll, the wheel) does with each modifier key.
struct NavBindings: Codable, Equatable {
    var plain: NavAction
    var shift: NavAction
    var control: NavAction
    var option: NavAction

    init(plain: NavAction, shift: NavAction? = nil, control: NavAction? = nil, option: NavAction? = nil) {
        self.plain = plain
        self.shift = shift ?? plain
        self.control = control ?? plain
        self.option = option ?? plain
    }

    subscript(modifier: NavModifier) -> NavAction {
        get {
            switch modifier {
            case .plain: return plain
            case .shift: return shift
            case .control: return control
            case .option: return option
            }
        }
        set {
            switch modifier {
            case .plain: plain = newValue
            case .shift: shift = newValue
            case .control: control = newValue
            case .option: option = newValue
            }
        }
    }
}

/// Where a movement came from; the same action feels different from each.
enum NavInput {
    /// A mouse button held down while moving.
    case drag
    /// Two fingers on the trackpad, in points.
    case trackpad
    /// A wheel with notches, in lines.
    case wheel
}

/// Presets that copy how other 3D apps navigate. They set the bindings only; the direction and speed
/// choices stay as they are, since those are personal.
enum NavigationPreset: String, CaseIterable, Identifiable {
    case simplMaker, blender, fusion, onshape, solidWorks, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .simplMaker: return "SimplMaker"
        case .blender: return "Blender"
        case .fusion: return "Fusion"
        case .onshape: return "Onshape"
        case .solidWorks: return "SolidWorks"
        case .custom: return "Custom"
        }
    }

    /// The presets one can choose; Custom is only what is shown once the bindings were edited by hand.
    static var choosable: [NavigationPreset] { allCases.filter { $0 != .custom } }
}

/// Where the pointer is in the view, so a zoom can keep the spot under it in place.
struct ZoomAnchor {
    var point: CGPoint      // points, origin top-left
    var viewSize: CGSize
}

struct NavigationConfig: Codable, Equatable {
    /// Dragging with the left button on empty space (on a face, edge or handle it selects or drags that instead).
    var left: NavBindings
    var right: NavBindings
    var middle: NavBindings
    var trackpad: NavBindings
    var wheel: NavBindings

    var invertOrbitHorizontal = false
    var invertOrbitVertical = false
    var invertPanHorizontal = false
    var invertPanVertical = false
    /// Scroll-wheel, trackpad-scroll and drag zoom.
    var invertZoom = false
    /// The trackpad's rotate gesture spins the view.
    var rotateSpins = true
    /// Multipliers on the orbit and zoom speed (1 is the original).
    var orbitSpeed = 1.0
    var zoomSpeed = 1.0

    static let speedRange = 0.25...3.0

    // MARK: presets

    /// ⌃-click is a right-click on a Mac, so a left button held with ⌃ has nothing to bind.
    /// ⌥ turns the sketch's picture on the paper.
    private static let leftDrag = NavBindings(plain: .orbit, control: NavAction.none, option: .roll)

    /// What SimplMaker has always done. `trackpadOrbits` and `invertZoom` carry over the two choices
    /// the Settings had before the bindings could be edited.
    static func simplMaker(trackpadOrbits: Bool = false, invertZoom: Bool = false) -> NavigationConfig {
        var config = NavigationConfig(
            left: leftDrag,
            right: NavBindings(plain: .pan),
            middle: NavBindings(plain: .pan),
            trackpad: trackpadOrbits ? NavBindings(plain: .orbit, shift: .pan, control: .zoom, option: .orbit)
                                     : NavBindings(plain: .pan, shift: .orbit, control: .zoom, option: .pan),
            wheel: NavBindings(plain: .zoom))
        config.invertZoom = invertZoom
        return config
    }

    /// The bindings of a preset, with the default direction and speed.
    static func preset(_ preset: NavigationPreset) -> NavigationConfig {
        var config = simplMaker()
        switch preset {
        case .simplMaker, .custom:
            break
        case .blender:
            // Middle button orbits, ⇧ pans, ⌃ zooms; two fingers orbit, ⇧ pans, ⌃ zooms.
            config.middle = NavBindings(plain: .orbit, shift: .pan, control: .zoom)
            config.trackpad = NavBindings(plain: .orbit, shift: .pan, control: .zoom)
            config.wheel = NavBindings(plain: .zoom, shift: .pan, control: .zoom)
        case .fusion:
            // Middle button pans, ⇧ + middle orbits.
            config.middle = NavBindings(plain: .pan, shift: .orbit)
        case .onshape:
            // Right button orbits, middle button pans.
            config.right = NavBindings(plain: .orbit)
            config.middle = NavBindings(plain: .pan)
        case .solidWorks:
            // Middle button orbits, ⌃ pans, ⇧ zooms.
            config.middle = NavBindings(plain: .orbit, shift: .zoom, control: .pan)
        }
        return config
    }

    /// The preset whose bindings these are, or Custom.
    var matchingPreset: NavigationPreset {
        NavigationPreset.choosable.first { Self.preset($0).hasSameBindings(as: self) } ?? .custom
    }

    private func hasSameBindings(as other: NavigationConfig) -> Bool {
        left == other.left && right == other.right && middle == other.middle
            && trackpad == other.trackpad && wheel == other.wheel
    }

    /// Takes the bindings of `preset` and leaves the direction and speed alone.
    mutating func apply(_ preset: NavigationPreset) {
        guard preset != .custom else { return }
        let bindings = Self.preset(preset)
        left = bindings.left; right = bindings.right; middle = bindings.middle
        trackpad = bindings.trackpad; wheel = bindings.wheel
    }

    // MARK: moving the camera

    /// Moves the camera. `dx` is to the right and `dy` downward, in points on screen (for a wheel, in lines):
    /// how far the fingers or the pointer moved.
    /// A zoom by scroll or wheel keeps the spot under `cursor` (view coordinates) where it is, when one is given.
    func navigate(_ camera: inout Camera, _ action: NavAction, input: NavInput, dx: Float, dy: Float, viewHeight: Float,
                  cursor: ZoomAnchor? = nil) {
        // A notch of the wheel is a lot less than a point on the trackpad.
        let scale: Float = input == .wheel ? 10 : 1
        let dx = dx * scale, dy = dy * scale
        switch action {
        case .none:
            break
        case .orbit:
            // Scrolling turns the view the opposite way to dragging.
            let sign: Float = input == .drag ? 1 : -1
            let speed = Float(orbitSpeed)
            camera.orbit(dx: dx * sign * (invertOrbitHorizontal ? -1 : 1) * speed,
                         dy: -dy * sign * (invertOrbitVertical ? -1 : 1) * speed)
        case .pan:
            camera.pan(dx: dx * (invertPanHorizontal ? -1 : 1), dy: dy * (invertPanVertical ? -1 : 1), viewHeight: viewHeight)
        case .zoom:
            // Dragging down zooms out; scrolling or wheeling down (as the fingers see it) zooms in.
            let perUnit: Float = input == .wheel ? log(1.1) / scale : 0.01
            let sign: Float = input == .drag ? 1 : -1
            let exponent = sign * dy * perUnit * Float(zoomSpeed) * (invertZoom ? -1 : 1)
            if let cursor { camera.zoom(exp(exponent), about: cursor.point, viewSize: cursor.viewSize) } else { camera.zoom(exp(exponent)) }
        case .roll:
            // A drag follows the pointer round the middle of the view (see ViewportMTKView); a scroll, which has
            // no pointer to follow, turns by how far it went sideways.
            camera.roll(by: -dx * 0.008 * Float(orbitSpeed))
        }
    }

    /// The trackpad's pinch; `magnification` is positive when the fingers spread.
    func pinch(_ camera: inout Camera, magnification: Float, cursor: ZoomAnchor? = nil) {
        guard magnification > -1 else { return }
        let base = 1 + magnification
        let factor = pow(base, -Float(zoomSpeed))
        if let cursor { camera.zoom(factor, about: cursor.point, viewSize: cursor.viewSize) } else { camera.zoom(factor) }
    }

    /// The trackpad's rotate gesture, in degrees (positive counter-clockwise). In a sketch the picture turns
    /// with the fingers; elsewhere the view spins round the vertical.
    func rotate(_ camera: inout Camera, degrees: Float, sketching: Bool = false) {
        guard rotateSpins else { return }
        if sketching {
            camera.roll(by: degrees * .pi / 180)
        } else {
            camera.orbit(dx: degrees * 4, dy: 0)
        }
    }
}
