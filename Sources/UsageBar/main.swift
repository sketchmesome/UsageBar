import AppKit

// Headless one-shot mode: refresh every source, dump rows, exit. No UI, no
// status item. Normal launch below is untouched.
if CommandLine.arguments.contains("--dump") {
    DumpMode.run()
}
if CommandLine.arguments.contains("--test-alert") {
    UsageAlerts.sendTest { error in print(error.map { "test alert failed: \($0)" } ?? "test alert posted") }
    Thread.sleep(forTimeInterval: 3)
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = nil
app.setActivationPolicy(.accessory)
controller.start()
app.run()
