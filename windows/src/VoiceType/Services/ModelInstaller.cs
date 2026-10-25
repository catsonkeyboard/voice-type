using System.Diagnostics;
using System.Net;
using System.Net.Http;

namespace VoiceType.Services;

/// <summary>模型安装进度（阶段文案 + 0~1 的可选比例）</summary>
/// <param name="Stage">如「下载中」「解压中」</param>
/// <param name="Fraction">已知总大小时才有</param>
public sealed record ModelInstallProgress(string Stage, double? Fraction);

/// <summary>
/// 模型的安装与删除（设置界面按钮背后），与 windows/scripts 下脚本同源同校验：
/// ModelScope 优先（国内快）、GitHub 回退，tar.bz2 用系统自带 tar.exe 解压，
/// FireRed 包内主文件改名 model.int8.onnx，安装识别模型时顺带补齐 silero_vad.onnx。
/// 供应用脱离仓库脚本独立安装（脚本仍保留，效果等价）。
/// </summary>
public static class ModelInstaller
{
    private static readonly HttpClient Http = CreateClient();

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("VoiceType/1.0");
        return client;
    }

    /// <summary>各档位的下载包与安装布局</summary>
    private sealed record Source(string Tarball, string OutDir, bool RenamePlainModel);

    private static Source? SourceOf(LocalAsrModel model) => model switch
    {
        LocalAsrModel.FunasrNano => new(
            "sherpa-onnx-funasr-nano-int8-2025-12-30.tar.bz2", "funasr-nano", false),
        LocalAsrModel.Qwen3Asr => new(
            "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2", "qwen3-asr", false),
        LocalAsrModel.FireRedCtc => new(
            "sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25.tar.bz2", "fire-red-ctc", true),
        // SenseVoice 是历史布局：model.int8.onnx + tokens.txt 直接放 models 根
        LocalAsrModel.SenseVoice => new(
            "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2", "", false),
        _ => null,
    };

    public static async Task InstallAsync(
        LocalAsrModel model, IProgress<ModelInstallProgress> progress, CancellationToken ct)
    {
        Source source = SourceOf(model)
            ?? throw new NotSupportedException($"{model} 不支持应用内安装");
        string modelsDir = ModelPaths.ModelsDir;
        string tarball = Path.Combine(Path.GetTempPath(), source.Tarball);
        string extractDir = Path.Combine(Path.GetTempPath(), "voicetype-model-extract");
        try
        {
            progress.Report(new("下载中", null));
            await DownloadTarballAsync(source.Tarball, tarball, progress, ct);
            progress.Report(new("解压中", null));
            ExtractTarBz2(tarball, extractDir);
            string inner = Directory.EnumerateDirectories(extractDir).FirstOrDefault()
                ?? throw new IOException("压缩包内容为空");
            if (source.OutDir.Length == 0)
            {
                // SenseVoice：两个文件拷到 models 根
                foreach (string name in new[] { "model.int8.onnx", "tokens.txt" })
                {
                    string from = Path.Combine(inner, name);
                    if (File.Exists(from))
                        File.Copy(from, Path.Combine(modelsDir, name), overwrite: true);
                }
            }
            else
            {
                string dest = Path.Combine(modelsDir, source.OutDir);
                if (Directory.Exists(dest))
                    Directory.Delete(dest, recursive: true);
                Directory.Move(inner, dest);
                if (source.RenamePlainModel)
                {
                    // FireRedASR2-CTC 包内主文件名可能不是 model.int8.onnx，统一重命名
                    string plain = Path.Combine(dest, "model.onnx");
                    string int8 = Path.Combine(dest, "model.int8.onnx");
                    if (File.Exists(plain) && !File.Exists(int8))
                        File.Move(plain, int8);
                }
            }
            // 公共组件与脚本一致：装任何识别档位都补齐 VAD（失败不致命）
            progress.Report(new("补齐 VAD 模型", null));
            try
            {
                await EnsureVadAsync(ct);
            }
            catch
            {
                // VAD 缺失只影响文件转写，安装本身仍算成功
            }
        }
        finally
        {
            try { File.Delete(tarball); } catch { }
            try { if (Directory.Exists(extractDir)) Directory.Delete(extractDir, true); } catch { }
        }
    }

    public static async Task InstallDiarizationAsync(
        IProgress<ModelInstallProgress> progress, CancellationToken ct)
    {
        string modelsDir = ModelPaths.ModelsDir;
        string segTarball = Path.Combine(Path.GetTempPath(), "pyannote-seg.tar.bz2");
        string extractDir = Path.Combine(Path.GetTempPath(), "voicetype-seg-extract");
        try
        {
            progress.Report(new("下载分段模型", null));
            await DownloadFileAsync(
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2",
                segTarball, progress, ct);
            progress.Report(new("解压中", null));
            ExtractTarBz2(segTarball, extractDir);
            string model = Directory.EnumerateFiles(extractDir, "model.onnx", SearchOption.AllDirectories)
                .FirstOrDefault()
                ?? throw new IOException("压缩包内没有 model.onnx");
            File.Copy(model, Path.Combine(modelsDir, "segmentation.onnx"), overwrite: true);
            progress.Report(new("下载声纹模型", null));
            await DownloadFileAsync(
                // 注意：官方 release tag 的 recongition 为历史遗留错拼，保持原样（与脚本一致）
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx",
                Path.Combine(modelsDir, "speaker-embedding.onnx"), progress, ct);
        }
        finally
        {
            try { File.Delete(segTarball); } catch { }
            try { if (Directory.Exists(extractDir)) Directory.Delete(extractDir, true); } catch { }
        }
    }

    /// <summary>VAD 模型只在 GitHub release 有（ModelScope 仓库无单文件）</summary>
    private static async Task EnsureVadAsync(CancellationToken ct)
    {
        string dest = ModelPaths.VadModel;
        if (File.Exists(dest))
            return;
        string tmp = Path.Combine(Path.GetTempPath(), "silero_vad.onnx");
        await DownloadFileAsync(
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
            tmp, new Progress<ModelInstallProgress>(_ => { }), ct);
        File.Move(tmp, dest);
    }

    /// <summary>ModelScope 优先（国内快），失败回退 GitHub（与脚本一致）</summary>
    private static async Task DownloadTarballAsync(
        string name, string dest, IProgress<ModelInstallProgress> progress, CancellationToken ct)
    {
        string ms = $"https://modelscope.cn/models/csukuangfj/asr-models/resolve/master/{name}";
        string gh = $"https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{name}";
        try
        {
            await DownloadFileAsync(ms, dest, progress, ct);
        }
        catch (Exception e) when (e is HttpRequestException or WebException or TaskCanceledException)
        {
            if (File.Exists(dest))
                File.Delete(dest);
            await DownloadFileAsync(gh, dest, progress, ct);
        }
    }

    private static async Task DownloadFileAsync(
        string url, string dest, IProgress<ModelInstallProgress> progress, CancellationToken ct)
    {
        using HttpResponseMessage response = await Http.GetAsync(
            url, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();
        long? total = response.Content.Headers.ContentLength;
        await using Stream source = await response.Content.ReadAsStreamAsync(ct);
        await using FileStream file = File.Create(dest);
        var buffer = new byte[1 << 16];
        long copied = 0;
        double reported = -1;
        int read;
        while ((read = await source.ReadAsync(buffer, ct)) > 0)
        {
            await file.WriteAsync(buffer.AsMemory(0, read), ct);
            copied += read;
            // 每 64KB 都上报会把进度回调刷进 UI 调度队列：至少跨 0.5% 才报一次
            if (total is > 0 && (double)copied / total.Value - reported >= 0.005)
            {
                reported = (double)copied / total.Value;
                progress.Report(new("下载中", reported));
            }
        }
        progress.Report(total is > 0
            ? new("下载完成", 1.0)
            : new($"下载完成（{(double)copied / 1024 / 1024:F0} MB）", null));
    }

    /// <summary>tar.bz2 用系统自带 tar.exe 解压（Windows 10 1803+，脚本同款依赖）</summary>
    private static void ExtractTarBz2(string tarball, string extractDir)
    {
        if (Directory.Exists(extractDir))
            Directory.Delete(extractDir, true);
        Directory.CreateDirectory(extractDir);
        string tar = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "tar.exe");
        using var process = Process.Start(new ProcessStartInfo(tar, $"-xjf \"{tarball}\" -C \"{extractDir}\"")
        {
            CreateNoWindow = true,
            UseShellExecute = false,
            RedirectStandardError = true,
        }) ?? throw new IOException("无法启动 tar.exe");
        string stderr = process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0)
            throw new IOException($"解压失败：{stderr.Trim()}");
    }

    /// <summary>删除某档位的模型文件（VAD 等公共组件不动）。调用前须先卸载已加载的该模型。</summary>
    public static void Delete(LocalAsrModel model)
    {
        string dir = model switch
        {
            LocalAsrModel.FunasrNano => ModelPaths.FunasrDir,
            LocalAsrModel.Qwen3Asr => ModelPaths.Qwen3Dir,
            LocalAsrModel.FireRedCtc => ModelPaths.FireRedDir,
            _ => "",
        };
        if (dir.Length > 0)
        {
            if (Directory.Exists(dir))
                Directory.Delete(dir, recursive: true);
            return;
        }
        if (model == LocalAsrModel.SenseVoice)
        {
            foreach (string name in new[] { "model.int8.onnx", "tokens.txt" })
            {
                string path = Path.Combine(ModelPaths.ModelsDir, name);
                if (File.Exists(path))
                    File.Delete(path);
            }
        }
    }

    public static void DeleteDiarization()
    {
        foreach (string path in new[] { ModelPaths.SegmentationModel, ModelPaths.SpeakerEmbeddingModel })
        {
            if (File.Exists(path))
                File.Delete(path);
        }
    }
}
