import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    let onDone: () -> Void

    @FocusState private var isAPIKeyFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            geminiGroup
            modelGroup
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            // Focus the API key field so Cmd+V works immediately.
            DispatchQueue.main.async {
                isAPIKeyFieldFocused = true
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preferences")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Configure optional rewrite and model storage settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var geminiGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gemini Rewrite (Optional)")
                        .font(.headline)
                    Text("When enabled, transcripts are rewritten using Gemini Flash to fix errors and improve formatting. Audio stays on your Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    SecureField("API Key", text: $viewModel.geminiAPIKeyInput, onCommit: {
                        viewModel.saveGeminiAPIKey()
                    })
                    .textFieldStyle(.roundedBorder)
                    .focused($isAPIKeyFieldFocused)

                    Button {
                        if let value = NSPasteboard.general.string(forType: .string) {
                            viewModel.geminiAPIKeyInput = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            isAPIKeyFieldFocused = true
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .help("Paste from Clipboard")

                    Button("Save") {
                        viewModel.saveGeminiAPIKey()
                        isAPIKeyFieldFocused = false
                    }
                    .disabled(viewModel.geminiAPIKeyInput.isEmpty)
                }

                Toggle("Enable rewrite on stop", isOn: Binding(
                    get: { viewModel.isRewriteEnabled && viewModel.hasGeminiAPIKey },
                    set: { _ in viewModel.toggleRewrite() }
                ))
                .disabled(!viewModel.hasGeminiAPIKey)

                if viewModel.hasGeminiAPIKey {
                    Button("Remove API Key") {
                        viewModel.deleteGeminiAPIKey()
                    }
                    .controlSize(.small)
                } else {
                    Text("Tip: You can create an API key in Google AI Studio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modelGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Transcription Model")
                    .font(.headline)

                Picker("Model", selection: Binding(
                    get: { viewModel.selectedModel },
                    set: { viewModel.applySelectedModel($0) }
                )) {
                    ForEach(ModelAssetManager.ModelChoice.allCases) { model in
                        Text(model.displayName)
                            .tag(model)
                    }
                }
                .pickerStyle(.radioGroup)

                if viewModel.selectedModel.backendKind == .whisper {
                    Text("Estimated download: \(viewModel.selectedModelDownloadSizeText) (downloaded on first use)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Download size: \(viewModel.selectedModelDownloadSizeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.selectedModel.backendKind == .whisper ? "Model cache location (HF_HOME):" : "Downloaded model location:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.modelDownloadPath)
                        .font(.caption)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    Button("Open in Finder") {
                        viewModel.openModelFolder()
                    }

                    if viewModel.selectedModel.backendKind == .voxtral {
                        Button("Retry Download") {
                            viewModel.retryModelDownload()
                        }
                    }

                    Button(viewModel.selectedModel.backendKind == .whisper ? "Reset Cache" : "Reset Model") {
                        viewModel.resetModel()
                    }

                    Spacer(minLength: 0)
                }

                if viewModel.selectedModel.backendKind == .voxtral {
                    Text("Note: downloads are staged in a temporary folder first, so you may need extra free disk space during download.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Note: models are downloaded on-demand into the Hugging Face cache.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                viewModel.saveGeminiAPIKey()
                onDone()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
