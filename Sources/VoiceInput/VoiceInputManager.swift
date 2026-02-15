import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech

class VoiceInputManager: NSObject {
    private enum ASRProviderType: String {
        case qwen3Local = "qwen3_local"
        case appleSpeech = "apple_speech"
        case tencentCloud = "tencent_cloud"
    }

    private static let asrProviderOverrideKey = "voiceinput.asr.provider.override"
    private static let tencentSecretIdOverrideKey = "voiceinput.tencent.secret_id.override"
    private static let tencentSecretKeyOverrideKey = "voiceinput.tencent.secret_key.override"

    static let supportedASRProviderRawValues = [
        ASRProviderType.qwen3Local.rawValue,
        ASRProviderType.appleSpeech.rawValue,
        ASRProviderType.tencentCloud.rawValue
    ]

    static func currentASRProviderRawValue() -> String {
        let defaults = UserDefaults.standard
        if let override = defaults.string(forKey: asrProviderOverrideKey), !override.isEmpty {
            return override
        }
        return ProcessInfo.processInfo.environment["VOICEINPUT_ASR_PROVIDER"] ?? ASRProviderType.qwen3Local.rawValue
    }

    static func setASRProviderOverride(rawValue: String) {
        UserDefaults.standard.set(rawValue, forKey: asrProviderOverrideKey)
    }

    var isRecording = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let llmKeepAliveInterval: TimeInterval = 180
    private let llmKeepAliveMinIdleSeconds: TimeInterval = 180
    private var llmKeepAliveTimer: DispatchSourceTimer?
    private var llmMemoryPressureSource: DispatchSourceMemoryPressure?

    // 录音数据
    private var audioData = Data()

    private let onResult: (Result<String, Error>) -> Void
    private let onStatusUpdate: ((String) -> Void)?
    private var recognizedText = ""
    private var hasReturnedResult = false

    // 主 ASR（本地 Qwen3）
    private var asrProviderType: ASRProviderType = .qwen3Local
    private var asrProvider: ASRProvider?
    private var llmTextOptimizer: LLMTextOptimizer?
    private var tencentSecretId: String?
    private var tencentSecretKey: String?
    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1
    private let targetBitsPerSample = 16

    init(
        onResult: @escaping (Result<String, Error>) -> Void,
        onStatusUpdate: ((String) -> Void)? = nil
    ) {
        self.onResult = onResult
        self.onStatusUpdate = onStatusUpdate

        let env = ProcessInfo.processInfo.environment
        if let persisted = Self.loadPersistedTencentCredentials() {
            self.tencentSecretId = persisted.secretId
            self.tencentSecretKey = persisted.secretKey
            print("[SmartVoiceIn] Loaded persisted Tencent credentials from local storage")
        } else {
            self.tencentSecretId = env["VOICEINPUT_TENCENT_SECRET_ID"]
            self.tencentSecretKey = env["VOICEINPUT_TENCENT_SECRET_KEY"]
        }
        self.asrProviderType = ASRProviderType(rawValue: Self.currentASRProviderRawValue()) ?? .qwen3Local
        let hasTencentCredentialsAtStartup =
            (self.tencentSecretId?.isEmpty == false) && (self.tencentSecretKey?.isEmpty == false)
        if self.asrProviderType == .tencentCloud && !hasTencentCredentialsAtStartup {
            self.asrProviderType = .qwen3Local
            Self.setASRProviderOverride(rawValue: ASRProviderType.qwen3Local.rawValue)
            print("[SmartVoiceIn] Requested ASR provider is unavailable at startup, fallback to Qwen3 local model")
        }

        self.llmTextOptimizer = LLMTextOptimizer(
            fallbackTencentSecretId: tencentSecretId,
            fallbackTencentSecretKey: tencentSecretKey
        )
        let shouldPrewarmLLMAtStartup = (self.llmTextOptimizer != nil)
        if self.llmTextOptimizer == nil {
            print("[SmartVoiceIn] LLM optimizer disabled (startup, missing/invalid provider config), using local clean only")
        } else {
            print("[SmartVoiceIn] LLM optimizer enabled (startup)")
        }

        // 初始化苹果语音识别器（备用）
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        super.init()
        configureASRProvider()
        self.speechRecognizer?.delegate = self
        startLLMRuntimeGuards()
        if shouldPrewarmLLMAtStartup {
            prewarmLocalLLMIfNeeded(reason: "startup")
        }
    }

