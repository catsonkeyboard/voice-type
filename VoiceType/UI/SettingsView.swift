import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
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
