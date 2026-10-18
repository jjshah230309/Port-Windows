import ControllerKit
import Foundation

// Give GameController a moment to report already-connected pads before reading them.
RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
print(ControllerDump.text(), terminator: "")
