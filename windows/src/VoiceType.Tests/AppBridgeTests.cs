using VoiceType.Interop;
using VoiceType.Services;
using Xunit;

namespace VoiceType.Tests;

/// <summary>与 macOS AppBridgeTests.swift 对齐（除 PendingEnd：Windows 启动是同步的，无此机制）</summary>
public class AppBridgeTests
{
    private const string Callback = "testapp://voicetype-result";
    private const string EncodedCallback = "testapp%3A%2F%2Fvoicetype-result";

    private static BridgeRequest.DictateCase Dictate(string session = "abc123") =>
        new(session, Callback);

    // ----- 请求解析 -----

    [Fact]
    public void Parse_ParsesDictate()
    {
        Assert.Equal(
            Dictate(),
            BridgeRequest.Parse($"voicetype://dictate?session=abc123&callback={EncodedCallback}"));
    }

    [Fact]
    public void Parse_ParsesStopAndCancel()
    {
        Assert.Equal(
            new BridgeRequest.StopCase("abc123"),
            BridgeRequest.Parse("voicetype://stop?session=abc123"));
        Assert.Equal(
            new BridgeRequest.CancelCase("abc123"),
            BridgeRequest.Parse("voicetype://cancel?session=abc123"));
    }

    [Fact]
    public void Parse_DictateWithoutAUsableCallbackIsRejected()
    {
        Assert.Null(BridgeRequest.Parse("voicetype://dictate?session=abc123"));
        Assert.Null(BridgeRequest.Parse(
            "voicetype://dictate?session=abc123&callback=https%3A%2F%2Fexample.com%2F"));
    }

    [Fact]
    public void Parse_RejectsBadSessionsSchemesAndCommands()
    {
        Assert.Null(BridgeRequest.Parse("voicetype://stop"));
        Assert.Null(BridgeRequest.Parse("voicetype://stop?session="));
        Assert.Null(BridgeRequest.Parse("voicetype://stop?session=a%20b"));
        Assert.Null(BridgeRequest.Parse($"voicetype://stop?session={new string('a', 65)}"));
        Assert.Null(BridgeRequest.Parse("other://stop?session=abc123"));
        Assert.Null(BridgeRequest.Parse("voicetype://record?session=abc123"));
    }

    [Fact]
    public void Parse_AcceptsSessionsAtTheLimitsAndInTheUsualShapes()
    {
        foreach (string session in new[]
        {
            new string('a', 64),  // 长度上限
            "A-b-9",  // 大小写字母、连字符、数字
            "0123456789abcdef0123456789abcdef",  // 32 位十六进制
        })
        {
            Assert.Equal(
                new BridgeRequest.StopCase(session),
                BridgeRequest.Parse($"voicetype://stop?session={session}"));
        }
    }

    [Fact]
    public void Parse_RejectsASessionMadeOfMultiByteCharacters()
    {
        // 「你」是 3 个字节：长度在范围内，但不是字母、数字或连字符
        Assert.Null(BridgeRequest.Parse("voicetype://stop?session=%E4%BD%A0"));
        Assert.Null(BridgeRequest.Parse("voicetype://stop?session=ab%E4%BD%A0cd"));
    }

    // ----- 回调地址校验 -----

    [Fact]
    public void Validate_AcceptsCustomSchemeCallbacks()
    {
        foreach (string raw in new[]
        {
            "testapp://voicetype-result", "com.example.notes://dictation/result",
            "my-app+beta://cb", "notesapp:result",
        })
        {
            Assert.Equal(raw, BridgeCallback.Validate(raw));
        }
    }

    [Fact]
    public void Validate_CallbackSchemeIsLowercased()
    {
        // 授权按回调地址记忆：同一个地址不能因为 scheme 大小写不同变成两条
        Assert.Equal(
            "testapp://voicetype-result",
            BridgeCallback.Validate("TestApp://voicetype-result"));
    }

    [Fact]
    public void Validate_RejectsCallbacksThatWouldLeaveTheDeviceOrLoopBack()
    {
        // 网页、文件、邮件短信电话：一旦允许，识别出的文字会被送进浏览器或别的系统应用
        foreach (string raw in new[]
        {
            "http://example.com/cb", "https://example.com/cb", "HTTPS://example.com/cb",
            "file:///tmp/x", "ftp://example.com/", "mailto:a@example.com", "sms:10086",
            "tel:10086", "facetime:a@example.com", "voicetype://dictate",
        })
        {
            Assert.Null(BridgeCallback.Validate(raw));
        }
    }

