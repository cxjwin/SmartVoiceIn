import Foundation

final class LLMTextOptimizer: @unchecked Sendable {
    struct ProviderOption {
        let rawValue: String
        let displayName: String
    }

    private static let providerOverrideKey = "voiceinput.llm.provider.override"
    nonisolated(unsafe) private static let providerTypes: [LLMTextOptimizeProvider.Type] = [
        LocalMLXLLMProvider.self,
        TencentHunyuanLLMProvider.self,
        MiniMaxLLMProvider.self
    ]

    static var providerOptions: [ProviderOption] {
        return providerTypes.map { ProviderOption(rawValue: $0.rawValue, displayName: $0.displayName) }
    }

    static let supportedProviderRawValues = providerTypes.map { $0.rawValue }

    static func displayName(for rawValue: String) -> String? {
        return providerTypes.first(where: { $0.rawValue == rawValue })?.displayName
    }

    static func currentProviderRawValue(providerRawValueOverride: String? = nil) -> String {
        if let providerRawValueOverride,
           supportedProviderRawValues.contains(providerRawValueOverride) {
            return providerRawValueOverride
        }

        let defaults = UserDefaults.standard
        if let override = defaults.string(forKey: providerOverrideKey),
           supportedProviderRawValues.contains(override) {
            return override
        }

        let envProvider = ProcessInfo.processInfo.environment["VOICEINPUT_LLM_PROVIDER"] ?? ""
        if supportedProviderRawValues.contains(envProvider) {
            return envProvider
        }

        return supportedProviderRawValues.first ?? TencentHunyuanLLMProvider.rawValue
    }

    static func setProviderOverride(rawValue: String) {
        guard supportedProviderRawValues.contains(rawValue) else {
            return
        }
        UserDefaults.standard.set(rawValue, forKey: providerOverrideKey)
    }

    private let providerRawValue: String
    private let provider: any LLMTextOptimizeProvider
    private let prewarmStateLock = NSLock()
    private var prewarmStarted = false
    private let activityStateLock = NSLock()
    private var lastActivityAt = Date()

    init?(
        providerRawValueOverride: String? = nil,
        fallbackLocalLLMModelID: String? = nil,
        fallbackTencentSecretId: String? = nil,
        fallbackTencentSecretKey: String? = nil,
        fallbackMiniMaxAPIKey: String? = nil
    ) {
        let env = ProcessInfo.processInfo.environment
        let providerRawValue = Self.currentProviderRawValue(providerRawValueOverride: providerRawValueOverride)
        guard let providerType = Self.providerTypes.first(where: { $0.rawValue == providerRawValue }) else {
            return nil
        }

        let timeout: TimeInterval
        if let timeoutRaw = env["VOICEINPUT_LLM_TIMEOUT"], let parsed = TimeInterval(timeoutRaw), parsed > 0 {
            timeout = parsed
        } else {
            timeout = 6
        }

        let configuration = LLMTextOptimizeConfiguration(
            environment: env,
            timeout: timeout,
            fallbackLocalLLMModelID: fallbackLocalLLMModelID,
            fallbackTencentSecretId: fallbackTencentSecretId,
            fallbackTencentSecretKey: fallbackTencentSecretKey,
            fallbackMiniMaxAPIKey: fallbackMiniMaxAPIKey
        )

        guard let provider = providerType.init(configuration: configuration) else {
            return nil
        }

        self.providerRawValue = providerRawValue
        self.provider = provider
    }

    func prewarmIfNeeded(completion: ((Result<Void, Error>) -> Void)? = nil) {
        // 目前仅本地 MLX provider 需要预热；远程 provider 无需处理
        guard providerRawValue == LocalMLXLLMProvider.rawValue else {
            completion?(.success(()))
            return
        }

        prewarmStateLock.lock()
        if prewarmStarted {
            prewarmStateLock.unlock()
            completion?(.success(()))
            return
        }
        prewarmStarted = true
        prewarmStateLock.unlock()

        provider.prewarm { [weak self] result in
            if case .failure = result {
                self?.prewarmStateLock.lock()
                self?.prewarmStarted = false
                self?.prewarmStateLock.unlock()
            } else {
                self?.markActivityNow()
            }
            completion?(result)
        }
    }

