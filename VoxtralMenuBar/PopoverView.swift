import SwiftUI

struct PopoverView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    let onOpenPreferences: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusCard
            modelCard
            errorCard
            recordButton
            rewriteIndicator
            Divider()
            outputCard
            Divider()
            footerButtons
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Voxtral")
                    .font(.headline)
                Text("Menu Bar Transcriber")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
        }
    }

    private var statusCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Label("Status", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.statusText)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            if viewModel.currentLatencyMs > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text("Latency")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(viewModel.currentLatencyMs.rounded())) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var modelCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Label("Model", systemImage: "cube.transparent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let progress = viewModel.modelDownloadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
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

    @ViewBuilder
    private var errorCard: some View {
        if let error = viewModel.currentError {
            Card(tint: .orange) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Error")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                }

                Text(error.errorDescription ?? "Unknown error")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                errorActions(for: error)
            }
        }
    }

    @ViewBuilder
    private func errorActions(for error: AppError) -> some View {
        switch error {
        case .microphoneDenied:
            Button("Open System Settings…", action: viewModel.openSystemSettingsForMicrophone)
                .buttonStyle(.bordered)
        case .backendLaunchFailed, .backendNotReady:
            Button("Retry", action: viewModel.retryBackend)
                .buttonStyle(.bordered)
        case .modelDownloadFailed:
            HStack(spacing: 8) {
                Button("Retry Download", action: viewModel.retryModelDownload)
                    .buttonStyle(.bordered)
                Button("Reset", action: viewModel.resetModel)
                    .buttonStyle(.bordered)
                Button("Open Folder", action: viewModel.openModelFolder)
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
        case .modelNotReady:
            EmptyView()
        case .outputFolderUnavailable, .outputFolderAccessDenied:
            Button("Change Folder…", action: viewModel.selectOutputFolder)
                .buttonStyle(.bordered)
        case .transcriptionFailed:
            EmptyView()
        }
    }

    private var recordButton: some View {
        HStack(spacing: 10) {
            Button(action: viewModel.toggleRecording) {
                HStack {
                    Image(systemName: isRecordingLike ? "stop.fill" : "record.circle.fill")
                    Text(viewModel.recordButtonTitle)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.recordButtonTint)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .accessibilityLabel(viewModel.recordButtonTitle)
            .accessibilityHint("Toggle recording (Command-Shift-R)")
            .disabled(viewModel.isRecordButtonDisabled)

            ShortcutBadge(text: "Cmd+Shift+R")
        }
    }

    private var isRecordingLike: Bool {
        viewModel.status == .recording || viewModel.status == .transcribing
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

    private var outputCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Label("Output", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(viewModel.outputFolderPath)
                .font(.callout)
                .lineLimit(2)
                .foregroundStyle(viewModel.isOutputFolderSet ? .primary : .secondary)

            HStack(spacing: 8) {
                Button("Change…", action: viewModel.selectOutputFolder)
                Button("Open", action: viewModel.openOutputFolder)
                    .disabled(!viewModel.isOutputFolderSet)
                Spacer(minLength: 0)
            }
        }
    }

    private var footerButtons: some View {
        HStack(spacing: 10) {
            Button("Preferences…", action: onOpenPreferences)
            Button("Quit", action: viewModel.quitApp)
            Spacer(minLength: 0)
        }
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

private struct Card<Content: View>: View {
    let tint: Color?
    @ViewBuilder let content: () -> Content

    init(tint: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.tint = tint
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder((tint ?? .primary).opacity(0.12), lineWidth: 1)
        )
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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}
