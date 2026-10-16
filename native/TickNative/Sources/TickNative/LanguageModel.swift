import Foundation
import MLXLLM
import MLXLMCommon
import Tokenizers
import os

private let logger = Logger(subsystem: "com.dipxsy.Tick", category: "Transcription")

private struct LocalTokenizerBridge: MLXLMCommon.Tokenizer {
  private let upstream: any Tokenizers.Tokenizer
  init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
  }
  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
  }
  func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
  func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
  var bosToken: String? { upstream.bosToken }
  var eosToken: String? { upstream.eosToken }
  var unknownToken: String? { upstream.unknownToken }

  func applyChatTemplate(
    messages: [[String: any Sendable]],
    tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] {
    do {
      return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    } catch Tokenizers.TokenizerError.missingChatTemplate {
      throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
  }
}

private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
  func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
    LocalTokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
  }
}

/// Holds one loaded Qwen container. Download, prompt construction, edit-script
/// validation, and fallbacks live in Rust; this actor only loads and decodes.
actor LanguageModel {
  static let shared = LanguageModel()

  private var container: ModelContainer?
  private var loadedDirectory: URL?
  private var warmedDirectory: URL?
  private var warmTask: Task<Void, Error>?

  func warm(directory: URL) async throws {
    guard warmedDirectory != directory else { return }
    if let warmTask {
      try await warmTask.value
      if warmedDirectory == directory { return }
    }
    let task = Task { try await self.performWarmup(directory: directory) }
    warmTask = task
    defer { warmTask = nil }
    do {
      try await task.value
      warmedDirectory = directory
    } catch {
      warmedDirectory = nil
      throw error
    }
  }

  private func performWarmup(directory: URL) async throws {
    let container = try await load(directory: directory)
    let input = UserInput(
      chat: [.system("Return only transformed text."), .user("Warm up.")],
      additionalContext: ["enable_thinking": false]
    )
    let prepared = try await container.prepare(input: input)
    let generation = try await container.generate(
      input: prepared,
      parameters: GenerateParameters(maxTokens: 1, temperature: 0, prefillStepSize: 512)
    )
    for try await _ in generation { try Task.checkCancellation() }
    logger.notice("On-device AI model warmed and Metal kernels compiled")
  }

  func generate(
    directory: URL,
    system: String,
    user: String,
    maxTokens: Int,
    onChunk: @escaping @Sendable (String) -> Bool
  ) async throws {
    try await warm(directory: directory)
    let container = try await load(directory: directory)
    let input = UserInput(chat: [.system(system), .user(user)], additionalContext: ["enable_thinking": false])
    let prepared = try await container.prepare(input: input)
    try Task.checkCancellation()
    // Keep the producer handle so the caller can stop decoding as soon as it
    // has a valid edit script, and join it before the model is reused.
    let (stream, producer) = try await container.perform(nonSendable: prepared) { context, input in
      let iterator = try TokenIterator(
        input: input,
        model: context.model,
        parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0, prefillStepSize: 512)
      )
      return MLXLMCommon.generateTask(
        promptTokenCount: input.text.tokens.size,
        modelConfiguration: context.configuration,
        tokenizer: context.tokenizer,
        iterator: iterator
      )
    }
    do {
      for try await event in stream {
        try Task.checkCancellation()
        guard case let .chunk(text) = event else { continue }
        if !onChunk(text) { break }
      }
      producer.cancel()
      await producer.value
    } catch {
      producer.cancel()
      await producer.value
      throw error
    }
  }

  func unload() {
    warmTask?.cancel()
    warmTask = nil
    container = nil
    loadedDirectory = nil
    warmedDirectory = nil
  }

  private func load(directory: URL) async throws -> ModelContainer {
    if let container, loadedDirectory == directory { return container }
    container = nil
    loadedDirectory = nil
    warmedDirectory = nil
    let loaded = try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
    container = loaded
    loadedDirectory = directory
    return loaded
  }
}