    func keepAliveIfNeeded(minIdleSeconds: TimeInterval = 180, completion: ((Bool) -> Void)? = nil) {
        guard providerRawValue == LocalMLXLLMProvider.rawValue,
              let localProvider = provider as? LocalMLXLLMProvider else {
            completion?(false)
            return
        }
        if currentIdleSeconds() < minIdleSeconds {
            completion?(false)
            return
        }

        localProvider.keepAliveIfLoaded { [weak self] keptAlive in
            if keptAlive {
                self?.markActivityNow()
            }
            completion?(keptAlive)
        }
    }

    func releaseLocalResources(completion: ((Result<Bool, Error>) -> Void)? = nil) {
        guard providerRawValue == LocalMLXLLMProvider.rawValue,
              let localProvider = provider as? LocalMLXLLMProvider else {
            completion?(.success(false))
            return
        }

        localProvider.releaseLoadedModel { [weak self] result in
            if case .success(let released) = result, released {
                self?.prewarmStateLock.lock()
                self?.prewarmStarted = false
                self?.prewarmStateLock.unlock()
            }
            completion?(result)
        }
    }

    func optimize(text rawText: String, completion: @escaping (Result<String, Error>) -> Void) {
        let cleanedInput = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedInput.isEmpty else {
            completion(.success(rawText))
            return
        }
        markActivityNow()

        provider.optimize(text: cleanedInput, templatePromptOverride: nil) { result in
            switch result {
            case .success(let outputText):
                self.markActivityNow()
                let normalized = self.normalizeOutput(outputText)
                if self.isLikelyModelRefusal(output: normalized, input: cleanedInput) {
                    AppLog.log("[LLMTextOptimizer] Output looks like refusal, fallback to original text")
                    completion(.success(cleanedInput))
                    return
                }
                if self.shouldFallbackToOriginal(input: cleanedInput, output: normalized) {
                    AppLog.log("[LLMTextOptimizer] Output is over-compressed, fallback to original text")
                    completion(.success(cleanedInput))
                    return
                }
                if self.losesCriticalContext(input: cleanedInput, output: normalized) {
                    AppLog.log("[LLMTextOptimizer] Output loses critical context, fallback to original text")
                    completion(.success(cleanedInput))
                    return
                }
                if self.losesQuestionIntent(input: cleanedInput, output: normalized) {
                    AppLog.log("[LLMTextOptimizer] Output loses question intent, fallback to original text")
                    completion(.success(cleanedInput))
                    return
                }
                if self.isLikelyOverRephrased(input: cleanedInput, output: normalized) {
                    AppLog.log("[LLMTextOptimizer] Output is over-rephrased for clean short input, fallback to original text")
                    completion(.success(cleanedInput))
                    return
                }
                completion(.success(normalized))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func providerDisplayName() -> String {
        return Self.displayName(for: providerRawValue) ?? providerRawValue
    }

    func providerLogDescription() -> String {
        let displayName = provider.providerLogDisplayName()
        guard let modelID = provider.providerModelIdentifier()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelID.isEmpty else {
            return displayName
        }
        return "\(displayName) [\(modelID)]"
    }

    private func markActivityNow() {
        activityStateLock.lock()
        lastActivityAt = Date()
        activityStateLock.unlock()
    }

    private func currentIdleSeconds() -> TimeInterval {
        activityStateLock.lock()
        let idle = Date().timeIntervalSince(lastActivityAt)
        activityStateLock.unlock()
        return idle
    }

    private func normalizeOutput(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        // Remove common wrapper prefixes some models add instead of returning pure cleaned text.
        let wrapperPattern = #"^\s*(清洗后|优化后|输出|结果|改写后)\s*[:：]\s*"#
        let unwrapped = trimmed.replacingOccurrences(
            of: wrapperPattern,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return stripASRTextWrapperArtifacts(from: unwrapped)
    }

    private func stripASRTextWrapperArtifacts(from text: String) -> String {
        var candidate = text

        // Some models may echo prompt wrappers like <asr_text>...</asr_text>.
        let blockPattern = #"(?is)<asr_text>\s*(.*?)\s*</asr_text>"#
        if let regex = try? NSRegularExpression(pattern: blockPattern),
           let match = regex.firstMatch(
               in: candidate,
               options: [],
               range: NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
           ),
           match.numberOfRanges > 1,
           let innerRange = Range(match.range(at: 1), in: candidate) {
            candidate = String(candidate[innerRange])
        }

        candidate = candidate.replacingOccurrences(
            of: #"(?i)</?asr_text>"#,
            with: "",
            options: .regularExpression
        )
        candidate = candidate.replacingOccurrences(
            of: #"(?i)&lt;/?asr_text&gt;"#,
            with: "",
            options: .regularExpression
        )

        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldFallbackToOriginal(input: String, output: String) -> Bool {
        if output.isEmpty {
            return !isLikelyFillerOnly(input)
        }

        let inputCoreCount = coreCharacterCount(in: input)
        let outputCoreCount = coreCharacterCount(in: output)

        // For non-trivial input, reject suspiciously short outputs to avoid meaning loss.
        if inputCoreCount >= 20 {
            if outputCoreCount <= 6 {
                return true
            }
            let ratio = Double(outputCoreCount) / Double(inputCoreCount)
            if ratio < 0.2 {
                return true
            }
        } else if inputCoreCount >= 12, outputCoreCount <= 3 {
            return true
        }

        return false
    }

    private func losesCriticalContext(input: String, output: String) -> Bool {
        let inputCoreCount = coreCharacterCount(in: input)
        let outputCoreCount = coreCharacterCount(in: output)
        guard inputCoreCount >= 16, outputCoreCount > 0 else {
            return false
        }

        let compressionRatio = Double(outputCoreCount) / Double(inputCoreCount)
        guard compressionRatio < 0.85 else {
            return false
        }

        guard let firstClause = firstMeaningfulClause(in: input) else {
            return false
        }

        let anchors = extractAnchors(from: firstClause)
        guard !anchors.isEmpty else {
            return false
        }

        let coveredAnchorCount = anchors.reduce(into: 0) { partial, anchor in
            if output.contains(anchor) {
                partial += 1
            }
        }
        if coveredAnchorCount > 0 {
            return false
        }

        return containsCriticalConnector(in: firstClause)
    }

    private func isLikelyModelRefusal(output: String, input: String) -> Bool {
        let normalizedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedOutput.isEmpty else {
            return false
        }

        let markers = [
            "对不起，我无法",
            "抱歉，我无法",
            "我无法提供帮助",
            "我不能提供帮助",
            "无法提供帮助",
            "作为ai",
            "作为一个ai",
            "我无法协助",
            "我不能协助",
            "我无法回答",
            "i'm sorry",
            "i am sorry",
            "i cannot help",
            "i can't help",
            "as an ai"
        ]

        guard markers.contains(where: { normalizedOutput.contains($0) }) else {
            return false
        }

        let normalizedInput = input.lowercased()
        // Only treat as refusal when marker is introduced by the model (not present in source text).
        let introducedByModel = markers.contains { marker in
            normalizedOutput.contains(marker) && !normalizedInput.contains(marker)
        }
        guard introducedByModel else {
            return false
        }

        // Refusal replies are usually short and non-content preserving.
        return coreCharacterCount(in: output) <= max(24, coreCharacterCount(in: input) / 2)
    }

    private func isLikelyFillerOnly(_ text: String) -> Bool {
        var candidate = text.lowercased()
        let fillerTerms = [
            "嗯", "呃", "啊", "额", "哦", "唉", "诶", "那个", "这个",
            "就是", "然后", "的话", "吧", "呀", "嘛"
        ]
        fillerTerms.forEach { candidate = candidate.replacingOccurrences(of: $0, with: "") }
        return coreCharacterCount(in: candidate) == 0
    }

    private func firstMeaningfulClause(in text: String) -> String? {
        let separators = CharacterSet(charactersIn: "，。！？；,!?;")
        let parts = text.components(separatedBy: separators)
        for rawPart in parts {
            let cleaned = stripFillerTerms(in: rawPart)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if coreCharacterCount(in: cleaned) >= 8 {
                return cleaned
            }
        }
        return nil
    }

    private func extractAnchors(from text: String) -> [String] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return []
        }
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9]{2,}|[\p{Han}]{2,}"#, options: []) else {
            return []
        }

        let stopwords: Set<String> = [
            "因为", "所以", "如果", "虽然", "但是", "不过", "另外", "同时",
            "就是", "这个", "那个", "我们", "你们", "他们", "一个", "一些",
            "可以", "需要", "进行", "通过", "然后", "还有"
        ]

        let nsRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        var anchors: [String] = []
        for match in regex.matches(in: normalized, options: [], range: nsRange) {
            guard let range = Range(match.range, in: normalized) else {
                continue
            }
            let token = String(normalized[range])
            if stopwords.contains(token) {
                continue
            }
            anchors.append(token)
        }

        if anchors.isEmpty {
            return []
        }
        let unique = Array(Set(anchors))
        return unique.sorted { $0.count > $1.count }.prefix(3).map { $0 }
    }

    private func stripFillerTerms(in text: String) -> String {
        var candidate = text
        let fillerTerms = [
            "嗯", "呃", "啊", "额", "哦", "唉", "诶", "那个", "这个",
            "就是", "然后", "的话", "吧", "呀", "嘛"
        ]
        fillerTerms.forEach { candidate = candidate.replacingOccurrences(of: $0, with: "") }
        return candidate
    }

    private func containsCriticalConnector(in text: String) -> Bool {
        let markers = ["因为", "由于", "如果", "虽然", "但是", "不过", "另外", "同时"]
        return markers.contains { text.contains($0) }
    }

    private func losesQuestionIntent(input: String, output: String) -> Bool {
        return hasQuestionIntent(in: input) && !hasQuestionIntent(in: output)
    }

    private func hasQuestionIntent(in text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return false
        }

        if normalized.contains("?") || normalized.contains("？") {
            return true
        }

        let markers = [
            "吗", "么", "呢", "为何", "为什么", "是否", "是不是",
            "哪", "哪些", "哪一些", "如何", "怎么", "怎样", "多少", "几"
        ]
        return markers.contains { normalized.contains($0) }
    }

