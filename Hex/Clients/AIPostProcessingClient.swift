//
//  AIPostProcessingClient.swift
//  Hex
//

import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(Tokenizers)
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

private let aiLogger = HexLog.transcription

#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(Tokenizers)
private struct LocalTokenizerBridge: MLXLMCommon.Tokenizer {
	private let upstream: any Tokenizers.Tokenizer

	init(_ upstream: any Tokenizers.Tokenizer) {
		self.upstream = upstream
	}

	func encode(text: String, addSpecialTokens: Bool) -> [Int] {
		upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
	}

	func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
		upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
	}

	func convertTokenToId(_ token: String) -> Int? {
		upstream.convertTokenToId(token)
	}

	func convertIdToToken(_ id: Int) -> String? {
		upstream.convertIdToToken(id)
	}

	var bosToken: String? { upstream.bosToken }
	var eosToken: String? { upstream.eosToken }
	var unknownToken: String? { upstream.unknownToken }

	func applyChatTemplate(
		messages: [[String: any Sendable]],
		tools: [[String: any Sendable]]?,
		additionalContext: [String: any Sendable]?
	) throws -> [Int] {
		do {
			return try upstream.applyChatTemplate(
				messages: messages,
				tools: tools,
				additionalContext: additionalContext
			)
		} catch Tokenizers.TokenizerError.missingChatTemplate {
			throw MLXLMCommon.TokenizerError.missingChatTemplate
		}
	}
}

private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
	func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
		let tokenizer = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
		return LocalTokenizerBridge(tokenizer)
	}
}
#endif

@DependencyClient
struct AIPostProcessingClient {
	var postProcess: @Sendable (String, AIPostProcessingMode, AppContext?) async throws -> String
	var isModelDownloaded: @Sendable () async -> Bool = { false }
	var modelSize: @Sendable () async -> Int64? = { nil }
	var downloadModel: @Sendable (@escaping @Sendable (Progress) -> Void) async throws -> Void
	var warmModel: @Sendable () async throws -> Void
	var deleteModel: @Sendable () async throws -> Void
}

extension AIPostProcessingClient: DependencyKey {
	static var liveValue: Self {
		let manager = LocalAIModelManager()
		return .init(
			postProcess: { text, mode, appContext in
				try await manager.postProcess(text: text, mode: mode, appContext: appContext)
			},
			isModelDownloaded: {
				await manager.isModelDownloaded()
			},
			modelSize: {
				await manager.modelSize()
			},
			downloadModel: { progressHandler in
				try await manager.downloadModel(progressHandler: progressHandler)
			},
			warmModel: {
				try await manager.warmModel()
			},
			deleteModel: {
				try await manager.deleteModel()
			}
		)
	}
}

extension DependencyValues {
	var aiPostProcessing: AIPostProcessingClient {
		get { self[AIPostProcessingClient.self] }
		set { self[AIPostProcessingClient.self] = newValue }
	}
}

