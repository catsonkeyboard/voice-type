import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            PolishSettingsView()
                .tabItem { Label("润色", systemImage: "sparkles") }
            HotwordSettingsView()
                .tabItem { Label("热词", systemImage: "character.book.closed") }
        }
        .frame(width: 440)
        .padding(.bottom, 8)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var combo = SettingsStore.keyCombo
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var accessibilityTrusted = TextInjector.isTrusted

    var body: some View {
        Form {
            Section("听写快捷键") {
                LabeledContent("全局快捷键") {
                    KeyComboRecorder(combo: $combo)
                        .frame(width: 160)
                }
                .onChange(of: combo) { _, newValue in
                    SettingsStore.keyCombo = newValue
                    HotkeyManager.shared.register(newValue)
                }
            }

            Section("权限") {
                LabeledContent("辅助功能（注入文本必需）") {
                    if accessibilityTrusted {
                        Label("已授权", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("去授权…") {
                            TextInjector.promptForAccessibility()
                        }
                    }
                }
            }

            Section("启动") {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("模型") {
                LabeledContent("SenseVoice + VAD") {
                    if deps.state.modelsReady {
                        Label("已安装", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("未安装", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if !deps.state.modelsReady {
                    Text("请在项目目录运行 scripts/export_model.sh 后点击刷新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("打开模型目录") {
                        try? FileManager.default.createDirectory(
                            at: ModelPaths.modelsDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(ModelPaths.modelsDir)
                    }
                    Button("刷新状态") {
                        deps.state.refreshModelsReady()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            accessibilityTrusted = TextInjector.isTrusted
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct PolishSettingsView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var enabled = SettingsStore.polishEnabled
    @State private var style = SettingsStore.polishStyle
    @State private var baseURL = SettingsStore.polishBaseURL
    @State private var apiKey = SettingsStore.polishAPIKey
    @State private var model = SettingsStore.polishModel
    @State private var probing = false
    @State private var probeResult: PolishService.ProbeResult?

    var body: some View {
        Form {
            Section("智能润色") {
                Toggle("启用润色（关闭后输出原始转写）", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        SettingsStore.polishEnabled = newValue
                        if newValue { deps.polish.warmUp() }
                    }
                Picker("风格", selection: $style) {
                    ForEach(PolishStyle.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .onChange(of: style) { _, newValue in
                    SettingsStore.polishStyle = newValue
                }
            }

            Section("服务（OpenAI 兼容，默认本地 Ollama）") {
                TextField("服务地址", text: $baseURL)
                    .onChange(of: baseURL) { _, v in SettingsStore.polishBaseURL = v }
                SecureField("API Key（本地 Ollama 留空）", text: $apiKey)
                    .onChange(of: apiKey) { _, v in SettingsStore.polishAPIKey = v }
                TextField("模型", text: $model)
                    .onChange(of: model) { _, v in SettingsStore.polishModel = v }
                if let models = probeResult?.models, !models.isEmpty {
                    Menu("从已装模型中选择") {
                        ForEach(models, id: \.self) { name in
                            Button(name) {
                                model = name
                                SettingsStore.polishModel = name
                            }
                        }
                    }
                }
                Button(probing ? "检测中…" : "测试连接") {
                    probing = true
                    probeResult = nil
                    Task {
                        probeResult = await deps.polish.probe()
                        probing = false
                    }
                }
                .disabled(probing)
                if let result = probeResult {
                    probeStatus(result)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func probeStatus(_ result: PolishService.ProbeResult) -> some View {
        if !result.reachable {
            Label(
                "无法连接：\(result.errorMessage ?? "未知错误")（Ollama 是否在运行？）",
                systemImage: "xmark.circle.fill"
            )
            .foregroundStyle(.red)
            .font(.caption)
        } else if result.models.isEmpty {
            Label("已连接（该服务不支持列出模型）", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else if result.models.contains(model) {
            Label("已连接，模型可用", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("已连接，但模型未安装", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                HStack {
                    Text("ollama pull \(model)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button("复制命令") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("ollama pull \(model)", forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct HotwordSettingsView: View {
    @State private var text = SettingsStore.hotwordsText

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每行一个热词（人名、品牌、专业术语等，仅支持中文词）。识别后按拼音相似度自动纠正。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator))
                .onChange(of: text) { _, newValue in
                    SettingsStore.hotwordsText = newValue
                }
            Text("当前生效 \(SettingsStore.hotwords.count) 个热词")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }
}
