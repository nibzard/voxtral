import Cocoa
import SwiftUI

final class PreferencesWindowController: NSWindowController {
    init(viewModel: MenuBarViewModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()

        super.init(window: window)

        let hostingController = NSHostingController(rootView: PreferencesView(viewModel: viewModel) { [weak window] in
            window?.close()
        })
        window.contentViewController = hostingController
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