private actor LocalAIModelManager {
	#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(Tokenizers)
	private var modelContainer: ModelContainer?

	private let modelDirectoryName = "Qwen3-1.7B-MLX-4bit"

	private var modelDirectory: URL {
		get throws {
			try URL.hexAIModelsDirectory.appendingPathComponent(modelDirectoryName, isDirectory: true)
		}
	}

	func isModelDownloaded() -> Bool {
		guard let directory = try? modelDirectory,
			FileManager.default.fileExists(atPath: directory.path)
		else { return false }

		let fileManager = FileManager.default
		let requiredFiles = ["config.json", "tokenizer.json", "tokenizer_config.json"]
		guard requiredFiles.allSatisfy({ fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
			return false
		}

		return fileManager.enumerator(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)?
			.compactMap { $0 as? URL }
			.contains(where: { $0.pathExtension == "safetensors" }) ?? false
	}

	func modelSize() -> Int64? {
		guard let directory = try? modelDirectory else { return nil }
		guard let enumerator = FileManager.default.enumerator(
			at: directory,
			includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
			options: .skipsHiddenFiles
		) else { return nil }

		var total: Int64 = 0
		for case let url as URL in enumerator {
			guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
				values.isRegularFile == true
			else { continue }
			total += Int64(values.fileSize ?? 0)
		}
		return total > 0 ? total : nil
	}

	func downloadModel(progressHandler: @escaping @Sendable (Progress) -> Void) async throws {
		let fileManager = FileManager.default
		let destination = try modelDirectory
		try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

		let totalBytes = OnDeviceAIModel.files.reduce(Int64(0)) { $0 + $1.size }
		let progress = Progress(totalUnitCount: totalBytes)
		progressHandler(progress)
		aiLogger.notice("Starting on-device AI model download from R2")

		for file in OnDeviceAIModel.files {
			try Task.checkCancellation()
			let source = OnDeviceAIModel.remoteBaseURL.appendingPathComponent(file.name)
			let (temporaryURL, response) = try await URLSession.shared.download(from: source)
			guard let httpResponse = response as? HTTPURLResponse,
				(200..<300).contains(httpResponse.statusCode)
			else {
				throw AIPostProcessingError.remoteDownloadFailed
			}

			let localURL = destination.appendingPathComponent(file.name)
			if fileManager.fileExists(atPath: localURL.path) {
				try fileManager.removeItem(at: localURL)
			}
			try fileManager.moveItem(at: temporaryURL, to: localURL)
			progress.completedUnitCount += file.size
			progressHandler(progress)
		}

		guard isModelDownloaded() else {
			throw AIPostProcessingError.incompleteModel
		}
		aiLogger.notice("On-device AI model download completed")
	}

	func warmModel() async throws {
		guard isModelDownloaded() else {
			throw AIPostProcessingError.modelUnavailable
		}
		_ = try await loadLocalModel()
		aiLogger.notice("On-device AI model warmed")
	}

	func deleteModel() throws {
		modelContainer = nil
		let fileManager = FileManager.default
		let destination = try modelDirectory
		if fileManager.fileExists(atPath: destination.path) {
			try fileManager.removeItem(at: destination)
		}
	}

	func postProcess(text: String, mode: AIPostProcessingMode, appContext: AppContext?) async throws -> String {
		guard mode != .off else { return text }
		guard isModelDownloaded() else {
			aiLogger.warning("On-device AI is enabled but its model is unavailable")
			throw AIPostProcessingError.modelUnavailable
		}

		let prompt = mode.systemPrompt(appContext: appContext, selectedStyleIndex: currentStyleIndex())
		guard !prompt.isEmpty else { return text }

		#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(Tokenizers)
		let container = try await loadLocalModel()
		let input = UserInput(
			chat: [
				.system(prompt),
				.user(text)
			],
			additionalContext: ["enable_thinking": false]
		)
		let preparedInput = try await container.prepare(input: input)
		let generation = try await container.generate(
			input: preparedInput,
			parameters: GenerateParameters(maxTokens: 256, temperature: 0, prefillStepSize: 512)
		)

		var output = ""
		for await event in generation {
			try Task.checkCancellation()
			if case let .chunk(chunk) = event {
				output.append(chunk)
			}
		}

		guard let validated = AIPostProcessingOutputValidator.validated(output) else {
			aiLogger.warning("Rejected invalid on-device AI output")
			throw AIPostProcessingError.invalidOutput
		}
		return validated
		#else
		throw AIPostProcessingError.mlXUnavailable
		#endif
	}

	private func currentStyleIndex() -> Int {
		@Shared(.hexSettings) var settings: HexSettings
		return settings.selectedStyleIndex
	}

	#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(Tokenizers)
	private func loadLocalModel() async throws -> ModelContainer {
		if let modelContainer { return modelContainer }
		let container = try await LLMModelFactory.shared.loadContainer(
			from: try modelDirectory,
			using: LocalTokenizerLoader()
		)
		modelContainer = container
		return container
	}
	#endif

	#else
	func isModelDownloaded() -> Bool { false }
	func modelSize() -> Int64? { nil }
	func downloadModel(progressHandler: @escaping @Sendable (Progress) -> Void) async throws {
		throw AIPostProcessingError.mlXUnavailable
	}
	func warmModel() async throws { throw AIPostProcessingError.mlXUnavailable }
	func deleteModel() throws {}
	func postProcess(text: String, mode: AIPostProcessingMode, appContext: AppContext?) async throws -> String {
		throw AIPostProcessingError.mlXUnavailable
	}
	#endif
}

enum AIPostProcessingError: Error, LocalizedError {
	case invalidModelIdentifier
	case incompleteModel
	case remoteDownloadFailed
	case modelUnavailable
	case invalidOutput
	case mlXUnavailable

	var errorDescription: String? {
		switch self {
		case .invalidModelIdentifier:
			return "The on-device AI model identifier is invalid."
		case .incompleteModel:
			return "The on-device AI model download is incomplete."
		case .remoteDownloadFailed:
			return "The on-device AI model could not be downloaded from the model server."
		case .modelUnavailable:
			return "The on-device AI model is not downloaded."
		case .invalidOutput:
			return "The on-device AI returned invalid output."
		case .mlXUnavailable:
			return "On-device AI support is not linked in this build."
		}
	}
}