    deinit {
        llmKeepAliveTimer?.cancel()
        llmKeepAliveTimer = nil
        llmMemoryPressureSource?.cancel()
        llmMemoryPressureSource = nil
    }

    func currentTextOptimizeProviderRawValue() -> String {
        return LLMTextOptimizer.currentProviderRawValue()
    }

    func currentASRProviderRawValue() -> String {
        return asrProviderType.rawValue
    }

    @discardableResult
    func updateASRProvider(rawValue: String) -> Bool {
        guard let providerType = ASRProviderType(rawValue: rawValue) else {
            return false
        }
        guard isASRProviderAvailable(providerType) else {
            return false
        }
        asrProviderType = providerType
        Self.setASRProviderOverride(rawValue: rawValue)
        configureASRProvider()
        return true
    }

    @discardableResult
    func updateTextOptimizeProvider(rawValue: String) -> Bool {
        guard LLMTextOptimizer.supportedProviderRawValues.contains(rawValue) else {
            return false
        }
        LLMTextOptimizer.setProviderOverride(rawValue: rawValue)
        rebuildLLMTextOptimizer(logPrefix: "provider switch to \(rawValue)")
        return true
    }

    func currentTencentCredentialValues() -> (secretId: String, secretKey: String)? {
        guard let secretId = tencentSecretId, !secretId.isEmpty,
              let secretKey = tencentSecretKey, !secretKey.isEmpty else {
            return nil
        }
        return (secretId, secretKey)
    }

    func hasTencentCredentialsConfigured() -> Bool {
        return currentTencentCredentialValues() != nil
    }

    @discardableResult
    func updateTencentCredentials(secretId: String, secretKey: String) -> Bool {
        let normalizedSecretId = secretId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSecretKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSecretId.isEmpty, !normalizedSecretKey.isEmpty else {
            return false
        }

        tencentSecretId = normalizedSecretId
        tencentSecretKey = normalizedSecretKey
        Self.persistTencentCredentials(secretId: normalizedSecretId, secretKey: normalizedSecretKey)
        rebuildLLMTextOptimizer(logPrefix: "credentials updated")
        if asrProviderType == .tencentCloud {
            configureASRProvider()
        }
        return true
    }

    private func isASRProviderAvailable(_ providerType: ASRProviderType) -> Bool {
        switch providerType {
        case .tencentCloud:
            return hasTencentCredentialsConfigured()
        case .qwen3Local, .appleSpeech:
            return true
        }
    }

    private func rebuildLLMTextOptimizer(logPrefix: String) {
        llmTextOptimizer = LLMTextOptimizer(
            fallbackTencentSecretId: tencentSecretId,
            fallbackTencentSecretKey: tencentSecretKey
        )
        if llmTextOptimizer == nil {
            print("[SmartVoiceIn] LLM optimizer disabled (\(logPrefix), missing/invalid provider config), using local clean only")
        } else {
            print("[SmartVoiceIn] LLM optimizer enabled (\(logPrefix))")
            prewarmLocalLLMIfNeeded(reason: logPrefix)
        }
    }

    private func prewarmLocalLLMIfNeeded(reason: String) {
        guard let llmTextOptimizer else {
            return
        }
        llmTextOptimizer.prewarmIfNeeded { result in
            switch result {
            case .success:
                print("[SmartVoiceIn] Local LLM prewarm completed (\(reason))")
            case .failure(let error):
                print("[SmartVoiceIn] Local LLM prewarm failed (\(reason)): \(error)")
            }
        }
    }

