using System.Text.Json;
using System.Text.Json.Serialization;
using VoiceType.Interop;
using VoiceType.Models;

namespace VoiceType.Services;

public enum AsrEngine
{
    Local,
    DashScope,
}

public static class AsrEngineExtensions
{
    public static string Label(this AsrEngine engine) => engine switch
    {
        AsrEngine.Local => "本地识别",
        AsrEngine.DashScope => "云端 Fun-ASR-Realtime",
        _ => engine.ToString(),
    };
}

/// <summary>本地识别模型档位（均为 sherpa-onnx 离线模型）。</summary>
[JsonConverter(typeof(JsonStringEnumConverter<LocalAsrModel>))]
public enum LocalAsrModel
{
    FunasrNano,
    Qwen3Asr,
    SenseVoice,
}

public static class LocalAsrModelExtensions
{
    public static string Label(this LocalAsrModel m) => m switch
    {
        LocalAsrModel.FunasrNano => "Fun-ASR-Nano-2512",
        LocalAsrModel.Qwen3Asr => "Qwen3-ASR-0.6B",
        LocalAsrModel.SenseVoice => "SenseVoiceSmall",
        _ => m.ToString(),
    };

    /// <summary>设置页一行说明</summary>
    public static string Note(this LocalAsrModel m) => m switch
    {
        LocalAsrModel.FunasrNano => "默认 · 中英混杂与方言最强（0.8B，约 1GB，速度稍慢）",
        LocalAsrModel.Qwen3Asr => "30 语种 + 22 中文方言（0.6B，约 950MB）",
        LocalAsrModel.SenseVoice => "轻量极速，纯中文/英文较好，混杂较弱（约 230MB）",
        _ => "",
    };

    /// <summary>未安装时的下载命令（Windows 版，以仓库根为工作目录）</summary>
    public static string InstallCommand(this LocalAsrModel m) => m switch
    {
        LocalAsrModel.FunasrNano => @".\windows\scripts\download_models.ps1 funasr-nano",
        LocalAsrModel.Qwen3Asr => @".\windows\scripts\download_models.ps1 qwen3",
        LocalAsrModel.SenseVoice => @".\windows\scripts\export_sensevoice.ps1",
        _ => "",
    };
}

public enum PolishStyle
{
    Clean,   // 智能清理：保留原话风格
    Formal,  // 完全书面化：允许重组句式
}

public static class PolishStyleExtensions
{
    public static string Label(this PolishStyle s) => s switch
    {
        PolishStyle.Clean => "智能清理",
        PolishStyle.Formal => "完全书面化",
        _ => s.ToString(),
    };
}

public sealed record PolishConfig(
    bool Enabled, string BaseUrl, string ApiKey, string Model, PolishStyle Style);

/// <summary>润色服务商预设：仅作为设置页的一键填充器</summary>
public enum PolishPreset
{
    Ollama,
    Bailian,
    DeepSeek,
    OpenAI,
}

public static class PolishPresetExtensions
{
    public static string Label(this PolishPreset p) => p switch
    {
        PolishPreset.Ollama => "本地 Ollama",
        PolishPreset.Bailian => "阿里百炼",
        PolishPreset.DeepSeek => "DeepSeek",
        PolishPreset.OpenAI => "OpenAI",
        _ => p.ToString(),
    };

    public static string BaseUrl(this PolishPreset p) => p switch
    {
        PolishPreset.Ollama => "http://localhost:11434/v1",
        PolishPreset.Bailian => "https://dashscope.aliyuncs.com/compatible-mode/v1",
        PolishPreset.DeepSeek => "https://api.deepseek.com/v1",
        PolishPreset.OpenAI => "https://api.openai.com/v1",
        _ => "",
    };

    public static string RecommendedModel(this PolishPreset p) => p switch
    {
        // Windows 上 Ollama 走 CPU/CUDA，推荐非 nvfp4 量化标签
        PolishPreset.Ollama => "qwen3.5:4b",
        PolishPreset.Bailian => "qwen-flash",
        PolishPreset.DeepSeek => "deepseek-chat",
        PolishPreset.OpenAI => "gpt-5-mini",
        _ => "",
    };
}

