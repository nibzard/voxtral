import SwiftUI

struct PopoverView: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusSection
            modelSection
            errorSection
            recordButton
            rewriteIndicator
            Divider()
            outputSection
            actionRow
            Divider()
            preferencesButton
            Button("Quit Voxtral", action: viewModel.quitApp)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .sheet(isPresented: $viewModel.isShowingPreferences) {
            PreferencesView(viewModel: viewModel)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Voxtral")
                .font(.headline)
            Text("Menu Bar Transcriber")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var statusSection: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(viewModel.statusText)
                    .font(.body)
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = viewModel.currentError {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Error")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.errorDescription ?? "Unknown error")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if let suggestion = error.recoverySuggestion {
                        Text(suggestion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                errorActions(for: error)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.orange.opacity(0.1))
            )
        }
    }

    @ViewBuilder
    private func errorActions(for error: AppError) -> some View {
        switch error {
        case .microphoneDenied:
            Button("Open System Settings…", action: viewModel.openSystemSettingsForMicrophone)
                .font(.caption)
                .buttonStyle(.bordered)
        case .backendLaunchFailed, .backendNotReady:
            Button("Retry", action: viewModel.retryBackend)
                .font(.caption)
                .buttonStyle(.bordered)
        case .modelDownloadFailed:
            Button("Retry Download", action: viewModel.retryModelDownload)
                .font(.caption)
                .buttonStyle(.bordered)
        case .modelNotReady:
            EmptyView()
        case .outputFolderUnavailable, .outputFolderAccessDenied:
            Button("Change Folder…", action: viewModel.selectOutputFolder)
                .font(.caption)
                .buttonStyle(.bordered)
        case .transcriptionFailed:
            EmptyView()
        }
    }

    private var recordButton: some View {
        HStack(spacing: 8) {
            Button(viewModel.recordButtonTitle, action: viewModel.toggleRecording)
                .buttonStyle(.borderedProminent)
                .tint(viewModel.recordButtonTint)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .accessibilityLabel(viewModel.recordButtonTitle)
                .accessibilityHint("Toggle recording (Command-Shift-R)")
                .disabled(viewModel.isRecordButtonDisabled)
            Spacer(minLength: 0)
            ShortcutBadge(text: "Cmd+Shift+R")
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output Folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(viewModel.outputFolderPath)
                .font(.callout)
                .lineLimit(2)
                .foregroundStyle(viewModel.isOutputFolderSet ? .primary : .secondary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button("Change…", action: viewModel.selectOutputFolder)
            Button("Open Folder", action: viewModel.openOutputFolder)
                .disabled(!viewModel.isOutputFolderSet)
        }
    }

    @ViewBuilder
    private var rewriteIndicator: some View {
        if viewModel.isRewriting {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Rewriting transcript…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        if viewModel.shouldShowModelStatus {
            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let progress = viewModel.modelDownloadProgress {
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .frame(width: 160)
                        Text(viewModel.modelStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(viewModel.modelStatusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var preferencesButton: some View {
        Button("Preferences…") {
            viewModel.isShowingPreferences = true
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity)
    }

    private var statusColor: Color {
        switch viewModel.status {
        case .idle:
            return .secondary
        case .initializing:
            return .orange
        case .recording, .transcribing:
            return .red
        case .backpressure:
            return .orange
        case .error:
            return .red
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isAPIKeyFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Preferences")
                .font(.headline)
            Divider()
            geminiSection
            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    viewModel.saveGeminiAPIKey()
                    dismiss()
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400, alignment: .leading)
        .onDisappear {
            viewModel.saveGeminiAPIKey()
        }
    }

    private var geminiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gemini Rewrite (Optional)")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("When enabled, transcripts are rewritten using Gemini Flash to fix errors and improve formatting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Privacy: When enabled, transcript text is sent to Google Gemini over HTTPS for rewriting. Audio stays on your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                SecureField("API Key", text: $viewModel.geminiAPIKeyInput, onCommit: {
                    viewModel.saveGeminiAPIKey()
                })
                    .textFieldStyle(.roundedBorder)
                    .focused($isAPIKeyFieldFocused)
                Button("Save") {
                    viewModel.saveGeminiAPIKey()
                    isAPIKeyFieldFocused = false
                }
                    .controlSize(.regular)
            }

            HStack(spacing: 8) {
                Toggle("Enable rewrite on stop", isOn: Binding(
                    get: { viewModel.isRewriteEnabled && viewModel.hasGeminiAPIKey },
                    set: { _ in viewModel.toggleRewrite() }
                ))
                .disabled(!viewModel.hasGeminiAPIKey)
                Spacer()
            }

            if viewModel.hasGeminiAPIKey {
                Button("Remove API Key") {
                    viewModel.deleteGeminiAPIKey()
                }
                .controlSize(.small)
            }
        }
    }
}

private struct ShortcutBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}