    private func isLikelyOverRephrased(input: String, output: String) -> Bool {
        let inputCoreCount = coreCharacterCount(in: input)
        guard inputCoreCount >= 8, inputCoreCount <= 32 else {
            return false
        }
        guard !hasHeavyCleanupSignals(in: input) else {
            return false
        }

        let inputComparable = canonicalComparableText(input)
        let outputComparable = canonicalComparableText(output)
        guard !inputComparable.isEmpty, !outputComparable.isEmpty else {
            return false
        }
        guard inputComparable != outputComparable else {
            return false
        }

        let similarity = lcsSimilarity(lhs: inputComparable, rhs: outputComparable)
        return similarity < 0.72
    }

    private func hasHeavyCleanupSignals(in text: String) -> Bool {
        let fillerTerms = ["嗯", "呃", "啊", "额", "哦", "唉", "诶", "那个", "就是", "然后", "的话"]
        if fillerTerms.contains(where: { text.contains($0) }) {
            return true
        }

        if text.range(of: #"[，。！？；][，。！？；]"#, options: .regularExpression) != nil {
            return true
        }

        if text.range(of: #"[A-Za-z](?:\s+[A-Za-z]){1,}"#, options: .regularExpression) != nil {
            return true
        }

        if text.range(of: #"百分之|[零〇一二两三四五六七八九十百千万亿]点|[零〇一二两三四五六七八九十百千万亿]+\s*(个|次|版|年|月|天|小时|分钟|秒|项|条|种|倍|场景|版本)"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private func canonicalComparableText(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar.properties.isIdeographic
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private func lcsSimilarity(lhs: String, rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty, !right.isEmpty else {
            return 0
        }

        var previous = Array(repeating: 0, count: right.count + 1)
        var current = Array(repeating: 0, count: right.count + 1)

        for i in 1...left.count {
            current[0] = 0
            for j in 1...right.count {
                if left[i - 1] == right[j - 1] {
                    current[j] = previous[j - 1] + 1
                } else {
                    current[j] = max(previous[j], current[j - 1])
                }
            }
            swap(&previous, &current)
        }

        let lcs = previous[right.count]
        let base = max(left.count, right.count)
        return base == 0 ? 0 : Double(lcs) / Double(base)
    }

    private func coreCharacterCount(in text: String) -> Int {
        return text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) || scalar.properties.isIdeographic {
                count += 1
            }
        }
    }

}
