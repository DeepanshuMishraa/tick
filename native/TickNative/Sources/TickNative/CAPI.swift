import Foundation
import os

// MARK: - C ABI
//
// Every asynchronous entry point takes an opaque `ctx` pointer that is handed
// back unchanged to exactly one `done` callback. String arguments passed to a
// callback are only valid for the duration of that call; the Rust side copies
// them. Callbacks run on arbitrary threads.

public typealias TNDoneCallback = @convention(c) (
  UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> Void
public typealias TNProgressCallback = @convention(c) (UnsafeMutableRawPointer?, Double) -> Void
/// Returns `false` to stop generation early.
public typealias TNChunkCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Bool

let nativeLogger = Logger(subsystem: "com.dipxsy.Tick", category: "Native")

struct Reply: @unchecked Sendable {
  let ctx: UnsafeMutableRawPointer?
  let done: TNDoneCallback

  func success(_ value: String?) {
    if let value {
      value.withCString { done(ctx, $0, nil) }
    } else {
      done(ctx, nil, nil)
    }
  }

  func failure(_ error: Error) {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    message.withCString { done(ctx, nil, $0) }
  }

  func run(_ operation: @escaping @Sendable () async throws -> String?) -> Task<Void, Never> {
    Task {
      do {
        success(try await operation())
      } catch is CancellationError {
        "cancelled".withCString { done(ctx, nil, $0) }
      } catch {
        failure(error)
      }
    }
  }
}

struct Progress: @unchecked Sendable {
  let ctx: UnsafeMutableRawPointer?
  let callback: TNProgressCallback
  func report(_ fraction: Double) { callback(ctx, fraction) }
}

/// Cancellable long-running operations (model downloads) keyed by an id the
/// caller can pass to `tn_task_cancel`.
final class TaskRegistry: @unchecked Sendable {
  static let shared = TaskRegistry()
  private let lock = NSLock()
  private var nextID: UInt64 = 1
  private var tasks: [UInt64: Task<Void, Never>] = [:]

  func insert(_ make: (UInt64) -> Task<Void, Never>) -> UInt64 {
    lock.lock()
    let id = nextID
    nextID += 1
    lock.unlock()
    let task = make(id)
    lock.lock()
    tasks[id] = task
    lock.unlock()
    return id
  }

  func remove(_ id: UInt64) {
    lock.lock()
    tasks[id] = nil
    lock.unlock()
  }

  func cancel(_ id: UInt64) {
    lock.lock()
    let task = tasks.removeValue(forKey: id)
    lock.unlock()
    task?.cancel()
  }
}

func string(_ pointer: UnsafePointer<CChar>?) -> String? {
  pointer.map { String(cString: $0) }
}

@_cdecl("tn_task_cancel")
public func tn_task_cancel(_ id: UInt64) {
  TaskRegistry.shared.cancel(id)
}

// MARK: Speech

@_cdecl("tn_speech_download")
public func tn_speech_download(
  _ model: UnsafePointer<CChar>,
  _ ctx: UnsafeMutableRawPointer?,
  _ progress: TNProgressCallback,
  _ done: TNDoneCallback
) -> UInt64 {
  let model = String(cString: model)
  let reply = Reply(ctx: ctx, done: done)
  let progress = Progress(ctx: ctx, callback: progress)
  return TaskRegistry.shared.insert { id in
    reply.run {
      defer { TaskRegistry.shared.remove(id) }
      try await SpeechEngine.shared.downloadAndLoad(model: model) { progress.report($0) }
      return nil
    }
  }
}

@_cdecl("tn_speech_warm")
public func tn_speech_warm(_ model: UnsafePointer<CChar>, _ ctx: UnsafeMutableRawPointer?, _ done: TNDoneCallback) {
  let model = String(cString: model)
  _ = Reply(ctx: ctx, done: done).run {
    try await SpeechEngine.shared.warm(model: model)
    return nil
  }
}

@_cdecl("tn_speech_transcribe")
public func tn_speech_transcribe(
  _ path: UnsafePointer<CChar>,
  _ model: UnsafePointer<CChar>,
  _ language: UnsafePointer<CChar>?,
  _ ctx: UnsafeMutableRawPointer?,
  _ done: TNDoneCallback
) {
  let path = String(cString: path)
  let model = String(cString: model)
  let language = string(language)
  _ = Reply(ctx: ctx, done: done).run {
    try await SpeechEngine.shared.transcribe(url: URL(fileURLWithPath: path), model: model, language: language)
  }
}

@_cdecl("tn_speech_delete")
public func tn_speech_delete(_ model: UnsafePointer<CChar>, _ ctx: UnsafeMutableRawPointer?, _ done: TNDoneCallback) {
  let model = String(cString: model)
  _ = Reply(ctx: ctx, done: done).run {
    try await SpeechEngine.shared.delete(model: model)
    return nil
  }
}

/// Result: "1" when downloaded, "0" otherwise.
@_cdecl("tn_speech_is_downloaded")
public func tn_speech_is_downloaded(_ model: UnsafePointer<CChar>, _ ctx: UnsafeMutableRawPointer?, _ done: TNDoneCallback) {
  let model = String(cString: model)
  _ = Reply(ctx: ctx, done: done).run {
    await SpeechEngine.shared.isDownloaded(model: model) ? "1" : "0"
  }
}

/// Result: JSON `{"recommended": String, "models": [{"name": String, "downloaded": Bool}]}`.
@_cdecl("tn_speech_catalog")
public func tn_speech_catalog(_ ctx: UnsafeMutableRawPointer?, _ done: TNDoneCallback) {
  _ = Reply(ctx: ctx, done: done).run {
    try await SpeechEngine.shared.catalogJSON()
  }
}

/// Result: "1" when a streaming session started, "0" when the model does not stream.
@_cdecl("tn_stream_start")
public func tn_stream_start(_ model: UnsafePointer<CChar>, _ ctx: UnsafeMutableRawPointer?, _ done: TNDoneCallback) {
  let model = String(cString: model)
  _ = Reply(ctx: ctx, done: done).run {
    try await SpeechEngine.shared.startStreaming(model: model) ? "1" : "0"
  }
}

/// Synchronous and cheap: copies 16 kHz mono Float32 samples into the active stream.
@_cdecl("tn_stream_push")
public func tn_stream_push(_ samples: UnsafePointer<Float>, _ count: Int) {
  StreamingSink.shared.push(Array(UnsafeBufferPointer(start: samples, count: count)))
}

@_cdecl("tn_stream_finish")
public func tn_stream_finish(_ ctx: UnsafeMutableRawPointer?, _ done: TNDoneCallback) {
  _ = Reply(ctx: ctx, done: done).run {
    try await SpeechEngine.shared.finishStreaming()
  }
}

@_cdecl("tn_stream_cancel")
public func tn_stream_cancel() {
  Task { await SpeechEngine.shared.cancelStreaming() }
}

// MARK: LLM

@_cdecl("tn_llm_warm")
public func tn_llm_warm(_ directory: UnsafePointer<CChar>, _ ctx: UnsafeMutableRawPointer?, _ done: TNDoneCallback) {
  let directory = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
  _ = Reply(ctx: ctx, done: done).run {
    try await LanguageModel.shared.warm(directory: directory)
    return nil
  }
}

@_cdecl("tn_llm_generate")
public func tn_llm_generate(
  _ directory: UnsafePointer<CChar>,
  _ system: UnsafePointer<CChar>,
  _ user: UnsafePointer<CChar>,
  _ maxTokens: Int32,
  _ ctx: UnsafeMutableRawPointer?,
  _ chunk: TNChunkCallback,
  _ done: TNDoneCallback
) {
  let directory = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
  let system = String(cString: system)
  let user = String(cString: user)
  let sink = ChunkSink(ctx: ctx, callback: chunk)
  _ = Reply(ctx: ctx, done: done).run {
    try await LanguageModel.shared.generate(
      directory: directory,
      system: system,
      user: user,
      maxTokens: Int(maxTokens),
      onChunk: sink.send
    )
    return nil
  }
}

@_cdecl("tn_llm_unload")
public func tn_llm_unload() {
  Task { await LanguageModel.shared.unload() }
}

struct ChunkSink: @unchecked Sendable {
  let ctx: UnsafeMutableRawPointer?
  let callback: TNChunkCallback
  func send(_ text: String) -> Bool {
    text.withCString { callback(ctx, $0) }
  }
}

// MARK: Permission panel

/// pane: 0 = Accessibility, 1 = Input Monitoring.
@_cdecl("tn_permission_flow_open")
public func tn_permission_flow_open(_ pane: Int32) {
  DispatchQueue.main.async { PermissionPanel.shared.open(pane: pane) }
}

@_cdecl("tn_permission_flow_dismiss")
public func tn_permission_flow_dismiss() {
  DispatchQueue.main.async { PermissionPanel.shared.dismiss() }
}

// MARK: Updates

@_cdecl("tn_updater_start")
public func tn_updater_start() {
  DispatchQueue.main.async { Updater.shared.start() }
}

@_cdecl("tn_updater_check")
public func tn_updater_check() {
  DispatchQueue.main.async { Updater.shared.check() }
}

@_cdecl("tn_updater_can_check")
public func tn_updater_can_check() -> Bool {
  Updater.shared.canCheck
}
