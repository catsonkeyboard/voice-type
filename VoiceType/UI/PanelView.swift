import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct PanelView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \TranscriptRecord.createdAt, order: .reverse)
    private var records: [TranscriptRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
            Divider()
            recordButton
            Divider()
            fileSection
            Divider()
            historySection
            Divider()
            footer
        }
        .frame(width: 320)
    }

    // MARK: - 状态

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
    }

    private var statusColor: Color {
        if !deps.state.modelsReady { return .orange }
        switch deps.state.phase {
        case .idle: return .green
        case .recording: return .red
        case .transcribing: return .blue
        case .polishing: return .purple
        case .error: return .orange
        }
    }

    private var statusText: String {
        if !deps.state.modelsReady {
            return "模型未安装：请运行 scripts/export_model.sh"
        }
        switch deps.state.phase {
        case .idle: return "就绪 · 按 \(SettingsStore.keyCombo.display) 开始听写"
        case .recording: return "录音中…再按快捷键结束"
        case .transcribing: return "识别中…"
        case .polishing: return "润色中…"
        case .error(let message): return message
        }
    }

    // MARK: - 录音按钮

    private var recordButton: some View {
        Button {
            deps.dictation.toggle()
        } label: {
            Label(
                deps.state.phase == .recording ? "停止并转写" : "开始录音",
                systemImage: deps.state.phase == .recording ? "stop.circle.fill" : "record.circle"
            )
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(deps.state.phase == .recording ? .red : .accentColor)
        .disabled(
            deps.state.phase == .transcribing || deps.state.phase == .polishing
                || !deps.state.modelsReady)
        .padding(12)
    }

    // MARK: - 文件转写

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch deps.state.fileJob {
            case .idle:
                fileDropArea(prompt: "拖入音频文件转写 (wav/mp3/m4a)")
            case .running(let progress):
                ProgressView(value: progress) {
                    Text("文件转写中… \(Int(progress * 100))%")
                        .font(.caption)
                }
            case .done(let text):
                VStack(alignment: .leading, spacing: 6) {
                    Text(text)
                        .font(.caption)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    HStack {
                        Button("复制结果") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        Button("完成") { deps.state.fileJob = .idle }
                    }
                    .controlSize(.small)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("重试") { deps.state.fileJob = .idle }
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
    }

    private func fileDropArea(prompt: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.badge.arrow.up")
                .foregroundStyle(.secondary)
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("选择文件…") { pickFile() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundStyle(.secondary.opacity(0.5))
        )
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in deps.dictation.transcribeFile(url: url) }
            }
            return true
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            deps.dictation.transcribeFile(url: url)
        }
    }

    // MARK: - 历史

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("最近转写")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !records.isEmpty {
                    Button("清空") { deps.history.clear() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if records.isEmpty {
                Text("暂无记录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(records.prefix(20)) { record in
                            HistoryRow(record: record) {
                                deps.history.delete(record)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack {
            Button {
                // LSUIElement 应用需先激活自身，否则设置窗口不前置
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
            }
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(12)
    }
}

private struct HistoryRow: View {
    let record: TranscriptRecord
    let onDelete: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.text)
                    .font(.callout)
                    .lineLimit(2)
                Text(record.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contextMenu {
            if let rawText = record.rawText {
                Button("复制原始转写") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rawText, forType: .string)
                }
            }
            Button("删除", role: .destructive, action: onDelete)
        }
    }
}
