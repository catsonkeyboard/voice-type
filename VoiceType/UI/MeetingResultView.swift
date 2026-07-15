import AppKit
import SwiftUI

/// 会议转写结果窗口：分段展示、说话人改名、复制/导出、生成纪要
struct MeetingResultView: View {
    let jsonURL: URL

    @Environment(AppDependencies.self) private var deps
    @State private var transcript: MeetingTranscript?
    @State private var renamingSpeaker: Int?
    @State private var renameText = ""
    @State private var minutes: String?
    @State private var minutesError: String?
    @State private var generatingMinutes = false

    private static let speakerColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .red, .indigo,
    ]

    var body: some View {
        Group {
            if let transcript {
                content(transcript)
            } else {
                Text("无法加载会议稿")
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear { transcript = try? MeetingTranscript.load(from: jsonURL) }
        .alert(
            "说话人改名", isPresented: Binding(
                get: { renamingSpeaker != nil },
                set: { if !$0 { renamingSpeaker = nil } })
        ) {
            TextField("名字", text: $renameText)
            Button("确定") { applyRename() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将「\(transcript?.displayName(for: renamingSpeaker ?? 0) ?? "")」改为新名字，全文生效")
        }
    }

    @ViewBuilder
    private func content(_ transcript: MeetingTranscript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(transcript)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if transcript.degraded {
                        Label("说话人分离不可用，本稿为整段转写", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, seg in
                        segmentRow(seg, transcript: transcript)
                    }
                    if let minutes {
                        Divider()
                        minutesSection(minutes)
                    }
                    if let minutesError {
                        Label(minutesError, systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
        }
    }

    private func header(_ transcript: MeetingTranscript) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("会议转写")
                    .font(.headline)
                Text(
                    "\(transcript.createdAt.formatted(date: .abbreviated, time: .shortened)) · 时长 \(MeetingTranscript.timestamp(transcript.duration)) · \(transcript.speakerIds.count) 位说话人"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("复制全文") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcript.markdown(), forType: .string)
            }
            Button("导出 Markdown") { exportMarkdown(transcript) }
            Button(generatingMinutes ? "生成中…" : "生成纪要") { generateMinutes(transcript) }
                .disabled(generatingMinutes)
        }
        .padding(12)
    }

    private func segmentRow(_ seg: SpeakerSegment, transcript: MeetingTranscript) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                renamingSpeaker = seg.speaker
                renameText = transcript.speakerNames[seg.speaker] ?? ""
            } label: {
                Text(transcript.displayName(for: seg.speaker))
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Self.speakerColors[seg.speaker % Self.speakerColors.count].opacity(0.2),
                        in: Capsule())
            }
            .buttonStyle(.plain)
            .help("点击改名")
            VStack(alignment: .leading, spacing: 2) {
                Text(MeetingTranscript.timestamp(seg.start))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(seg.text)
                    .textSelection(.enabled)
            }
        }
    }

    private func minutesSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("会议纪要", systemImage: "sparkles")
                    .font(.headline)
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)
            }
            Text(text)
                .textSelection(.enabled)
        }
    }

    private func applyRename() {
        guard var t = transcript, let speaker = renamingSpeaker else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            t.speakerNames.removeValue(forKey: speaker)
        } else {
            t.speakerNames[speaker] = name
        }
        transcript = t
        try? t.save(to: jsonURL)
        renamingSpeaker = nil
    }

    private func exportMarkdown(_ transcript: MeetingTranscript) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            jsonURL.deletingPathExtension().lastPathComponent + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            try? transcript.markdown().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func generateMinutes(_ transcript: MeetingTranscript) {
        generatingMinutes = true
        minutesError = nil
        Task {
            if let result = await deps.polish.complete(
                system: MinutesPrompt.system, user: MinutesPrompt.user(transcript: transcript))
            {
                minutes = result
            } else {
                minutesError = "纪要生成失败：LLM 服务不可用（检查设置 → 润色）"
            }
            generatingMinutes = false
        }
    }
}
