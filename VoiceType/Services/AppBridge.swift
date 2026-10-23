import Foundation

// 第三方应用联动协议（v6）的纯逻辑：请求解析、回调地址校验、请求该做什么、回传 URL。
// 第三方应用用 voicetype:// 发起听写，并在 callback 参数里给出自己的回调地址；
// VoiceType 把结果经这个回调地址回传。某个回调地址第一次使用时要用户在弹窗里允许。
// 收发 URL 的两端在 App/AppDelegate.swift，授权弹窗在 UI/BridgePermissionPrompt.swift。

/// 一次听写的输出去向
enum DictationTarget: Equatable {
    /// 现状：注入前台 App 光标处
    case cursor
    /// 第三方应用发起：回传给 callback，不写剪贴板、不模拟 ⌘V
    case external(session: String, callback: URL)

    /// 是不是第三方应用的这一次会话
    func isExternal(_ session: String) -> Bool {
        if case .external(let current, _) = self { return current == session }
        return false
    }
}

/// 没有文字可给时的原因（回传 URL 里的 error 参数）
enum BridgeFailure: String, Equatable {
    /// 没说话：录音太短，或只录到按键声、底噪（见 SpeechGate）
    case empty
    case micDenied = "mic_denied"
    /// 本地模型没装，或云端引擎没填密钥
    case notReady = "not_ready"
    case busy
    /// 用户拒绝了这个应用使用 VoiceType 听写
    case notAllowed = "not_allowed"
    case failed
}

/// 回传给第三方应用的结果
enum BridgeOutcome: Equatable {
    case text(String)
    case failure(BridgeFailure)
}

/// 某个回调地址的授权状态
enum BridgePermission: Equatable {
    case allowed
    case denied
    /// 还没问过用户
    case unknown
}

/// 请求在当前状态下该做什么
enum BridgeAction: Equatable {
    /// 开始一次回传给第三方应用的录音
    case start(session: String, callback: URL)
    /// 这个回调地址第一次出现：先问用户允不允许，再重新判定
    case askPermission(session: String, callback: URL)
    /// 结束当前录音并识别
    case finish
    /// 丢弃当前录音，不回传
    case cancel
    /// 不开始录音，立刻回传失败
    case refuse(session: String, callback: URL, reason: BridgeFailure)
    case ignore
}

/// 录音启动期间到达的结束或取消请求，取消优先于结束。
/// 启动成功后立刻执行；启动失败时，记下的是结束就回传失败原因，记下的是取消就不回传。
enum PendingEnd: Equatable {
    case finish
    case cancel

    /// 取消优先：已经取消的会话，之后到达的结束请求不能把它改回去
    static func merge(_ current: PendingEnd?, _ new: PendingEnd) -> PendingEnd {
        current == .cancel ? .cancel : new
    }
}

/// 第三方应用发来的请求
enum BridgeRequest: Equatable {
    case dictate(session: String, callback: URL)
    case stop(session: String)
    case cancel(session: String)

    /// 只有 dictate 带回调地址
    var callback: URL? {
        if case .dictate(_, let callback) = self { return callback }
        return nil
    }

    /// 解析 voicetype://dictate|stop|cancel?session=…[&callback=…]；不合法返回 nil
    static func parse(_ url: URL) -> BridgeRequest? {
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
            guard let raw = value("callback"), let callback = BridgeCallback.validate(raw)
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

    /// session 由第三方应用生成：1–64 个字母、数字或连字符
    static func isValidSession(_ session: String) -> Bool {
        guard (1...64).contains(session.utf8.count) else { return false }
        return session.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 45
        }
    }

    /// 纯函数：当前状态下这个请求该做什么。
    /// - idle：没有录音、识别、润色或授权弹窗在进行，也没有录音正在启动
    /// - recording：正在录音，或录音正在启动
    /// - meetingRecording：会议录音进行中
    /// - target：当前这次听写的去向
    /// - permission：dictate 的回调地址的授权状态（stop/cancel 不看）
    func action(
        idle: Bool, recording: Bool, meetingRecording: Bool, target: DictationTarget,
        permission: BridgePermission
    ) -> BridgeAction {
        switch self {
        case .dictate(let session, let callback):
            // 已拒绝的应用不论忙不忙都回 not_allowed
            if permission == .denied {
                return .refuse(session: session, callback: callback, reason: .notAllowed)
            }
            // 录音（含启动中）也算忙：不依赖调用方把 idle 算对。忙的时候不弹窗
            guard idle, !recording, !meetingRecording else {
                return .refuse(session: session, callback: callback, reason: .busy)
            }
            return permission == .allowed
                ? .start(session: session, callback: callback)
                : .askPermission(session: session, callback: callback)
        case .stop(let session):
            return recording && target.isExternal(session) ? .finish : .ignore
        case .cancel(let session):
            return recording && target.isExternal(session) ? .cancel : .ignore
        }
    }
}

/// 回调地址的校验与回传 URL 的拼接
enum BridgeCallback {
    /// 不接受的 scheme：一旦允许，识别出的文字会被送进浏览器、文件或别的系统应用；
    /// voicetype 自己也不行（回传给自己会形成循环）
    static let blockedSchemes: Set<String> = [
        "http", "https", "file", "ftp", "mailto", "sms", "tel", "facetime", "voicetype",
    ]
    static let maxLength = 256

    /// 第三方应用给的回调地址能不能用：自定义 scheme，不带查询、片段和用户信息，
    /// 不超过 256 字节。可用时返回 scheme 转成小写的地址（授权按这个地址记忆）。
    static func validate(_ raw: String) -> URL? {
        guard !raw.isEmpty, raw.utf8.count <= maxLength,
            var components = URLComponents(string: raw),
            let scheme = components.scheme?.lowercased(), !scheme.isEmpty,
            !blockedSchemes.contains(scheme),
            // 回传要在后面拼 ?session=…：已有查询或片段会把参数弄乱
            components.query == nil, components.fragment == nil,
            components.user == nil, components.password == nil
        else { return nil }
        components.scheme = scheme
        return components.url
    }

    /// 字母、数字和 -._~ 之外的字节全部百分号编码：空格是 %20，加号是 %2B，
    /// 接收方按表单规则解码（把 + 当空格）也不会出错
    static func encode(_ text: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// <callback>?session=…&text=… 或 …&error=…
    static func url(callback: URL, session: String, outcome: BridgeOutcome) -> URL? {
        let tail: String
        switch outcome {
        case .text(let text): tail = "text=" + encode(text)
        case .failure(let failure): tail = "error=" + failure.rawValue
        }
        return URL(string: "\(callback.absoluteString)?session=\(encode(session))&\(tail)")
    }
}
