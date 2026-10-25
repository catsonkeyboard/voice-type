using System.Text;

namespace VoiceType.Services;

/// <summary>
/// 第三方应用联动协议（v6）的纯逻辑：请求解析、回调地址校验、请求该做什么、回传 URL。
/// 第三方应用用 voicetype:// 发起听写，并在 callback 参数里给出自己的回调地址；
/// VoiceType 把结果经这个回调地址回传。某个回调地址第一次使用时要用户在弹窗里允许。
/// 收 URL 的两端在 App.xaml.cs（scheme 注册 + 单实例管道转发），授权弹窗在 UI/BridgePermissionPrompt.cs。
/// 与 macOS AppBridge.swift 对齐；差异：Windows 录音启动是同步调用（无麦克风授权等待），
/// 不存在「启动期间收到结束/取消」的窗口，故无 PendingEnd。
/// </summary>
public static class AppBridge
{
}

/// <summary>一次听写的输出去向</summary>
public abstract record DictationTarget
{
    /// <summary>现状：注入前台应用光标处</summary>
    public sealed record CursorCase : DictationTarget;

    /// <summary>第三方应用发起：回传给 Callback，不写剪贴板、不模拟 Ctrl+V</summary>
    public sealed record External(string Session, string Callback) : DictationTarget;

    public static readonly DictationTarget Cursor = new CursorCase();

    /// <summary>是不是第三方应用的这一次会话</summary>
    public bool IsExternal(string session) =>
        this is External external && external.Session == session;
}

/// <summary>没有文字可给时的原因（回传 URL 里的 error 参数）</summary>
public enum BridgeFailure
{
    /// <summary>没说话：录音太短，或只录到按键声、底噪（见 SpeechGate）</summary>
    Empty,
    MicDenied,
    /// <summary>本地模型没装，或云端引擎没填密钥</summary>
    NotReady,
    Busy,
    /// <summary>用户拒绝了这个应用使用 VoiceType 听写</summary>
    NotAllowed,
    Failed,
}

public static class BridgeFailureExtensions
{
    /// <summary>回传 URL 里的小写错误码</summary>
    public static string Code(this BridgeFailure failure) => failure switch
    {
        BridgeFailure.Empty => "empty",
        BridgeFailure.MicDenied => "mic_denied",
        BridgeFailure.NotReady => "not_ready",
        BridgeFailure.Busy => "busy",
        BridgeFailure.NotAllowed => "not_allowed",
        _ => "failed",
    };
}

/// <summary>回传给第三方应用的结果</summary>
public abstract record BridgeOutcome
{
    public sealed record WithText(string Text) : BridgeOutcome;

    public sealed record WithFailure(BridgeFailure Failure) : BridgeOutcome;
}

/// <summary>某个回调地址的授权状态</summary>
public enum BridgePermission
{
    /// <summary>还没问过用户</summary>
    Unknown,
    Allowed,
    Denied,
}

/// <summary>请求在当前状态下该做什么</summary>
public abstract record BridgeAction
{
    /// <summary>开始一次回传给第三方应用的录音</summary>
    public sealed record Start(string Session, string Callback) : BridgeAction;

    /// <summary>这个回调地址第一次出现：先问用户允不允许，再重新判定</summary>
    public sealed record AskPermission(string Session, string Callback) : BridgeAction;

    /// <summary>结束当前录音并识别</summary>
    public sealed record FinishCase : BridgeAction;

    /// <summary>丢弃当前录音，不回传</summary>
    public sealed record CancelCase : BridgeAction;

    /// <summary>录音已结束、正在识别的这次会话被取消：识别完不回传（结果照常进历史记录）</summary>
    public sealed record DropReplyCase : BridgeAction;

    /// <summary>不开始录音，立刻回传失败</summary>
    public sealed record Refuse(string Session, string Callback, BridgeFailure Reason)
        : BridgeAction;

    public sealed record IgnoreCase : BridgeAction;

    public static readonly BridgeAction Finish = new FinishCase();
    public static readonly BridgeAction Cancel = new CancelCase();
    public static readonly BridgeAction DropReply = new DropReplyCase();
    public static readonly BridgeAction Ignore = new IgnoreCase();
}

