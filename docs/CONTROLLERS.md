# Controllers

Full design: section 8 of [PLAN.md](PLAN.md). Summary:

* **Supported:** Xbox One S/X, Series X|S, Elite Series 2, Adaptive Controller; DualShock 4 (v1/v2); DualSense; DualSense Edge. Bluetooth and USB.
* **Main path:** Apple's GameController framework (input, rumble, Xbox trigger rumble, DualSense adaptive triggers, lightbar, motion, touchpad, battery).
* **Opt-in extras** ("Advanced controller features", off by default): raw HID for DualSense Edge paddles/Fn, the mute button and LED, player-LED patterns, raw touchpad data, device identity.
* **Known macOS limits:** wired-USB Xbox pads have no rumble and no Share button through Apple's API (use Bluetooth); DualSense HD haptics, speaker and mic work over USB only; the Xbox Wireless Adapter dongle is unsupported.
* **Find out what your pads expose:** `swift run controller-dump` on a Mac with the pads connected.

## Code map
* `Sources/ControllerModel` (pure Swift, tested on Linux): types, input pipeline, mailboxes, Sony report CRC, input traces.
* `Sources/ControllerKit` (macOS): controller discovery and classification, the dump tool.
