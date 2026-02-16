import Foundation

enum AppLog {
    static func log(_ message: @autoclosure () -> String) {
        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        )
        Swift.print("[\(timestamp)] \(message())")
    }
}

struct LLMPromptTemplate: Codable, Equatable {
    let id: String
    let title: String
    let prompt: String
    let isBuiltIn: Bool
}

enum LLMPromptTemplateStore {
    private static let selectedTemplateIDKey = "voiceinput.llm.prompt_template.selected_id"
    private static let customTemplatesKey = "voiceinput.llm.prompt_template.custom_templates"
    private struct TransferTemplate: Codable {
        let title: String
        let prompt: String
    }

    private static let builtInTemplates: [LLMPromptTemplate] = [
        LLMPromptTemplate(
            id: "basic_cleanup",
            title: "基础清洗",
            prompt: defaultOptimizationSystemPrompt,
            isBuiltIn: true
        ),
        LLMPromptTemplate(
            id: "strict_cleanup",
            title: "严格清洗",
            prompt: strictCleanupSystemPrompt,
            isBuiltIn: true
        ),
        LLMPromptTemplate(
            id: "meeting_cleanup",
            title: "会议记录",
            prompt: meetingCleanupSystemPrompt,
            isBuiltIn: true
        )
    ]

    static func allTemplates() -> [LLMPromptTemplate] {
        return builtInTemplates + loadCustomTemplates()
    }

    static func currentTemplate() -> LLMPromptTemplate {
        let selectedID = UserDefaults.standard.string(forKey: selectedTemplateIDKey)
        if let selectedID,
           let template = allTemplates().first(where: { $0.id == selectedID }) {
            return template
        }
        return builtInTemplates[0]
    }

    static func currentTemplateID() -> String {
        return currentTemplate().id
    }

    static func template(withID id: String) -> LLMPromptTemplate? {
        return allTemplates().first(where: { $0.id == id })
    }

    @discardableResult
    static func setCurrentTemplate(id: String) -> Bool {
        guard allTemplates().contains(where: { $0.id == id }) else {
            return false
        }
        UserDefaults.standard.set(id, forKey: selectedTemplateIDKey)
        return true
    }

    static func defaultTemplatePrompt() -> String {
        return builtInTemplates[0].prompt
    }

    static func customTemplateCount() -> Int {
        return loadCustomTemplates().count
    }

    static func addCustomTemplate(title: String, prompt: String) -> LLMPromptTemplate? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, !normalizedPrompt.isEmpty else {
            return nil
        }

        var customTemplates = loadCustomTemplates()
        let newTemplate = LLMPromptTemplate(
            id: UUID().uuidString,
            title: normalizedTitle,
            prompt: normalizedPrompt,
            isBuiltIn: false
        )
        customTemplates.append(newTemplate)
        saveCustomTemplates(customTemplates)
        return newTemplate
    }

    @discardableResult
    static func updateCustomTemplate(id: String, title: String, prompt: String) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, !normalizedPrompt.isEmpty else {
            return false
        }

        var customTemplates = loadCustomTemplates()
        guard let index = customTemplates.firstIndex(where: { $0.id == id }) else {
            return false
        }

        customTemplates[index] = LLMPromptTemplate(
            id: id,
            title: normalizedTitle,
            prompt: normalizedPrompt,
            isBuiltIn: false
        )
        saveCustomTemplates(customTemplates)
        return true
    }

    @discardableResult
    static func deleteCustomTemplate(id: String) -> Bool {
        var customTemplates = loadCustomTemplates()
        guard let index = customTemplates.firstIndex(where: { $0.id == id }) else {
            return false
        }
        customTemplates.remove(at: index)
        saveCustomTemplates(customTemplates)

        if currentTemplateID() == id {
            UserDefaults.standard.set(builtInTemplates[0].id, forKey: selectedTemplateIDKey)
        }
        return true
    }

    static func exportCustomTemplates() -> Data? {
        let payload = loadCustomTemplates().map { TransferTemplate(title: $0.title, prompt: $0.prompt) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(payload)
    }

    @discardableResult
    static func importCustomTemplates(from data: Data) -> Int {
        let decoder = JSONDecoder()

        let importedEntries: [TransferTemplate]
        if let transferTemplates = try? decoder.decode([TransferTemplate].self, from: data) {
            importedEntries = transferTemplates
        } else if let oldTemplates = try? decoder.decode([LLMPromptTemplate].self, from: data) {
            importedEntries = oldTemplates.map { TransferTemplate(title: $0.title, prompt: $0.prompt) }
        } else {
            return 0
        }

        var customTemplates = loadCustomTemplates()
        var importedCount = 0

        for entry in importedEntries {
            let normalizedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedPrompt = entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedTitle.isEmpty, !normalizedPrompt.isEmpty else {
                continue
            }

            let duplicated = customTemplates.contains {
                $0.title == normalizedTitle && $0.prompt == normalizedPrompt
            }
            if duplicated {
                continue
            }

            customTemplates.append(
                LLMPromptTemplate(
                    id: UUID().uuidString,
                    title: normalizedTitle,
                    prompt: normalizedPrompt,
                    isBuiltIn: false
                )
            )
            importedCount += 1
        }

        if importedCount > 0 {
            saveCustomTemplates(customTemplates)
        }
        return importedCount
    }

    private static func loadCustomTemplates() -> [LLMPromptTemplate] {
        guard let data = UserDefaults.standard.data(forKey: customTemplatesKey) else {
            return []
        }
        guard let templates = try? JSONDecoder().decode([LLMPromptTemplate].self, from: data) else {
            return []
        }
        return templates.filter { !$0.title.isEmpty && !$0.prompt.isEmpty }
    }

    private static func saveCustomTemplates(_ templates: [LLMPromptTemplate]) {
        guard let data = try? JSONEncoder().encode(templates) else {
            return
        }
        UserDefaults.standard.set(data, forKey: customTemplatesKey)
    }
}

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
    let fallbackLocalLLMModelID: String?
    let fallbackTencentSecretId: String?
    let fallbackTencentSecretKey: String?
    let fallbackMiniMaxAPIKey: String?
}

