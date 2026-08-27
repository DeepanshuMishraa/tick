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
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var appContext: AppContext?
    var feedback: Feedback?
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
    case beginCorrectionMonitoring(baseline: String)
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
          warmUpRecorderEffect()
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
        return .merge(
          .cancel(id: CancelID.feedback),
          .cancel(id: CancelID.correctionMonitoring),
          handleStartRecording(&state, isLocked: isLocked)
        )

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionResult(result, audioURL):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL)

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case let .beginCorrectionMonitoring(baseline):
        return monitorForCorrectionEffect(baseline: baseline)

      case let .correctionDetected(correction):
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

    // Prevent system sleep during recording
    return .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] send in
      // Play sound immediately for instant feedback
      soundEffect.play(.startRecording)

      if preventSleep {
        await sleepManagement.preventSleep(reason: "Hex Voice Recording")
      }
      await recording.startRecording()
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
        try? FileManager.default.removeItem(at: url)
      }
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage

    state.isPrewarming = true

    return .run { [sleepManagement] send in
      // Allow system to sleep again
      await sleepManagement.allowSleep()

      var audioURL: URL?
      do {
        soundEffect.play(.stopRecording)
        let capturedURL = await recording.stopRecording()
        audioURL = capturedURL

        // Create transcription options with the selected language
        // Note: cap concurrency to avoid audio I/O overloads on some Macs
        let decodeOptions = DecodingOptions(
          language: language,
          detectLanguage: language == nil, // Only auto-detect if no language specified
          chunkingStrategy: .vad,
        )
        
        let result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }
        
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
    state.isTranscribing = false
    state.isPrewarming = false

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
      return .none
    }

    let duration = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

    transcriptionFeatureLogger.info("Raw transcription: '\(result)'")
    let remappings = state.hexSettings.wordRemappings
    let snippets = state.hexSettings.snippets
    let removalsEnabled = state.hexSettings.wordRemovalsEnabled
    let removals = state.hexSettings.wordRemovals
    let aiMode = state.hexSettings.aiPostProcessingMode
    var canLearnDictionary = false
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
      canLearnDictionary = remappedResult == output && snippetResult == remappedResult
      modifiedResult = snippetResult
    }

    guard !modifiedResult.isEmpty else {
      return .none
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let appContext = state.appContext
    let transcriptionHistory = state.$transcriptionHistory
    let isRemappingScratchpadFocused = state.isRemappingScratchpadFocused
    let useAI = aiMode != .off && !isRemappingScratchpadFocused
    let shouldLearnDictionary = canLearnDictionary && !isRemappingScratchpadFocused && !useAI

    return .run { send in
      var resultToUse = modifiedResult

      if useAI {
        do {
          resultToUse = try await aiPostProcessing.postProcess(modifiedResult, aiMode, appContext)
          transcriptionFeatureLogger.info("AI post-processing completed with mode: \(aiMode.displayName), app: \(appContext?.appName ?? "unknown")")
        } catch {
          transcriptionFeatureLogger.error("AI post-processing failed: \(error.localizedDescription), using raw result")
          resultToUse = modifiedResult
        }
      }

      guard !resultToUse.isEmpty else {
        return
      }

      do {
        let pasteResult = try await finalizeRecordingAndStoreTranscript(
          result: resultToUse,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory
        )

        switch pasteResult {
        case let .pasted(_, afterText) where shouldLearnDictionary:
          if let afterText {
            await send(.beginCorrectionMonitoring(baseline: afterText))
          }
        case .noFocusedInput:
          await send(.pasteUnavailable(resultToUse, reason: .noFocusedInput))
        case .failed:
          await send(.pasteUnavailable(resultToUse, reason: .insertionRejected))
        case .pasted:
          break
        }
      } catch {
        await send(.transcriptionError(error, audioURL))
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
    state.error = error.localizedDescription
    
    if let audioURL {
      try? FileManager.default.removeItem(at: audioURL)
    }

    soundEffect.play(.error)

    return .none
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) async throws -> PasteboardPasteResult {
    @Shared(.hexSettings) var hexSettings: HexSettings

    if hexSettings.saveTranscriptionHistory {
      let transcript = try await transcriptPersistence.save(
        result,
        audioURL,
        duration,
        sourceAppBundleID,
        sourceAppName
      )

      transcriptionHistory.withLock { history in
        history.history.insert(transcript, at: 0)

        if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
          while history.history.count > maxEntries {
            if let removedTranscript = history.history.popLast() {
              Task {
                 try? await transcriptPersistence.deleteAudio(removedTranscript)
              }
            }
          }
        }
      }
    } else {
      try? FileManager.default.removeItem(at: audioURL)
    }

    let pasteResult = await pasteboard.paste(result)
    if case .pasted = pasteResult {
      soundEffect.play(.pasteTranscript)
    }
    return pasteResult
  }
}

// MARK: - Dictionary Learning & Feedback

private extension TranscriptionFeature {
  func monitorForCorrectionEffect(baseline: String) -> Effect<Action> {
    .run { [pasteboard] send in
      // Watch the edited field for a while after pasting. A correction is only
      // learned once the text has SETTLED — unchanged for a full settle window
      // — and is then compared against the ORIGINAL transcription, never
      // against intermediate states. Otherwise in-flight edits (backspacing
      // through "pushh" -> "push" -> "pu") would be captured as bogus
      // dictionary entries mid-keystroke.
      let settleWindow: TimeInterval = 1.2
      let observationWindow: TimeInterval = 20

      let startedAt = Date()
      var lastSeenText: String?
      var lastChangedAt = startedAt

      do {
        while Date().timeIntervalSince(startedAt) < observationWindow {
          try await Task.sleep(for: .milliseconds(150))
          guard let currentText = await pasteboard.focusedText() else { continue }

          if currentText != lastSeenText {
            // Edit in flight: reset the settle timer and keep waiting.
            lastSeenText = currentText
            lastChangedAt = Date()
            continue
          }

          // Identical to the previous poll; only act once the text has held
          // still for the entire settle window.
          guard Date().timeIntervalSince(lastChangedAt) >= settleWindow else { continue }

          if currentText == baseline {
            // User reverted everything: no correction intended.
            return
          }

          if let correction = WordCorrectionDetector.detect(before: baseline, after: currentText) {
            await send(.correctionDetected(correction))
          }
          return
        }
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
