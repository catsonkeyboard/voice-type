using System.Net.WebSockets;
using System.Runtime.InteropServices;

namespace VoiceType.Services;

public enum DashScopeError
{
    NotConfigured,
    ConnectFailed,
    TaskFailed,
    Timeout,
}

public sealed class DashScopeException : Exception
{
    public DashScopeError Kind { get; }

    public DashScopeException(DashScopeError kind, string message) : base(message) =>
        Kind = kind;

    public static string Describe(DashScopeError kind, string detail) => kind switch
    {
        DashScopeError.NotConfigured => "未配置 DashScope API Key",
        DashScopeError.ConnectFailed => $"云端连接失败：{detail}",
        DashScopeError.TaskFailed => $"云端识别失败：{detail}",
        DashScopeError.Timeout => "云端识别超时",
        _ => detail,
    };
}

/// <summary>
/// Fun-ASR-Realtime WebSocket 会话（一次听写一个实例）。
/// 生命周期：StartAsync() → Send(samples)... → FinishAsync() -> 终稿；任何失败由调用方回退本地。
/// 音频在 task-started 之前自动缓冲，之后按 ~100ms 帧推送。
/// </summary>
public sealed class DashScopeAsrSession : IDisposable
{
    private const int FrameSamples = 1600;  // 100ms @16kHz
    private static readonly TimeSpan StartTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan FinishTimeout = TimeSpan.FromSeconds(15);

    public Action<string>? OnPartial { get; set; }

    private readonly string _apiKey;
    private readonly string _model;
    private readonly Uri _endpoint;
    private readonly string _taskId = DashScopeAsr.NewTaskId();

    private readonly object _lock = new();
    private ClientWebSocket? _socket;
    private SentenceAssembler _assembler = new();
    private List<float> _pending = [];
    private volatile bool _started;
    private TaskCompletionSource _startedTcs =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private TaskCompletionSource<string> _finishTcs =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private CancellationTokenSource? _startTimeoutCts;
    private CancellationTokenSource? _finishTimeoutCts;
    private Task? _receiveLoop;

    public DashScopeAsrSession(string apiKey, string model, string? endpoint = null)
    {
        _apiKey = apiKey;
        _model = model;
        _endpoint = new Uri(endpoint ?? DashScopeAsr.DefaultEndpoint);
    }

