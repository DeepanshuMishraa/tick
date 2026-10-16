import AVFoundation
import FluidAudio
import Foundation
import WhisperKit
import os

private let logger = Logger(subsystem: "com.dipxsy.Tick", category: "Transcription")

enum TickPaths {
  static var applicationSupport: URL {
    get throws {
      let fm = FileManager.default
      let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let directory = base.appendingPathComponent("com.dipxsy.Tick", isDirectory: true)
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    }
  }

  static var models: URL {
    get throws {
      let directory = try applicationSupport.appendingPathComponent("models", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    }
  }
}

enum ParakeetVariant: String, CaseIterable {
  case englishV2 = "parakeet-tdt-0.6b-v2-coreml"
  case multilingualV3 = "parakeet-tdt-0.6b-v3-coreml"

  var asrVersion: AsrModelVersion {
    switch self {
    case .englishV2: return .v2
    case .multilingualV3: return .v3
    }
  }
}

struct SpeechError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Forwards PCM chunks from the Rust capture thread into the active
/// Parakeet streaming session. Pushing without a session is a no-op.
final class StreamingSink: @unchecked Sendable {
  static let shared = StreamingSink()
  private let lock = NSLock()
  private var continuation: AsyncStream<[Float]>.Continuation?

  func attach(_ continuation: AsyncStream<[Float]>.Continuation) {
    lock.lock()
    self.continuation?.finish()
    self.continuation = continuation
    lock.unlock()
  }

  func push(_ samples: [Float]) {
    lock.lock()
    let continuation = continuation
    lock.unlock()
    continuation?.yield(samples)
  }