    [Fact]
    public void Validate_RejectsMalformedCallbacks()
    {
        string tooLong = "testapp://" + new string('a', 250);
        foreach (string raw in new[]
        {
            "", "voicetype-result", "://x",
            "testapp://result?x=1",  // 回传要在后面拼 ?session=…，已有查询会弄乱参数
            "testapp://result#frag", "testapp://user:pass@host", tooLong,
        })
        {
            Assert.Null(BridgeCallback.Validate(raw));
        }
        Assert.NotNull(BridgeCallback.Validate("testapp://" + new string('a', 246)));
    }

    // ----- 回传 URL -----

    [Fact]
    public void Encode_LeavesUnreservedCharactersAlone()
    {
        Assert.Equal("a-b_c.d~e", BridgeCallback.Encode("a-b_c.d~e"));
    }

    [Fact]
    public void Url_EncodesText()
    {
        Assert.Equal(
            "testapp://voicetype-result?session=abc123&text=%E4%BD%A0%E5%A5%BD%20a%2Bb%26c%3Dd%23e%0A100%25",
            BridgeCallback.Url(
                Callback, "abc123", new BridgeOutcome.WithText("你好 a+b&c=d#e\n100%")));
    }

    [Fact]
    public void Url_RoundTripsThroughQueryDecoding()
    {
        // 接收方按查询参数解码后应得到原文
        string text = "明天上午 9 点 + 下午 3 点；50% & more = ok 😀";
        string url = BridgeCallback.Url(Callback, "abc123", new BridgeOutcome.WithText(text));
        Dictionary<string, string> items = ParseQuery(url);
        Assert.Equal(text, items["text"]);
        Assert.Equal("abc123", items["session"]);
        // 接收方若按表单规则解码，裸的 + 会被当成空格：文字里的加号和空格都必须编码
        Assert.DoesNotContain("+", url);
    }

    [Fact]
    public void Url_CarriesFailures()
    {
        foreach ((BridgeFailure failure, string code) in new[]
        {
            (BridgeFailure.Empty, "empty"), (BridgeFailure.MicDenied, "mic_denied"),
            (BridgeFailure.NotReady, "not_ready"), (BridgeFailure.Busy, "busy"),
            (BridgeFailure.NotAllowed, "not_allowed"), (BridgeFailure.Failed, "failed"),
        })
        {
            Assert.Equal(
                $"testapp://voicetype-result?session=abc123&error={code}",
                BridgeCallback.Url(Callback, "abc123", new BridgeOutcome.WithFailure(failure)));
        }
    }

    [Fact]
    public void Url_LongTextStaysInTheURL()
    {
        // 5 分钟听写约 1500 字：不写临时文件，全部放进 URL（每个汉字编码后 9 个字符）
        string text = new string('字', 1500);
        string url = BridgeCallback.Url(Callback, "abc123", new BridgeOutcome.WithText(text));
        Assert.Equal("testapp://voicetype-result?session=abc123&text=".Length + 1500 * 9,
            url.Length);
    }

    private static Dictionary<string, string> ParseQuery(string url)
    {
        var items = new Dictionary<string, string>();
        string query = url[(url.IndexOf('?') + 1)..];
        foreach (string pair in query.Split('&'))
        {
            int eq = pair.IndexOf('=');
            items[pair[..eq]] = Uri.UnescapeDataString(pair[(eq + 1)..]);
        }
        return items;
    }

    // ----- 请求该做什么 -----

    [Fact]
    public void Action_DictateInAllStatesAndPermissions()
    {
        var request = Dictate("s1");
        var start = new BridgeAction.Start("s1", Callback);
        var ask = new BridgeAction.AskPermission("s1", Callback);
        var busy = new BridgeAction.Refuse("s1", Callback, BridgeFailure.Busy);
        var notAllowed = new BridgeAction.Refuse("s1", Callback, BridgeFailure.NotAllowed);
        int checked_ = 0;
        foreach (BridgePermission permission in new[]
            { BridgePermission.Allowed, BridgePermission.Denied, BridgePermission.Unknown })
        {
            foreach (bool idle in new[] { false, true })
            {
                foreach (bool recording in new[] { false, true })
                {
                    foreach (bool meetingRecording in new[] { false, true })
                    {
                        // 只有「空闲、没在录音、没有会议录音」才会开始或询问；
                        // 已拒绝的应用不论忙不忙都回 not_allowed；忙的时候不弹窗，直接回 busy
                        bool free = idle && !recording && !meetingRecording;
                        BridgeAction expected = permission switch
                        {
                            BridgePermission.Denied => notAllowed,
                            BridgePermission.Unknown => free ? ask : busy,
                            BridgePermission.Allowed => free ? start : busy,
                            _ => throw new InvalidOperationException(),
                        };
                        Assert.Equal(expected,
                            request.Action(idle, recording, meetingRecording,
                                DictationTarget.Cursor, permission));
                        checked_++;
                    }
                }
            }
        }
        Assert.Equal(24, checked_);
    }

