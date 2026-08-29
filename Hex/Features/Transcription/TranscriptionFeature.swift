//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var isLocked: Bool = false
    var error: String?
    var recordingStartTime: Date?
    var transcriptionRequestStartUptime: TimeInterval?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var appContext: AppContext?
    var feedback: Feedback?
    var correctionKeystrokeTracker: WordCorrectionKeystrokeTracker?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory

    enum Feedback: Equatable {
      case dictionaryAdded(match: String, replacement: String)
      case pasteUnavailable(text: String, reason: PasteFailureReason)
      case copied
    }

    enum PasteFailureReason: Equatable {
      case noFocusedInput
      case insertionRejected
    }
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased
    case setLocked(Bool)

    // Recording flow
    case startRecording(isLocked: Bool)
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcriptionResult(String, URL)
    case transcriptionError(Error, URL?)
    case pasteCompleted
    case beginCorrectionMonitoring(beforeText: String?, baseline: String?, insertedText: String)
    case correctionKeyEvent(KeyEvent)
    case evaluateKeystrokeCorrection
    case correctionMonitoringExpired
    case correctionDetected(WordCorrection)
    case pasteUnavailable(String, reason: State.PasteFailureReason)
    case copyFeedback
    case feedbackCopied
    case feedbackDismissed

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case transcription
    case correctionMonitoring
    case correctionTypingSettle
    case feedback
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.aiPostProcessing) var aiPostProcessing

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect(),
          warmUpModelsEffect(
            speechModel: state.hexSettings.selectedModel,
            aiEnabled: state.hexSettings.aiPostProcessingMode != .off
          )
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      case let .setLocked(isLocked):
        state.isLocked = isLocked
        return .none

      // MARK: - Recording Flow

      case let .startRecording(isLocked):
        state.feedback = nil
        state.correctionKeystrokeTracker = nil
        return .merge(
          .cancel(id: CancelID.feedback),
          .cancel(id: CancelID.correctionMonitoring),
          .cancel(id: CancelID.correctionTypingSettle),
          handleStartRecording(&state, isLocked: isLocked)
        )

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionResult(result, audioURL):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL)

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case .pasteCompleted:
        // Keep the notch in its processing state until the target application
        // has accepted the final text, including any optional AI formatting.
        state.isTranscribing = false
        state.isPrewarming = false
        state.transcriptionRequestStartUptime = nil
        return .none

      case let .beginCorrectionMonitoring(beforeText, baseline, insertedText):
        // Keyboard reconstruction is only a fallback for editors that do not
        // expose a complete AX value. When a complete baseline exists, AX is
        // the authority and global keystrokes must not be allowed to create a
        // dictionary entry from unrelated typing elsewhere in the document.
        state.correctionKeystrokeTracker = baseline == nil
          ? WordCorrectionKeystrokeTracker(insertedText: insertedText)
          : nil
        return monitorForCorrectionEffect(
          beforeText: beforeText,
          baseline: baseline,
          insertedText: insertedText
        )

      case let .correctionKeyEvent(event):
        guard event.isKeyDown, var tracker = state.correctionKeystrokeTracker else {
          return .none
        }
        guard tracker.apply(key: event.key, text: event.text, modifiers: event.modifiers) else {
          state.correctionKeystrokeTracker = tracker
          return .none
        }
        state.correctionKeystrokeTracker = tracker
        return .run { send in
          try await Task.sleep(for: .milliseconds(700))
          await send(.evaluateKeystrokeCorrection)
        }
        .cancellable(id: CancelID.correctionTypingSettle, cancelInFlight: true)

      case .evaluateKeystrokeCorrection:
        guard let correction = state.correctionKeystrokeTracker?.correction else { return .none }
        return .send(.correctionDetected(correction))

      case .correctionMonitoringExpired:
        state.correctionKeystrokeTracker = nil
        return .cancel(id: CancelID.correctionTypingSettle)

      case let .correctionDetected(correction):
        state.correctionKeystrokeTracker = nil
        return handleCorrectionDetected(&state, correction: correction)

      case let .pasteUnavailable(text, reason):
        state.feedback = .pasteUnavailable(text: text, reason: reason)
        return dismissFeedbackEffect(after: .seconds(4))

      case .copyFeedback:
        guard case let .pasteUnavailable(text, _) = state.feedback else { return .none }
        return .run { [pasteboard] send in
          await pasteboard.copy(text)
          await send(.feedbackCopied)
        }

      case .feedbackCopied:
        state.feedback = .copied
        return dismissFeedbackEffect(after: .seconds(1.8))

      case .feedbackDismissed:
        state.feedback = nil
        return .cancel(id: CancelID.feedback)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled && hexSettings.useDoubleTapOnly
        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        let shouldIntercept: Bool
        switch inputEvent {
        case .keyboard(let keyEvent):
          Task { await send(.correctionKeyEvent(keyEvent)) }
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            shouldIntercept = false
          } else {
            // Process the key event
            switch hotKeyProcessor.process(keyEvent: keyEvent) {
            case .startRecording:
              // If double-tap lock is triggered, we start recording immediately
              if hotKeyProcessor.state == .doubleTapLock {
                Task { await send(.startRecording(isLocked: true)) }
              } else {
                Task { await send(.hotKeyPressed) }
              }
              // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
              // But if useDoubleTapOnly is true, always intercept the key
              shouldIntercept = useDoubleTapOnly || keyEvent.key != nil

            case .stopRecording:
              Task { await send(.hotKeyReleased) }
              shouldIntercept = false // or `true` if you want to intercept

            case .cancel:
              Task { await send(.cancel) }
              shouldIntercept = true

            case .discard:
              Task { await send(.discard) }
              shouldIntercept = false // Don't intercept - let the key chord reach other apps

            case .none:
              // If we detect repeated same chord, maybe intercept.
              if let pressedKey = keyEvent.key,
                 pressedKey == hotKeyProcessor.hotkey.key,
                 keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
              {
                shouldIntercept = true
              } else {
                shouldIntercept = false
              }
            }
          }

        case .mouseClick:
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
          case .cancel:
            Task { await send(.cancel) }
            shouldIntercept = false // Don't intercept the click itself
          case .discard:
            Task { await send(.discard) }
            shouldIntercept = false // Don't intercept the click itself
          case .startRecording, .stopRecording, .none:
            shouldIntercept = false
          }
        }

        // Sync the lock state back to the reducer
        let isCurrentLocked = hotKeyProcessor.state == .doubleTapLock
        Task { await send(.setLocked(isCurrentLocked)) }
        
        return shouldIntercept
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    // If already transcribing, cancel first. Otherwise start recording immediately.
    let maybeCancel = isTranscribing ? Effect.send(Action.cancel) : .none
    let startRecording = Effect.send(Action.startRecording(isLocked: false))
    return .merge(maybeCancel, startRecording)
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State, isLocked: Bool) -> Effect<Action> {
    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.isRecording = true
    state.isLocked = isLocked
    let startTime = Date()
    state.recordingStartTime = startTime
    
    // Capture the active application and app context
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    state.appContext = AppContext.detect(
      bundleID: state.sourceAppBundleID,
      appName: state.sourceAppName
    )
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    let speechModel = state.hexSettings.selectedModel

    // Prevent system sleep during recording
    return .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] send in
      // Play sound immediately for instant feedback
      soundEffect.play(.startRecording)

      if preventSleep {
        await sleepManagement.preventSleep(reason: "Hex Voice Recording")
      }
      do {
        if let sink = try await transcription.startStreaming(speechModel) {
          await recording.setAudioChunkHandler { sink.yield($0) }
        }
      } catch {
        transcriptionFeatureLogger.error("Streaming transcription setup failed: \(error.localizedDescription); batch fallback remains available")
      }
      await recording.startRecording()
    }
  }

  /// Warm Core ML before MLX. Compiling both backends concurrently causes
  /// severe resource contention on first launch and can stretch a sub-second
  /// Parakeet load into several seconds.
  func warmUpModelsEffect(speechModel: String, aiEnabled: Bool) -> Effect<Action> {
    .run { [transcription, aiPostProcessing] _ in
      do {
        try await transcription.warmModel(speechModel)
      } catch {
        transcriptionFeatureLogger.error("Speech model prewarm failed: \(error.localizedDescription)")
      }

      guard aiEnabled, await aiPostProcessing.isModelDownloaded() else { return }
      do {
        try await aiPostProcessing.warmModel()
      } catch {
        transcriptionFeatureLogger.error("On-device AI prewarm failed: \(error.localizedDescription)")
      }
    }
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isLocked = false
    
    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.hexSettings.hotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    let minimumKeyTime = state.hexSettings.minimumKeyTime
    let hotkeyHasKey = state.hexSettings.hotkey.key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

    guard decision == .proceedToTranscription else {
      // If the user recorded for less than minimumKeyTime and the hotkey is modifier-only,
      // discard the audio to avoid accidental triggers.
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision))")
      return .run { _ in
        let url = await recording.stopRecording()
        await recording.clearAudioChunkHandler()
        await transcription.cancelStreaming()
        try? FileManager.default.removeItem(at: url)
      }
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    state.transcriptionRequestStartUptime = ProcessInfo.processInfo.systemUptime
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage

    state.isPrewarming = true

    let stateTranscriptionStartUptime = state.transcriptionRequestStartUptime

    return .run { [sleepManagement] send in
      // Allow system to sleep again
      await sleepManagement.allowSleep()

      var audioURL: URL?
      do {
        soundEffect.play(.stopRecording)
        let capturedURL = await recording.stopRecording()
        await recording.clearAudioChunkHandler()
        audioURL = capturedURL
        transcriptionFeatureLogger.info(
          "Release-to-recording-stop elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - (stateTranscriptionStartUptime ?? ProcessInfo.processInfo.systemUptime)) * 1000), privacy: .public)"
        )

        let streamingResult: String?
        do {
          streamingResult = try await transcription.finishStreaming()
        } catch {
          transcriptionFeatureLogger.error("Streaming transcription flush failed: \(error.localizedDescription); using batch transcription")
          await transcription.cancelStreaming()
          streamingResult = nil
        }

        // Create transcription options with the selected language
        // Note: cap concurrency to avoid audio I/O overloads on some Macs
        let decodeOptions = DecodingOptions(
          language: language,
          detectLanguage: language == nil, // Only auto-detect if no language specified
          chunkingStrategy: .vad,
        )
        
        let result: String
        if let streamingResult, !streamingResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          result = streamingResult
          transcriptionFeatureLogger.notice("Used streaming Parakeet result length=\(result.count)")
        } else {
          result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }
        }

        transcriptionFeatureLogger.notice("Transcribed audio from \(capturedURL.lastPathComponent) to text length \(result.count)")
        await send(.transcriptionResult(result, capturedURL))
      } catch {
        transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result: String,
    audioURL: URL
  ) -> Effect<Action> {
    // Raw transcription is only the first stage. Keep this true while AI
    // post-processing and paste are running so the notch reflects the actual
    // end-to-end operation.
    state.isPrewarming = false
    let requestStartUptime = state.transcriptionRequestStartUptime ?? ProcessInfo.processInfo.systemUptime
    let transcriptionElapsedMs = Int((ProcessInfo.processInfo.systemUptime - requestStartUptime) * 1000)
    transcriptionFeatureLogger.info("Key-release-to-raw-result elapsedMs=\(transcriptionElapsedMs, privacy: .public) resultChars=\(result.count, privacy: .public)")

    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        try? FileManager.default.removeItem(at: audioURL)
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    // If empty text, nothing else to do
    guard !result.isEmpty else {
      state.isTranscribing = false
      state.transcriptionRequestStartUptime = nil
      return .none
    }

    let duration = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

    transcriptionFeatureLogger.info("Raw transcription: '\(result)'")
    let remappings = state.hexSettings.wordRemappings
    let snippets = state.hexSettings.snippets
    let removalsEnabled = state.hexSettings.wordRemovalsEnabled
    let removals = state.hexSettings.wordRemovals
    let aiMode = state.hexSettings.aiPostProcessingMode
    let modifiedResult: String

    if state.isRemappingScratchpadFocused {
      modifiedResult = result
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications and AI processing")
    } else {
      var output = result
      if removalsEnabled {
        let removedResult = WordRemovalApplier.apply(output, removals: removals)
        if removedResult != output {
          let enabledRemovalCount = removals.filter(\.isEnabled).count
          transcriptionFeatureLogger.info("Applied \(enabledRemovalCount) word removal(s)")
        }
        output = removedResult
      }
      let remappedResult = WordRemappingApplier.apply(output, remappings: remappings)
      if remappedResult != output {
        transcriptionFeatureLogger.info("Applied \(remappings.count) word remapping(s)")
      }
      let snippetResult = SnippetApplier.apply(remappedResult, snippets: snippets)
      if snippetResult != remappedResult {
        transcriptionFeatureLogger.info("Applied snippet expansion(s)")
      }
      modifiedResult = snippetResult
    }

    guard !modifiedResult.isEmpty else {
      state.isTranscribing = false
      state.transcriptionRequestStartUptime = nil
      return .none
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let appContext = state.appContext
    let transcriptionHistory = state.$transcriptionHistory
    let isRemappingScratchpadFocused = state.isRemappingScratchpadFocused
    let useAI = aiMode != .off && !isRemappingScratchpadFocused
    // Learn from the exact final text Hex inserts. Existing remappings,
    // snippets, and AI formatting must not disable correction monitoring for
    // every other word in the transcription.
    let shouldLearnDictionary = !isRemappingScratchpadFocused

    return .run { send in
      // Formatting must finish before insertion so the target receives one
      // clean final transcript. Keep all persistence and verification after
      // insertion; they must never extend this critical path.
      var resultToUse = modifiedResult

      if useAI {
        let aiStartedAt = ProcessInfo.processInfo.systemUptime
        do {
          resultToUse = try await aiPostProcessing.postProcess(modifiedResult, aiMode, appContext)
          transcriptionFeatureLogger.info("AI post-processing completed with mode: \(aiMode.displayName), app: \(appContext?.appName ?? "unknown"), elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - aiStartedAt) * 1000), privacy: .public)")
        } catch {
          // Model loading and runtime failures must not discard a complete
          // transcription. The deterministic stage still removes fillers,
          // resolves high-confidence corrections, and formats spoken lists.
          let deterministic = AIPostProcessingInputNormalizer.normalized(modifiedResult)
          resultToUse = deterministic.isEmpty ? modifiedResult : deterministic
          transcriptionFeatureLogger.error("AI post-processing failed: \(error.localizedDescription); completed with deterministic processor")
        }
      }

      guard !resultToUse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        await send(.transcriptionError(AIPostProcessingError.invalidOutput, audioURL))
        return
      }

      let pasteStartedAt = ProcessInfo.processInfo.systemUptime
      let pasteResult = await pasteboard.paste(resultToUse)
      transcriptionFeatureLogger.info("Paste transport elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - pasteStartedAt) * 1000), privacy: .public) totalKeyReleaseToPasteMs=\(Int((ProcessInfo.processInfo.systemUptime - requestStartUptime) * 1000), privacy: .public)")
      if case .pasted = pasteResult {
        soundEffect.play(.pasteTranscript)
      }

      persistTranscriptInBackground(
        result: resultToUse,
        duration: duration,
        sourceAppBundleID: sourceAppBundleID,
        sourceAppName: sourceAppName,
        audioURL: audioURL,
        transcriptionHistory: transcriptionHistory
      )

      switch pasteResult {
      case let .pasted(beforeText, afterText) where shouldLearnDictionary:
        await send(.pasteCompleted)
        await send(.beginCorrectionMonitoring(
          beforeText: beforeText,
          baseline: afterText,
          insertedText: resultToUse
        ))
      case .noFocusedInput:
        await send(.pasteCompleted)
        await send(.pasteUnavailable(resultToUse, reason: .noFocusedInput))
      case .failed:
        await send(.pasteCompleted)
        await send(.pasteUnavailable(resultToUse, reason: .insertionRejected))
      case .pasted:
        await send(.pasteCompleted)
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.transcriptionRequestStartUptime = nil
    state.error = error.localizedDescription
    
    if let audioURL {
      try? FileManager.default.removeItem(at: audioURL)
    }

    soundEffect.play(.error)

    return .none
  }

  /// Persist the audio and history without delaying text insertion.
  func persistTranscriptInBackground(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) {
    @Shared(.hexSettings) var hexSettings: HexSettings
    let shouldSaveHistory = hexSettings.saveTranscriptionHistory
    let maxHistoryEntries = hexSettings.maxHistoryEntries
    if shouldSaveHistory {
      Task { [transcriptPersistence, transcriptionHistory] in
        do {
          let transcript = try await transcriptPersistence.save(
            result,
            audioURL,
            duration,
            sourceAppBundleID,
            sourceAppName
          )

          transcriptionHistory.withLock { history in
            history.history.insert(transcript, at: 0)

            if let maxEntries = maxHistoryEntries, maxEntries > 0 {
              while history.history.count > maxEntries {
                if let removedTranscript = history.history.popLast() {
                  Task {
                    try? await transcriptPersistence.deleteAudio(removedTranscript)
                  }
                }
              }
            }
          }
        } catch {
          transcriptionFeatureLogger.error("Failed to save transcript history: \(error.localizedDescription)")
        }
      }
    } else {
      try? FileManager.default.removeItem(at: audioURL)
    }
  }
}

// MARK: - Dictionary Learning & Feedback

private extension TranscriptionFeature {
  func monitorForCorrectionEffect(
    beforeText: String?,
    baseline initialBaseline: String?,
    insertedText: String
  ) -> Effect<Action> {
    .run { [pasteboard] send in
      // Watch the edited field for a while after pasting. A correction is only
      // learned once the text has SETTLED — unchanged for a full settle window
      // — and is then compared against the ORIGINAL transcription, never
      // against intermediate states. Otherwise in-flight edits (backspacing
      // through "pushh" -> "push" -> "pu") would be captured as bogus
      // dictionary entries mid-keystroke.
      // The pasted value is already known. Give a multi-key replacement time
      // to finish before comparing the complete field value.
      let settleWindow: TimeInterval = 0.7
      let observationWindow: TimeInterval = 20

      let startedAt = Date()
      // A transport read-back can itself race with the user's edit. Validate
      // the supplied snapshot before trusting it for the diff.
      var baseline = initialBaseline.flatMap {
        WordCorrectionDetector.containsInsertedText($0, insertedText: insertedText) ? $0 : nil
      }

      var lastSeenText: String? = baseline
      var lastChangedAt = Date()

      do {
        while Date().timeIntervalSince(startedAt) < observationWindow {
          try await Task.sleep(for: .milliseconds(80))
          guard let currentText = await pasteboard.focusedText() else { continue }

          // AX can briefly return the value from before Cmd-V. It is neither a
          // baseline nor a user correction, so wait for the next snapshot.
          if baseline == nil, currentText == beforeText {
            continue
          }

          // If the pristine paste becomes visible, adopt it as the strongest
          // possible baseline. Crucially, do not wait for it: a user can begin
          // correcting the word before Accessibility ever exposes this state.
          if baseline == nil,
             WordCorrectionDetector.containsInsertedText(currentText, insertedText: insertedText)
          {
            baseline = currentText
            lastSeenText = currentText
            lastChangedAt = Date()
            continue
          }

          if currentText != lastSeenText {
            // Edit in flight: reset the settle timer and keep waiting.
            lastSeenText = currentText
            lastChangedAt = Date()
            continue
          }

          // Identical to the previous poll; only act once the text has held
          // still for the entire settle window.
          guard Date().timeIntervalSince(lastChangedAt) >= settleWindow else { continue }

          if let baseline, currentText == baseline {
            // This is also the ordinary idle state immediately after paste.
            // Keep watching: the user may correct a word several seconds later.
            continue
          }

          let correction = WordCorrectionDetector.detectObservedCorrection(
            beforeInsertion: beforeText,
            baseline: baseline,
            snapshot: currentText,
            insertedText: insertedText
          )
          if let correction {
            await send(.correctionDetected(correction))
            return
          }

          // A user may pause after an intermediate multi-word edit. Keep
          // watching instead of abandoning the monitor so a later valid
          // one-word correction can still be learned.
        }
        await send(.correctionMonitoringExpired)
      } catch {
        // Cancellation is expected when another transcription starts.
      }
    }
    .cancellable(id: CancelID.correctionMonitoring, cancelInFlight: true)
  }

  func handleCorrectionDetected(
    _ state: inout State,
    correction: WordCorrection
  ) -> Effect<Action> {
    guard correction.match.caseInsensitiveCompare(correction.replacement) != .orderedSame else {
      return .none
    }

    let didAdd = state.$hexSettings.withLock { settings in
      let alreadyExists = settings.wordRemappings.contains {
        $0.isEnabled
          && $0.match.caseInsensitiveCompare(correction.match) == .orderedSame
          && $0.replacement.caseInsensitiveCompare(correction.replacement) == .orderedSame
      }
      guard !alreadyExists else { return false }
      settings.wordRemappings.append(
        WordRemapping(match: correction.match, replacement: correction.replacement)
      )
      return true
    }

    guard didAdd else { return .cancel(id: CancelID.correctionMonitoring) }
    transcriptionFeatureLogger.notice(
      "Learned dictionary correction match=\(correction.match, privacy: .private) replacement=\(correction.replacement, privacy: .private)"
    )
    state.feedback = .dictionaryAdded(
      match: correction.match,
      replacement: correction.replacement
    )

    return .merge(
      .cancel(id: CancelID.correctionMonitoring),
      dismissFeedbackEffect(after: .seconds(4))
    )
  }

  func dismissFeedbackEffect(after duration: Duration) -> Effect<Action> {
    .run { send in
      do {
        try await Task.sleep(for: duration)
        await send(.feedbackDismissed)
      } catch {
        // Cancellation is expected when feedback is replaced.
      }
    }
    .cancellable(id: CancelID.feedback, cancelInFlight: true)
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false
    state.isLocked = false

    return .merge(
      .cancel(id: CancelID.transcription),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        // Stop the recording to release microphone access
        let url = await recording.stopRecording()
        try? FileManager.default.removeItem(at: url)
        soundEffect.play(.cancel)
      }
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false
    state.isLocked = false

    // Silently discard - no sound effect
    return .run { [sleepManagement] _ in
      // Allow system to sleep again
      await sleepManagement.allowSleep()
      let url = await recording.stopRecording()
      try? FileManager.default.removeItem(at: url)
    }
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
    if store.isTranscribing {
      return .transcribing
    } else if store.isRecording {
      return .recording
    } else if store.isPrewarming {
      return .prewarming
    } else {
      return .hidden
    }
  }

  var body: some View {
    TranscriptionIndicatorView(
      status: status,
      isLocked: store.isLocked,
      meter: store.meter,
      sourceAppBundleID: store.sourceAppBundleID,
      sourceAppName: store.sourceAppName,
      feedback: store.feedback,
      onCopy: { store.send(.copyFeedback) }
    )
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Force Quit Command

private enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit hex now" || normalized == "force quit hex"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
