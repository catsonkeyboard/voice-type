using System.Text.RegularExpressions;

namespace VoiceType.Services;

/// <summary>
/// 听写的人声把关。
///
/// 识别模型面对纯噪音会「幻听」：连按两下说话键、只录到按键声或底噪时，
/// 会识别出 `the`、`你。`、`/sil` 这类没人说过的文字（2026-10-23 实测）。
/// 所以识别前先看录音里有没有一段连续的人声；识别后再去掉漏出来的静音标记。
/// 录音过程中也用同一套判断：开头一直没人说话、或说完后长时间安静，就自动结束。
/// </summary>
public static class SpeechGate
{
    /// <summary>一帧 30 ms（16 kHz 下 480 个采样）</summary>
    public const double FrameSeconds = 0.03;
    /// <summary>音量（均方根）不低于这个值的帧才算有声音，约 −40 dBFS</summary>
    public const float VoicedLevel = 0.01f;
    /// <summary>连续有声音至少这么长才算有人说话。一声按键只有一两帧，一个字也有 0.2 秒以上</summary>
    public const double MinVoicedSeconds = 0.15;
    /// <summary>连续段里允许夹这么多帧安静（字与字之间的短停顿）</summary>
    public const int HangoverFrames = 1;
    /// <summary>录完后判断时不看最后这一段：结束录音时按快捷键的按键声落在这里</summary>
    public const double TailIgnoredSeconds = 0.15;
    /// <summary>开头这么久一直没有人声，就自动结束录音（用户 2026-10-23 选定 30 秒）</summary>
    public const double NoSpeechTimeoutSeconds = 30.0;
    /// <summary>说过话之后连续安静这么久，就当作说完了，自动结束录音（用户 2026-10-23 选定 15 秒）</summary>
    public const double TrailingSilenceSeconds = 15.0;

    /// <summary>一段录音的人声情况，被挡掉时写进日志（只有数字，不含内容）</summary>
    public readonly record struct Analysis(double LongestRunSeconds, float PeakLevel)
    {
        /// <summary>最长的连续有声段够不够长</summary>
        public bool HasSpeech => LongestRunSeconds >= MinVoicedSeconds - 1e-9;
    }

    /// <summary>逐帧跟踪人声，可以一块块喂（录音过程中），也可以一次喂完（录音结束后）</summary>
    public sealed class Tracker
    {
        private readonly int _frameSize;
        /// <summary>还凑不满一帧的采样，等下一块来了再算</summary>
        private readonly float[] _pending;
        private int _pendingCount;
        private int _frames;
        private int _run;
        private int _gap;
        private int _longestRun;
        private float _peak;
        /// <summary>最近一个有声帧结束时的帧数</summary>
        private int _lastVoicedFrameEnd;

        public Tracker(int sampleRate = 16000)
        {
            _frameSize = Math.Max(1, (int)(FrameSeconds * sampleRate));
            _pending = new float[_frameSize];
        }

        public void Feed(ReadOnlySpan<float> samples)
        {
            ReadOnlySpan<float> rest = samples;
            if (_pendingCount > 0)
            {
                int take = Math.Min(_frameSize - _pendingCount, rest.Length);
                rest[..take].CopyTo(_pending.AsSpan(_pendingCount));
                _pendingCount += take;
                rest = rest[take..];
                if (_pendingCount != _frameSize)
                    return;
                Measure(_pending);
                _pendingCount = 0;
            }
            while (rest.Length >= _frameSize)
            {
                Measure(rest[.._frameSize]);
                rest = rest[_frameSize..];
            }
            rest.CopyTo(_pending.AsSpan(_pendingCount));
            _pendingCount += rest.Length;
        }

        /// <summary>录音结束：最后不满一帧的部分也算一帧</summary>
        public void Finish()
        {
            if (_pendingCount == 0)
                return;
            Measure(_pending.AsSpan(0, _pendingCount));
            _pendingCount = 0;
        }