  func finish() {
    lock.lock()
    continuation?.finish()
    continuation = nil
    lock.unlock()
  }
}

/// Downloads, loads, and runs WhisperKit and Parakeet models. Behavior and
/// storage layout match the original Swift TranscriptionClient so existing
/// downloads remain valid.
actor SpeechEngine {
  static let shared = SpeechEngine()

  private var whisperKit: WhisperKit?
  private var currentModelName: String?
  private let parakeet = ParakeetEngine()

  private lazy var modelsBaseFolder: URL = {
    do {
      return try TickPaths.models
    } catch {
      logger.error("Could not create Application Support folder: \(error.localizedDescription); using temporary models folder")
      let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("com.dipxsy.Tick/models", isDirectory: true)
      try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
      return fallback
    }
  }()

  func downloadAndLoad(model variant: String, progress: @escaping @Sendable (Double) -> Void) async throws {
    if let parakeetVariant = ParakeetVariant(rawValue: variant) {
      try await parakeet.ensureLoaded(parakeetVariant, progress: progress)
      currentModelName = variant
      return
    }
    let variant = await resolveVariant(variant)
    guard !variant.isEmpty else {
      throw SpeechError(message: "Cannot download model: the model name is empty.")
    }
    progress(0)
    if !(await isDownloaded(model: variant)) {
      try await downloadWhisperIfNeeded(variant: variant) { progress($0 * 0.5) }
    } else {
      progress(0.5)
    }
    try await loadWhisper(variant) { progress(0.5 + $0 * 0.5) }
    progress(1)
  }

  func warm(model variant: String) async throws {
    guard await isDownloaded(model: variant) else { return }
    if let parakeetVariant = ParakeetVariant(rawValue: variant) {
      guard currentModelName != variant else { return }
      try await parakeet.ensureLoaded(parakeetVariant) { _ in }
      currentModelName = variant
      logger.notice("Parakeet prewarmed variant=\(variant, privacy: .public)")
      return
    }
    guard currentModelName != variant else { return }
    try await loadWhisper(variant) { _ in }
  }

  func delete(model variant: String) async throws {
    if let parakeetVariant = ParakeetVariant(rawValue: variant) {
      try await parakeet.deleteCaches(parakeetVariant)
      if currentModelName == variant { unload() }
      return
    }
    let folder = modelPath(for: variant)
    guard FileManager.default.fileExists(atPath: folder.path) else { return }
    if currentModelName == variant { unload() }
    try FileManager.default.removeItem(at: folder)
    logger.info("Deleted model \(variant, privacy: .public)")
  }

  func isDownloaded(model name: String) async -> Bool {
    if let parakeetVariant = ParakeetVariant(rawValue: name) {
      return await parakeet.isAvailable(parakeetVariant)
    }
    let fm = FileManager.default
    let folder = modelPath(for: name).path
    guard fm.fileExists(atPath: folder),
          let contents = try? fm.contentsOfDirectory(atPath: folder),
          !contents.isEmpty
    else { return false }
    let hasModelFiles = contents.contains { $0.hasSuffix(".mlmodelc") || $0.contains("model") }
    let hasTokenizer = fm.fileExists(atPath: tokenizerPath(for: name).path)
    return hasModelFiles && hasTokenizer
  }

  func catalogJSON() async throws -> String {
    struct Entry: Encodable { let name: String; let downloaded: Bool }
    struct Catalog: Encodable { let recommended: String; let models: [Entry] }
    let recommended = await WhisperKit.recommendedRemoteModels().default
    var names = try await WhisperKit.fetchAvailableModels()
    for variant in ParakeetVariant.allCases.reversed() where !names.contains(variant.rawValue) {
      names.insert(variant.rawValue, at: 0)
    }
    var entries: [Entry] = []
    for name in names {
      entries.append(Entry(name: name, downloaded: await isDownloaded(model: name)))
    }
    let data = try JSONEncoder().encode(Catalog(recommended: recommended, models: entries))
    return String(decoding: data, as: UTF8.self)
  }

  func transcribe(url: URL, model: String, language: String?) async throws -> String {
    let startedAt = Date()
    if ParakeetVariant(rawValue: model) != nil {
      try await downloadAndLoad(model: model) { _ in }
      let prepared = try ParakeetClipPreparer.ensureMinimumDuration(url: url)
      defer { prepared.cleanup() }
      let text = try await parakeet.transcribe(prepared.url)
      logger.info("Parakeet request total elapsed \(String(format: "%.2f", Date().timeIntervalSince(startedAt)), privacy: .public)s")
      return text
    }
    let model = await resolveVariant(model)
    if whisperKit == nil || model != currentModelName {
      unload()
      try await downloadAndLoad(model: model) { _ in }
    }
    guard let whisperKit else {
      throw SpeechError(message: "WhisperKit failed to initialize model \(model). Try deleting and re-downloading it in Settings.")
    }
    let options = DecodingOptions(
      language: language,
      detectLanguage: language == nil,
      chunkingStrategy: .vad
    )
    let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
    logger.info("WhisperKit request total elapsed \(String(format: "%.2f", Date().timeIntervalSince(startedAt)), privacy: .public)s")
    return results.map(\.text).joined(separator: " ")
  }

  func startStreaming(model: String) async throws -> Bool {
    guard let variant = ParakeetVariant(rawValue: model) else { return false }
    try await parakeet.startStreaming(variant)
    return true
  }

  func finishStreaming() async throws -> String? {
    try await parakeet.finishStreaming()
  }

  func cancelStreaming() async {
    await parakeet.cancelStreaming()
  }

  // MARK: Helpers

  private func resolveVariant(_ variant: String) async -> String {
    guard variant.contains("*") || variant.contains("?") else { return variant }
    guard let names = try? await WhisperKit.fetchAvailableModels() else { return variant }
    var matched: [(name: String, downloaded: Bool)] = []
    for name in names where fnmatch(variant, name, 0) == 0 {
      matched.append((name, await isDownloaded(model: name)))
    }
    guard !matched.isEmpty else { return variant }
    let downloaded = matched.filter(\.downloaded)
    let pool = downloaded.isEmpty ? matched : downloaded
    return pool.first(where: { !$0.name.localizedCaseInsensitiveContains("turbo") })?.name ?? pool[0].name
  }

  private func modelPath(for variant: String) -> URL {
    let sanitized = variant.components(separatedBy: CharacterSet(charactersIn: "./\\")).joined(separator: "_")
    return modelsBaseFolder
      .appendingPathComponent("argmaxinc")
      .appendingPathComponent("whisperkit-coreml")
      .appendingPathComponent(sanitized, isDirectory: true)
  }

  private func tokenizerPath(for variant: String) -> URL {
    modelPath(for: variant).appendingPathComponent("tokenizer", isDirectory: true)
  }

  private func unload() {
    whisperKit = nil
    currentModelName = nil
  }

  private func downloadWhisperIfNeeded(variant: String, progress: @escaping @Sendable (Double) -> Void) async throws {
    let folder = modelPath(for: variant)
    let fm = FileManager.default
    let downloaded = await isDownloaded(model: variant)
    if fm.fileExists(atPath: folder.path), !downloaded {
      try fm.removeItem(at: folder)
    }
    if downloaded { return }
    try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
      let tempFolder = try await WhisperKit.download(
        variant: variant,
        downloadBase: nil,
        useBackgroundSession: false,
        progressCallback: { progress($0.fractionCompleted) }
      )
      try Task.checkCancellation()
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      for item in try fm.contentsOfDirectory(atPath: tempFolder.path) {
        try fm.moveItem(at: tempFolder.appendingPathComponent(item), to: folder.appendingPathComponent(item))
      }
      logger.info("Downloaded model to \(folder.path, privacy: .private)")
    } catch {
      try? fm.removeItem(at: folder)
      logger.error("Error downloading model \(variant, privacy: .public): \(error.localizedDescription, privacy: .public)")
      throw error
    }
  }

