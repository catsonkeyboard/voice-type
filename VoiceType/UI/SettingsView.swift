import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            RecognitionSettingsView()
                .tabItem { Label("识别", systemImage: "waveform") }
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

private struct RecognitionSettingsView: View {
    @State private var engine = SettingsStore.asrEngine
    @State private var apiKey = SettingsStore.dashScopeAPIKey
    @State private var model = SettingsStore.dashScopeModel
    @State private var testing = false
    @State private var testOK = false
    @State private var testResult: String?

    var body: some View {
        Form {
            Section("识别引擎") {
                Picker("引擎", selection: $engine) {
                    ForEach(AsrEngine.allCases, id: \.self) { e in
                        Text(e.label).tag(e)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: engine) { _, newValue in
                    SettingsStore.asrEngine = newValue
                }
                if engine == .dashscope {
                    Text("云端模式下，录音音频将实时发送至阿里云百炼进行识别；失败时自动回退本地引擎。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("说话人分离（会议转写）") {
                LabeledContent("分离模型") {
                    if ModelPaths.diarizationPresent {
                        Label("已安装", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("未安装", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if !ModelPaths.diarizationPresent {
                    HStack {
                        Text("scripts/setup_diarization.sh")
                            .font(.caption.monospaced())
                        Button("复制命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                "./scripts/setup_diarization.sh", forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            }

            if engine == .dashscope {
                Section("阿里百炼 (DashScope)") {
                    SecureField("API Key（存储于钥匙串）", text: $apiKey)
                        .onChange(of: apiKey) { _, v in SettingsStore.dashScopeAPIKey = v }
                    TextField("模型", text: $model)
                        .onChange(of: model) { _, v in SettingsStore.dashScopeModel = v }
                    Button(testing ? "测试中…" : "测试连接") { runTest() }
                        .disabled(testing || apiKey.isEmpty)
                    if let testResult {
                        Label(
                            testResult,
                            systemImage: testOK ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .foregroundStyle(testOK ? .green : .red)
                        .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 用 0.5 秒静音走完整协议验证 Key 与连通性
    private func runTest() {
        testing = true
        testResult = nil
        Task {
            let session = DashScopeAsrSession(apiKey: apiKey, model: model)
            do {
                try await session.start()
                session.send(samples: [Float](repeating: 0, count: 8000))
                _ = try await session.finish()
                testOK = true
                testResult = "连接成功，Key 有效"
            } catch {
                session.cancel()
                testOK = false
                testResult = "失败：\(error.localizedDescription)"
            }
            testing = false
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
                Menu("服务商预设") {
                    ForEach(PolishPreset.allCases, id: \.self) { preset in
                        Button("\(preset.rawValue)（\(preset.recommendedModel)）") {
                            baseURL = preset.baseURL
                            SettingsStore.polishBaseURL = preset.baseURL
                            model = preset.recommendedModel
                            SettingsStore.polishModel = preset.recommendedModel
                        }
                    }
                }
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
