using System.Runtime.InteropServices;
using NAudio.Wave;

namespace VoiceType.Services;

public sealed class AudioDecodeException : Exception
{
    public AudioDecodeException(string message) : base(message) { }
}

/// <summary>
/// 解码任意 Media Foundation 支持的音频文件（wav/mp3/m4a/wma/aac…）
/// 为 16kHz 单声道 Float32（对应 macOS AVAudioFile + AVAudioConverter）。
/// </summary>
public static class AudioFileDecoder
{
    public static float[] Decode16kMono(string path)
    {
        MediaFoundationReader reader;
        try
        {
            reader = new MediaFoundationReader(path);
        }
        catch (Exception e)
        {
            throw new AudioDecodeException($"不支持的音频格式或无法读取文件：{e.Message}");
        }
        using (reader)
        using (var resampler = new MediaFoundationResampler(
            reader, WaveFormat.CreateIeeeFloatWaveFormat(16000, 1))
        {
            ResamplerQuality = 60,
        })
        {
            var result = new List<float>(1 << 16);
            var buffer = new byte[1 << 16];
            int read;
            while ((read = resampler.Read(buffer)) > 0)
            {
                int floatCount = read / 4;
                var floats = new float[floatCount];
                System.Buffer.BlockCopy(buffer, 0, floats, 0, read);
                result.AddRange(floats);
            }
            return [.. result];
        }
    }
}
