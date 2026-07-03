import AppKit
import SwiftUI

/// 录音/识别状态悬浮窗：无边框、不抢焦点、置顶、所有空间可见。
@MainActor
final class HUDController {
    static let shared = HUDController()
    private var panel: NSPanel?
    private var flashTask: Task<Void, Never>?

    private init() {}

    func show(state: AppState) {
        flashTask?.cancel()
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 56),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: RecordingHUDView(state: state))
            panel = p
        }
        if let screen = NSScreen.main, let panel {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 100))
        }
        panel?.orderFrontRegardless()
    }

    /// 显示一条短消息后自动隐藏
    func flash(_ message: String, state: AppState, seconds: Double = 2.0) {
        state.hudMessage = message
        show(state: state)
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            state.hudMessage = nil
            self?.hide()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

struct RecordingHUDView: View {
    var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            if let message = state.hudMessage {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary)
                Text(message)
                    .lineLimit(1)
            } else {
                switch state.phase {
                case .recording:
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                    LevelBarsView(level: state.micLevel)
                    Text("录音中")
                        .foregroundStyle(.secondary)
                case .transcribing:
                    ProgressView()
                        .controlSize(.small)
                    Text("识别中…")
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(width: 240, height: 56)
    }
}

struct LevelBarsView: View {
    var level: Float
    private let barCount = 8

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(
                        Float(i) / Float(barCount) < level
                            ? Color.red : Color.secondary.opacity(0.3)
                    )
                    .frame(width: 3, height: 6 + CGFloat(i) * 1.5)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
