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
    private static let qwen3ASRModelOverrideKey = "voiceinput.qwen3.asr.model.override"
    private static let localLLMModelOverrideKey = "voiceinput.local_llm.model.override"
    private static let tencentSecretIdOverrideKey = "voiceinput.tencent.secret_id.override"
    private static let tencentSecretKeyOverrideKey = "voiceinput.tencent.secret_key.override"
    private static let minimaxAPIKeyOverrideKey = "voiceinput.minimax.api_key.override"

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
    private var qwen3ASRModelID: String?
    private var llmTextOptimizer: LLMTextOptimizer?
    private var localLLMModelID: String?
    private var tencentSecretId: String?
    private var tencentSecretKey: String?
    private var minimaxAPIKey: String?
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
        if let persistedQwen3ASRModelID = Self.loadPersistedQwen3ASRModelID() {
            self.qwen3ASRModelID = persistedQwen3ASRModelID
            AppLog.log("[SmartVoiceIn] Loaded persisted Qwen3 ASR model ID from local storage")
        } else {
            self.qwen3ASRModelID = env["VOICEINPUT_QWEN3_MODEL"]
        }
        if let currentQwen3ModelID = qwen3ASRModelID {
            if let normalizedQwen3ModelID = Qwen3ASRProvider.normalizedSupportedModelID(from: currentQwen3ModelID) {
                if normalizedQwen3ModelID != currentQwen3ModelID {
                    qwen3ASRModelID = normalizedQwen3ModelID
                    Self.persistQwen3ASRModelID(modelID: normalizedQwen3ModelID)
                    AppLog.log("[SmartVoiceIn] Normalized Qwen3 ASR model ID to supported value: \(normalizedQwen3ModelID)")
                }
            } else {
                qwen3ASRModelID = Qwen3ASRProvider.defaultModelID
                Self.persistQwen3ASRModelID(modelID: Qwen3ASRProvider.defaultModelID)
                AppLog.log("[SmartVoiceIn] Unsupported Qwen3 ASR model ID detected, fallback to default: \(Qwen3ASRProvider.defaultModelID)")
            }
        }
        if let persistedLocalLLMModelID = Self.loadPersistedLocalLLMModelID() {
            self.localLLMModelID = persistedLocalLLMModelID
            AppLog.log("[SmartVoiceIn] Loaded persisted local LLM model ID from local storage")
        } else {
            self.localLLMModelID = env["VOICEINPUT_LOCAL_LLM_MODEL"]
        }
        if let persisted = Self.loadPersistedTencentCredentials() {
            self.tencentSecretId = persisted.secretId
            self.tencentSecretKey = persisted.secretKey
            AppLog.log("[SmartVoiceIn] Loaded persisted Tencent credentials from local storage")
        } else {
            self.tencentSecretId = env["VOICEINPUT_TENCENT_SECRET_ID"]
            self.tencentSecretKey = env["VOICEINPUT_TENCENT_SECRET_KEY"]
        }
        if let persistedMiniMaxAPIKey = Self.loadPersistedMiniMaxAPIKey() {
            self.minimaxAPIKey = persistedMiniMaxAPIKey
            AppLog.log("[SmartVoiceIn] Loaded persisted MiniMax API key from local storage")
        } else {
            self.minimaxAPIKey = env["VOICEINPUT_MINIMAX_API_KEY"] ?? env["MINIMAX_API_KEY"]
        }
        self.asrProviderType = ASRProviderType(rawValue: Self.currentASRProviderRawValue()) ?? .qwen3Local
        let hasTencentCredentialsAtStartup =
            (self.tencentSecretId?.isEmpty == false) && (self.tencentSecretKey?.isEmpty == false)
        if self.asrProviderType == .tencentCloud && !hasTencentCredentialsAtStartup {
            self.asrProviderType = .qwen3Local
            Self.setASRProviderOverride(rawValue: ASRProviderType.qwen3Local.rawValue)
            AppLog.log("[SmartVoiceIn] Requested ASR provider is unavailable at startup, fallback to Qwen3 local model")
        }

        self.llmTextOptimizer = LLMTextOptimizer(
            fallbackLocalLLMModelID: localLLMModelID,
            fallbackTencentSecretId: tencentSecretId,
            fallbackTencentSecretKey: tencentSecretKey,
            fallbackMiniMaxAPIKey: minimaxAPIKey
        )
        let shouldPrewarmLLMAtStartup = (self.llmTextOptimizer != nil)
        if self.llmTextOptimizer == nil {
            AppLog.log("[SmartVoiceIn] LLM optimizer disabled (startup, missing/invalid provider config), using local clean only")
        } else {
            AppLog.log("[SmartVoiceIn] LLM optimizer enabled (startup)")
        }

        // 初始化苹果语音识别器（备用）
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        super.init()
        configureASRProvider(reason: "startup")
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
        configureASRProvider(reason: "provider switch")
        return true
    }

    @discardableResult
    func updateTextOptimizeProvider(rawValue: String) -> Bool {
        guard LLMTextOptimizer.supportedProviderRawValues.contains(rawValue) else {
            return false
        }

        let previousRawValue = LLMTextOptimizer.currentProviderRawValue()
        LLMTextOptimizer.setProviderOverride(rawValue: rawValue)
        rebuildLLMTextOptimizer(logPrefix: "provider switch to \(rawValue)")
        if llmTextOptimizer != nil {
            return true
        }

        LLMTextOptimizer.setProviderOverride(rawValue: previousRawValue)
        rebuildLLMTextOptimizer(logPrefix: "provider rollback to \(previousRawValue)")
        return false
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

    func currentMiniMaxAPIKeyValue() -> String? {
        guard let minimaxAPIKey, !minimaxAPIKey.isEmpty else {
            return nil
        }
        return minimaxAPIKey
    }

    func hasMiniMaxAPIKeyConfigured() -> Bool {
        return currentMiniMaxAPIKeyValue() != nil
    }

    func currentLocalLLMModelIDValue() -> String? {
        guard let localLLMModelID else {
            return nil
        }
        let normalized = localLLMModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    func currentQwen3ASRModelIDValue() -> String? {
        guard let qwen3ASRModelID else {
            return nil
        }
        let normalized = qwen3ASRModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
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
            configureASRProvider(reason: "tencent credentials updated")
        }
        return true
    }

    @discardableResult
    func updateMiniMaxAPIKey(apiKey: String) -> Bool {
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAPIKey.isEmpty else {
            return false
        }

        minimaxAPIKey = normalizedAPIKey
        Self.persistMiniMaxAPIKey(apiKey: normalizedAPIKey)
        rebuildLLMTextOptimizer(logPrefix: "MiniMax API key updated")
        return true
    }

    @discardableResult
    func updateLocalLLMModelID(modelID: String) -> Bool {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else {
            return false
        }

        localLLMModelID = normalizedModelID
        Self.persistLocalLLMModelID(modelID: normalizedModelID)
        rebuildLLMTextOptimizer(logPrefix: "local LLM model updated")
        return true
    }

    @discardableResult
    func updateQwen3ASRModelID(modelID: String) -> Bool {
        guard let normalizedModelID = Qwen3ASRProvider.normalizedSupportedModelID(from: modelID) else {
            return false
        }

        qwen3ASRModelID = normalizedModelID
        Self.persistQwen3ASRModelID(modelID: normalizedModelID)
        if asrProviderType == .qwen3Local {
            configureASRProvider(reason: "Qwen3 model updated")
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
            fallbackLocalLLMModelID: localLLMModelID,
            fallbackTencentSecretId: tencentSecretId,
            fallbackTencentSecretKey: tencentSecretKey,
            fallbackMiniMaxAPIKey: minimaxAPIKey
        )
        if llmTextOptimizer == nil {
            AppLog.log("[SmartVoiceIn] LLM optimizer disabled (\(logPrefix), missing/invalid provider config), using local clean only")
        } else {
            AppLog.log("[SmartVoiceIn] LLM optimizer enabled (\(logPrefix))")
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
                AppLog.log("[SmartVoiceIn] Local LLM prewarm completed (\(reason))")
            case .failure(let error):
                AppLog.log("[SmartVoiceIn] Local LLM prewarm failed (\(reason)): \(error)")
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
                AppLog.log("[SmartVoiceIn] Local LLM keep-alive tick completed")
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
        AppLog.log("[SmartVoiceIn] Memory pressure detected (\(level)), releasing local LLM resources")

        llmTextOptimizer?.releaseLocalResources { result in
            switch result {
            case .success(let released):
                if released {
                    AppLog.log("[SmartVoiceIn] Local LLM resources released due to memory pressure")
                } else {
                    AppLog.log("[SmartVoiceIn] Local LLM release skipped (not loaded or non-local provider)")
                }
            case .failure(let error):
                AppLog.log("[SmartVoiceIn] Local LLM release failed under memory pressure: \(error)")
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

    private static func loadPersistedMiniMaxAPIKey() -> String? {
        let defaults = UserDefaults.standard
        guard let apiKey = defaults.string(forKey: minimaxAPIKeyOverrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty else {
            return nil
        }
        return apiKey
    }

    private static func persistMiniMaxAPIKey(apiKey: String) {
        UserDefaults.standard.set(apiKey, forKey: minimaxAPIKeyOverrideKey)
    }

    private static func loadPersistedLocalLLMModelID() -> String? {
        let defaults = UserDefaults.standard
        guard let modelID = defaults.string(forKey: localLLMModelOverrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !modelID.isEmpty else {
            return nil
        }
        return modelID
    }

    private static func persistLocalLLMModelID(modelID: String) {
        UserDefaults.standard.set(modelID, forKey: localLLMModelOverrideKey)
    }

    private static func loadPersistedQwen3ASRModelID() -> String? {
        let defaults = UserDefaults.standard
        guard let modelID = defaults.string(forKey: qwen3ASRModelOverrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !modelID.isEmpty else {
            return nil
        }
        return modelID
    }

    private static func persistQwen3ASRModelID(modelID: String) {
        UserDefaults.standard.set(modelID, forKey: qwen3ASRModelOverrideKey)
    }

    private func configureASRProvider(reason: String) {
        switch asrProviderType {
        case .qwen3Local:
            let qwen3ModelID = currentQwen3ASRModelIDValue() ?? Qwen3ASRProvider.defaultModelID
            let provider = Qwen3ASRProvider(
                modelId: qwen3ModelID,
                statusReporter: { [weak self] status in
                    self?.onStatusUpdate?(status)
                }
            )
            asrProvider = provider
            AppLog.log("[SmartVoiceIn] ASR provider switched to Qwen3 local model (\(qwen3ModelID))")
            prewarmQwen3ASRIfNeeded(provider: provider, modelID: qwen3ModelID, reason: reason)
        case .appleSpeech:
            asrProvider = nil
            AppLog.log("[SmartVoiceIn] ASR provider switched to Apple Speech")
        case .tencentCloud:
            guard let credentials = currentTencentCredentialValues() else {
                asrProvider = nil
                AppLog.log("[SmartVoiceIn] ASR provider switch failed: Tencent credentials missing")
                return
            }
            asrProvider = TencentASRProvider(secretId: credentials.secretId, secretKey: credentials.secretKey)
            AppLog.log("[SmartVoiceIn] ASR provider switched to Tencent Cloud")
        }
    }

    private func prewarmQwen3ASRIfNeeded(provider: ASRProvider, modelID: String, reason: String) {
        AppLog.log("[SmartVoiceIn] Qwen3 ASR prewarm started (\(reason), model: \(modelID))")
        onStatusUpdate?("正在预加载 Qwen3 模型（首次可能较慢）...")
        provider.prewarm { result in
            switch result {
            case .success:
                AppLog.log("[SmartVoiceIn] Qwen3 ASR prewarm completed (\(reason), model: \(modelID))")
                self.onStatusUpdate?("Qwen3 模型预加载完成")
            case .failure(let error):
                AppLog.log("[SmartVoiceIn] Qwen3 ASR prewarm failed (\(reason), model: \(modelID)): \(error)")
                self.onStatusUpdate?("Qwen3 模型预加载失败，已使用备用识别")
            }
        }
    }

    func startRecording() {
        AppLog.log("[SmartVoiceIn] Starting recording...")
        recognizedText = ""
        hasReturnedResult = false
        audioData = Data()

        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        AppLog.log("[SmartVoiceIn] Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        // 使用 16kHz 采样率
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else {
            AppLog.log("[SmartVoiceIn] Cannot create 16kHz format")
            onResult(.failure(NSError(domain: "SmartVoiceIn", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法创建音频格式"])))
            return
        }

        AppLog.log("[SmartVoiceIn] Target format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")

        // 安装重采样器
        guard let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            AppLog.log("[SmartVoiceIn] Cannot create converter from \(inputFormat) to \(recordingFormat)")
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
            AppLog.log("[SmartVoiceIn] Audio engine started")
        } catch {
            AppLog.log("[SmartVoiceIn] Failed to start audio engine: \(error)")
            onResult(.failure(error))
        }
    }

    /// 转换音频缓冲区
    private func convertBuffer(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            AppLog.log("[SmartVoiceIn] Cannot create converted buffer")
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            AppLog.log("[SmartVoiceIn] Convert error: \(error)")
            return
        }

        if let channelData = convertedBuffer.int16ChannelData {
            let frameLength = Int(convertedBuffer.frameLength)
            let data = Data(bytes: channelData[0], count: frameLength * 2)
            audioData.append(data)
        } else {
            AppLog.log("[SmartVoiceIn] No int16 channel data")
        }
    }

    func stopRecording() {
        AppLog.log("[SmartVoiceIn] Stopping recording...")
        isRecording = false

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        let dataSize = audioData.count
        AppLog.log("[SmartVoiceIn] Collected audio data: \(dataSize) bytes")

        guard dataSize > 0 else {
            AppLog.log("[SmartVoiceIn] No audio data collected")
            recognizeWithLocalFallback()
            return
        }

        if asrProviderType == .appleSpeech {
            AppLog.log("[SmartVoiceIn] Using Apple Speech ASR...")
            recognizeWithLocalFallback()
            return
        }

        guard let asrProvider else {
            AppLog.log("[SmartVoiceIn] No ASR provider, using local fallback")
            recognizeWithLocalFallback()
            return
        }

        AppLog.log("[SmartVoiceIn] Using \(asrProvider.name) ASR...")
        asrProvider.recognize(
            audioPCMData: audioData,
            sampleRate: Int(targetSampleRate),
            channels: Int(targetChannels),
            bitsPerSample: targetBitsPerSample
        ) { [weak self] result in
            switch result {
            case .success(let text):
                AppLog.log("[SmartVoiceIn] \(asrProvider.name) ASR success: \(text)")
                self?.postProcessRecognizedText(text)
            case .failure(let error):
                let nsError = error as NSError
                if nsError.domain == "Qwen3ASRProvider", nsError.code == -4 {
                    self?.onStatusUpdate?("Qwen3 模型加载中，已回退 Apple Speech")
                }
                AppLog.log("[SmartVoiceIn] \(asrProvider.name) ASR failed: \(error), falling back to local")
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
                    AppLog.log("[SmartVoiceIn] Local ASR success: \(text)")
                    self?.postProcessRecognizedText(text)
                }
                if let error = error {
                    AppLog.log("[SmartVoiceIn] Local ASR error: \(error)")
                    self?.onResult(.failure(error))
                }
            }
        } catch {
            AppLog.log("[SmartVoiceIn] Failed to save audio file: \(error)")
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

    /// 统一后处理：全部交由 LLM；失败时回退原文。
    private func postProcessRecognizedText(_ text: String) {
        AppLog.log("[SmartVoiceIn] Post-processing text started")
        let callback = onResult
        if let llmTextOptimizer {
            AppLog.log("[SmartVoiceIn] Running LLM text optimization...")
            onStatusUpdate?("正在转换中（LLM 文本优化）...")
            llmTextOptimizer.optimize(text: text) { result in
                switch result {
                case .success(let optimized):
                    AppLog.log("[SmartVoiceIn] LLM optimized text: \(optimized)")
                    callback(.success(optimized))
                case .failure(let error):
                    AppLog.log("[SmartVoiceIn] LLM optimization failed: \(error), fallback to original text")
                    self.onStatusUpdate?("转换失败，返回原文")
                    callback(.success(text))
                }
            }
        } else {
            AppLog.log("[SmartVoiceIn] LLM optimizer unavailable, passthrough original text")
            onResult(.success(text))
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
        AppLog.log("[SmartVoiceIn] Availability changed: \(available)")
    }
}
