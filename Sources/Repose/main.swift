import AppKit

// Menu bar only: no Dock icon, no main window. The Info.plist in the app bundle
// also sets LSUIElement, but setting the policy here covers running the bare
// executable from `swift run` or Xcode as well.
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