    [Fact]
    public void Action_StopAndCancelActOnlyOnTheirOwnRecordingInAllCombinations()
    {
        (string Label, DictationTarget Target)[] targets =
        {
            ("external s1", new DictationTarget.External("s1", Callback)),
            ("external s2", new DictationTarget.External("s2", Callback)),
            ("cursor", DictationTarget.Cursor),
        };
        (string Label, BridgeRequest Request, BridgeAction Effect)[] requests =
        {
            ("stop", new BridgeRequest.StopCase("s1"), BridgeAction.Finish),
            ("cancel", new BridgeRequest.CancelCase("s1"), BridgeAction.Cancel),
        };
        int checked_ = 0;
        foreach (var (requestLabel, request, effect) in requests)
        {
            foreach (bool recording in new[] { false, true })
            {
                foreach (var (targetLabel, target) in targets)
                {
                    // 只有「正在录音，且这次听写就是 s1 自己的会话」才动手；
                    // 别的 session、光标听写、已经不在录音：全部忽略
                    BridgeAction expected =
                        recording && targetLabel == "external s1" ? effect : BridgeAction.Ignore;
                    Assert.Equal(expected,
                        request.Action(idle: !recording, recording, meetingRecording: false,
                            target, BridgePermission.Unknown));
                    checked_++;
                }
            }
        }
        Assert.Equal(12, checked_);
    }

    [Fact]
    public void Action_OnlyDictateCarriesACallback()
    {
        Assert.Equal(Callback, Dictate("s1").Callback);
        Assert.Null(new BridgeRequest.StopCase("s1").CallbackUrl);
        Assert.Null(new BridgeRequest.CancelCase("s1").CallbackUrl);
    }

    [Fact]
    public void Action_CancelWhileTranscribingDropsOnlyThatSessionsReply()
    {
        // 结束录音后、结果回传前，第三方应用退出时发来的取消：识别完不回传（2026-10-24）
        var cancel = new BridgeRequest.CancelCase("s1");
        Assert.Equal(BridgeAction.DropReply,
            cancel.Action(idle: false, recording: false, meetingRecording: false,
                DictationTarget.Cursor, BridgePermission.Unknown, transcribing: "s1"));
        Assert.Equal(BridgeAction.Ignore,
            new BridgeRequest.CancelCase("s2").Action(
                idle: false, recording: false, meetingRecording: false,
                DictationTarget.Cursor, BridgePermission.Unknown, transcribing: "s1"));
        // 结束请求在识别阶段没有意义
        Assert.Equal(BridgeAction.Ignore,
            new BridgeRequest.StopCase("s1").Action(
                idle: false, recording: false, meetingRecording: false,
                DictationTarget.Cursor, BridgePermission.Unknown, transcribing: "s1"));
        // 不在识别时一切照旧
        Assert.Equal(BridgeAction.Ignore,
            cancel.Action(idle: true, recording: false, meetingRecording: false,
                DictationTarget.Cursor, BridgePermission.Unknown));
    }
}

/// <summary>授权记录的存取（settings.json，对应 macOS UserDefaults 版测试）</summary>
public class BridgePermissionStoreTests
{
    private const string A = "testapp://voicetype-result";
    private const string B = "otherapp://cb";

    private static SettingsStore NewStore()
    {
        string path = Path.Combine(Path.GetTempPath(), $"vt-settings-{Guid.NewGuid():N}.json");
        return new SettingsStore(path, new InMemoryCredentialStore());
    }

    [Fact]
    public void UnknownUntilDecided()
    {
        SettingsStore store = NewStore();
        Assert.Equal(BridgePermission.Unknown, store.BridgePermissionFor(A));
    }

    [Fact]
    public void RemembersAllowAndDenyPerCallback()
    {
        SettingsStore store = NewStore();
        store.SetBridgePermission(true, A);
        store.SetBridgePermission(false, B);
        Assert.Equal(BridgePermission.Allowed, store.BridgePermissionFor(A));
        Assert.Equal(BridgePermission.Denied, store.BridgePermissionFor(B));
    }

    [Fact]
    public void RemoveForgetsTheDecision()
    {
        SettingsStore store = NewStore();
        store.SetBridgePermission(false, A);
        store.RemoveBridgePermission(A);
        Assert.Equal(BridgePermission.Unknown, store.BridgePermissionFor(A));
    }

    [Fact]
    public void DecisionsPersistAcrossInstances()
    {
        string path = Path.Combine(Path.GetTempPath(), $"vt-settings-{Guid.NewGuid():N}.json");
        var store = new SettingsStore(path, new InMemoryCredentialStore());
        store.SetBridgePermission(true, A);
        var reopened = new SettingsStore(path, new InMemoryCredentialStore());
        Assert.Equal(BridgePermission.Allowed, reopened.BridgePermissionFor(A));
    }
}