protocol LLMTextOptimizeProvider: AnyObject {
    static var rawValue: String { get }
    static var displayName: String { get }

    init?(configuration: LLMTextOptimizeConfiguration)
    func prewarm(completion: @escaping (Result<Void, Error>) -> Void)
    func optimize(text: String, templatePromptOverride: String?, completion: @escaping (Result<String, Error>) -> Void)
}

extension LLMTextOptimizeProvider {
    func prewarm(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }

    func optimize(text: String, completion: @escaping (Result<String, Error>) -> Void) {
        optimize(text: text, templatePromptOverride: nil, completion: completion)
    }
}

let defaultOptimizationSystemPrompt = """
你是 ASR 文本清洗器，不是问答助手。下面是原始转写文本，请仅做清洗，不要回答问题、不要讲解知识、不要扩写内容。

清洗规则：
1. 删除口头禅、卡顿词、回读重复（如“嗯/呃/那个/就是/然后”）。
2. 修复明显 ASR 术语误识别，规范中英混排空格与常见术语大小写。
3. 保留原意与语气，仅做最小必要编辑；不要改写成教程或方案。
4. 若原文已清晰则原样输出。
5. 仅输出最终文本，不要解释，不要 JSON，不要引号，不要列表。

原文：
{{input}}
"""

let strictCleanupSystemPrompt = """
你是中文语音转写文本优化助手。任务：
1. 仅做清洗，不改写句式，不替换同义词。
2. 删除语气词（如“嗯”“呃”“啊”“那个”“就是”“然后”）和明显重复片段。
3. 保留原文标点和大小写；如果原文有句号、问号、叹号，必须保留。
4. 不新增任何原文不存在的信息。
5. 仅输出最终文本。
"""

let meetingCleanupSystemPrompt = """
你是会议语音转写清洗助手。任务：
1. 删除口头禅、重复词和无意义停顿词。
2. 保留人名、产品名、英文术语、数字、时间和关键动作。
3. 不改变事实、不补充内容、不改写为总结。
4. 尽量保留原句结构，只做最小必要删除。
5. 仅输出最终文本。
"""

private let optimizationInputPlaceholder = "{{input}}"

struct OptimizationPromptRequest {
    let systemPrompt: String?
    let userPrompt: String
}

func buildOptimizationPromptRequest(userText: String, templatePromptOverride: String? = nil) -> OptimizationPromptRequest {
    let templatePrompt: String
    if let templatePromptOverride {
        templatePrompt = templatePromptOverride.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        let selectedTemplate = LLMPromptTemplateStore.currentTemplate()
        templatePrompt = selectedTemplate.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if templatePrompt.contains(optimizationInputPlaceholder) {
        let rendered = templatePrompt.replacingOccurrences(of: optimizationInputPlaceholder, with: userText)
        return OptimizationPromptRequest(systemPrompt: nil, userPrompt: rendered)
    }

    return OptimizationPromptRequest(systemPrompt: templatePrompt, userPrompt: userText)
}

func buildOptimizationPromptMessages(userText: String, templatePromptOverride: String? = nil) -> [(role: String, content: String)] {
    let request = buildOptimizationPromptRequest(userText: userText, templatePromptOverride: templatePromptOverride)
    if let systemPrompt = request.systemPrompt {
        return [
            ("system", systemPrompt),
            ("user", request.userPrompt)
        ]
    }
    return [("user", request.userPrompt)]
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

func extractTextFromOpenAIStyle(response: [String: Any]) -> String? {
    if let choices = response["choices"] as? [[String: Any]], let first = choices.first {
        if let message = first["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            return content
        }
        if let delta = first["delta"] as? [String: Any],
           let content = delta["content"] as? String,
           !content.isEmpty {
            return content
        }
        if let text = first["text"] as? String, !text.isEmpty {
            return text
        }
    }
    if let text = response["content"] as? String, !text.isEmpty {
        return text
    }
    return nil
}

func extractTextFromAnthropicStyle(response: [String: Any]) -> String? {
    if let contentItems = response["content"] as? [[String: Any]] {
        let textChunks = contentItems.compactMap { item -> String? in
            let type = (item["type"] as? String)?.lowercased() ?? ""
            guard type == "text" || type == "output_text" else {
                return nil
            }
            guard let text = item["text"] as? String, !text.isEmpty else {
                return nil
            }
            return text
        }
        if !textChunks.isEmpty {
            return textChunks.joined()
        }
    }

    if let message = response["message"] as? [String: Any],
       let nested = extractTextFromAnthropicStyle(response: message) {
        return nested
    }

    return nil
}
