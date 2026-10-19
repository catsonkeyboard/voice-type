import Foundation

enum PolishStyle: String, Codable, CaseIterable, Hashable {
    case clean    // 智能清理：保留原话风格
    case formal   // 完全书面化：允许重组句式

    var label: String {
        switch self {
        case .clean: return "智能清理"
        case .formal: return "完全书面化"
        }
    }
}

struct PolishConfig: Equatable {
    var enabled: Bool
    var baseURL: String
    var apiKey: String
    var model: String
    var style: PolishStyle
}

/// 润色服务商预设：仅作为设置页的一键填充器
enum PolishPreset: String, CaseIterable {
    case ollama = "本地 Ollama"
    case bailian = "阿里百炼"
    case deepseek = "DeepSeek"
    case openai = "OpenAI"

    var baseURL: String {
        switch self {
        case .ollama: return "http://localhost:11434/v1"
        case .bailian: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .openai: return "https://api.openai.com/v1"
        }
    }

    var recommendedModel: String {
        switch self {
        case .ollama: return "qwen3.5:4b-nvfp4"
        case .bailian: return "qwen-flash"
        case .deepseek: return "deepseek-chat"
        case .openai: return "gpt-5-mini"
        }
    }
}

enum PromptTemplates {
    static func system(for style: PolishStyle) -> String {
        switch style {
        case .clean: return clean
        case .formal: return formal
        }
    }

    /// 共同规则：口头禅过滤、自我纠正、列表化、英文术语保护、防幻觉、纯文本输出
    private static let commonRules = """
1. 删除口头禅和填充词（呃、嗯、啊、那个、就是说、然后那个、这个这个 等）以及无意义的重复。
2. 识别并应用说话人的自我纠正：出现「不对」「不是」「说错了」「应该是」等纠正标记时，只保留纠正后的内容，删除被纠正的内容和纠正标记本身。
3. 当内容在列举事项或步骤（如「第一…第二…」「首先…然后…最后…」）时，输出为 Markdown 列表：有顺序用 1. 2. 3.，无顺序用 - 。其余情况输出普通段落。
4. 原文中的英文单词、缩写与技术术语（如 API、Kubernetes、cache invalidate、Vue 组件）必须原样保留：禁止翻译成中文、禁止改写拼写、禁止变更大小写；中英混说时保留英文嵌入中文的原始语序。
5. 严禁添加原文没有的信息，严禁遗漏原文的实质内容。
6. 只输出处理后的文本本身，不要任何解释、前缀、引号或代码块。

示例：
输入：明天下午呃不对是明天上午九点开会
输出：明天上午九点开会。

输入：嗯我觉得这个方案就是说还有一些问题那个性能方面可能得再优化一下
输出：我觉得这个方案还有一些问题，性能方面可能得再优化一下。

输入：买菜清单第一个是西红柿第二个是鸡蛋然后还有那个牛奶
输出：买菜清单：
1. 西红柿
2. 鸡蛋
3. 牛奶

输入：这个 bug 呃我看了一下应该是 cache 没有 invalidate 导致的
输出：这个 bug 我看了一下，应该是 cache 没有 invalidate 导致的。

输入：帮我把这个 function 重构一下尤其是那个 refac 重构 refactor 逻辑
输出：帮我把这个 function 重构一下，尤其是 refactor 逻辑。

输入：deployment 的 replicas 应该是三 不对 是三个实例
输出：deployment 的 replicas 应该是三个实例。
"""

    static let clean = """
你是一个语音转写文本的清理引擎。用户消息是一段中英混合（code-switching）的语音识别原文。按以下规则处理，把口语碎片整理为通顺连贯的表达：调整语序、补全标点，但保留说话人的用词和语气，不要替换成你自己的措辞。
\(commonRules)
"""

    static let formal = """
你是一个语音转写文本的书面化引擎。用户消息是一段中英混合（code-switching）的语音识别原文。按以下规则处理，并将内容改写为正式、精炼的书面语：可以重组句式、替换口语化用词，但不得改变含义。
\(commonRules)
"""
}
