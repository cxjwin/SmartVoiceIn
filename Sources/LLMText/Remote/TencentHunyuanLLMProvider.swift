import Foundation
import CommonCrypto

final class TencentHunyuanLLMProvider: LLMTextOptimizeProvider, @unchecked Sendable {
    static let rawValue = "tencent_hunyuan"
    static let displayName = "腾讯混元"

    private let model: String
    private let endpoint: URL
    private let timeout: TimeInterval
    private let secretId: String
    private let secretKey: String
    private let region: String
    private let temperature: Double

    private let action = "ChatCompletions"
    private let version = "2023-09-01"
    private let service = "hunyuan"

    required init?(configuration: LLMTextOptimizeConfiguration) {
        let env = configuration.environment
        let secretId = (env["VOICEINPUT_TENCENT_SECRET_ID"]?.isEmpty == false)
            ? env["VOICEINPUT_TENCENT_SECRET_ID"]
            : configuration.fallbackTencentSecretId
        let secretKey = (env["VOICEINPUT_TENCENT_SECRET_KEY"]?.isEmpty == false)
            ? env["VOICEINPUT_TENCENT_SECRET_KEY"]
            : configuration.fallbackTencentSecretKey

        guard let secretId, !secretId.isEmpty,
              let secretKey, !secretKey.isEmpty else {
            return nil
        }

        let endpointString = env["VOICEINPUT_LLM_ENDPOINT"] ?? "https://hunyuan.tencentcloudapi.com"
        guard let endpoint = URL(string: endpointString) else {
            return nil
        }

        let configuredModel = env["VOICEINPUT_LLM_MODEL"] ?? ""

        self.secretId = secretId
        self.secretKey = secretKey
        self.region = env["VOICEINPUT_TENCENT_REGION"] ?? "ap-guangzhou"
        self.model = configuredModel.isEmpty ? "hunyuan-lite" : configuredModel
        self.endpoint = endpoint
        self.timeout = configuration.timeout
        let configuredTemperature = Double(env["VOICEINPUT_LLM_TEMPERATURE"] ?? "") ?? 0.8
        self.temperature = min(max(configuredTemperature, 0), 2)
    }

    func optimize(text: String, templatePromptOverride: String?, completion: @escaping (Result<String, Error>) -> Void) {
        let relay = LLMCompletionRelay(completion)

        let bodyObject: [String: Any] = [
            "Model": model,
            "Messages": buildOptimizationPromptMessages(userText: text, templatePromptOverride: templatePromptOverride).map { ["Role": $0.role, "Content": $0.content] },
            "Temperature": temperature,
            "Stream": false
        ]

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: bodyObject, options: [])
        } catch {
            completion(.failure(error))
            return
        }

        guard let host = endpoint.host else {
            completion(.failure(NSError(domain: "LLMTextOptimizer", code: -12, userInfo: [NSLocalizedDescriptionKey: "腾讯云端点无效"])))
            return
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let date = formatDate(Date())
        let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
        let hashedRequestPayload = sha256Hex(string: bodyString)

        let canonicalHeaders = "content-type:application/json\nhost:\(host)\n"
        let signedHeaders = "content-type;host"
        let canonicalRequest = """
        POST
        /

        \(canonicalHeaders)
        \(signedHeaders)
        \(hashedRequestPayload)
        """

        let algorithm = "TC3-HMAC-SHA256"
        let credentialScope = "\(date)/\(service)/tc3_request"
        let hashedCanonicalRequest = sha256Hex(string: canonicalRequest)
        let stringToSign = """
        \(algorithm)
        \(timestamp)
        \(credentialScope)
        \(hashedCanonicalRequest)
        """

        let secretDate = hmacSHA256(key: "TC3\(secretKey)".data(using: .utf8) ?? Data(), data: date.data(using: .utf8) ?? Data())
        let secretService = hmacSHA256(key: secretDate, data: service.data(using: .utf8) ?? Data())
        let secretSigning = hmacSHA256(key: secretService, data: "tc3_request".data(using: .utf8) ?? Data())
        let signature = hmacSHA256(key: secretSigning, data: stringToSign.data(using: .utf8) ?? Data()).map { String(format: "%02x", $0) }.joined()
        let authorization = "\(algorithm) Credential=\(secretId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(region, forHTTPHeaderField: "X-TC-Region")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                relay.resolve(.failure(error))
                return
            }
            guard let data else {
                relay.resolve(.failure(NSError(domain: "LLMTextOptimizer", code: -1, userInfo: [NSLocalizedDescriptionKey: "腾讯混元返回为空"])))
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let response = json["Response"] as? [String: Any] else {
                    let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode"
                    relay.resolve(.failure(NSError(domain: "LLMTextOptimizer", code: -13, userInfo: [NSLocalizedDescriptionKey: "无法解析腾讯混元响应: \(responseString)"])))
                    return
                }

                if let errorObject = response["Error"] as? [String: Any] {
                    let message = errorObject["Message"] as? String ?? "Unknown Tencent Hunyuan error"
                    relay.resolve(.failure(NSError(domain: "LLMTextOptimizer", code: -14, userInfo: [NSLocalizedDescriptionKey: message])))
                    return
                }

                if let outputText = extractTextFromTencentStyle(response: response) {
                    relay.resolve(.success(outputText))
                    return
                }

                relay.resolve(.failure(NSError(domain: "LLMTextOptimizer", code: -15, userInfo: [NSLocalizedDescriptionKey: "腾讯混元响应不含文本"])))
            } catch {
                relay.resolve(.failure(error))
            }
        }.resume()
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func sha256Hex(string: String) -> String {
        let data = string.data(using: .utf8) ?? Data()
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBytes.baseAddress,
                    key.count,
                    dataBytes.baseAddress,
                    data.count,
                    &result
                )
            }
        }
        return Data(result)
    }
}
