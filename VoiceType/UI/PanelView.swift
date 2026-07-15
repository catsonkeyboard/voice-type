import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct PanelView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    // 不用 @Query：MenuBarExtra 面板中其变更观察不可靠，
    // 改为面板出现/状态变化时直接从 HistoryStore 读取（与写入同一上下文）
    @State private var records: [TranscriptRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
            Divider()
            recordButton
            Divider()
            meetingSection
            Divider()
            fileSection
            Divider()
            historySection
            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear { refreshHistory() }
        .onChange(of: deps.state.phase) { _, _ in refreshHistory() }
        .onChange(of: deps.state.fileJob) { _, _ in refreshHistory() }
    }

    private func refreshHistory() {
        records = deps.history.recent(limit: 20)
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

    /// 按当前引擎判断听写就绪：本地看模型，云端看 Key
    private var engineReady: Bool {
        switch SettingsStore.asrEngine {
        case .local: return deps.state.modelsReady
        case .dashscope: return !SettingsStore.dashScopeAPIKey.isEmpty
        }
    }

    private var statusColor: Color {
        if !engineReady { return .orange }
        switch deps.state.phase {
        case .idle: return .green
        case .recording: return .red
        case .transcribing: return .blue
        case .polishing: return .purple
        case .error: return .orange
        }
    }

    private var statusText: String {
        if !engineReady {
            switch SettingsStore.asrEngine {
            case .local: return "模型未安装：请运行 scripts/export_model.sh"
            case .dashscope: return "未配置 DashScope API Key（设置 → 识别）"
            }
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
                || !engineReady)
        .padding(12)
    }

    // MARK: - 会议（v4）

    private var meetingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch deps.state.meeting {
            case .idle, .failed:
                HStack {
                    Button {
                        deps.meeting.startRecording()
                    } label: {
                        Label("开始会议录音", systemImage: "person.2.wave.2")
                    }
                    .disabled(!ModelPaths.diarizationPresent)
                    Spacer()
                    if let url = deps.state.meetingResultURL {
                        Button("查看结果") {
                            NSApp.activate(ignoringOtherApps: true)
                            openWindow(id: "meeting", value: url)
                        }
                        .controlSize(.small)
                    }
                }
                if case .failed(let message) = deps.state.meeting {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !ModelPaths.diarizationPresent {
                    Text("说话人分离模型未安装：运行 scripts/setup_diarization.sh")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .recording(let startedAt):
                HStack {
                    Label("会议录音中", systemImage: "record.circle")
                        .foregroundStyle(.red)
                    Text(startedAt, style: .timer)
                        .monospacedDigit()
                    Spacer()
                    Button("停止并转写") {
                        deps.meeting.stopAndProcess()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
            case .processing(let stage, let progress):
                ProgressView(value: progress) {
                    Text("会议处理：\(stage)")
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .onChange(of: deps.state.meetingResultURL) { _, url in
            if let url {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "meeting", value: url)
            }
        }
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
            HStack {
                Button("选择文件…") { pickFile() }
                Button("会议转写…") { pickMeetingFile() }
                    .disabled(!ModelPaths.diarizationPresent)
                    .help("区分说话人的会议转写")
            }
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

    private func pickMeetingFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            deps.meeting.process(url: url)
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
                    Button("清空") {
                        deps.history.clear()
                        refreshHistory()
                    }
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
                        ForEach(records) { record in
                            HistoryRow(record: record) {
                                deps.history.delete(record)
                                refreshHistory()
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
