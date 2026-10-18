import Foundation
import GameController

/// Plain-text dump of every connected controller: which elements, haptic localities and motion flags it exposes.
/// Run `swift run controller-dump` with pads connected; the output becomes the hardware fixtures CI tests against.
public enum ControllerDump {
    public static func text() -> String {
        let controllers = GCController.controllers()
        if controllers.isEmpty { return "No game controllers connected.\n" }
        var out = ""
        for (i, c) in controllers.enumerated() {
            out += "Controller \(i): \(c.vendorName ?? "?")\n"
            out += "  productCategory: \(c.productCategory)\n"
            out += "  attached: \(c.isAttachedToDevice)\n"
            out += "  profile class: \(type(of: c.extendedGamepad as Any))\n"
            let profile = c.physicalInputProfile
            out += "  buttons: \(profile.buttons.keys.sorted().joined(separator: ", "))\n"
            out += "  axes: \(profile.axes.keys.sorted().joined(separator: ", "))\n"
            out += "  dpads: \(profile.dpads.keys.sorted().joined(separator: ", "))\n"
            if let h = c.haptics {
                out += "  haptic localities: \(h.supportedLocalities.map { $0.rawValue }.sorted().joined(separator: ", "))\n"
            } else {
                out += "  haptics: none\n"
            }
            if let m = c.motion {
                out += "  motion: gravity+userAccel=\(m.hasGravityAndUserAcceleration) "
                out += "attitude+rotation=\(m.hasAttitudeAndRotationRate) manualActivation=\(m.sensorsRequireManualActivation)\n"
            } else {
                out += "  motion: none\n"
            }
            out += "  light: \(c.light != nil)  battery: \(c.battery.map { String($0.batteryLevel) } ?? "none")\n"
        }
        return out
    }
}
