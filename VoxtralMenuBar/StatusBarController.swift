import Cocoa
import Combine
import SwiftUI

final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let viewModel: MenuBarViewModel
    private var preferencesWindowController: PreferencesWindowController?
    private var cancellables = Set<AnyCancellable>()

    init(backendServiceManager: BackendServiceManager = .shared, modelAssetManager: ModelAssetManager = .shared) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        viewModel = MenuBarViewModel(
            backendServiceManager: backendServiceManager,
            modelAssetManager: modelAssetManager
        )
        super.init()
        configureStatusItem()
        configurePopover()
        bindViewModel()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voxtral")
        button.action = #selector(togglePopover(_:))
        button.target = self
        updateStatusItem(for: viewModel.status)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 460)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(viewModel: viewModel, onOpenPreferences: { [weak self] in
                self?.showPreferences()
            })
        )
    }

    private func bindViewModel() {
        viewModel.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.updateStatusItem(for: status)
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem(for status: RecordingStatus) {
        guard let button = statusItem.button else { return }
        let symbolName: String
        let tintColor: NSColor?

        switch status {
        case .idle:
            symbolName = "waveform"
            tintColor = nil
        case .initializing:
            symbolName = "waveform.circle.fill"
            tintColor = .systemOrange
        case .recording, .transcribing:
            symbolName = "waveform.circle.fill"
            tintColor = .systemRed
        case .backpressure:
            symbolName = "waveform.circle.fill"
            tintColor = .systemOrange
        case .error:
            symbolName = "exclamationmark.triangle.fill"
            tintColor = .systemRed
        }

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Voxtral")
        button.contentTintColor = tintColor
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showPreferences() {
        if popover.isShown {
            popover.performClose(nil)
        }
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(viewModel: viewModel)
        }
        preferencesWindowController?.show()
    }
}