/// <summary>第三方应用发来的请求</summary>
public abstract record BridgeRequest
{
    public sealed record DictateCase(string Session, string Callback) : BridgeRequest;

    public sealed record StopCase(string Session) : BridgeRequest;

    public sealed record CancelCase(string Session) : BridgeRequest;

    /// <summary>只有 dictate 带回调地址（基类属性不与 DictateCase 的位置参数 Callback 同名，避免递归）</summary>
    public string? CallbackUrl => this is DictateCase dictate ? dictate.Callback : null;

    /// <summary>
    /// 解析 voicetype://dictate|stop|cancel?session=…[&amp;callback=…]；不合法返回 null。
    /// 手工解析而非 System.Uri：自定义 scheme 的 Host/UserInfo 各平台行为不一致，
    /// 且这里的语义（首次命中、百分号解码、host 小写化）要完全对齐 macOS URLComponents。
    /// </summary>
    public static BridgeRequest? Parse(string url)
    {
        int colon = url.IndexOf(':');
        if (colon <= 0 || url[..colon].ToLowerInvariant() != "voicetype")
            return null;
        string rest = url[(colon + 1)..];
        if (!rest.StartsWith("//", StringComparison.Ordinal))
            return null;
        string afterSlashes = rest[2..];
        // host 到 '/'、'?' 或 '#' 为止；查询/片段从 '?'（含）开始
        int hostEnd = afterSlashes.IndexOfAny(['/', '?', '#']);
        string host = hostEnd < 0 ? afterSlashes : afterSlashes[..hostEnd];
        if (host.Length == 0)
            return null;
        string? session = null, callbackRaw = null;
        int queryStart = afterSlashes.IndexOf('?');
        if (queryStart >= 0)
        {
            string query = afterSlashes[(queryStart + 1)..];
            int fragment = query.IndexOf('#');
            if (fragment >= 0)
                query = query[..fragment];
            foreach (string pair in query.Split('&'))
            {
                int eq = pair.IndexOf('=');
                if (eq < 0)
                    continue;
                string name = pair[..eq];
                string value = Uri.UnescapeDataString(pair[(eq + 1)..]);
                if (name == "session")
                    session ??= value;
                else if (name == "callback")
                    callbackRaw ??= value;
            }
        }
        if (session is null || !IsValidSession(session))
            return null;
        switch (host.ToLowerInvariant())
        {
            case "dictate":
                if (callbackRaw is null)
                    return null;
                string? callback = BridgeCallback.Validate(callbackRaw);
                return callback is null ? null : new DictateCase(session, callback);
            case "stop":
                return new StopCase(session);
            case "cancel":
                return new CancelCase(session);
            default:
                return null;
        }
    }

    /// <summary>session 由第三方应用生成：1–64 个字母、数字或连字符（按 UTF-8 字节算）</summary>
    public static bool IsValidSession(string session)
    {
        int bytes = Encoding.UTF8.GetByteCount(session);
        if (bytes < 1 || bytes > 64)
            return false;
        foreach (byte b in Encoding.UTF8.GetBytes(session))
        {
            bool ok = b is >= (byte)'0' and <= (byte)'9'
                or >= (byte)'A' and <= (byte)'Z'
                or >= (byte)'a' and <= (byte)'z'
                or (byte)'-';
            if (!ok)
                return false;
        }
        return true;
    }

    /// <summary>
    /// 纯函数：当前状态下这个请求该做什么。
    /// - idle：没有录音、识别、润色或授权弹窗在进行
    /// - recording：正在录音
    /// - meetingRecording：会议录音进行中
    /// - target：当前这次听写的去向
    /// - permission：dictate 的回调地址的授权状态（stop/cancel 不看）
    /// - transcribing：录音已结束、还在识别没回传的第三方会话（没有就是 null）
    /// </summary>
    public BridgeAction Action(
        bool idle, bool recording, bool meetingRecording, DictationTarget target,
        BridgePermission permission, string? transcribing = null)
    {
        switch (this)
        {
            case DictateCase dictate:
                // 已拒绝的应用不论忙不忙都回 not_allowed
                if (permission == BridgePermission.Denied)
                    return new BridgeAction.Refuse(
                        dictate.Session, dictate.Callback, BridgeFailure.NotAllowed);
                // 忙的时候不弹窗
                if (!(idle && !recording && !meetingRecording))
                    return new BridgeAction.Refuse(
                        dictate.Session, dictate.Callback, BridgeFailure.Busy);
                return permission == BridgePermission.Allowed
                    ? new BridgeAction.Start(dictate.Session, dictate.Callback)
                    : new BridgeAction.AskPermission(dictate.Session, dictate.Callback);
            case StopCase stop:
                return recording && target.IsExternal(stop.Session)
                    ? BridgeAction.Finish
                    : BridgeAction.Ignore;
            case CancelCase cancel:
                if (recording && target.IsExternal(cancel.Session))
                    return BridgeAction.Cancel;
                // 第三方应用在结果回来之前退出了：回传会把它重新拉起来，所以不回传
                return transcribing == cancel.Session
                    ? BridgeAction.DropReply
                    : BridgeAction.Ignore;
            default:
                return BridgeAction.Ignore;
        }
    }
}

