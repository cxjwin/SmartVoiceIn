import Foundation
@preconcurrency import Qwen3ASR

private final class CompletionRelay: @unchecked Sendable {
    private let completion: (Result<String, Error>) -> Void

    init(_ completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
    }

    func send(_ result: Result<String, Error>) {
        DispatchQueue.main.async {
            self.completion(result)
        }
    }
}

private final class VoidCompletionRelay: @unchecked Sendable {
    private let completion: (Result<Void, Error>) -> Void

    init(_ completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
    }

    func send(_ result: Result<Void, Error>) {
        DispatchQueue.main.async {
            self.completion(result)
        }
    }
}

private final class StatusRelay: @unchecked Sendable {
    private let onStatus: (String) -> Void

    init(_ onStatus: @escaping (String) -> Void) {
        self.onStatus = onStatus
    }

    func send(_ status: String) {
        DispatchQueue.main.async {
            self.onStatus(status)
        }
    }
}

private actor Qwen3ModelStore {
    enum LoadingState {
        case unloaded
        case loading
        case loaded
    }

    private let modelId: String
    private let statusRelay: StatusRelay?
    private var loadedModel: Qwen3ASRModel?
    private var isLoading = false

    init(modelId: String, statusRelay: StatusRelay? = nil) {
        self.modelId = modelId
        self.statusRelay = statusRelay
    }

    func loadingState() -> LoadingState {
        if loadedModel != nil {
            return .loaded
        }
        return isLoading ? .loading : .unloaded
    }

    func model() async throws -> Qwen3ASRModel {
        if let loadedModel {
            return loadedModel
        }

        while isLoading {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let loadedModel {
                return loadedModel
            }
        }

        isLoading = true
        defer { isLoading = false }
        let statusRelay = self.statusRelay

        let model = try await Qwen3ASRModel.fromPretrained(
            modelId: modelId,
            progressHandler: { progress, stage in
                let percent = max(0, min(100, Int(progress * 100)))
                AppLog.log("[Qwen3ASR] \(stage) \(percent)%")
                statusRelay?.send("正在加载 Qwen3 模型：\(stage) \(percent)%")
            }
        )
        loadedModel = model
        statusRelay?.send("Qwen3 模型加载完成")
        return model
    }
}

final class Qwen3ASRProvider: ASRProvider, @unchecked Sendable {
    let name = "Qwen3-ASR"
    static let defaultModelID = "mlx-community/Qwen3-ASR-0.6B-4bit"
    static let largeModelID = "mlx-community/Qwen3-ASR-1.7B-8bit"
    static let legacyUnsupportedLargeModelID = "mlx-community/Qwen3-ASR-1.7B-4bit"
    static let supportedModelIDs: [String] = [defaultModelID, largeModelID]
    private let modelStore: Qwen3ModelStore

    init(
        modelId: String = ProcessInfo.processInfo.environment["VOICEINPUT_QWEN3_MODEL"] ?? defaultModelID,
        statusReporter: ((String) -> Void)? = nil
    ) {
        let statusRelay = statusReporter.map(StatusRelay.init)
        self.modelStore = Qwen3ModelStore(modelId: modelId, statusRelay: statusRelay)
    }

    static func normalizedSupportedModelID(from rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }

        if normalized == legacyUnsupportedLargeModelID {
            return largeModelID
        }

        switch normalized.lowercased() {
        case "0.6b", "small":
            return defaultModelID
        case "1.7b", "large":
            return largeModelID
        default:
            return supportedModelIDs.contains(normalized) ? normalized : nil
        }
    }

    func recognize(
        audioPCMData: Data,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let relay = CompletionRelay(completion)

        Task { [weak self] in
            guard let self else { return }
            do {
                let samples = try Self.makeFloatSamples(
                    fromPCMData: audioPCMData,
                    channels: channels,
                    bitsPerSample: bitsPerSample
                )
                guard !samples.isEmpty else {
                    throw NSError(
                        domain: "Qwen3ASRProvider",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "音频数据为空"]
                    )
                }

                let loadingState = await self.modelStore.loadingState()
                if case .loading = loadingState {
                    throw NSError(
                        domain: "Qwen3ASRProvider",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "Qwen3 模型仍在加载中，请稍后重试"]
                    )
                }

                let model = try await self.modelStore.model()
                let text = model
                    .transcribe(audio: samples, sampleRate: sampleRate)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw NSError(
                        domain: "Qwen3ASRProvider",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "识别结果为空"]
                    )
                }

                relay.send(.success(text))
            } catch {
                relay.send(.failure(error))
            }
        }
    }

    func prewarm(completion: @escaping (Result<Void, Error>) -> Void) {
        let relay = VoidCompletionRelay(completion)
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.modelStore.model()
                relay.send(.success(()))
            } catch {
                relay.send(.failure(error))
            }
        }
    }

    private static func makeFloatSamples(
        fromPCMData pcmData: Data,
        channels: Int,
        bitsPerSample: Int
    ) throws -> [Float] {
        guard bitsPerSample == 16 else {
            throw NSError(
                domain: "Qwen3ASRProvider",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "仅支持 16-bit PCM"]
            )
        }

        let safeChannels = max(channels, 1)
        let bytesPerSample = MemoryLayout<Int16>.size
        let sampleCount = pcmData.count / bytesPerSample
        let frameCount = sampleCount / safeChannels
        var samples = [Float](repeating: 0, count: frameCount)

        pcmData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for frame in 0..<frameCount {
                let index = frame * safeChannels
                if index < int16Buffer.count {
                    let sample = Int16(littleEndian: int16Buffer[index])
                    samples[frame] = Float(sample) / 32768.0
                }
            }
        }

        return samples
    }
}
