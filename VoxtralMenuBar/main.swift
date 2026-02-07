import Cocoa

private func setUpMainMenu() {
    let mainMenu = NSMenu()

    // App menu (only used to provide standard key equivalents like Quit).
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenuItem.submenu = appMenu
    appMenu.addItem(withTitle: "Quit Voxtral", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    // Edit menu to enable standard clipboard shortcuts (Cmd+C/V/X/A) in text fields.
    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Edit")
    editMenuItem.submenu = editMenu

    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    NSApp.mainMenu = mainMenu
}

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
setUpMainMenu()

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
