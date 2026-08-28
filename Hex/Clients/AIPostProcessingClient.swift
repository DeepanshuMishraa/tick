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

private final class IncrementalDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
	private let destination: URL
	private let onProgress: @Sendable (Int64) -> Void
	private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
	private var downloadTask: URLSessionDownloadTask?
	private var session: URLSession?
	private var bytesReported: Int64 = 0
	private var moveError: Error?

	init(destination: URL, onProgress: @escaping @Sendable (Int64) -> Void) {
		self.destination = destination
		self.onProgress = onProgress
	}

	func download(request: URLRequest) async throws -> HTTPURLResponse {
		try await withTaskCancellationHandler(operation: {
			try await withCheckedThrowingContinuation { continuation in
				self.continuation = continuation
				let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
				self.session = session
				let task = session.downloadTask(with: request)
				self.downloadTask = task
				task.resume()
			}
		}, onCancel: {
			self.downloadTask?.cancel()
		})
	}

	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didWriteData bytesWritten: Int64,
		totalBytesWritten: Int64,
		totalBytesExpectedToWrite: Int64
	) {
		let delta = totalBytesWritten - bytesReported
		bytesReported = totalBytesWritten
		if delta > 0 {
			onProgress(delta)
		}
	}

	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didFinishDownloadingTo location: URL
	) {
		do {
			let fileManager = FileManager.default
			if fileManager.fileExists(atPath: destination.path) {
				try fileManager.removeItem(at: destination)
			}
			try fileManager.moveItem(at: location, to: destination)
		} catch {
			moveError = error
		}
	}

	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		didCompleteWithError error: Error?
	) {
		if let error {
			continuation?.resume(throwing: error)
		} else if let moveError {
			continuation?.resume(throwing: moveError)
		} else if let response = task.response as? HTTPURLResponse {
			continuation?.resume(returning: response)
		} else {
			continuation?.resume(throwing: AIPostProcessingError.remoteDownloadFailed)
		}
		continuation = nil
		session.finishTasksAndInvalidate()
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
	private let parallelDownloadThreshold: Int64 = 64 * 1024 * 1024
	private let downloadChunkSize: Int64 = 64 * 1024 * 1024
	private let maxConcurrentDownloads = 6

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
		let progressReporter = DownloadProgressReporter(progress: progress, handler: progressHandler)
		progressReporter.notify()
		aiLogger.notice("Starting on-device AI model download from R2")
		let stagingDirectory = try URL.hexAIModelsDirectory.appendingPathComponent(".download-\(modelDirectoryName)", isDirectory: true)
		try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

		for file in OnDeviceAIModel.files {
			try Task.checkCancellation()
			let localURL = destination.appendingPathComponent(file.name)
			if fileManager.fileExists(atPath: localURL.path),
				let values = try? localURL.resourceValues(forKeys: [.fileSizeKey]),
				Int64(values.fileSize ?? 0) == file.size {
				progressReporter.add(file.size)
				continue
			}

			let source = OnDeviceAIModel.remoteBaseURL.appendingPathComponent(file.name)
			let fileProgressStart = progressReporter.completedUnitCount
			if file.size >= parallelDownloadThreshold {
				do {
					try await downloadInParallel(
						source: source,
						expectedSize: file.size,
						destination: localURL,
						stagingDirectory: stagingDirectory,
						progress: progressReporter
					)
				} catch AIPostProcessingError.rangeDownloadsUnavailable {
					progressReporter.setCompleted(fileProgressStart)
					try await downloadSingle(
						source: source,
						expectedSize: file.size,
						destination: localURL,
						stagingDirectory: stagingDirectory,
						progress: progressReporter
					)
				}
			} else {
				try await downloadSingle(
					source: source,
					expectedSize: file.size,
					destination: localURL,
					stagingDirectory: stagingDirectory,
					progress: progressReporter
				)
			}
			progressReporter.notify()
		}

		guard isModelDownloaded() else {
			throw AIPostProcessingError.incompleteModel
		}
		try? fileManager.removeItem(at: stagingDirectory)
		aiLogger.notice("On-device AI model download completed")
	}

	private struct DownloadedChunk: Sendable {
		let index: Int
		let url: URL
	}

	private final class DownloadProgressReporter: @unchecked Sendable {
		private let progress: Progress
		private let handler: @Sendable (Progress) -> Void
		private let lock = NSLock()
		private let notificationInterval: TimeInterval = 0.1
		private let notificationByteInterval: Int64 = 512 * 1024
		private var lastNotifiedBytes: Int64 = 0
		private var lastNotificationUptime: TimeInterval = 0

		init(progress: Progress, handler: @escaping @Sendable (Progress) -> Void) {
			self.progress = progress
			self.handler = handler
		}

		var completedUnitCount: Int64 {
			lock.lock()
			defer { lock.unlock() }
			return progress.completedUnitCount
		}

		func add(_ bytes: Int64) {
			guard bytes > 0 else { return }
			lock.lock()
			progress.completedUnitCount += bytes
			let now = ProcessInfo.processInfo.systemUptime
			let shouldNotify = progress.completedUnitCount - lastNotifiedBytes >= notificationByteInterval
				|| now - lastNotificationUptime >= notificationInterval
			if shouldNotify {
				lastNotifiedBytes = progress.completedUnitCount
				lastNotificationUptime = now
			}
			lock.unlock()
			if shouldNotify {
				handler(progress)
			}
		}

		func setCompleted(_ value: Int64) {
			lock.lock()
			progress.completedUnitCount = value
			lastNotifiedBytes = value
			lastNotificationUptime = ProcessInfo.processInfo.systemUptime
			lock.unlock()
			handler(progress)
		}

		func notify() {
			lock.lock()
			lastNotifiedBytes = progress.completedUnitCount
			lastNotificationUptime = ProcessInfo.processInfo.systemUptime
			lock.unlock()
			handler(progress)
		}
	}

	private func downloadSingle(
		source: URL,
		expectedSize: Int64,
		destination: URL,
		stagingDirectory: URL,
		progress: DownloadProgressReporter
	) async throws {
		let temporaryURL = stagingDirectory.appendingPathComponent("single-\(UUID().uuidString).download")
		let delegate = IncrementalDownloadDelegate(destination: temporaryURL) { bytes in
			progress.add(bytes)
		}
		let response = try await delegate.download(request: URLRequest(url: source))
		guard (200..<300).contains(response.statusCode)
		else {
			throw AIPostProcessingError.remoteDownloadFailed
		}
		guard response.expectedContentLength == -1 || response.expectedContentLength == expectedSize else {
			throw AIPostProcessingError.incompleteModel
		}

		let fileManager = FileManager.default
		if fileManager.fileExists(atPath: destination.path) {
			try fileManager.removeItem(at: destination)
		}
		try fileManager.moveItem(at: temporaryURL, to: destination)
		let values = try destination.resourceValues(forKeys: [.fileSizeKey])
		guard Int64(values.fileSize ?? 0) == expectedSize else {
			try? fileManager.removeItem(at: destination)
			throw AIPostProcessingError.incompleteModel
		}
	}

	private func downloadInParallel(
		source: URL,
		expectedSize: Int64,
		destination: URL,
		stagingDirectory: URL,
		progress: DownloadProgressReporter
	) async throws {
		let chunkCount = Int((expectedSize + downloadChunkSize - 1) / downloadChunkSize)
		let fileManager = FileManager.default
		var chunkURLs = Array<URL?>(repeating: nil, count: chunkCount)
		for index in 0..<chunkCount {
			let lowerBound = Int64(index) * downloadChunkSize
			let upperBound = min(lowerBound + downloadChunkSize, expectedSize)
			let chunkURL = stagingDirectory.appendingPathComponent("chunk-\(index).part")
			if fileManager.fileExists(atPath: chunkURL.path),
				let values = try? chunkURL.resourceValues(forKeys: [.fileSizeKey]),
				Int64(values.fileSize ?? 0) == upperBound - lowerBound {
				chunkURLs[index] = chunkURL
				progress.add(upperBound - lowerBound)
			}
		}
		var nextChunk = 0

		try await withThrowingTaskGroup(of: DownloadedChunk.self) { group in
			func addNextChunk() {
				while nextChunk < chunkCount, chunkURLs[nextChunk] != nil {
					nextChunk += 1
				}
				guard nextChunk < chunkCount else { return }
				let index = nextChunk
				nextChunk += 1
				let lowerBound = Int64(index) * downloadChunkSize
				let upperBound = min(lowerBound + downloadChunkSize, expectedSize)
				group.addTask {
					try await self.downloadChunk(
						source: source,
						lowerBound: lowerBound,
						upperBound: upperBound,
						index: index,
						stagingDirectory: stagingDirectory,
						progress: progress
					)
				}
			}

			for _ in 0..<min(maxConcurrentDownloads, chunkCount) {
				addNextChunk()
			}

			while let chunk = try await group.next() {
				chunkURLs[chunk.index] = chunk.url
				addNextChunk()
			}
		}

		if fileManager.fileExists(atPath: destination.path) {
			try fileManager.removeItem(at: destination)
		}
		fileManager.createFile(atPath: destination.path, contents: nil)
		let output = try FileHandle(forWritingTo: destination)
		defer { try? output.close() }

		for chunkURL in chunkURLs {
			guard let chunkURL else { throw AIPostProcessingError.incompleteModel }
			let input = try FileHandle(forReadingFrom: chunkURL)
			defer { try? input.close() }
			while let data = try input.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
				try output.write(contentsOf: data)
			}
		}

		let values = try destination.resourceValues(forKeys: [.fileSizeKey])
		guard Int64(values.fileSize ?? 0) == expectedSize else {
			try? fileManager.removeItem(at: destination)
			throw AIPostProcessingError.incompleteModel
		}
	}

	private func downloadChunk(
		source: URL,
		lowerBound: Int64,
		upperBound: Int64,
		index: Int,
		stagingDirectory: URL,
		progress: DownloadProgressReporter
	) async throws -> DownloadedChunk {
		var request = URLRequest(url: source)
		request.setValue("bytes=\(lowerBound)-\(upperBound - 1)", forHTTPHeaderField: "Range")
		let chunkURL = stagingDirectory.appendingPathComponent("chunk-\(index).part")
		let delegate = IncrementalDownloadDelegate(destination: chunkURL) { bytes in
			progress.add(bytes)
		}
		let response = try await delegate.download(request: request)
		guard response.statusCode == 206
		else {
			throw AIPostProcessingError.rangeDownloadsUnavailable
		}

		let expectedSize = upperBound - lowerBound
		guard response.expectedContentLength == -1 || response.expectedContentLength == expectedSize else {
			throw AIPostProcessingError.incompleteModel
		}
		let values = try chunkURL.resourceValues(forKeys: [.fileSizeKey])
		guard Int64(values.fileSize ?? 0) == expectedSize else {
			throw AIPostProcessingError.incompleteModel
		}
		return DownloadedChunk(index: index, url: chunkURL)
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
		let stagingDirectory = try URL.hexAIModelsDirectory.appendingPathComponent(".download-\(modelDirectoryName)", isDirectory: true)
		if fileManager.fileExists(atPath: stagingDirectory.path) {
			try fileManager.removeItem(at: stagingDirectory)
		}
	}

	func postProcess(text: String, mode: AIPostProcessingMode, appContext: AppContext?) async throws -> String {
		let startedAt = ProcessInfo.processInfo.systemUptime
		guard mode != .off else { return text }
		guard isModelDownloaded() else {
			aiLogger.warning("On-device AI is enabled but its model is unavailable")
			throw AIPostProcessingError.modelUnavailable
		}

		let prompt = mode.systemPrompt(appContext: appContext, selectedStyleIndex: currentStyleIndex())
		guard !prompt.isEmpty else { return text }
		let normalizedInput = AIPostProcessingInputNormalizer.normalized(text)

		#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(Tokenizers)
		let container = try await loadLocalModel()
		let input = UserInput(
			chat: [
				.system(prompt),
				.user(normalizedInput)
			],
			additionalContext: ["enable_thinking": false]
		)
		let preparedInput = try await container.prepare(input: input)
		// Keep the generation budget proportional to the dictation. A large
		// fixed budget makes the local model spend time exploring completions
		// that cannot fit a short voice command, while still allowing longer
		// dictation to be formatted without truncation.
		let estimatedOutputTokens = normalizedInput.utf8.count / 4 + 64
		let maxOutputTokens = min(2048, max(128, estimatedOutputTokens))
		let generation = try await container.generate(
			input: preparedInput,
			parameters: GenerateParameters(
				maxTokens: maxOutputTokens,
				temperature: 0,
				prefillStepSize: 512
			)
		)

		var output = ""
		for await event in generation {
			try Task.checkCancellation()
			if case let .chunk(chunk) = event {
				output.append(chunk)
			}
		}

		guard let validated = AIPostProcessingOutputValidator.validated(output, sourceText: text) else {
			let containsReasoning = output.range(of: "<think>", options: .caseInsensitive) != nil
				|| output.range(of: "<reasoning>", options: .caseInsensitive) != nil
			let containsWrapper = output.lowercased().hasPrefix("output:")
				|| output.lowercased().hasPrefix("corrected text:")
			aiLogger.warning(
				"Rejected invalid on-device AI output chars=\(output.count, privacy: .public) reasoning=\(containsReasoning, privacy: .public) wrapper=\(containsWrapper, privacy: .public) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000), privacy: .public)"
			)
			throw AIPostProcessingError.invalidOutput
		}
		aiLogger.info(
			"Accepted on-device AI output chars=\(validated.count, privacy: .public) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000), privacy: .public)"
		)
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
	case rangeDownloadsUnavailable
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
		case .rangeDownloadsUnavailable:
			return "The model server does not support parallel downloads."
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
