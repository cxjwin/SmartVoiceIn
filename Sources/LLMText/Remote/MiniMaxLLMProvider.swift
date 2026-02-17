import Foundation

final class MiniMaxLLMProvider: LLMTextOptimizeProvider, @unchecked Sendable {
    static let rawValue = "minimax_text"
    static let displayName = "MiniMax"

    private enum ThinkingMode {
        case disabled
        case enabled
    }

    private let endpoint: URL
    private let timeout: TimeInterval
    private let apiKey: String
    private let anthropicVersion: String
    private let model: String
    private let temperature: Double
    private let topP: Double
    private let thinkingMode: ThinkingMode

    required init?(configuration: LLMTextOptimizeConfiguration) {
        let env = configuration.environment

        let apiKey = env["VOICEINPUT_MINIMAX_API_KEY"]
            ?? env["MINIMAX_API_KEY"]
            ?? configuration.fallbackMiniMaxAPIKey
            ?? ""
        guard !apiKey.isEmpty else {
            return nil
        }

        let endpointString = env["VOICEINPUT_MINIMAX_ENDPOINT"] ?? "https://api.minimaxi.com/anthropic/v1/messages"
        guard let endpoint = URL(string: endpointString) else {
            return nil
        }

        let modelRaw = env["VOICEINPUT_MINIMAX_MODEL"] ?? ""
        let configuredTemperature = Double(env["VOICEINPUT_LLM_TEMPERATURE"] ?? "") ?? 0.8
        let configuredTopP = Double(env["VOICEINPUT_MINIMAX_TOP_P"] ?? "") ?? 0.95

        let thinkingRaw = (env["VOICEINPUT_MINIMAX_THINKING"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let thinkingMode: ThinkingMode
        switch thinkingRaw {
        case "1", "true", "on", "enabled":
            thinkingMode = .enabled
        default:
            thinkingMode = .disabled
        }

        self.endpoint = endpoint
        self.timeout = configuration.timeout
        self.apiKey = apiKey
        self.anthropicVersion = env["VOICEINPUT_MINIMAX_ANTHROPIC_VERSION"] ?? "2023-06-01"
        self.model = modelRaw.isEmpty ? "MiniMax-M2.5-highspeed" : modelRaw
        self.temperature = min(max(configuredTemperature, 0.01), 1.0)
        self.topP = min(max(configuredTopP, 0), 1)
        self.thinkingMode = thinkingMode
    }

    func optimize(text: String, templatePromptOverride: String?, completion: @escaping (Result<String, Error>) -> Void) {
        let relay = LLMCompletionRelay(completion)

        let prompt = buildOptimizationPromptRequest(
            userText: text,
            templatePromptOverride: templatePromptOverride
        )

        var bodyObject: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": prompt.userPrompt
                        ]
                    ]
                ]
            ],
            "temperature": temperature,
            "top_p": topP,
            "stream": false
        ]

        if let systemPrompt = prompt.systemPrompt, !systemPrompt.isEmpty {
            bodyObject["system"] = systemPrompt
        }

        switch thinkingMode {
        case .disabled:
            bodyObject["thinking"] = ["type": "disabled"]
        case .enabled:
            bodyObject["thinking"] = ["type": "enabled"]
        }

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: bodyObject, options: [])
        } catch {
            relay.resolve(.failure(error))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                relay.resolve(.failure(error))
                return
            }
            guard let data else {
                relay.resolve(.failure(NSError(domain: "LLMTextOptimizer", code: -30, userInfo: [NSLocalizedDescriptionKey: "MiniMax 返回为空"])))
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode"
                    relay.resolve(.failure(NSError(domain: "LLMTextOptimizer", code: -31, userInfo: [NSLocalizedDescriptionKey: "MiniMax 响应解析失败: \(responseString)"])))
                    return
                }

                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    let message = (json["error"] as? [String: Any])?["message"] as? String
                        ?? json["message"] as? String
                        ?? "MiniMax HTTP \(httpResponse.statusCode)"
                    relay.resolve(.failure(NSError(domain: "LLMTextOptimizer", code: -32, userInfo: [NSLocalizedDescriptionKey: message])))
                    return
                }

                if let errorObject = json["error"] as? [String: Any] {
                    let message = errorObject["message"] as? String ?? "MiniMax API error"
                    relay.resolve(.failure(NSError(domain: "LLMTextOptimizer", code: -33, userInfo: [NSLocalizedDescriptionKey: message])))
                    return
                }

                if let text = extractTextFromAnthropicStyle(response: json) {
                    relay.resolve(.success(text))
                    return
                }

                if let text = extractTextFromOpenAIStyle(response: json) {
                    relay.resolve(.success(text))
                    return
                }

                let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode"
                let snippet = String(responseString.prefix(600))
                relay.resolve(
                    .failure(
                        NSError(
                            domain: "LLMTextOptimizer",
                            code: -34,
                            userInfo: [NSLocalizedDescriptionKey: "MiniMax 响应不含文本（可能仅返回 thinking）: \(snippet)"]
                        )
                    )
                )
            } catch {
                relay.resolve(.failure(error))
            }
        }.resume()
    }

    func providerModelIdentifier() -> String? {
        return model
    }
}
