import AppKit
import InputMethodKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let connection = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String ?? "HaiwangInputConnection"
let server = IMKServer(name: connection, bundleIdentifier: Bundle.main.bundleIdentifier!)
application.run()
