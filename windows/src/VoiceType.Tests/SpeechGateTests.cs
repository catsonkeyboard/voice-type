using VoiceType.Services;
using Xunit;

namespace VoiceType.Tests;

public class SpeechGateTests
{
    private const int Rate = 16000;

    /// <summary><paramref name="seconds"/> 秒的静音</summary>
    private static float[] Silence(double seconds) => new float[(int)(seconds * Rate)];

    /// <summary>在 <paramref name="samples"/> 的 <paramref name="start"/> 秒处写入一段
    /// <paramref name="seconds"/> 秒、幅度 <paramref name="amplitude"/> 的 220 Hz 正弦（模拟人声能量）</summary>
    private static void Tone(float[] samples, double start, double seconds, float amplitude)
    {
        int from = (int)(start * Rate);
        int count = (int)(seconds * Rate);
        for (int i = 0; i < count && from + i < samples.Length; i++)
            samples[from + i] = amplitude * MathF.Sin(2 * MathF.PI * 220 * i / Rate);
    }

    /// <summary>确定性的弱噪声（线性同余），幅度不超过 <paramref name="amplitude"/></summary>
    private static float[] Noise(double seconds, float amplitude)
    {
        uint state = 12345;
        var samples = new float[(int)(seconds * Rate)];
        for (int i = 0; i < samples.Length; i++)
        {
            state = state * 1_103_515_245u + 12345u;
            samples[i] = ((state >> 16 & 0x7FFF) / 32767f * 2 - 1) * amplitude;
        }
        return samples;
    }

    [Fact]
    public void SilenceAndFaintNoise_HaveNoSpeech()
    {
        Assert.False(SpeechGate.HasSpeech(Silence(1)));
        Assert.False(SpeechGate.HasSpeech(Noise(1, 0.004f)));
    }

    [Fact]
    public void KeyClick_IsNotSpeech()
    {
        // 按键声：一声 30 ms 的短促响动
        float[] samples = Silence(1);
        Tone(samples, 0.4, 0.03, 0.3f);
        Assert.False(SpeechGate.HasSpeech(samples));
    }

    [Fact]
    public void ShortBurstBelowTheMinimum_IsNotSpeech()
    {
        float[] samples = Silence(1);
        Tone(samples, 0.3, 0.12, 0.1f);
        Assert.False(SpeechGate.HasSpeech(samples));
    }

    [Fact]
    public void ExactlyTheMinimumRun_IsSpeech()
    {
        // 0.3 秒处对齐帧边界：0.15 秒正好 5 帧
        float[] samples = Silence(1);
        Tone(samples, 0.3, 0.15, 0.1f);
        Assert.True(SpeechGate.HasSpeech(samples));
    }

    [Fact]
    public void TwoClicksApart_AreNotSpeech()
    {
        // 连按两下：两团按键声各 3 帧，中间隔开，不能加起来算人声
        float[] samples = Silence(1);
        Tone(samples, 0.2, 0.09, 0.3f);
        Tone(samples, 0.5, 0.09, 0.3f);
        Assert.False(SpeechGate.HasSpeech(samples));
    }

    [Fact]
    public void ClickAtTheVeryEnd_IsIgnored()
    {
        // 结束录音时的按键声落在最后 0.15 秒
        float[] samples = Silence(1);
        Tone(samples, 0.86, 0.14, 0.3f);
        Assert.False(SpeechGate.HasSpeech(samples));
    }

    [Fact]
    public void SyllablesWithAShortPause_CountAsOneRun()
    {
        // 两个音节各 3 帧，中间停 1 帧
        float[] samples = Silence(1);
        Tone(samples, 0.3, 0.09, 0.1f);
        Tone(samples, 0.42, 0.09, 0.1f);
        Assert.True(SpeechGate.HasSpeech(samples));
    }

    [Fact]
    public void EmptyRecording_HasNoSpeech()
    {
        Assert.False(SpeechGate.HasSpeech(Array.Empty<float>()));
        Assert.Equal(new SpeechGate.Analysis(0, 0), SpeechGate.Analyze(Array.Empty<float>()));
    }

    [Fact]
    public void ShortWord_IsSpeech()
    {
        // 一个字（「好」）大约 0.2–0.3 秒
        float[] samples = Silence(1);
        Tone(samples, 0.3, 0.25, 0.05f);
        Assert.True(SpeechGate.HasSpeech(samples));
    }

    [Fact]
    public void SpeechOverFaintNoise_IsSpeech()
    {
        float[] samples = Noise(2, 0.004f);
        Tone(samples, 0.5, 0.8, 0.08f);
        Assert.True(SpeechGate.HasSpeech(samples));
    }

