import Foundation

private enum LLMEvalCLIError: LocalizedError {
    case missingInputPath
    case invalidArgument(String)
    case unreadableInputFile(String)
    case noSamplesFound

    var errorDescription: String? {
        switch self {
        case .missingInputPath:
            return "缺少 --input 参数。"
        case .invalidArgument(let message):
            return message
        case .unreadableInputFile(let path):
            return "无法读取输入文件: \(path)"
        case .noSamplesFound:
            return "输入文件中未找到可评测样本。"
        }
    }
}

private struct EvalOptions {
    let inputPath: String
    let outputPath: String
    let providers: [String]
    let limit: Int?
    let skipPrewarm: Bool
}

private struct EvalSample {
    let id: String
    let text: String
}

private struct EvalRecord {
    let sampleID: String
    let providerRawValue: String
    let providerDisplayName: String
    let status: String
    let latencyMS: Int
    let changed: Bool
    let fillerReduced: Bool
    let input: String
    let output: String
    let error: String
}

enum LLMEvalCLI {
    static func main() {
        do {
            let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            let samples = try loadSamples(from: options.inputPath, limit: options.limit)
            let records = runEvaluation(samples: samples, options: options)
            try writeCSV(records: records, to: options.outputPath)
            printSummary(records: records, outputPath: options.outputPath)
        } catch {
            fputs("[LLMEvalCLI] \(error.localizedDescription)\n", stderr)
            printUsage()
            Foundation.exit(1)
        }
    }

