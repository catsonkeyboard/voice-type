import Foundation

/// 内置开发术语表（v7）：编译进二进制的常见开发词汇，
/// 与用户热词合并后交给 HotwordCorrector，为纯拉丁长词自动提供
/// 模糊纠错（kubernets→Kubernetes）、大小写归位（api→API）。
///
/// 收录原则：常见到会出现在中文技术口语里的词；刻意不放日常英文单词
/// （避免误替换），也不放生僻框架（用户可自行加进热词表）。
enum DevGlossary {
    static let terms: [String] = [
        // 平台 / OS
        "macOS", "iOS", "iPadOS", "watchOS", "tvOS", "visionOS", "Linux", "Windows",
        "Android", "HarmonyOS",
        // 语言与运行时
        "Swift", "SwiftUI", "AppKit", "UIKit", "Combine", "Objective-C",
        "TypeScript", "JavaScript", "Python", "Rust", "Kotlin", "Java", "Go",
        "Dart", "Ruby", "PHP", "C++", "C#", "JSON", "YAML", "TOML", "XML",
        // Apple 生态工具
        "Xcode", "xcodegen", "SwiftData", "CoreML", "Playground", "TestFlight",
        // 前端 / 客户端
        "React", "Vue", "Angular", "Svelte", "Node.js", "Webpack", "Vite",
        "Tailwind", "Electron", "Flutter", "WPF", "MAUI",
        // 后端 / 基础设施
        "Kubernetes", "Docker", "Nginx", "Redis", "PostgreSQL", "MySQL",
        "MongoDB", "Elasticsearch", "Kafka", "RabbitMQ", "gRPC", "GraphQL",
        "RESTful", "WebSocket", "WebRTC", "Serverless", "Lambda",
        // DevOps / CI
        "CI/CD", "GitHub", "GitLab", "Jenkins", "Fastlane", "Terraform",
        "Ansible", "Homebrew",
        // AI / ML
        "LLM", "GPT", "BERT", "Whisper", "Ollama", "PyTorch", "TensorFlow",
        "onnxruntime", "ONNX", "CoreData", "tokenizer", "embeddings",
        "transformer", "quantization", "distil-whisper",
        // 通用协议与缩写
        "API", "SDK", "HTTP", "HTTPS", "HTTP/2", "TCP", "UDP", "DNS", "CDN",
        "SSH", "VPN", "OAuth", "JWT", "SAML", "LSB", "CSV", "SVG", "PDF",
        "URL", "URI", "UUID", "MD5", "SHA-256", "AES", "RSA",
        // 常见开发动名词（ASR 高频误识）
        "cache", "deploy", "refactor", "replicas", "rollback", "hotfix",
        "middleware", "serializer", "tokenizer", "endpoint", "framework",
        "repository", "pipeline", "daemon", "runtime", "thread", "mutex",
    ]

    /// 用户热词 + 内置术语合并（大小写不敏感去重，用户条目优先且在前）
    static func merged(withUser user: [String]) -> [String] {
        let userLower = Set(user.map { $0.lowercased() })
        return user + terms.filter { !userLower.contains($0.lowercased()) }
    }
}
