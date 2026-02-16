import Foundation

final class LLMTextOptimizer: @unchecked Sendable {
    struct ProviderOption {
        let rawValue: String
        let displayName: String
    }

    private static let providerOverrideKey = "voiceinput.llm.provider.override"
    nonisolated(unsafe) private static let providerTypes: [LLMTextOptimizeProvider.Type] = [
        LocalMLXLLMProvider.self,
        MiniMaxLLMProvider.self,
        TencentHunyuanLLMProvider.self
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
                completion(.success(normalized))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func providerDisplayName() -> String {
        return Self.displayName(for: providerRawValue) ?? providerRawValue
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

        return unwrapped
    }
}