/// <summary>
/// 设置持久化：%APPDATA%\VoiceType\settings.json（对应 macOS UserDefaults）。
/// API Key 不落盘，走 ICredentialStore（对应 Keychain）。
/// 写入即时落盘（文件极小，无需防抖）。
/// </summary>
public sealed class SettingsStore
{
    public const string DashScopeApiKeyAccount = "dashscope-api-key";
    public const string PolishApiKeyAccount = "polish-api-key";

    private sealed class Data
    {
        public string HotwordsText { get; set; } = "";
        public KeyCombo? KeyCombo { get; set; }
        public AsrEngine AsrEngine { get; set; } = AsrEngine.Local;
        public LocalAsrModel LocalAsrModel { get; set; } = LocalAsrModel.FunasrNano;
        public string DashScopeModel { get; set; } = "fun-asr-realtime";
        public bool? PolishEnabled { get; set; }
        public string PolishBaseUrl { get; set; } = "http://localhost:11434/v1";
        public string PolishModel { get; set; } = "qwen3.5:4b";
        public PolishStyle PolishStyle { get; set; } = PolishStyle.Clean;
    }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter<AsrEngine>() },
    };

    private readonly string _path;
    private readonly ICredentialStore _credentials;
    private Data _data;

    public static SettingsStore Default { get; } =
        new(DefaultPath(), new CredentialStore());

    public static string DefaultPath() =>
        Path.Combine(ModelPaths.AppDataRoot, "settings.json");

    public SettingsStore(string path, ICredentialStore credentials)
    {
        _path = path;
        _credentials = credentials;
        _data = Load(path);
    }

    private static Data Load(string path)
    {
        try
        {
            if (File.Exists(path))
                return JsonSerializer.Deserialize<Data>(File.ReadAllText(path), JsonOpts) ?? new Data();
        }
        catch
        {
            // 损坏的设置文件按默认值启动，不让应用挂死
        }
        return new Data();
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(_data, JsonOpts));
        }
        catch
        {
            // 设置写盘失败不致命（只读目录等场景），下次能写时恢复
        }
    }

    // ----- 热词 -----

    public string HotwordsText
    {
        get => _data.HotwordsText;
        set { _data.HotwordsText = value; Save(); }
    }

    public List<string> Hotwords => HotwordsText
        .Split('\n', StringSplitOptions.RemoveEmptyEntries)
        .Select(l => l.Trim())
        .Where(l => l.Length > 0)
        .ToList();

    // ----- 快捷键 -----

    public KeyCombo KeyCombo
    {
        get => _data.KeyCombo ?? Models.KeyCombo.Default;
        set { _data.KeyCombo = value; Save(); }
    }

    // ----- 识别引擎 -----

    public AsrEngine AsrEngine
    {
        get => _data.AsrEngine;
        set { _data.AsrEngine = value; Save(); }
    }

    public LocalAsrModel LocalAsrModel
    {
        get => _data.LocalAsrModel;
        set { _data.LocalAsrModel = value; Save(); }
    }

    public string DashScopeModel
    {
        get => _data.DashScopeModel;
        set { _data.DashScopeModel = value; Save(); }
    }

    public string DashScopeApiKey
    {
        get => _credentials.Get(DashScopeApiKeyAccount) ?? "";
        set => _credentials.Set(value, DashScopeApiKeyAccount);
    }

    // ----- 润色 -----

    public bool PolishEnabled
    {
        get => _data.PolishEnabled ?? true;
        set { _data.PolishEnabled = value; Save(); }
    }

    public string PolishBaseUrl
    {
        get => _data.PolishBaseUrl;
        set { _data.PolishBaseUrl = value; Save(); }
    }

    public string PolishApiKey
    {
        get => _credentials.Get(PolishApiKeyAccount) ?? "";
        set => _credentials.Set(value, PolishApiKeyAccount);
    }

    public string PolishModel
    {
        get => _data.PolishModel;
        set { _data.PolishModel = value; Save(); }
    }

    public PolishStyle PolishStyle
    {
        get => _data.PolishStyle;
        set { _data.PolishStyle = value; Save(); }
    }

    public PolishConfig PolishConfig => new(
        PolishEnabled, PolishBaseUrl, PolishApiKey, PolishModel, PolishStyle);
}