  private func loadWhisper(_ name: String, progress: @escaping @Sendable (Double) -> Void) async throws {
    progress(0)
    let config = WhisperKitConfig(
      model: name,
      modelFolder: modelPath(for: name).path,
      tokenizerFolder: tokenizerPath(for: name),
      prewarm: false,
      load: true
    )
    whisperKit = try await WhisperKit(config)
    currentModelName = name
    progress(1)
    logger.info("Loaded WhisperKit model \(name, privacy: .public)")
  }
}

// MARK: - Parakeet

actor ParakeetEngine {
  private var asr: AsrManager?
  private var models: AsrModels?
  private var currentVariant: ParakeetVariant?
  private var loadTask: Task<Void, Error>?
  private var loadingVariant: ParakeetVariant?
  private var streamingManager: StreamingAsrManager?
  private var streamingInputTask: Task<Void, Error>?
  private var availabilityCache: [String: (result: Bool, at: Date)] = [:]
  private let vendorDirs = ["fluidaudio/Models", "FluidAudio/Models"]

  func isAvailable(_ variant: ParakeetVariant) -> Bool {
    if currentVariant == variant, asr != nil { return true }
    if let cached = availabilityCache[variant.rawValue], Date().timeIntervalSince(cached.at) < 30 {
      return cached.result
    }
    let result = modelDirectories(variant).contains(where: containsCompiledModel)
    availabilityCache[variant.rawValue] = (result, Date())
    return result
  }

  func ensureLoaded(_ variant: ParakeetVariant, progress: @escaping @Sendable (Double) -> Void) async throws {
    if currentVariant == variant, asr != nil { return }
    if let loadTask, loadingVariant == variant {
      try await loadTask.value
      return
    }
    if let loadTask {
      try await loadTask.value
      if currentVariant == variant, asr != nil { return }
    }
    let task = Task { try await self.load(variant, progress: progress) }
    loadTask = task
    loadingVariant = variant
    defer {
      loadTask = nil
      loadingVariant = nil
    }
    try await task.value
  }

  private func load(_ variant: ParakeetVariant, progress: @escaping @Sendable (Double) -> Void) async throws {
    if currentVariant != variant {
      asr = nil
      models = nil
    }
    let startedAt = Date()
    progress(0.01)
    let fm = FileManager.default
    let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let downloadDir = support?.appendingPathComponent("FluidAudio/Models/\(variant.rawValue)", isDirectory: true)
    // FluidAudio reports no progress; poll the directory size against ~650 MB.
    let poll = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        if let downloadDir, let size = Self.directorySize(downloadDir) {
          let fraction = max(0, min(1, Double(size) / (650 * 1024 * 1024)))
          progress(0.05 + fraction * 0.90)
        }
      }
    }
    defer { poll.cancel() }

    let models = try await AsrModels.downloadAndLoad(version: variant.asrVersion)
    let manager = AsrManager(config: .init())
    try await manager.initialize(models: models)
    self.models = models
    self.asr = manager
    self.currentVariant = variant
    availabilityCache[variant.rawValue] = nil
    progress(1)
    logger.notice("Parakeet loaded in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)), privacy: .public)s")
  }

  func transcribe(_ url: URL) async throws -> String {
    guard let asr else { throw SpeechError(message: "Parakeet is not initialized. Download the model in Settings.") }
    return try await asr.transcribe(url).text
  }

  func startStreaming(_ variant: ParakeetVariant) async throws {
    try await ensureLoaded(variant) { _ in }
    await cancelStreaming()
    guard let models else {
      throw SpeechError(message: "Parakeet models are unavailable for streaming.")
    }
    let manager = StreamingAsrManager(config: .streaming)
    let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(32))
    StreamingSink.shared.attach(continuation)
    streamingManager = manager
    streamingInputTask = Task {
      try await manager.start(models: models, source: .microphone)
      for await samples in stream {
        try Task.checkCancellation()
        guard let buffer = Self.pcmBuffer(samples) else { continue }
        await manager.streamAudio(buffer)
      }
    }
    logger.notice("Parakeet streaming session prepared")
  }

  func finishStreaming() async throws -> String? {
    guard let manager = streamingManager else { return nil }
    StreamingSink.shared.finish()
    try await streamingInputTask?.value
    let result = try await manager.finish()
    streamingManager = nil
    streamingInputTask = nil
    return result
  }

  func cancelStreaming() async {
    StreamingSink.shared.finish()
    streamingInputTask?.cancel()
    await streamingManager?.cancel()
    streamingManager = nil
    streamingInputTask = nil
  }

  func deleteCaches(_ variant: ParakeetVariant) throws {
    let fm = FileManager.default
    var removed = false
    for directory in modelDirectories(variant) where fm.fileExists(atPath: directory.path) {
      try? fm.removeItem(at: directory)
      removed = true
    }
    if removed {
      asr = nil
      models = nil
      if currentVariant == variant { currentVariant = nil }
      availabilityCache[variant.rawValue] = nil
    }
  }

  private func modelDirectories(_ variant: ParakeetVariant) -> [URL] {
    let fm = FileManager.default
    var result: [URL] = []
    for root in candidateRoots() {
      for vendor in vendorDirs {
        let base = root.appendingPathComponent(vendor, isDirectory: true)
        let direct = base.appendingPathComponent(variant.rawValue, isDirectory: true)
        result.append(direct)
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
          result += items.filter { $0.lastPathComponent.hasPrefix(variant.rawValue) && $0 != direct }
        }
      }
    }
    return result
  }

  private func candidateRoots() -> [URL] {
    let fm = FileManager.default
    let xdg = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    let appCache = try? TickPaths.applicationSupport.appendingPathComponent("cache", isDirectory: true)
    let userCache = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cache", isDirectory: true)
    return [xdg, appCache, appSupport, userCache].compactMap { $0 }
  }

  private func containsCompiledModel(_ directory: URL) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: directory.path) else { return false }
    if let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
      for child in children {
        if child.lastPathComponent.hasSuffix(".mlmodelc") { return true }
        if let nested = try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
           nested.contains(where: { $0.lastPathComponent.hasSuffix(".mlmodelc") }) {
          return true
        }
      }
    }
    if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
      for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".mlmodelc") {
        return true
      }
    }
    return false
  }

  private static func pcmBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
    guard !samples.isEmpty,
          let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
          let destination = buffer.floatChannelData?[0]
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      if let base = source.baseAddress { destination.update(from: base, count: samples.count) }
    }
    return buffer
  }

  private static func directorySize(_ directory: URL) -> UInt64? {
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: .skipsHiddenFiles
    ) else { return nil }
    var total: UInt64 = 0
    for case let url as URL in enumerator {
      if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true {
        total &+= UInt64(values.fileSize ?? 0)
      }
    }
    return total
  }
}

