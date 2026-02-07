import Cocoa
import SwiftUI

final class PreferencesWindowController: NSWindowController {
    init(viewModel: MenuBarViewModel) {
        let window = NSWindow(contentViewController: nil)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        window.setContentSize(NSSize(width: 520, height: 460))
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