/// <summary>回调地址的校验与回传 URL 的拼接</summary>
public static class BridgeCallback
{
    /// <summary>
    /// 不接受的 scheme：一旦允许，识别出的文字会被送进浏览器、文件或别的系统应用；
    /// voicetype 自己也不行（回传给自己会形成循环）
    /// </summary>
    public static readonly HashSet<string> BlockedSchemes = new(StringComparer.Ordinal)
    {
        "http", "https", "file", "ftp", "mailto", "sms", "tel", "facetime", "voicetype",
    };

    public const int MaxLength = 256;

    /// <summary>
    /// 第三方应用给的回调地址能不能用：自定义 scheme，不带查询、片段和用户信息，
    /// 不超过 256 字节。可用时返回 scheme 转成小写的地址（授权按这个地址记忆）。
    /// </summary>
    public static string? Validate(string raw)
    {
        if (raw.Length == 0 || Encoding.UTF8.GetByteCount(raw) > MaxLength)
            return null;
        // 回传要在后面拼 ?session=…：已有查询或片段会把参数弄乱
        if (raw.Contains('?') || raw.Contains('#'))
            return null;
        int colon = raw.IndexOf(':');
        if (colon <= 0)
            return null;
        string scheme = raw[..colon];
        if (!char.IsAsciiLetter(scheme[0]))
            return null;
        foreach (char c in scheme)
        {
            if (!char.IsAsciiLetterOrDigit(c) && c is not '+' and not '-' and not '.')
                return null;
        }
        scheme = scheme.ToLowerInvariant();
        if (BlockedSchemes.Contains(scheme))
            return null;
        // 用户信息（user:pass@host）：authority 是 // 之后、下一个 / 之前的部分
        if (colon + 2 < raw.Length && raw[colon + 1] == '/' && raw[colon + 2] == '/')
        {
            int pathStart = raw.IndexOf('/', colon + 3);
            string authority = pathStart < 0 ? raw[(colon + 3)..] : raw[(colon + 3)..pathStart];
            if (authority.Contains('@'))
                return null;
        }
        return scheme + raw[colon..];
    }

    /// <summary>
    /// 字母、数字和 -._~ 之外的字节全部百分号编码：空格是 %20，加号是 %2B，
    /// 接收方按表单规则解码（把 + 当空格）也不会出错
    /// </summary>
    public static string Encode(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (byte b in Encoding.UTF8.GetBytes(text))
        {
            if (b is >= (byte)'A' and <= (byte)'Z'
                or >= (byte)'a' and <= (byte)'z'
                or >= (byte)'0' and <= (byte)'9'
                or (byte)'-' or (byte)'.' or (byte)'_' or (byte)'~')
                sb.Append((char)b);
            else
                sb.Append('%').Append(b.ToString("X2"));
        }
        return sb.ToString();
    }

    /// <summary>&lt;callback&gt;?session=…&amp;text=… 或 …&amp;error=…</summary>
    public static string Url(string callback, string session, BridgeOutcome outcome)
    {
        string tail = outcome switch
        {
            BridgeOutcome.WithText text => "text=" + Encode(text.Text),
            BridgeOutcome.WithFailure failure => "error=" + failure.Failure.Code(),
            _ => "",
        };
        return $"{callback}?session={Encode(session)}&{tail}";
    }
}
