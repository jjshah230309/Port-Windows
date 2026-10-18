import Combine
import ControllerModel
import Foundation
import GameController

public struct ConnectedController: Identifiable, Equatable {
    public let id: ObjectIdentifier
    public var name: String
    public var family: ControllerFamily
    public var capabilities: ControllerCapabilities
    public var batteryLevel: Float?

    public var summary: String {
        let caps = capabilities.names.joined(separator: ", ")
        return caps.isEmpty ? "basic gamepad" : caps
    }
}

public enum ControllerProbe {
    /// Classifies a pad from Apple's product category plus the features it actually exposes.
    public static func describe(_ controller: GCController) -> ConnectedController {
        var caps: ControllerCapabilities = []
        if let haptics = controller.haptics {
            caps.insert(.rumble)
            let localities = haptics.supportedLocalities.map { $0.rawValue }
            if localities.contains(GCHapticsLocality.leftTrigger.rawValue) { caps.insert(.triggerRumble) }
        }
        if controller.motion != nil { caps.insert(.motion) }
        if controller.light != nil { caps.insert(.lightbar) }
        if controller.battery != nil { caps.insert(.battery) }

        let gamepad = controller.extendedGamepad
        var family: ControllerFamily = .generic
        switch controller.productCategory {
        case GCProductCategoryXboxOne:
            family = .xboxOne
            if let xbox = gamepad as? GCXboxGamepad {
                if xbox.buttonShare != nil { family = .xboxSeries; caps.insert(.share) }
                if xbox.paddleButton1 != nil { family = .xboxElite2; caps.insert(.paddles) }
            }
        case GCProductCategoryDualShock4:
            family = .dualShock4
            caps.insert(.touchpad)
            caps.insert(.share)
        case GCProductCategoryDualSense:
            family = .dualSense
            caps.insert(.touchpad)
            caps.insert(.share)
            caps.insert(.adaptiveTriggers)
        default:
            break
        }
        if gamepad?.buttonHome != nil { caps.insert(.home) }

        return ConnectedController(
            id: ObjectIdentifier(controller),
            name: controller.vendorName ?? "Controller",
            family: family,
            capabilities: caps,
            batteryLevel: controller.battery?.batteryLevel)
    }
}

/// Tracks connected game controllers and publishes them to the UI.
@MainActor
public final class ControllerRegistry: ObservableObject {
    @Published public private(set) var controllers: [ConnectedController] = []
    private var observers: [NSObjectProtocol] = []

    public init() {
        refresh()
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    public func refresh() {
        controllers = GCController.controllers().map(ControllerProbe.describe)
    }
}
