using System.IO;

namespace VoiceType.Services;

/// <summary>
/// 简单追加式启动/异常日志：诊断托盘应用「看起来没启动」这类静默失败。
/// 只记事件行，永不抛出；文件 %APPDATA%\VoiceType\logs\app.log，按天滚动。
/// </summary>
public static class DiagnosticsLog
{
    private static readonly object Lock = new();

    public static void Write(string message)
    {
        try
        {
            string dir = Path.Combine(ModelPaths.AppDataRoot, "logs");
            Directory.CreateDirectory(dir);
            string path = Path.Combine(dir, $"app-{DateTime.Now:yyyyMMdd}.log");
            lock (Lock)
            {
                File.AppendAllText(path, $"{DateTime.Now:HH:mm:ss.fff} {message}\n");
            }
        }
        catch
        {
            // 日志失败不能再打扰应用本身
        }
    }

    /// <summary>记录异常（含类型与消息，不记堆栈里的用户数据）</summary>
    public static void Write(string context, Exception e) =>
        Write($"{context}: {e.GetType().Name} {e.Message}");
}
