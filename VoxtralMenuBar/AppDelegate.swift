import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let modelAssetManager = ModelAssetManager.shared
    private let backendServiceManager = BackendServiceManager.shared
    private var modelStateToken: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.shared.logApplicationLaunch()
        statusBarController = StatusBarController(
            backendServiceManager: backendServiceManager,
            modelAssetManager: modelAssetManager
        )
        modelStateToken = modelAssetManager.observeState { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                if let modelPath = self.modelAssetManager.modelPathForBackend() {
                    self.backendServiceManager.setModelPath(modelPath)
                }
                self.backendServiceManager.start()
            }
        }
        modelAssetManager.checkModelAvailability()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.shared.logApplicationTerminate()
        backendServiceManager.stop()
    }
}
