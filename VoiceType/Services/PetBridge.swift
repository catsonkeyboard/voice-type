import Foundation

// 桌宠（Pet）联动协议（v6）的纯逻辑：请求解析、请求该做什么、回传 URL。
// 桌宠用 voicetype:// 发起听写，VoiceType 把结果经 pet://transcript 回传。
// 收发 URL 的两端在 App/AppDelegate.swift。

/// 一次听写的输出去向
enum DictationTarget: Equatable {
    /// 现状：注入前台 App 光标处
    case cursor
    /// 桌宠发起：回传给 callback，不写剪贴板、不模拟 ⌘V
    case pet(session: String, callback: URL)

    /// 是不是桌宠的这一次会话
    func isPet(_ session: String) -> Bool {
        if case .pet(let current, _) = self { return current == session }
        return false
    }
}

/// 没有文字可给时的原因（回传 URL 里的 error 参数）
enum PetFailure: String, Equatable {
    /// 没说话，或录音太短
    case empty
    case micDenied = "mic_denied"
    /// 本地模型没装，或云端引擎没填密钥
    case notReady = "not_ready"
    case busy
    case failed
}

/// 回传给桌宠的结果
enum PetOutcome: Equatable {
    case text(String)
    case failure(PetFailure)
}

/// 请求在当前状态下该做什么
enum PetAction: Equatable {
    /// 开始一次回传给桌宠的录音
    case start(session: String, callback: URL)
    /// 结束当前录音并识别
    case finish
    /// 丢弃当前录音，不回传
    case cancel
    /// 不开始录音，立刻回传失败
    case refuse(session: String, callback: URL, reason: PetFailure)
    case ignore
}

/// 桌宠发来的请求
enum PetRequest: Equatable {
    case dictate(session: String, callback: URL)
    case stop(session: String)
    case cancel(session: String)

    /// 回调只认这一个地址：否则任何网页或 App 都能让 VoiceType 录音，并把文字发到任意地址
    static let allowedCallback = "pet://transcript"

    /// 解析 voicetype://dictate|stop|cancel?session=…[&callback=…]；不合法返回 nil
    static func parse(_ url: URL) -> PetRequest? {
        guard url.scheme?.lowercased() == "voicetype",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let session = value("session"), isValidSession(session) else { return nil }
        switch components.host?.lowercased() {
        case "dictate":
            guard value("callback") == allowedCallback,
                let callback = URL(string: allowedCallback)
            else { return nil }
            return .dictate(session: session, callback: callback)
        case "stop":
            return .stop(session: session)
        case "cancel":
            return .cancel(session: session)
        default:
            return nil
        }
    }

    /// session 由桌宠生成：1–64 个字母、数字或连字符
    static func isValidSession(_ session: String) -> Bool {
        guard (1...64).contains(session.utf8.count) else { return false }
        return session.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 45
        }
    }

    /// 纯函数：当前状态下这个请求该做什么。
    /// - idle：没有录音、识别或润色在进行，也没有录音正在启动
    /// - recording：正在录音，或录音正在启动
    /// - meetingRecording：会议录音进行中
    /// - target：当前这次听写的去向
    func action(idle: Bool, recording: Bool, meetingRecording: Bool, target: DictationTarget)
        -> PetAction
    {
        switch self {
        case .dictate(let session, let callback):
            guard idle, !meetingRecording else {
                return .refuse(session: session, callback: callback, reason: .busy)
            }
            return .start(session: session, callback: callback)
        case .stop(let session):
            return recording && target.isPet(session) ? .finish : .ignore
        case .cancel(let session):
            return recording && target.isPet(session) ? .cancel : .ignore
        }
    }
}

/// 回传 URL 的拼接
enum PetCallback {
    /// 字母、数字和 -._~ 之外的字节全部百分号编码：空格是 %20，加号是 %2B，
    /// 接收方按表单规则解码（把 + 当空格）也不会出错
    static func encode(_ text: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// pet://transcript?session=…&text=… 或 …&error=…
    static func url(callback: URL, session: String, outcome: PetOutcome) -> URL? {
        let tail: String
        switch outcome {
        case .text(let text): tail = "text=" + encode(text)
        case .failure(let failure): tail = "error=" + failure.rawValue
        }
        return URL(string: "\(callback.absoluteString)?session=\(encode(session))&\(tail)")
    }
}
