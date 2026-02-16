import Foundation
import CommonCrypto

private final class TencentASRCompletionRelay: @unchecked Sendable {
    private let completion: (Result<String, Error>) -> Void

    init(_ completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
    }

    func resolve(_ result: Result<String, Error>) {
        completion(result)
    }
}

final class TencentASRProvider: ASRProvider, @unchecked Sendable {
    let name = "Tencent Cloud"

    private let secretId: String
    private let secretKey: String

    // 腾讯云服务区域
    private let endpoint = "asr.tencentcloudapi.com"
    private let region = "ap-guangzhou"
    private let action = "SentenceRecognition"
    private let version = "2019-06-14"
    private let service = "asr"

    init(secretId: String, secretKey: String) {
        self.secretId = secretId
        self.secretKey = secretKey
    }

    func recognize(
        audioPCMData: Data,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard bitsPerSample == 16 else {
            completion(
                .failure(
                    NSError(
                        domain: "TencentASR",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Tencent ASR 仅支持 16-bit PCM"]
                    )
                )
            )
            return
        }

        guard sampleRate == 16_000 else {
            completion(
                .failure(
                    NSError(
                        domain: "TencentASR",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "Tencent ASR 仅支持 16kHz 采样率"]
                    )
                )
            )
            return
        }

        recognize(audioData: audioPCMData, channels: channels, completion: completion)
    }

    /// 识别音频数据
    private func recognize(audioData: Data, channels: Int, completion: @escaping (Result<String, Error>) -> Void) {
        // 将音频转换为 Base64
        let audioBase64 = audioData.base64EncodedString()

        // 构建请求参数 - 使用 pcm 格式
        let params: [String: Any] = [
            "EngSerViceType": "16k_zh",  // 16k 中文引擎
            "VoiceFormat": "pcm",  // 使用 pcm 格式
            "SourceType": 1,  // 1 = 语音数据
            "Data": audioBase64,
            "DataLen": audioData.count,
            "FilterModal": 0,  // 不在 ASR 层做文本过滤，统一交给 LLM
            "ChannelNum": max(channels, 1)
        ]

        // 发送请求
        sendRequest(params: params, completion: completion)
    }

    private func sendRequest(params: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        let relay = TencentASRCompletionRelay(completion)
        let timestamp = Int(Date().timeIntervalSince1970)
        let date = formatDate(Date())

        // 请求体
        let body = try! JSONSerialization.data(withJSONObject: params, options: [])
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        let hashedRequestPayload = sha256Hex(string: bodyString)

        // 构建 CanonicalRequest
        let httpMethod = "POST"
        let canonicalUri = "/"
        let canonicalQueryString = ""
        let canonicalHeaders = "content-type:application/json\nhost:\(endpoint)\n"
        let signedHeaders = "content-type;host"

        let canonicalRequest = """
        \(httpMethod)
        \(canonicalUri)
        \(canonicalQueryString)
        \(canonicalHeaders)
        \(signedHeaders)
        \(hashedRequestPayload)
        """

        // 构建 StringToSign
        let algorithm = "TC3-HMAC-SHA256"
        let credentialScope = "\(date)/\(service)/tc3_request"
        let hashedCanonicalRequest = sha256Hex(string: canonicalRequest)
        let stringToSign = """
        \(algorithm)
        \(timestamp)
        \(credentialScope)
        \(hashedCanonicalRequest)
        """

        // 计算签名
        let secretDate = hmacSHA256(key: "TC3\(secretKey)".data(using: .utf8)!, data: date.data(using: .utf8)!)
        let secretService = hmacSHA256(key: secretDate, data: service.data(using: .utf8)!)
        let secretSigning = hmacSHA256(key: secretService, data: "tc3_request".data(using: .utf8)!)
        let signature = hmacSHA256(key: secretSigning, data: stringToSign.data(using: .utf8)!).map { String(format: "%02x", $0) }.joined()

        // 构建 Authorization
        let authorization = "\(algorithm) Credential=\(secretId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        // 构建 URL 请求
        var request = URLRequest(url: URL(string: "https://\(endpoint)")!)
        request.httpMethod = httpMethod
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(timestamp.description, forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(region, forHTTPHeaderField: "X-TC-Region")

        // 发送请求
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                relay.resolve(.failure(error))
                return
            }

            guard let data = data else {
                relay.resolve(.failure(NSError(domain: "TencentASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }

            // 解析响应
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let response = json["Response"] as? [String: Any] {

                    // 检查是否有错误
                    if let error = response["Error"] as? [String: Any] {
                        let message = error["Message"] as? String ?? "Unknown error"
                        let code: Int
                        if let intCode = error["Code"] as? Int {
                            code = intCode
                        } else if let strCode = error["Code"] as? String, let parsed = Int(strCode) {
                            code = parsed
                        } else {
                            code = -1
                        }
                        relay.resolve(.failure(NSError(domain: "TencentASR", code: code, userInfo: [NSLocalizedDescriptionKey: message])))
                        return
                    }

                    // SentenceRecognition 常见返回: Result 为 String
                    if let resultStr = response["Result"] as? String {
                        let trimmed = resultStr.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            relay.resolve(.success(trimmed))
                        } else {
                            AppLog.log("[TencentASR] Result is empty, audio may be unclear or format issue")
                            relay.resolve(.failure(NSError(domain: "TencentASR", code: -2, userInfo: [NSLocalizedDescriptionKey: "识别结果为空，可能是音频格式问题"])))
                        }
                        return
                    }

                    // 兼容少数结构: Result 为对象，文本字段可能叫 ResultText/Text
                    if let resultDict = response["Result"] as? [String: Any] {
                        if let text = (resultDict["ResultText"] as? String ?? resultDict["Text"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !text.isEmpty {
                            relay.resolve(.success(text))
                            return
                        }
                    }

                    // 其他情况
                    AppLog.log("[TencentASR] Response: \(response)")
                    relay.resolve(.failure(NSError(domain: "TencentASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析响应"])))
                } else {
                    let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode"
                    AppLog.log("[TencentASR] Response: \(responseString)")
                    relay.resolve(.failure(NSError(domain: "TencentASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析响应"])))
                }
            } catch {
                relay.resolve(.failure(error))
            }
        }
        task.resume()
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func sha256Hex(string: String) -> String {
        let data = string.data(using: .utf8)!
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyBytes.baseAddress, key.count, dataBytes.baseAddress, data.count, &result)
            }
        }
        return Data(result)
    }
}