        private void Measure(ReadOnlySpan<float> frame)
        {
            float sum = 0;
            foreach (float v in frame)
                sum += v * v;
            float level = MathF.Sqrt(sum / frame.Length);
            _peak = MathF.Max(_peak, level);
            _frames++;
            if (level >= VoicedLevel)
            {
                // 段内的短停顿算进这一段
                if (_run > 0)
                    _run += _gap;
                _run++;
                _gap = 0;
                _longestRun = Math.Max(_longestRun, _run);
                _lastVoicedFrameEnd = _frames;
            }
            else if (_run > 0)
            {
                _gap++;
                if (_gap > HangoverFrames)
                {
                    _run = 0;
                    _gap = 0;
                }
            }
        }

        public Analysis Analysis => new(_longestRun * FrameSeconds, _peak);

        /// <summary>已经录了多久（只算完整的帧）</summary>
        public double ElapsedSeconds => _frames * FrameSeconds;

        /// <summary>最后一次有声音之后又过了多久</summary>
        public double QuietSeconds => (_frames - _lastVoicedFrameEnd) * FrameSeconds;
    }

    /// <summary>录音过程中该不该自动结束</summary>
    public enum WatchResult
    {
        KeepGoing,
        /// <summary>开头一直没有人声</summary>
        NoSpeech,
        /// <summary>说过话之后安静了很久</summary>
        WentQuiet,
    }

    /// <summary>纯函数：根据目前录到的内容，判断录音该不该自动结束</summary>
    public static WatchResult Watch(Tracker tracker)
    {
        if (!tracker.Analysis.HasSpeech)
        {
            return tracker.ElapsedSeconds >= NoSpeechTimeoutSeconds
                ? WatchResult.NoSpeech
                : WatchResult.KeepGoing;
        }
        return tracker.QuietSeconds >= TrailingSilenceSeconds
            ? WatchResult.WentQuiet
            : WatchResult.KeepGoing;
    }

    /// <summary>纯函数：录完后逐帧算音量，找出最长的连续有声段（忽略结尾的按键声）</summary>
    public static Analysis Analyze(ReadOnlySpan<float> samples, int sampleRate = 16000)
    {
        int usable = Math.Max(0, samples.Length - (int)(TailIgnoredSeconds * sampleRate));
        var tracker = new Tracker(sampleRate);
        tracker.Feed(samples[..usable]);
        tracker.Finish();
        return tracker.Analysis;
    }

    /// <summary>
    /// 纯函数：整段都是绝对的 0。真实麦克风总有底噪，这只会是麦克风被系统拦下了
    /// （运行中被撤销了授权，或设备被静音），不是没说话
    /// </summary>
    public static bool IsDigitalSilence(ReadOnlySpan<float> samples)
    {
        if (samples.Length == 0)
            return false;
        foreach (float s in samples)
        {
            if (s != 0f)
                return false;
        }
        return true;
    }

    /// <summary>纯函数：录音里有没有足够长的连续人声</summary>
    public static bool HasSpeech(ReadOnlySpan<float> samples, int sampleRate = 16000) =>
        Analyze(samples, sampleRate).HasSpeech;

    /// <summary>识别结果里可能漏出的静音标记：`/sil`、`&lt;sil&gt;`、`[sil]`（不分大小写）。
    /// 后面紧跟中文或标点也算；`/silent`、`silver` 这类英文单词不受影响。</summary>
    private static readonly Regex SilenceToken =
        new(@"(?i)(?:/sil(?![A-Za-z0-9_])|<sil>|\[sil\])", RegexOptions.Compiled);
    private static readonly Regex ExtraSpaces = new(" {2,}", RegexOptions.Compiled);

    /// <summary>纯函数：去掉静音标记，收拢因此多出的空格、去掉首尾空白；只剩标点时返回空串</summary>
    public static string StripSilenceTokens(string text)
    {
        string removed = SilenceToken.Replace(text, "");
        string collapsed = ExtraSpaces.Replace(removed, " ");
        string trimmed = collapsed.Trim();
        bool meaningful = trimmed.Any(c =>
            !char.IsPunctuation(c) && !char.IsSymbol(c) && !char.IsWhiteSpace(c));
        return meaningful ? trimmed : "";
    }
}
