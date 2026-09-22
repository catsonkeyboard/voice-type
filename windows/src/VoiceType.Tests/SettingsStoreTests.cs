using VoiceType.Interop;
using VoiceType.Models;
using VoiceType.Services;
using Xunit;

namespace VoiceType.Tests;

public class SettingsStoreTests
{
    private static (SettingsStore Store, string Path, InMemoryCredentialStore Creds) NewStore()
    {
        string path = Path.Combine(Path.GetTempPath(), $"vt-settings-{Guid.NewGuid():N}.json");
        var creds = new InMemoryCredentialStore();
        return (new SettingsStore(path, creds), path, creds);
    }

    [Fact]
    public void Defaults()
    {
        (SettingsStore store, _, _) = NewStore();
        Assert.Equal(AsrEngine.Local, store.AsrEngine);
        Assert.Equal(LocalAsrModel.FunasrNano, store.LocalAsrModel);
        Assert.Equal("fun-asr-realtime", store.DashScopeModel);
        Assert.True(store.PolishEnabled);
        Assert.Equal("http://localhost:11434/v1", store.PolishBaseUrl);
        Assert.Equal(PolishStyle.Clean, store.PolishStyle);
        Assert.Equal(Models.KeyCombo.Default.Display, store.KeyCombo.Display);
        Assert.Empty(store.Hotwords);
    }

    [Fact]
    public void Setters_PersistAcrossInstances()
    {
        (SettingsStore store, string path, _) = NewStore();
        store.AsrEngine = AsrEngine.DashScope;
        store.LocalAsrModel = LocalAsrModel.SenseVoice;
        store.DashScopeModel = "other-model";
        store.PolishEnabled = false;
        store.PolishStyle = PolishStyle.Formal;
        store.PolishBaseUrl = "https://api.deepseek.com/v1";
        store.PolishModel = "deepseek-chat";
        store.HotwordsText = "朗诗德\n  \n盛派\n";
        var combo = KeyCombo.Create(
            HotkeyModifiers.Control | HotkeyModifiers.Shift, 0x42);
        store.KeyCombo = combo;

        var reopened = new SettingsStore(path, new InMemoryCredentialStore());
        Assert.Equal(AsrEngine.DashScope, reopened.AsrEngine);
        Assert.Equal(LocalAsrModel.SenseVoice, reopened.LocalAsrModel);
        Assert.Equal("other-model", reopened.DashScopeModel);
        Assert.False(reopened.PolishEnabled);
        Assert.Equal(PolishStyle.Formal, reopened.PolishStyle);
        Assert.Equal("https://api.deepseek.com/v1", reopened.PolishBaseUrl);
        Assert.Equal("deepseek-chat", reopened.PolishModel);
        Assert.Equal(combo, reopened.KeyCombo);
        Assert.Equal(["朗诗德", "盛派"], reopened.Hotwords);
    }

    [Fact]
    public void ApiKeys_StoredInCredentialStore()
    {
        (SettingsStore store, _, InMemoryCredentialStore creds) = NewStore();
        Assert.Equal("", store.DashScopeApiKey);
        store.DashScopeApiKey = "sk-abc";
        Assert.Equal("sk-abc", creds.Get(SettingsStore.DashScopeApiKeyAccount));
        store.DashScopeApiKey = "";  // 空串等价删除
        Assert.Null(creds.Get(SettingsStore.DashScopeApiKeyAccount));
    }

    [Fact]
    public void CorruptFile_FallsBackToDefaults()
    {
        string path = Path.Combine(Path.GetTempPath(), $"vt-settings-{Guid.NewGuid():N}.json");
        File.WriteAllText(path, "{oops");
        var store = new SettingsStore(path, new InMemoryCredentialStore());
        Assert.Equal(AsrEngine.Local, store.AsrEngine);
    }

    [Fact]
    public void PolishConfig_Composite()
    {
        (SettingsStore store, _, _) = NewStore();
        PolishConfig config = store.PolishConfig;
        Assert.True(config.Enabled);
        Assert.Equal(store.PolishBaseUrl, config.BaseUrl);
        Assert.Equal(store.PolishModel, config.Model);
    }
}

public class LocalAsrModelTests
{
    [Fact]
    public void Labels()
    {
        Assert.Equal("Fun-ASR-Nano-2512", LocalAsrModel.FunasrNano.Label());
        Assert.Equal("Qwen3-ASR-0.6B", LocalAsrModel.Qwen3Asr.Label());
        Assert.Equal("SenseVoiceSmall", LocalAsrModel.SenseVoice.Label());
    }

    [Fact]
    public void InstallCommands_ArePowerShell()
    {
        Assert.EndsWith(".ps1 funasr-nano", LocalAsrModel.FunasrNano.InstallCommand());
        Assert.EndsWith(".ps1 qwen3", LocalAsrModel.Qwen3Asr.InstallCommand());
        Assert.EndsWith("export_sensevoice.ps1", LocalAsrModel.SenseVoice.InstallCommand());
    }

    [Fact]
    public void Presets()
    {
        Assert.Equal("http://localhost:11434/v1", PolishPreset.Ollama.BaseUrl());
        Assert.Equal("qwen-flash", PolishPreset.Bailian.RecommendedModel());
    }
}

public class KeyComboTests
{
    [Fact]
    public void Default_IsCtrlAltSpace()
    {
        Assert.Equal(HotkeyModifiers.Control | HotkeyModifiers.Alt, KeyCombo.Default.Modifiers);
        Assert.Equal(0x20u, KeyCombo.Default.VirtualKey);
        Assert.Equal("Ctrl+Alt+Space", KeyCombo.Default.Display);
    }

    [Fact]
    public void Create_GeneratesDisplay()
    {
        KeyCombo combo = KeyCombo.Create(HotkeyModifiers.Shift | HotkeyModifiers.Win, 0x70);
        Assert.Equal("Shift+Win+F1", combo.Display);
    }

    [Fact]
    public void KeyNames_Special()
    {
        Assert.Equal("Enter", KeyNames.Name(0x0D));
        Assert.Equal("Up", KeyNames.Name(0x26));
        Assert.Equal("F5", KeyNames.Name(0x74));
        Assert.Equal("A", KeyNames.Name(0x41));
    }
}
