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

private actor Qwen3ModelStore {
    private let modelId: String
    private var loadedModel: Qwen3ASRModel?
    private var isLoading = false

    init(modelId: String) {
        self.modelId = modelId
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

        let model = try await Qwen3ASRModel.fromPretrained(
            modelId: modelId,
            progressHandler: { progress, stage in
                print("[Qwen3ASR] \(stage) \(Int(progress * 100))%")
            }
        )
        loadedModel = model
        return model
    }
}

final class Qwen3ASRProvider: ASRProvider, @unchecked Sendable {
    let name = "Qwen3-ASR"
    private let modelStore: Qwen3ModelStore

    init(
        modelId: String = ProcessInfo.processInfo.environment["VOICEINPUT_QWEN3_MODEL"] ?? "mlx-community/Qwen3-ASR-0.6B-4bit"
    ) {
        self.modelStore = Qwen3ModelStore(modelId: modelId)
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
