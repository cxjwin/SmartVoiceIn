import Foundation

final class LLMCompletionRelay: @unchecked Sendable {
    private let completion: (Result<String, Error>) -> Void

    init(_ completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
    }

    func resolve(_ result: Result<String, Error>) {
        completion(result)
    }
}

final class LLMVoidCompletionRelay: @unchecked Sendable {
    private let completion: (Result<Void, Error>) -> Void

    init(_ completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
    }

    func resolve(_ result: Result<Void, Error>) {
        completion(result)
    }
}

struct LLMTextOptimizeConfiguration {
    let environment: [String: String]
    let timeout: TimeInterval
    let fallbackTencentSecretId: String?
    let fallbackTencentSecretKey: String?
}

protocol LLMTextOptimizeProvider: AnyObject {
    static var rawValue: String { get }
    static var displayName: String { get }

    init?(configuration: LLMTextOptimizeConfiguration)
    func prewarm(completion: @escaping (Result<Void, Error>) -> Void)
    func optimize(text: String, completion: @escaping (Result<String, Error>) -> Void)
}

extension LLMTextOptimizeProvider {
    func prewarm(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
}

let optimizationSystemPrompt = """
你是中文语音转写文本优化助手。任务：
1. 删除语气词和口头禅（如“嗯”“啊”“就是”“然后”等），但不改变原意。
2. 去除明显重复片段（词语、短句重复）并保持语义完整。
3. 只允许做“删除”类编辑（删除口头禅、删除重复、删除多余空格），禁止改写、替换同义词、重组句式。
4. 必须保留原文中的词语、术语和符号写法（如 C加加/C++/API），不得替换。
5. 禁止改写任务意图，禁止补充、臆测、扩写新内容。
6. 仅输出最终文本，不要解释，不要加引号。
"""

func buildOptimizationUserPrompt(userText: String) -> String {
    return "请对以下文本做最小必要清洗，仅删除口头禅和明显重复，不改写其他内容。\n原文：\(userText)"
}

func buildOptimizationPromptMessages(userText: String) -> [(role: String, content: String)] {
    return [
        ("system", optimizationSystemPrompt),
        ("user", buildOptimizationUserPrompt(userText: userText))
    ]
}

func extractTextFromTencentStyle(response: [String: Any]) -> String? {
    if let choices = response["Choices"] as? [[String: Any]], let first = choices.first {
        if let message = first["Message"] as? [String: Any],
           let content = message["Content"] as? String,
           !content.isEmpty {
            return content
        }
        if let delta = first["Delta"] as? [String: Any],
           let content = delta["Content"] as? String,
           !content.isEmpty {
            return content
        }
        if let text = first["Text"] as? String, !text.isEmpty {
            return text
        }
    }
    if let text = response["Result"] as? String, !text.isEmpty {
        return text
    }
    return nil
}
