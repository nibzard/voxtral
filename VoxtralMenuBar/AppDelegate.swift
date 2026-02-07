import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let modelAssetManager = ModelAssetManager.shared
    private let backendServiceManager = BackendServiceManager.shared
    private var modelStateToken: Any?

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.shared.logApplicationLaunch()
        statusBarController = StatusBarController(
            backendServiceManager: backendServiceManager,
            modelAssetManager: modelAssetManager
        )
        modelStateToken = modelAssetManager.observeState { [weak self] state in
            guard let self else { return }
            guard !self.isRunningTests else { return }
            switch state {
            case .ready:
                let modelPath = self.modelAssetManager.modelPathForBackend()
                let modelName = self.modelAssetManager.selectedModelNameForBackend()
                let backend = self.modelAssetManager.selectedModelBackendKind().rawValue

                // Restart to ensure the backend picks up the selected model/backend kind.
                self.backendServiceManager.stop()
                self.backendServiceManager.configureModel(
                    modelPath: modelPath,
                    modelName: modelName,
                    backend: backend
                )
                self.backendServiceManager.start()
            case .missing, .failed:
                // Avoid running a backend configured for an old model if the user resets/switches.
                self.backendServiceManager.stop()
            default:
                break
            }
        }
        modelAssetManager.checkModelAvailability(autoDownload: !isRunningTests)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.shared.logApplicationTerminate()
        backendServiceManager.stop()
    }
}
