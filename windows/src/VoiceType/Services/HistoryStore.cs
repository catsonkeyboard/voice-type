using System.Text.Json;
using VoiceType.Models;

namespace VoiceType.Services;

/// <summary>
/// 转写历史（对应 macOS HistoryStore/SwiftData）。上限 200 条，JSON 落盘。
/// 线程安全：所有操作持锁（UI 与后台完成回调都会写）。
/// </summary>
public sealed class HistoryStore
{
    public const int MaxRecords = 200;

    private static readonly JsonSerializerOptions JsonOpts = new() { WriteIndented = true };

    private readonly string _path;
    private readonly object _lock = new();
    private List<TranscriptRecord> _records;

    public HistoryStore(string? path = null)
    {
        _path = path ?? DefaultPath();
        _records = Load(_path);
    }

    public static string DefaultPath() =>
        Path.Combine(ModelPaths.AppDataRoot, "history.json");

    private static List<TranscriptRecord> Load(string path)
    {
        try
        {
            if (File.Exists(path))
                return JsonSerializer.Deserialize<List<TranscriptRecord>>(
                    File.ReadAllText(path), JsonOpts) ?? [];
        }
        catch
        {
            // 损坏文件按空历史启动
        }
        return [];
    }

    private void SaveLocked()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(_records, JsonOpts));
        }
        catch
        {
            // 写盘失败不致命
        }
    }

    public void Add(string text, double durationSeconds, string source, string? rawText = null)
    {
        lock (_lock)
        {
            _records.Insert(0, new TranscriptRecord
            {
                Text = text,
                CreatedAt = DateTime.Now,
                DurationSeconds = durationSeconds,
                Source = source,
                RawText = rawText,
            });
            if (_records.Count > MaxRecords)
                _records.RemoveRange(MaxRecords, _records.Count - MaxRecords);
            SaveLocked();
        }
    }

    public List<TranscriptRecord> Recent(int limit = 50)
    {
        lock (_lock)
            return _records.Take(limit).Select(r => r).ToList();
    }

    public void Delete(Guid id)
    {
        lock (_lock)
        {
            _records.RemoveAll(r => r.Id == id);
            SaveLocked();
        }
    }

    public void Clear()
    {
        lock (_lock)
        {
            _records.Clear();
            SaveLocked();
        }
    }
}
