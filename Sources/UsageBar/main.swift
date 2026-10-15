import AppKit

// Headless one-shot mode: refresh every source, dump rows, exit. No UI, no
// status item. Normal launch below is untouched.
if CommandLine.arguments.contains("--dump") {
    DumpMode.run()
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = nil
app.setActivationPolicy(.accessory)
controller.start()
app.run()
