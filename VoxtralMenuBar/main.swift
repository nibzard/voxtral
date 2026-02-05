import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)

// Set up signal handlers for safe shutdown
signal(SIGTERM) { _ in
    AppLogger.shared.logApplicationTerminate()
    BackendServiceManager.shared.stop()
    NSApp.terminate(nil)
}

signal(SIGINT) { _ in
    AppLogger.shared.logApplicationTerminate()
    BackendServiceManager.shared.stop()
    NSApp.terminate(nil)
}

app.run()