    /// <summary>建连 + run-task，等待 task-started（5 秒超时）</summary>
    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_apiKey.Length == 0)
            throw new DashScopeException(DashScopeError.NotConfigured, "未配置 API Key");
        var socket = new ClientWebSocket();
        socket.Options.SetRequestHeader("Authorization", $"Bearer {_apiKey}");
        try
        {
            await socket.ConnectAsync(_endpoint, ct);
        }
        catch (Exception e)
        {
            socket.Dispose();
            throw new DashScopeException(
                DashScopeError.ConnectFailed, DashScopeException.Describe(DashScopeError.ConnectFailed, e.Message));
        }
        _socket = socket;
        _receiveLoop = Task.Run(() => ReceiveLoopAsync());

        await SendTextAsync(DashScopeAsr.RunTaskMessage(_taskId, _model), ct);

        _startTimeoutCts = new CancellationTokenSource(StartTimeout);
        CancellationTokenRegistration reg =
            _startTimeoutCts.Token.Register(() => ResumeStarted(
                new DashScopeException(DashScopeError.Timeout,
                    DashScopeException.Describe(DashScopeError.Timeout, ""))));
        try
        {
            await _startedTcs.Task.WaitAsync(ct);
        }
        finally
        {
            reg.Dispose();
            _startTimeoutCts.Dispose();
            _startTimeoutCts = null;
        }
    }

    /// <summary>追加音频；内部攒满 ~100ms 且任务已启动时发送二进制帧</summary>
    public void Send(ReadOnlySpan<float> samples)
    {
        byte[]? frame = null;
        lock (_lock)
        {
            _pending.AddRange(samples);
            if (_started && _pending.Count >= FrameSamples)
            {
                frame = DashScopeAsr.Pcm16Data(CollectionsMarshal.AsSpan(_pending));
                _pending.Clear();
            }
        }
        if (frame is not null)
            _ = SendBytesAsync(frame);
    }

    /// <summary>冲刷缓冲 + finish-task，等待 task-finished（15 秒超时），返回终稿</summary>
    public async Task<string> FinishAsync(CancellationToken ct = default)
    {
        byte[]? rest;
        lock (_lock)
        {
            rest = _pending.Count > 0 ? DashScopeAsr.Pcm16Data(CollectionsMarshal.AsSpan(_pending)) : null;
            _pending.Clear();
        }
        if (rest is not null)
            await SendBytesAsync(rest, ct);
        await SendTextAsync(DashScopeAsr.FinishTaskMessage(_taskId), ct);

        _finishTimeoutCts = new CancellationTokenSource(FinishTimeout);
        CancellationTokenRegistration reg =
            _finishTimeoutCts.Token.Register(() => ResumeFinish(
                new DashScopeException(DashScopeError.Timeout,
                    DashScopeException.Describe(DashScopeError.Timeout, ""))));
        try
        {
            return await _finishTcs.Task.WaitAsync(ct);
        }
        finally
        {
            reg.Dispose();
            _finishTimeoutCts.Dispose();
            _finishTimeoutCts = null;
        }
    }

    /// <summary>放弃会话（回退/取消路径）</summary>
    public void Cancel()
    {
        TryClose(WebSocketCloseStatus.NormalClosure);
        FailAll(new OperationCanceledException("DashScope 会话已取消"));
    }

    public void Dispose() => Cancel();

    // ----- 私有 -----

    private async Task ReceiveLoopAsync()
    {
        ClientWebSocket? socket = _socket;
        if (socket is null)
            return;
        var buffer = new byte[64 * 1024];
        try
        {
            while (socket.State == WebSocketState.Open)
            {
                WebSocketReceiveResult result;
                using var message = new MemoryStream();
                do
                {
                    result = await socket.ReceiveAsync(
                        new ArraySegment<byte>(buffer), CancellationToken.None);
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        FailAll(new DashScopeException(
                            DashScopeError.ConnectFailed, "服务端关闭了连接"));
                        return;
                    }
                    message.Write(buffer, 0, result.Count);
                } while (!result.EndOfMessage);

                if (result.MessageType != WebSocketMessageType.Text)
                    continue;
                string text;
                try
                {
                    text = System.Text.Encoding.UTF8.GetString(message.ToArray());
                }
                catch
                {
                    continue;
                }
                Handle(DashScopeAsr.ParseEvent(text));
            }
        }
        catch (Exception e)
        {
            FailAll(new DashScopeException(
                DashScopeError.ConnectFailed,
                DashScopeException.Describe(DashScopeError.ConnectFailed, e.Message)));
        }
    }

    private void Handle(DashScopeAsr.ServerEvent evt)
    {
        switch (evt.Kind)
        {
            case DashScopeAsr.ServerEventKind.TaskStarted:
                bool flushNeeded;
                lock (_lock)
                {
                    _started = true;
                    flushNeeded = _pending.Count >= FrameSamples;
                }
                ResumeStarted(null);
                if (flushNeeded)
                    Send([]);
                break;
            case DashScopeAsr.ServerEventKind.ResultGenerated:
                string live;
                lock (_lock)
                {
                    _assembler.Ingest(evt.Sentence);
                    live = _assembler.LiveText;
                }
                OnPartial?.Invoke(live);
                break;
            case DashScopeAsr.ServerEventKind.TaskFinished:
                string final;
                lock (_lock)
                    final = _assembler.FinalText;
                ResumeFinish(null, final);
                TryClose(WebSocketCloseStatus.NormalClosure);
                break;
            case DashScopeAsr.ServerEventKind.TaskFailed:
                FailAll(new DashScopeException(
                    DashScopeError.TaskFailed,
                    DashScopeException.Describe(DashScopeError.TaskFailed, $"{evt.Code}: {evt.Message}")));
                break;
            case DashScopeAsr.ServerEventKind.Unknown:
            default:
                break;
        }
    }

    private async Task SendTextAsync(string message, CancellationToken ct = default)
    {
        ClientWebSocket? socket = _socket;
        if (socket is null || socket.State != WebSocketState.Open)
            return;
        try
        {
            await socket.SendAsync(
                new ArraySegment<byte>(System.Text.Encoding.UTF8.GetBytes(message)),
                WebSocketMessageType.Text, true, ct);
        }
        catch (Exception e)
        {
            FailAll(new DashScopeException(
                DashScopeError.ConnectFailed,
                DashScopeException.Describe(DashScopeError.ConnectFailed, e.Message)));
        }
    }

    private Task SendBytesAsync(byte[] data, CancellationToken ct = default)
    {
        ClientWebSocket? socket = _socket;
        if (socket is null || socket.State != WebSocketState.Open)
            return Task.CompletedTask;
        return socket.SendAsync(new ArraySegment<byte>(data),
            WebSocketMessageType.Binary, true, ct);
    }

    private void TryClose(WebSocketCloseStatus status)
    {
        ClientWebSocket? socket = _socket;
        if (socket is not null && socket.State == WebSocketState.Open)
            _ = socket.CloseAsync(status, null, CancellationToken.None);
    }

    /// <summary>恢复 TCS（exactly-once：取出即置换）</summary>
    private void ResumeStarted(Exception? error)
    {
        TaskCompletionSource tcs = Interlocked.Exchange(
            ref _startedTcs, new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously));
        if (error is null)
            tcs.TrySetResult();
        else
            tcs.TrySetException(error);
    }

    private void ResumeFinish(Exception? error, string? text = null)
    {
        TaskCompletionSource<string> tcs = Interlocked.Exchange(
            ref _finishTcs,
            new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously));
        if (error is null)
            tcs.TrySetResult(text ?? "");
        else
            tcs.TrySetException(error);
    }

    private void FailAll(Exception error)
    {
        ResumeStarted(error);
        ResumeFinish(error);
    }
}