    [Fact]
    public void FeedingInChunks_MatchesAnalyzingAtOnce()
    {
        float[] samples = Noise(2, 0.004f);
        Tone(samples, 0.5, 0.4, 0.08f);
        Tone(samples, 1.2, 0.1, 0.3f);
        var tracker = new SpeechGate.Tracker();
        int offset = 0;
        foreach (int size in new[] { 100, 1000, 333, 4096, 7 })
        {
            if (offset >= samples.Length)
                break;
            int end = Math.Min(offset + size, samples.Length);
            tracker.Feed(samples[offset..end]);
            offset = end;
        }
        tracker.Feed(samples[offset..]);
        tracker.Finish();
        // 对照组补上结尾静音：Analyze 会忽略最后 0.15 秒
        float[] withTail = [.. samples, .. Silence(SpeechGate.TailIgnoredSeconds)];
        Assert.Equal(SpeechGate.Analyze(withTail), tracker.Analysis);
    }

    [Fact]
    public void NobodySpeaksForThirtySeconds_AutoEnds()
    {
        var tracker = new SpeechGate.Tracker();
        tracker.Feed(Noise(29.9, 0.004f));
        Assert.Equal(SpeechGate.WatchResult.KeepGoing, SpeechGate.Watch(tracker));
        tracker.Feed(Noise(0.2, 0.004f));
        Assert.Equal(SpeechGate.WatchResult.NoSpeech, SpeechGate.Watch(tracker));
    }

    [Fact]
    public void QuietForFifteenSecondsAfterSpeaking_AutoEnds()
    {
        float[] speech = Silence(1);
        Tone(speech, 0.2, 0.6, 0.08f);
        var tracker = new SpeechGate.Tracker();
        tracker.Feed(speech);
        tracker.Feed(Noise(14.5, 0.004f));
        // 说完 0.2 秒 + 14.5 秒，还不到 15 秒
        Assert.Equal(SpeechGate.WatchResult.KeepGoing, SpeechGate.Watch(tracker));
        tracker.Feed(Noise(0.5, 0.004f));
        Assert.Equal(SpeechGate.WatchResult.WentQuiet, SpeechGate.Watch(tracker));
    }

    [Fact]
    public void PauseShorterThanFifteenSeconds_KeepsRecording()
    {
        var tracker = new SpeechGate.Tracker();
        float[] first = Silence(1);
        Tone(first, 0.2, 0.6, 0.08f);
        tracker.Feed(first);
        tracker.Feed(Silence(10));
        float[] second = Silence(1);
        Tone(second, 0.1, 0.6, 0.08f);
        tracker.Feed(second);
        tracker.Feed(Silence(10));
        Assert.Equal(SpeechGate.WatchResult.KeepGoing, SpeechGate.Watch(tracker));
    }

    [Fact]
    public void DigitalSilence_MeansTheMicrophoneWasBlocked()
    {
        // 2026-10-23 实测：录音中途被撤销麦克风授权后，系统送来的是全 0
        Assert.True(SpeechGate.IsDigitalSilence(Silence(1)));
        Assert.False(SpeechGate.IsDigitalSilence(Array.Empty<float>()));
        Assert.False(SpeechGate.IsDigitalSilence(Noise(1, 0.0005f)));
        float[] almost = Silence(1);
        almost[8000] = 0.0001f;
        Assert.False(SpeechGate.IsDigitalSilence(almost));
    }

    [Fact]
    public void StripSilenceTokens_RemovesMarkers()
    {
        Assert.Equal("", SpeechGate.StripSilenceTokens("/sil"));
        Assert.Equal("", SpeechGate.StripSilenceTokens(" /sil "));
        Assert.Equal("你好", SpeechGate.StripSilenceTokens("你好 /sil"));
        Assert.Equal("好的", SpeechGate.StripSilenceTokens("<sil>好的"));
        Assert.Equal("明天见", SpeechGate.StripSilenceTokens("[SIL] 明天见"));
        Assert.Equal("你好", SpeechGate.StripSilenceTokens("/sil你好"));
    }

    [Fact]
    public void OnlyPunctuationLeft_CountsAsNothingSaid()
    {
        Assert.Equal("", SpeechGate.StripSilenceTokens("/sil。"));
        Assert.Equal("", SpeechGate.StripSilenceTokens("/sil."));
        Assert.Equal("", SpeechGate.StripSilenceTokens("。"));
        Assert.Equal("好。", SpeechGate.StripSilenceTokens("好。"));
    }

    [Fact]
    public void WordsThatOnlyContainSil_AreKept()
    {
        Assert.Equal("silver /silent", SpeechGate.StripSilenceTokens("silver /silent"));
        Assert.Equal("帮我打开 silo", SpeechGate.StripSilenceTokens("帮我打开 silo"));
    }
}