    private static func parseArguments(_ args: [String]) throws -> EvalOptions {
        if args.contains("--help") || args.contains("-h") {
            printUsage()
            Foundation.exit(0)
        }

        var inputPath: String?
        var outputPath: String?
        var providers = LLMTextOptimizer.supportedProviderRawValues
        var limit: Int?
        var skipPrewarm = false

        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--input":
                index += 1
                guard index < args.count else {
                    throw LLMEvalCLIError.invalidArgument("--input 后缺少文件路径。")
                }
                inputPath = args[index]
            case "--output":
                index += 1
                guard index < args.count else {
                    throw LLMEvalCLIError.invalidArgument("--output 后缺少输出路径。")
                }
                outputPath = args[index]
            case "--providers":
                index += 1
                guard index < args.count else {
                    throw LLMEvalCLIError.invalidArgument("--providers 后缺少 provider 列表。")
                }
                let parsed = args[index]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !parsed.isEmpty else {
                    throw LLMEvalCLIError.invalidArgument("--providers 不能为空。")
                }
                providers = parsed
            case "--limit":
                index += 1
                guard index < args.count, let parsedLimit = Int(args[index]), parsedLimit > 0 else {
                    throw LLMEvalCLIError.invalidArgument("--limit 需要正整数。")
                }
                limit = parsedLimit
            case "--skip-prewarm":
                skipPrewarm = true
            default:
                throw LLMEvalCLIError.invalidArgument("不支持的参数: \(arg)")
            }
            index += 1
        }

        guard let inputPath, !inputPath.isEmpty else {
            throw LLMEvalCLIError.missingInputPath
        }

        let defaultOutput = "llm_eval_results_\(timestampString()).csv"
        return EvalOptions(
            inputPath: inputPath,
            outputPath: outputPath ?? defaultOutput,
            providers: providers,
            limit: limit,
            skipPrewarm: skipPrewarm
        )
    }

    private static func loadSamples(from path: String, limit: Int?) throws -> [EvalSample] {
        let inputURL = URL(fileURLWithPath: path)
        guard let rawData = try? Data(contentsOf: inputURL),
              let rawContent = String(data: rawData, encoding: .utf8) else {
            throw LLMEvalCLIError.unreadableInputFile(path)
        }

        let samples: [EvalSample]
        if inputURL.pathExtension.lowercased() == "jsonl" {
            samples = parseJSONLSamples(rawContent)
        } else {
            samples = parseTextSamples(rawContent)
        }

        let filtered = samples.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !filtered.isEmpty else {
            throw LLMEvalCLIError.noSamplesFound
        }

        if let limit, filtered.count > limit {
            return Array(filtered.prefix(limit))
        }
        return filtered
    }

    private static func parseTextSamples(_ content: String) -> [EvalSample] {
        return content
            .split(whereSeparator: \.isNewline)
            .enumerated()
            .map { index, line in
                EvalSample(id: String(index + 1), text: String(line))
            }
    }

    private static func parseJSONLSamples(_ content: String) -> [EvalSample] {
        var samples: [EvalSample] = []
        let lines = content.split(whereSeparator: \.isNewline)
        for (index, line) in lines.enumerated() {
            let rawLine = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawLine.isEmpty else {
                continue
            }
            guard let data = rawLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                continue
            }
            let id = (json["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            samples.append(EvalSample(id: id?.isEmpty == false ? id! : String(index + 1), text: text))
        }
        return samples
    }

    private static func runEvaluation(samples: [EvalSample], options: EvalOptions) -> [EvalRecord] {
        var records: [EvalRecord] = []

        for providerRawValue in options.providers {
            guard LLMTextOptimizer.supportedProviderRawValues.contains(providerRawValue) else {
                fputs("[LLMEvalCLI] 跳过未知 provider: \(providerRawValue)\n", stderr)
                continue
            }

            guard let optimizer = LLMTextOptimizer(providerRawValueOverride: providerRawValue) else {
                fputs("[LLMEvalCLI] 初始化 provider 失败: \(providerRawValue)\n", stderr)
                continue
            }
            let providerDisplayName = optimizer.providerDisplayName()
            print("[LLMEvalCLI] Provider: \(providerDisplayName) (\(providerRawValue))")

            if !options.skipPrewarm {
                let prewarmResult = waitPrewarm(optimizer)
                switch prewarmResult {
                case .success:
                    print("[LLMEvalCLI] Prewarm done")
                case .failure(let error):
                    fputs("[LLMEvalCLI] Prewarm failed: \(error.localizedDescription)\n", stderr)
                }
            }

            for (index, sample) in samples.enumerated() {
                let start = Date()
                let result = waitOptimize(optimizer, text: sample.text)
                let latencyMS = Int(Date().timeIntervalSince(start) * 1000)

                let normalizedInput = normalizeForComparison(sample.text)
                switch result {
                case .success(let output):
                    let normalizedOutput = normalizeForComparison(output)
                    let changed = normalizedOutput != normalizedInput
                    let fillerReduced = containsFiller(sample.text) && !containsFiller(output)
                    records.append(
                        EvalRecord(
                            sampleID: sample.id,
                            providerRawValue: providerRawValue,
                            providerDisplayName: providerDisplayName,
                            status: "success",
                            latencyMS: latencyMS,
                            changed: changed,
                            fillerReduced: fillerReduced,
                            input: sample.text,
                            output: output,
                            error: ""
                        )
                    )
                case .failure(let error):
                    records.append(
                        EvalRecord(
                            sampleID: sample.id,
                            providerRawValue: providerRawValue,
                            providerDisplayName: providerDisplayName,
                            status: "failure",
                            latencyMS: latencyMS,
                            changed: false,
                            fillerReduced: false,
                            input: sample.text,
                            output: "",
                            error: error.localizedDescription
                        )
                    )
                }

                print("[LLMEvalCLI] \(providerRawValue) sample \(index + 1)/\(samples.count) done (\(latencyMS)ms)")
            }
        }

        return records
    }

    private static func waitOptimize(_ optimizer: LLMTextOptimizer, text: String) -> Result<String, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        var finalResult: Result<String, Error> = .failure(
            NSError(domain: "LLMEvalCLI", code: -1, userInfo: [NSLocalizedDescriptionKey: "LLM optimize returned no result"])
        )
        optimizer.optimize(text: text) { result in
            finalResult = result
            semaphore.signal()
        }
        semaphore.wait()
        return finalResult
    }

    private static func waitPrewarm(_ optimizer: LLMTextOptimizer) -> Result<Void, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        var finalResult: Result<Void, Error> = .success(())
        optimizer.prewarmIfNeeded { result in
            finalResult = result
            semaphore.signal()
        }
        semaphore.wait()
        return finalResult
    }

    private static func writeCSV(records: [EvalRecord], to outputPath: String) throws {
        let outputURL = URL(fileURLWithPath: outputPath)
        let directoryURL = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var lines: [String] = []
        lines.append("sample_id,provider_raw,provider_name,status,latency_ms,changed,filler_reduced,input,output,error")
        lines.append(
            contentsOf: records.map {
                [
                    escapeCSV($0.sampleID),
                    escapeCSV($0.providerRawValue),
                    escapeCSV($0.providerDisplayName),
                    escapeCSV($0.status),
                    String($0.latencyMS),
                    $0.changed ? "1" : "0",
                    $0.fillerReduced ? "1" : "0",
                    escapeCSV($0.input),
                    escapeCSV($0.output),
                    escapeCSV($0.error)
                ].joined(separator: ",")
            }
        )

        let content = lines.joined(separator: "\n")
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private static func printSummary(records: [EvalRecord], outputPath: String) {
        let grouped = Dictionary(grouping: records, by: { $0.providerRawValue })
        print("\n[LLMEvalCLI] Summary")
        for provider in grouped.keys.sorted() {
            let providerRecords = grouped[provider] ?? []
            let success = providerRecords.filter { $0.status == "success" }
            let changed = success.filter { $0.changed }.count
            let fillerReduced = success.filter { $0.fillerReduced }.count
            let avgLatency = success.isEmpty ? 0 : success.map { $0.latencyMS }.reduce(0, +) / success.count

            print("- \(provider): total \(providerRecords.count), success \(success.count), changed \(changed), filler_reduced \(fillerReduced), avg_latency \(avgLatency)ms")
        }
        print("[LLMEvalCLI] CSV: \(outputPath)")
    }

    private static func normalizeForComparison(_ text: String) -> String {
        return text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[，。！？、,.!?;:：；]"#, with: "", options: .regularExpression)
    }

    private static func containsFiller(_ text: String) -> Bool {
        let fillers = ["嗯", "呃", "额", "那个", "就是说", "然后"]
        return fillers.contains(where: { text.contains($0) })
    }

    private static func escapeCSV(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private static func printUsage() {
        let usage = """
        用法:
          LLMEvalCLI --input <path> [--providers local_mlx,minimax_text,tencent_hunyuan] [--output <csv_path>] [--limit N] [--skip-prewarm]

        输入格式:
          1. txt: 每行一条待清洗文本
          2. jsonl: 每行一个 JSON，至少包含字段 {"text":"..."}，可选 {"id":"..."}

        示例:
          LLMEvalCLI --input ./scripts/llm_eval_samples.txt --providers local_mlx,minimax_text,tencent_hunyuan
        """
        print(usage)
    }
}

LLMEvalCLI.main()
