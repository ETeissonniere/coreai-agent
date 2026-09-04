// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import CoreAIShared
import Foundation
import FoundationModels
import Tokenizers

/// Unified Core AI runner that creates FM API-compatible LanguageModel instances.
///
/// ## Usage
/// ```swift
/// let url = URL(fileURLWithPath: "/path/to/model")
/// let runner = try CoreAIRunner(contentsOf: url)
/// let model = try await runner.makeLanguageModel()
/// let session = LanguageModelSession(model: model)
/// ```
public struct CoreAIRunner {
    // MARK: - Properties

    private let bundle: LanguageBundle
    private let engineVariant: String?
    private let kvCacheStrategy: KVCacheStrategy

    // MARK: - Initialization

    /// Creates a runner by loading a model bundle from a URL.
    public init(
        contentsOf url: URL,
        variant: String? = nil,
        kvCacheStrategy: KVCacheStrategy = .auto
    ) throws {
        self.init(
            from: try LanguageBundle(at: url),
            variant: variant,
            kvCacheStrategy: kvCacheStrategy
        )
    }

    /// Creates a runner from a LanguageBundle.
    public init(
        from bundle: LanguageBundle,
        variant: String? = nil,
        kvCacheStrategy: KVCacheStrategy = .auto
    ) {
        self.bundle = bundle
        self.engineVariant = variant
        self.kvCacheStrategy = kvCacheStrategy
    }

    // MARK: - Engine Creation

    /// Creates an inference engine using auto-detection.
    public func makeInferenceEngine() async throws -> any InferenceEngine {
        let config = makeConfig()
        let configData = try JSONEncoder().encode(config)

        var options = EngineOptions(kvCacheStrategy: kvCacheStrategy)
        if let variant = engineVariant {
            options = EngineOptions(variant: variant, kvCacheStrategy: kvCacheStrategy)
        }

        return try await EngineFactory.createEngine(
            config: configData,
            modelURL: try bundle.requireModelURL(for: ModelBundle.ComponentKey.main),
            options: options
        )
    }

    /// Creates a LanguageModel for FM API usage.
    func makeLanguageModel() async throws -> CoreAILanguageModel {
        let chatTemplate = Self.prefixStableChatTemplate(in: bundle.tokenizerPath)
        let modelLoadSpan = InstrumentsProfiler.beginModelLoad(name: bundle.name)
        let engine = try await makeInferenceEngine()
        modelLoadSpan.end()

        let tokenizerLoadSpan = InstrumentsProfiler.beginTokenizerLoad(
            id: bundle.tokenizer)
        let tokenizer = try await bundle.loadTokenizer()
        tokenizerLoadSpan.end()

        // Read additional stop token IDs from tokenizer_config.json
        let additionalEos: [Int32]
        if let tokenizerDir = bundle.tokenizerPath {
            additionalEos = LanguageConfig.additionalStopTokenIds(
                from: tokenizerDir, tokenizer: tokenizer)
        } else {
            additionalEos = []
        }

        return CoreAILanguageModel(
            engine: engine,
            tokenizer: tokenizer,
            modelIdentifier: bundle.name,
            samplingConfig: SamplingConfiguration.greedy,
            vocabSize: bundle.vocabSize,
            additionalEosTokenIds: additionalEos,
            chatTemplateOverride: chatTemplate
        )
    }

    static func prefixStableChatTemplate(in tokenizerDirectory: URL?) -> String? {
        guard let tokenizerDirectory,
              let template = chatTemplate(in: tokenizerDirectory)
        else { return nil }
        let pattern = #"(\{%-?)\s*if\s+loop\.index0\s*>\s*ns\.last_query_index\s*(-?%\})"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(template.startIndex..., in: template)
        guard expression.firstMatch(in: template, range: range) != nil else {
            return template.contains("last_query_index") ? nil : template
        }
        var stableTemplate = expression.stringByReplacingMatches(
            in: template,
            range: range,
            withTemplate: "$1 if true $2"
        )
        let lastAssistantPattern =
            #"(\{%-?)\s*if\s+loop\.last\s+or\s+\(not\s+loop\.last\s+and\s+reasoning_content\)\s*(-?%\})"#
        guard let lastAssistantExpression = try? NSRegularExpression(
            pattern: lastAssistantPattern)
        else { return nil }
        let stableRange = NSRange(stableTemplate.startIndex..., in: stableTemplate)
        stableTemplate = lastAssistantExpression.stringByReplacingMatches(
            in: stableTemplate,
            range: stableRange,
            withTemplate: "$1 if true $2")
        return stableTemplate
    }

    private static func chatTemplate(in tokenizerDirectory: URL) -> String? {
        let jinjaURL = tokenizerDirectory.appending(path: "chat_template.jinja")
        if let template = try? String(contentsOf: jinjaURL, encoding: .utf8) {
            return template
        }

        for filename in ["chat_template.json", "tokenizer_config.json"] {
            let url = tokenizerDirectory.appending(path: filename)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let config = object as? [String: Any],
                  let template = config["chat_template"] as? String
            else { continue }
            return template
        }
        return nil
    }

    // MARK: - Private Helpers

    private func makeConfig() -> ModelConfig {
        let functionName = bundle.language.functionMap?.name(for: "main") ?? "main"
        let modelAsset = bundle.modelAssetPath
        return ModelConfig(
            name: bundle.name,
            tokenizer: bundle.tokenizer,
            vocabSize: bundle.vocabSize,
            maxContextLength: bundle.maxContextLength,
            source: ModelSource(
                hfModelId: bundle.tokenizer,
                modelDefinition: .pyTorch
            ),
            serializedModel: [modelAsset],
            function: functionName
        )
    }
}
