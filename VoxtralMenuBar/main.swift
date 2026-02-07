import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)

private func setUpSignalHandler(_ signalNumber: Int32) -> DispatchSourceSignal {
    Darwin.signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        AppLogger.shared.logApplicationTerminate()
        BackendServiceManager.shared.stop()
        NSApp.terminate(nil)
    }
    source.resume()
    return source
}

let signalSources = [setUpSignalHandler(SIGTERM), setUpSignalHandler(SIGINT)]
signalSources.forEach { _ in }

app.run()