    private func startLLMRuntimeGuards() {
        startLLMKeepAliveTimer()
        startLLMMemoryPressureMonitor()
    }

    private func startLLMKeepAliveTimer() {
        guard llmKeepAliveTimer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + llmKeepAliveInterval,
            repeating: llmKeepAliveInterval
        )
        timer.setEventHandler { [weak self] in
            self?.handleLLMKeepAliveTick()
        }
        llmKeepAliveTimer = timer
        timer.resume()
    }

    private func handleLLMKeepAliveTick() {
        guard let llmTextOptimizer else {
            return
        }
        llmTextOptimizer.keepAliveIfNeeded(minIdleSeconds: llmKeepAliveMinIdleSeconds) { keptAlive in
            if keptAlive {
                print("[SmartVoiceIn] Local LLM keep-alive tick completed")
            }
        }
    }

    private func startLLMMemoryPressureMonitor() {
        guard llmMemoryPressureSource == nil else {
            return
        }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.handleLLMMemoryPressureEvent()
        }
        llmMemoryPressureSource = source
        source.resume()
    }

    private func handleLLMMemoryPressureEvent() {
        let event = llmMemoryPressureSource?.data ?? []
        let level = event.contains(.critical) ? "critical" : "warning"
        print("[SmartVoiceIn] Memory pressure detected (\(level)), releasing local LLM resources")

        llmTextOptimizer?.releaseLocalResources { result in
            switch result {
            case .success(let released):
                if released {
                    print("[SmartVoiceIn] Local LLM resources released due to memory pressure")
                } else {
                    print("[SmartVoiceIn] Local LLM release skipped (not loaded or non-local provider)")
                }
            case .failure(let error):
                print("[SmartVoiceIn] Local LLM release failed under memory pressure: \(error)")
            }
        }
    }

    private static func loadPersistedTencentCredentials() -> (secretId: String, secretKey: String)? {
        let defaults = UserDefaults.standard
        guard let secretId = defaults.string(forKey: tencentSecretIdOverrideKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secretKey = defaults.string(forKey: tencentSecretKeyOverrideKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secretId.isEmpty,
              !secretKey.isEmpty else {
            return nil
        }
        return (secretId, secretKey)
    }

    private static func persistTencentCredentials(secretId: String, secretKey: String) {
        let defaults = UserDefaults.standard
        defaults.set(secretId, forKey: tencentSecretIdOverrideKey)
        defaults.set(secretKey, forKey: tencentSecretKeyOverrideKey)
    }

    private func configureASRProvider() {
        switch asrProviderType {
        case .qwen3Local:
            asrProvider = Qwen3ASRProvider()
            print("[SmartVoiceIn] ASR provider switched to Qwen3 local model")
        case .appleSpeech:
            asrProvider = nil
            print("[SmartVoiceIn] ASR provider switched to Apple Speech")
        case .tencentCloud:
            guard let credentials = currentTencentCredentialValues() else {
                asrProvider = nil
                print("[SmartVoiceIn] ASR provider switch failed: Tencent credentials missing")
                return
            }
            asrProvider = TencentASRProvider(secretId: credentials.secretId, secretKey: credentials.secretKey)
            print("[SmartVoiceIn] ASR provider switched to Tencent Cloud")
        }
    }

    func startRecording() {
        print("[SmartVoiceIn] Starting recording...")
        recognizedText = ""
        hasReturnedResult = false
        audioData = Data()

        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("[SmartVoiceIn] Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        // 使用 16kHz 采样率
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else {
            print("[SmartVoiceIn] Cannot create 16kHz format")
            onResult(.failure(NSError(domain: "SmartVoiceIn", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法创建音频格式"])))
            return
        }

        print("[SmartVoiceIn] Target format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")

        // 安装重采样器
        guard let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            print("[SmartVoiceIn] Cannot create converter from \(inputFormat) to \(recordingFormat)")
            onResult(.failure(NSError(domain: "SmartVoiceIn", code: 5, userInfo: [NSLocalizedDescriptionKey: "无法创建转换器"])))
            return
        }

        // 安装 tap 来收集音频数据
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.convertBuffer(buffer: buffer, converter: converter, outputFormat: recordingFormat)
        }

        // 启动音频引擎
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            print("[SmartVoiceIn] Audio engine started")
        } catch {
            print("[SmartVoiceIn] Failed to start audio engine: \(error)")
            onResult(.failure(error))
        }
    }

    /// 转换音频缓冲区
    private func convertBuffer(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            print("[SmartVoiceIn] Cannot create converted buffer")
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("[SmartVoiceIn] Convert error: \(error)")
            return
        }

        if let channelData = convertedBuffer.int16ChannelData {
            let frameLength = Int(convertedBuffer.frameLength)
            let data = Data(bytes: channelData[0], count: frameLength * 2)
            audioData.append(data)
            print("[SmartVoiceIn] Appended \(data.count) bytes (frames: \(frameLength)), total: \(audioData.count)")
        } else {
            print("[SmartVoiceIn] No int16 channel data")
        }
    }

    func stopRecording() {
        print("[SmartVoiceIn] Stopping recording...")
        isRecording = false

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        let dataSize = audioData.count
        print("[SmartVoiceIn] Collected audio data: \(dataSize) bytes")

        guard dataSize > 0 else {
            print("[SmartVoiceIn] No audio data collected")
            recognizeWithLocalFallback()
            return
        }

        if asrProviderType == .appleSpeech {
            print("[SmartVoiceIn] Using Apple Speech ASR...")
            recognizeWithLocalFallback()
            return
        }

        guard let asrProvider else {
            print("[SmartVoiceIn] No ASR provider, using local fallback")
            recognizeWithLocalFallback()
            return
        }

        print("[SmartVoiceIn] Using \(asrProvider.name) ASR...")
        asrProvider.recognize(
            audioPCMData: audioData,
            sampleRate: Int(targetSampleRate),
            channels: Int(targetChannels),
            bitsPerSample: targetBitsPerSample
        ) { [weak self] result in
            switch result {
            case .success(let text):
                print("[SmartVoiceIn] \(asrProvider.name) ASR success: \(text)")
                self?.postProcessRecognizedText(text)
            case .failure(let error):
                print("[SmartVoiceIn] \(asrProvider.name) ASR failed: \(error), falling back to local")
                self?.recognizeWithLocalFallback()
            }
        }
    }

    /// 使用本地苹果 Speech Framework 作为备用
    private func recognizeWithLocalFallback() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            onResult(.failure(NSError(domain: "SmartVoiceIn", code: 2, userInfo: [NSLocalizedDescriptionKey: "语音识别不可用"])))
            return
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("voice_input.wav")

        do {
            let wavData = createWAVFile(
                data: audioData,
                sampleRate: Int(targetSampleRate),
                channels: Int(targetChannels),
                bitsPerSample: targetBitsPerSample
            )
            try wavData.write(to: tempURL)

            let request = SFSpeechURLRecognitionRequest(url: tempURL)
            request.shouldReportPartialResults = false

            recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let result = result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    print("[SmartVoiceIn] Local ASR success: \(text)")
                    self?.postProcessRecognizedText(text)
                }
                if let error = error {
                    print("[SmartVoiceIn] Local ASR error: \(error)")
                    self?.onResult(.failure(error))
                }
            }
        } catch {
            print("[SmartVoiceIn] Failed to save audio file: \(error)")
            onResult(.failure(error))
        }
    }

    /// 创建 WAV 文件
    private func createWAVFile(data: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        var wavData = Data()

        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = data.count
        let fileSize = dataSize + 36

        // RIFF header
        wavData.append(contentsOf: "RIFF".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        wavData.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        wavData.append(contentsOf: "fmt ".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })

        // data chunk
        wavData.append(contentsOf: "data".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        wavData.append(data)

        return wavData
    }

    /// 清理文本，去除语气词和明显重复。
    /// - parameter aggressive: `true` 时也会清理“然后/就是/这个”等口头禅；`false` 仅清理高置信语气词（如“呃/嗯/uh”）
    private static func cleanText(_ text: String, aggressive: Bool = true) -> String {
        var result = text

        let lightFillers = [
            "嗯嗯", "嗯啊", "啊嗯", "啊啊", "嗯呢",
            "嗯", "啊", "呀", "哦", "额", "呃", "唔",
            "uh", "um", "ah"
        ]
        let aggressiveOnlyFillers = ["那个", "然后", "就是", "其实", "这个"]
        let fillers = aggressive ? (lightFillers + aggressiveOnlyFillers) : lightFillers

        result = removeStandaloneFillers(result, fillers: fillers)

        if let regex = try? NSRegularExpression(pattern: "(.)\\1{2,}", options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        result = normalizePunctuationAndWhitespace(result)

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let punctuationToRemove = ["...", "。", "，", "、", "；", "：", "？", "！"]
        for p in punctuationToRemove {
            if result.hasSuffix(p) {
                result = String(result.dropLast())
            }
            if result.hasPrefix(p) {
                result = String(result.dropFirst())
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeStandaloneFillers(_ text: String, fillers: [String]) -> String {
        guard !fillers.isEmpty else {
            return text
        }

        let escaped = fillers.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let separators = "\\s,，。！？!?：:；;、()（）\\[\\]【】\"“”'‘’"
        let pattern = "(^|[\(separators)])(\(escaped))(?=($|[\(separators)]))"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        var result = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1"
        )

        // 处理紧连的重复语气词，例如“呃呃”、“嗯嗯嗯”
        let repeatedLightFillerPattern = "(?:呃|额|嗯|啊|哦|唔){2,}"
        if let repeatedRegex = try? NSRegularExpression(pattern: repeatedLightFillerPattern, options: []) {
            result = repeatedRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        return result
    }

    private static func normalizePunctuationAndWhitespace(_ text: String) -> String {
        var result = text

        if let regex = try? NSRegularExpression(pattern: "\\s+", options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }

        if let regex = try? NSRegularExpression(pattern: "\\s*([，。！？；：、,.!?;:])\\s*", options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        if let regex = try? NSRegularExpression(pattern: "([，、,.]){2,}", options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        if let regex = try? NSRegularExpression(pattern: "([。！？!?]){2,}", options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        return result
    }

    /// 统一后处理：优先大模型，失败时回退本地清洗
    private func postProcessRecognizedText(_ text: String) {
        print("[SmartVoiceIn] Post-processing text started")
        let callback = onResult
        if let llmTextOptimizer {
            print("[SmartVoiceIn] Running LLM text optimization...")
            onStatusUpdate?("正在转换中（LLM 文本优化）...")
            llmTextOptimizer.optimize(text: text) { result in
                switch result {
                case .success(let optimized):
                    let finalized = Self.cleanText(optimized, aggressive: false)
                    print("[SmartVoiceIn] LLM optimized text: \(optimized)")
                    if finalized != optimized {
                        print("[SmartVoiceIn] LLM post-cleaned text: \(finalized)")
                    }
                    callback(.success(finalized))
                case .failure(let error):
                    print("[SmartVoiceIn] LLM optimization failed: \(error), fallback to local clean")
                    self.onStatusUpdate?("转换失败，正在回退本地清洗...")
                    let cleanedText = Self.cleanText(text)
                    callback(.success(cleanedText))
                }
            }
        } else {
            print("[SmartVoiceIn] LLM optimizer unavailable, fallback to local clean")
            let cleanedText = Self.cleanText(text)
            print("[SmartVoiceIn] Local cleaned text: \(cleanedText)")
            onResult(.success(cleanedText))
        }
    }

    private func stopAudioEngine() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest = nil
        recognitionTask = nil
    }
}

extension VoiceInputManager: SFSpeechRecognizerDelegate {
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        print("[SmartVoiceIn] Availability changed: \(available)")
    }
}
