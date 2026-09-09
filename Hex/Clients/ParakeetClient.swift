import AVFoundation
import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio

actor ParakeetClient {
  private var asr: AsrManager?
  private var models: AsrModels?
  private var currentVariant: ParakeetModel?
  private var loadTask: Task<Void, Error>?
  private var loadingVariant: ParakeetModel?
  private var streamingManager: StreamingAsrManager?
  private var streamingSink: RecordingAudioChunkSink?
  private var streamingInputTask: Task<Void, Error>?
  private let logger = HexLog.parakeet
  private var availabilityCache: [String: (result: Bool, at: Date)] = [:]
  private let availabilityCacheTTL: TimeInterval = 30
  private let vendorDirs = [
    // Our app-specific cache path convention (under XDG or com.dipxsy.Tick/cache)
    "fluidaudio/Models",
    "FluidAudio/Models"
  ]

  func isModelAvailable(_ modelName: String) async -> Bool {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      logger.error("Unknown Parakeet variant requested: \(modelName)")
      return false
    }
    if currentVariant == variant, asr != nil { return true }
    if let cached = availabilityCache[modelName], Date().timeIntervalSince(cached.at) < availabilityCacheTTL {
      return cached.result
    }

    logger.debug("Checking Parakeet availability variant=\(variant.identifier)")
    for dir in modelDirectories(variant) {
      if directoryContainsMLModelC(dir) {
        logger.notice("Found Parakeet cache at \(dir.path)")
        availabilityCache[modelName] = (true, Date())
        return true
      }
    }
    logger.debug("No Parakeet cache detected variant=\(variant.identifier)")
    availabilityCache[modelName] = (false, Date())
    return false
  }

  private func invalidateAvailabilityCache(_ modelName: String? = nil) {
    if let modelName { availabilityCache[modelName] = nil }
    else { availabilityCache.removeAll() }
  }

  private func directoryContainsMLModelC(_ dir: URL) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: dir.path) else { return false }
    // Fast path: compiled Core ML bundles usually sit 1-2 levels deep.
    // A shallow listing avoids a full recursive walk over ~650MB on every
    // availability check (warm/transcribe path).
    if let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
      for child in children {
        let name = child.lastPathComponent
        if name.hasSuffix(".mlmodelc") { return true }
        if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           let nested = try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
           nested.contains(where: { $0.lastPathComponent.hasSuffix(".mlmodelc") }) {
          return true
        }
      }
    }
    if let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
      for case let url as URL in en {
        if url.pathExtension == "mlmodelc" || url.lastPathComponent.hasSuffix(".mlmodelc") { return true }
      }
    }
    return false
  }

  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      throw NSError(
        domain: "Parakeet",
        code: -4,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported Parakeet variant: \(modelName)"]
      )
    }
    if currentVariant == variant, asr != nil { return }
    if let loadTask, loadingVariant == variant {
      logger.debug("Joining in-flight Parakeet load variant=\(variant.identifier)")
      try await loadTask.value
      return
    }
    if let loadTask {
      try await loadTask.value
      if currentVariant == variant, asr != nil { return }
    }

    let task = Task { try await self.load(variant: variant, progress: progress) }
    loadTask = task
    loadingVariant = variant
    do {
      try await task.value
      loadTask = nil
      loadingVariant = nil
    } catch {
      loadTask = nil
      loadingVariant = nil
      throw error
    }
  }

  private func load(variant: ParakeetModel, progress: @escaping (Progress) -> Void) async throws {
    if currentVariant != variant {
      asr = nil
      models = nil
    }
    let t0 = Date()
    logger.notice("Starting Parakeet load variant=\(variant.identifier)")
    let p = Progress(totalUnitCount: 100)
    p.completedUnitCount = 1
    progress(p)

    // Best-effort progress polling while FluidAudio downloads
    let fm = FileManager.default
    let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let faDir = support?.appendingPathComponent("FluidAudio/Models/\(variant.identifier)", isDirectory: true)
    let pollTask = Task {
      while p.completedUnitCount < 95 {
        try? await Task.sleep(for: .seconds(2))
        if let dir = faDir, let size = directorySize(dir) {
          let target: Double = 650 * 1024 * 1024 // ~650MB
          let frac = max(0.0, min(1.0, Double(size) / target))
          p.completedUnitCount = Int64(5 + frac * 90)
          progress(p)
        }
        if Task.isCancelled { break }
      }
    }
    defer { pollTask.cancel() }

    // Download + load the requested variant (returns when all assets are present)
    let models = try await AsrModels.downloadAndLoad(version: variant.asrVersion)
    self.models = models
    let manager = AsrManager(config: .init())
    try await manager.initialize(models: models)
    self.asr = manager
    self.currentVariant = variant
    invalidateAvailabilityCache(variant.identifier)
    p.completedUnitCount = 100
    progress(p)
    logger.notice("Parakeet ensureLoaded completed in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
  }

  func startStreaming(modelName: String) async throws -> RecordingAudioChunkSink {
    try await ensureLoaded(modelName: modelName) { _ in }
    await cancelStreaming()
    guard let models else {
      throw NSError(
        domain: "Parakeet",
        code: -5,
        userInfo: [NSLocalizedDescriptionKey: "Parakeet models are unavailable for streaming."]
      )
    }

    let manager = StreamingAsrManager(config: .streaming)
    let (stream, continuation) = AsyncStream<RecordingAudioChunk>.makeStream(
      bufferingPolicy: .bufferingNewest(32)
    )
    let sink = RecordingAudioChunkSink(continuation)
    streamingManager = manager
    streamingSink = sink
    streamingInputTask = Task {
      try await manager.start(models: models, source: .microphone)
      for await chunk in stream {
        try Task.checkCancellation()
        guard let buffer = Self.pcmBuffer(from: chunk.samples) else { continue }
        await manager.streamAudio(buffer)
      }
    }
    logger.notice("Parakeet streaming session prepared")
    return sink
  }

  func finishStreaming() async throws -> String? {
    guard let manager = streamingManager else { return nil }
    streamingSink?.finish()
    try await streamingInputTask?.value
    let result = try await manager.finish()
    streamingManager = nil
    streamingSink = nil
    streamingInputTask = nil
    logger.notice("Parakeet streaming session finished chars=\(result.count, privacy: .public)")
    return result
  }

  func cancelStreaming() async {
    streamingSink?.finish()
    streamingInputTask?.cancel()
    await streamingManager?.cancel()
    streamingManager = nil
    streamingSink = nil
    streamingInputTask = nil
  }

  private static func pcmBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
    guard !samples.isEmpty,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
      ),
      let destination = buffer.floatChannelData?[0]
    else { return nil }

    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      guard let baseAddress = source.baseAddress else { return }
      destination.update(from: baseAddress, count: samples.count)
    }
    return buffer
  }

  private func directorySize(_ dir: URL) -> UInt64? {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: .skipsHiddenFiles) else { return nil }
    var total: UInt64 = 0
    for case let url as URL in en {
      if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true {
        total &+= UInt64(vals.fileSize ?? 0)
      }
    }
    return total
  }

  func transcribe(_ url: URL) async throws -> String {
    guard let asr else { throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"]) }
    let t0 = Date()
    logger.notice("Transcribing with Parakeet file=\(url.lastPathComponent)")
    let result = try await asr.transcribe(url)
    logger.info("Parakeet transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    return result.text
  }

  // Delete cached Parakeet models from known locations and reset state
  func deleteCaches(modelName: String) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else { return }
    let fm = FileManager.default

    var removedAny = false
    for dir in modelDirectories(variant) {
      if fm.fileExists(atPath: dir.path) {
        try? fm.removeItem(at: dir)
        removedAny = true
      }
    }

    // Reset live objects so a future download can proceed cleanly
    if removedAny {
      self.asr = nil
      self.models = nil
      if currentVariant == variant {
        currentVariant = nil
      }
      invalidateAvailabilityCache(variant.identifier)
    }
  }

  /// Returns all candidate directories where a Parakeet model might be cached.
  /// Includes both exact matches and prefixed directories (e.g. versioned folders).
  private func modelDirectories(_ variant: ParakeetModel) -> [URL] {
    let fm = FileManager.default
    var result: [URL] = []

    for root in candidateRoots() {
      for vendor in vendorDirs {
        let base = root.appendingPathComponent(vendor, isDirectory: true)
        // Exact match directory
        let direct = base.appendingPathComponent(variant.identifier, isDirectory: true)
        result.append(direct)
        // Prefixed directories (e.g. versioned folders)
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
          for item in items where item.lastPathComponent.hasPrefix(variant.identifier) && item != direct {
            result.append(item)
          }
        }
      }
    }
    return result
  }

  private func candidateRoots() -> [URL] {
    let fm = FileManager.default
    let xdg = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
    let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    let appCache = try? URL.hexApplicationSupport.appendingPathComponent("cache", isDirectory: true)
    let userCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache", isDirectory: true)
    return [xdg, appCache, appSupport, userCache].compactMap { $0 }
  }
}

private extension ParakeetModel {
  var asrVersion: AsrModelVersion {
    switch self {
    case .englishV2: return .v2
    case .multilingualV3: return .v3
    }
  }
}

#else

actor ParakeetClient {
  func isModelAvailable(_ modelName: String) async -> Bool { false }
  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    throw NSError(
      domain: "Parakeet",
      code: -2,
      userInfo: [NSLocalizedDescriptionKey: "Parakeet support not linked. Add Swift Package: https://github.com/FluidInference/FluidAudio.git and link FluidAudio to Hex."]
    )
  }
  func startStreaming(modelName: String) async throws -> RecordingAudioChunkSink {
    throw NSError(domain: "Parakeet", code: -3, userInfo: [NSLocalizedDescriptionKey: "Parakeet not available"])
  }
  func finishStreaming() async throws -> String? { nil }
  func cancelStreaming() async {}
  func transcribe(_ url: URL) async throws -> String { throw NSError(domain: "Parakeet", code: -3, userInfo: [NSLocalizedDescriptionKey: "Parakeet not available"]) }
  func deleteCaches(modelName: String) async throws {}
}

#endif
