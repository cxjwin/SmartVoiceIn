import Foundation
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon

private actor LocalMLXModelStore {
    private let modelId: String
    private var modelContainer: ModelContainer?
    private var isLoading = false

    init(modelId: String) {
        self.modelId = modelId
    }

    func container() async throws -> ModelContainer {
        if let modelContainer {
            return modelContainer
        }

        while isLoading {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let modelContainer {
                return modelContainer
            }
        }

        isLoading = true
        defer { isLoading = false }

        let loaded = try await LLMModelFactory.shared.loadContainer(
            configuration: .init(id: modelId),
            progressHandler: { progress in
                let value = progress.fractionCompleted
                if value >= 0 {
                    print("[LocalLLM] \(self.modelId) loading \(Int(value * 100))%")
                }
            }
        )
        modelContainer = loaded
        return loaded
    }

    func hasLoadedContainer() -> Bool {
        return modelContainer != nil
    }

    func releaseLoadedContainer() -> Bool {
        guard modelContainer != nil else {
            return false
        }
        modelContainer = nil
        return true
    }
}

final class LocalMLXLLMProvider: LLMTextOptimizeProvider, @unchecked Sendable {
    static let rawValue = "local_mlx"
    static let displayName = "本地 MLX (Qwen2.5-0.5B)"

    private let modelStore: LocalMLXModelStore
    private let generateParameters: GenerateParameters

    required init?(configuration: LLMTextOptimizeConfiguration) {
        let env = configuration.environment
        let modelId = env["VOICEINPUT_LOCAL_LLM_MODEL"] ?? "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
        let configuredMaxTokens = Int(env["VOICEINPUT_LOCAL_LLM_MAX_TOKENS"] ?? "") ?? 160
        let maxTokens = max(64, configuredMaxTokens)

        self.modelStore = LocalMLXModelStore(modelId: modelId)
        self.generateParameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: 0,
            topP: 1.0
        )
    }

    func prewarm(completion: @escaping (Result<Void, Error>) -> Void) {
        let relay = LLMVoidCompletionRelay(completion)
        Task {
            do {
                _ = try await modelStore.container()
                relay.resolve(.success(()))
            } catch {
                relay.resolve(.failure(error))
            }
        }
    }

    func keepAliveIfLoaded(completion: @escaping (Bool) -> Void) {
        let relay = LocalLLMKeepAliveRelay(completion)
        Task {
            let loaded = await modelStore.hasLoadedContainer()
            relay.resolve(loaded)
        }
    }

    func releaseLoadedModel(completion: @escaping (Result<Bool, Error>) -> Void) {
        let relay = LocalLLMBoolRelay(completion)
        Task {
            let released = await modelStore.releaseLoadedContainer()
            relay.resolve(.success(released))
        }
    }

    func optimize(text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let relay = LLMCompletionRelay(completion)
        let userPrompt = buildOptimizationUserPrompt(userText: text)

        Task {
            do {
                let container = try await modelStore.container()
                let session = ChatSession(
                    container,
                    instructions: optimizationSystemPrompt,
                    generateParameters: generateParameters
                )
                let output = try await session.respond(to: userPrompt)
                relay.resolve(.success(output))
            } catch {
                relay.resolve(.failure(error))
            }
        }
    }
}

private final class LocalLLMBoolRelay: @unchecked Sendable {
    private let completion: (Result<Bool, Error>) -> Void

    init(_ completion: @escaping (Result<Bool, Error>) -> Void) {
        self.completion = completion
    }

    func resolve(_ result: Result<Bool, Error>) {
        completion(result)
    }
}

private final class LocalLLMKeepAliveRelay: @unchecked Sendable {
    private let completion: (Bool) -> Void

    init(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    func resolve(_ value: Bool) {
        completion(value)
    }
}
