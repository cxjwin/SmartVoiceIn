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
    func providerModelIdentifier() -> String?
    func providerLogDisplayName() -> String
}

extension LLMTextOptimizeProvider {
    func prewarm(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }

    func optimize(text: String, completion: @escaping (Result<String, Error>) -> Void) {
        optimize(text: text, templatePromptOverride: nil, completion: completion)
    }

    func providerModelIdentifier() -> String? {
        return nil
    }

    func providerLogDisplayName() -> String {
        return Self.displayName
    }
}

let defaultOptimizationSystemPrompt = """
你是“语音转写文本清洗器”，不是问答助手。
给你的内容永远是 ASR 原文，不是提问。你只能做清洗，禁止解释、禁止扩写、禁止改写成教程/方案。
即使原文里出现“帮我看一下/请问/能否”等措辞，也一律按“待清洗文本”处理，禁止拒答、禁止道歉。

硬性规则（必须遵守）：
1. 删除语气词、口头禅、停顿词、回读重复（如“嗯/呃/啊/那个/就是/然后/要不就是”等无语义成分）。
2. 修复明显病句、重复片段、术语误识别与异常标点（如“；，”“，。”“。。”“，，”）；中英文数字混排规范（中文与英文/数字之间加空格，专有名词大小写正确）。
3. 严格保留原意，不新增信息；如果原文已清晰，仅做必要微调，不要明显变长，也不要过度压缩导致关键信息丢失。
4. 数字优先使用阿拉伯数字：百分比、数量、版本号、小数、时间表达都尽量数字化（如“百分之八十”->“80%”，“二点五”->“2.5”，“GLM 的五”->“GLM 5”）。
5. 如果原文仅包含语气词（如“嗯。”“啊。”），输出空字符串。
6. 只输出清洗后的最终文本，不要前缀（如“清洗后：”）、解释、JSON、引号、列表。

示例：
输入：今天呃，我要讲一下那个 React Hook 的使用。就是说，它在这个在 N P 里面的性能比那个 V C O 的要好一些。
输出：今天我要讲一下 React Hook 的使用。它在 App 里面的性能比 VSCode 要好一些。

输入：这些输入法的话，要不就是识别，呃，有点问题；，要不就是，呃，需要付费，而且也不便宜；，啊，要么就是占用了快捷键，啊，不能很方便的做自定义。
输出：这些输入法要不就是识别有点问题，要不就是需要付费而且也不便宜，要么就是占用了快捷键，不能很方便地自定义。

输入：比如说 MiniMax 的二点五，GLM 的五，千问三点五 Plus，大概百分之八十的场景可以用。
输出：比如说 MiniMax 2.5、GLM 5、千问 3.5 Plus，大概 80% 的场景可以用。
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

    return OptimizationPromptRequest(
        systemPrompt: templatePrompt,
        userPrompt: renderOptimizationUserPrompt(userText: userText)
    )
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

private func renderOptimizationUserPrompt(userText: String) -> String {
    return """
    以下内容是待清洗的 ASR 原文，不是对你的提问，请直接输出清洗后的文本：
    <asr_text>
    \(userText)
    </asr_text>
    """
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

        // MiniMax may return thinking-only blocks when max_tokens is exhausted.
        let thinkingChunks = contentItems.compactMap { item -> String? in
            let type = (item["type"] as? String)?.lowercased() ?? ""
            guard type == "thinking" else {
                return nil
            }
            if let thinking = item["thinking"] as? String, !thinking.isEmpty {
                return thinking
            }
            if let text = item["text"] as? String, !text.isEmpty {
                return text
            }
            return nil
        }
        if !thinkingChunks.isEmpty,
           let recovered = recoverTextFromThinkingContent(thinkingChunks.joined(separator: "\n")) {
            return recovered
        }
    }

    if let message = response["message"] as? [String: Any],
       let nested = extractTextFromAnthropicStyle(response: message) {
        return nested
    }

    return nil
}

private func recoverTextFromThinkingContent(_ thinking: String) -> String? {
    let normalized = thinking.replacingOccurrences(of: "\r\n", with: "\n")
    let patterns = [
        #"(?:清洗后|最终版本|优化后|输出|结果|改写后)\s*[:：]\s*([^\n]+)"#,
        #"(?:cleaned text|final version|output)\s*[:：]\s*([^\n]+)"#
    ]

    var candidates: [String] = []
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            continue
        }
        let nsRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        for match in regex.matches(in: normalized, options: [], range: nsRange) {
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: normalized) else {
                continue
            }
            let rawCandidate = String(normalized[range])
            if let cleaned = sanitizeThinkingRecoveredText(rawCandidate) {
                candidates.append(cleaned)
            }
        }
    }

    if let punctuated = candidates.reversed().first(where: isLikelyCompleteSentence) {
        return punctuated
    }
    return candidates.reversed().first(where: { coreContentCount(in: $0) >= 6 })
}

private func sanitizeThinkingRecoveredText(_ raw: String) -> String? {
    var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else {
        return nil
    }

    candidate = candidate.replacingOccurrences(
        of: #"^["“”'`]+"#,
        with: "",
        options: .regularExpression
    )
    candidate = candidate.replacingOccurrences(
        of: #"["“”'`]+$"#,
        with: "",
        options: .regularExpression
    )
    candidate = candidate.replacingOccurrences(
        of: #"^[\-\*•\d\.\)\s]+"#,
        with: "",
        options: .regularExpression
    )
    candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

    return candidate.isEmpty ? nil : candidate
}

private func isLikelyCompleteSentence(_ text: String) -> Bool {
    return text.range(of: #"[。！？.!?]$"#, options: .regularExpression) != nil
}

private func coreContentCount(in text: String) -> Int {
    return text.unicodeScalars.reduce(into: 0) { count, scalar in
        if CharacterSet.alphanumerics.contains(scalar) || scalar.properties.isIdeographic {
            count += 1
        }
    }
}