// MARK: - Short clip padding

struct PreparedClip {
  let url: URL
  let cleanupURL: URL?
  func cleanup() {
    if let cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) }
  }
}

/// FluidAudio's decoder errors on clips shorter than its 1.5 s chunk window;
/// pad such clips with silence.
enum ParakeetClipPreparer {
  static let minimumDuration: TimeInterval = 1.5

  static func ensureMinimumDuration(url: URL) throws -> PreparedClip {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let duration = Double(file.length) / format.sampleRate
    guard duration < minimumDuration else { return PreparedClip(url: url, cleanupURL: nil) }
    guard format.commonFormat == .pcmFormatFloat32 else {
      throw SpeechError(message: "Parakeet can only pad mono Float32 PCM recordings.")
    }
    let minimumFrames = AVAudioFrameCount((minimumDuration * format.sampleRate).rounded(.up))
    let capacity = max(AVAudioFrameCount(min(max(0, file.length), AVAudioFramePosition(AVAudioFrameCount.max))), 1)
    guard let read = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
          let padded = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: minimumFrames)
    else { throw SpeechError(message: "Unable to allocate a buffer while preparing the Parakeet clip.") }
    try file.read(into: read)
    let framesRead = min(read.frameLength, minimumFrames)
    guard let source = read.floatChannelData, let destination = padded.floatChannelData else {
      throw SpeechError(message: "Parakeet can only pad mono Float32 PCM recordings.")
    }
    for channel in 0..<Int(format.channelCount) {
      if framesRead > 0 { destination[channel].update(from: source[channel], count: Int(framesRead)) }
      let padCount = Int(minimumFrames - framesRead)
      if padCount > 0 { destination[channel].advanced(by: Int(framesRead)).initialize(repeating: 0, count: padCount) }
    }
    padded.frameLength = minimumFrames
    let paddedURL = url.deletingLastPathComponent()
      .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-parakeet-padded.wav")
    try? FileManager.default.removeItem(at: paddedURL)
    let output = try AVAudioFile(forWriting: paddedURL, settings: file.fileFormat.settings)
    try output.write(from: padded)
    return PreparedClip(url: paddedURL, cleanupURL: paddedURL)
  }
}
