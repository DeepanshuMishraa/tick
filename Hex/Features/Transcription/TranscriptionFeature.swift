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

public enum ToolCallPhase: Equatable, Sendable {
	case none
	case executing(toolName: String)
	case completed(toolName: String)
	case failed(toolName: String, error: String)
}

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var isLocked: Bool = false
    var isAutonomousRecording: Bool = false
    var isToolCalling: Bool = false
    var toolCallMessage: String = ""
    var toolCallPhase: ToolCallPhase = .none
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var appContext: AppContext?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased
    case setLocked(Bool)
    case setAutonomousRecording(Bool)
    case toggleAutonomousMode

    // Recording flow
    case startRecording(isLocked: Bool)
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcriptionResult(result: String, url: URL, isAutonomous: Bool)
    case transcriptionError(error: Error, url: URL?, isAutonomous: Bool)

    // Tool calling UI
    case toolCallDetected(toolName: String, message: String)
    case toolCallCompleted(toolName: String)
    case toolCallFailed(toolName: String, error: String)
    case toolCallDismissed

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case transcription
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
  @Dependency(\.aiOrchestrator) var aiOrchestrator
  @Dependency(\.speechSynthesis) var speechSynthesis

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

      case let .setAutonomousRecording(isAuto):
        state.isAutonomousRecording = isAuto
        return .none

      case .toggleAutonomousMode:
        if state.isAutonomousRecording {
          // If already in autonomous recording, stop it and process
          transcriptionFeatureLogger.notice("🔮 Autonomous mode shortcut pressed while active, stopping...")
          return handleStopRecording(&state)
        } else {
          // Cancel normal dictation if recording
          let maybeCancel = state.isRecording ? handleCancel(&state) : .none
          transcriptionFeatureLogger.notice("🔮 Autonomous mode shortcut pressed, starting recording...")
          state.isAutonomousRecording = true
          let startRecording = handleStartRecording(&state, isLocked: true)
          return .merge(maybeCancel, startRecording)
        }

      // MARK: - Recording Flow

      case let .startRecording(isLocked):
        return handleStartRecording(&state, isLocked: isLocked)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionResult(result, audioURL, isAutonomous):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL, isAutonomous: isAutonomous)

      case let .transcriptionError(error, audioURL, isAutonomous):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL, isAutonomous: isAutonomous)

      case let .toolCallDetected(toolName, message):
        transcriptionFeatureLogger.notice("Tool call notch: detected \(toolName)")
        state.isToolCalling = true
        state.toolCallPhase = .executing(toolName: toolName)
        state.toolCallMessage = message
        return .none

      case let .toolCallCompleted(toolName):
        transcriptionFeatureLogger.notice("Tool call notch: completed \(toolName)")
        state.toolCallPhase = .completed(toolName: toolName)
        return .run { send in
          try? await Task.sleep(for: .seconds(2))
          await send(.toolCallDismissed)
        }

      case let .toolCallFailed(toolName, error):
        transcriptionFeatureLogger.notice("Tool call notch: failed \(toolName) - \(error)")
        state.toolCallPhase = .failed(toolName: toolName, error: error)
        state.toolCallMessage = error
        return .run { send in
          try? await Task.sleep(for: .seconds(3))
          await send(.toolCallDismissed)
        }

      case .toolCallDismissed:
        transcriptionFeatureLogger.notice("Tool call notch: dismissed")
        state.isToolCalling = false
        state.toolCallPhase = .none
        state.toolCallMessage = ""
        return .none

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
      var lastAutonomousToggle: Date = .distantPast
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
          // Cmd+Option(right) toggles autonomous mode (debounced)
          let hasCmd = keyEvent.modifiers.contains(Modifier(kind: .command))
          let hasRightOpt = keyEvent.modifiers.contains(Modifier(kind: .option, side: .right))
          if hasCmd && hasRightOpt {
            transcriptionFeatureLogger.notice("Cmd+Option(right) detected!")
            let now = Date()
            if now.timeIntervalSince(lastAutonomousToggle) > 0.5 {
              lastAutonomousToggle = now
              Task { await send(.toggleAutonomousMode) }
            }
            shouldIntercept = false
          } else if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
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
    return .run { [speechSynthesis, sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] send in
      // Stop any ongoing TTS from previous tool invocation
      await speechSynthesis.stopSpeaking()
      // Play sound immediately for instant feedback
      soundEffect.play(.startRecording)

      if preventSleep {
        await sleepManagement.preventSleep(reason: "Hex Voice Recording")
      }
      await recording.startRecording()
    }
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    let isAutonomous = state.isAutonomousRecording
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
        await send(.transcriptionResult(result: result, url: capturedURL, isAutonomous: isAutonomous))
      } catch {
        transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
        await send(.transcriptionError(error: error, url: audioURL, isAutonomous: isAutonomous))
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
    audioURL: URL,
    isAutonomous: Bool
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
    let aiMode = AIPostProcessingMode.appAware
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
      return .none
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let appContext = state.appContext
    let transcriptionHistory = state.$transcriptionHistory
    let isRemappingScratchpadFocused = state.isRemappingScratchpadFocused
    let useAI = !isRemappingScratchpadFocused

    return .run { send in
      var resultToUse = modifiedResult

      // Autonomous mode: try orchestrator first (tool detection + optional post-processing)
      if isAutonomous {
        transcriptionFeatureLogger.info("Autonomous mode active, calling orchestrator...")
        do {
          if let orchestratorOutput = try await aiOrchestrator.process(modifiedResult, appContext, onToolDetected: { toolName in
                await send(.toolCallDetected(toolName: toolName, message: "Calling " + toolName + "..."))
              }) {
            switch orchestratorOutput {
            case .text(let cleanedText):
              // No tool call — cleaned text, paste as normal
              resultToUse = cleanedText
              transcriptionFeatureLogger.info("Orchestrator returned cleaned text")

            case .toolCallsExecuted(let results):
              // Tool calls were detected and executed with TTS confirmation
              let toolNames = results.map(\.toolName).joined(separator: ", ")
              transcriptionFeatureLogger.info("Orchestrator executed tools: \(toolNames)")
              // Update notch based on success/failure of each tool
              for result in results {
                if result.success {
                  await send(.toolCallCompleted(toolName: result.toolName))
                } else {
                  await send(.toolCallFailed(toolName: result.toolName, error: result.message))
                }
              }
              // Skip pasting — the tool already handled the request
              return
            }
          } else {
            // Orchestrator returned nil (not configured), fall through to normal AI post-processing
            transcriptionFeatureLogger.info("Orchestrator returned nil, falling back to AI post-processing")
          }
        } catch {
          transcriptionFeatureLogger.error("Orchestrator failed: \(error.localizedDescription), falling back to AI post-processing")
        }
      }

      // Standard AI post-processing (used when orchestrator falls through or autonomous is off)
      if useAI && !isAutonomous {
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
        try await finalizeRecordingAndStoreTranscript(
          result: resultToUse,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory
        )
        if isAutonomous {
          await send(.setAutonomousRecording(false))
        }
      } catch {
        await send(.transcriptionError(error: error, url: audioURL, isAutonomous: isAutonomous))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?,
    isAutonomous: Bool
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
  ) async throws {
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

    await pasteboard.paste(result)
    soundEffect.play(.pasteTranscript)
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false
    state.isLocked = false
    state.isAutonomousRecording = false

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
    state.isAutonomousRecording = false

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
    if store.isToolCalling {
      switch store.toolCallPhase {
      case .none:
        return store.isTranscribing ? (store.isAutonomousRecording ? .autonomousTranscribing : .transcribing) : .hidden
      case .executing(let name):
        return .toolCalling(name: name, phase: .executing)
      case .completed(let name):
        return .toolCalling(name: name, phase: .completed)
      case .failed(let name, _):
        return .toolCalling(name: name, phase: .failed)
      }
    } else if store.isTranscribing {
      return store.isAutonomousRecording ? .autonomousTranscribing : .transcribing
    } else if store.isRecording {
      return store.isAutonomousRecording ? .autonomousRecording : .recording
    } else if store.isPrewarming {
      return .prewarming
    } else if store.isAutonomousRecording {
      return .autonomous
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
      toolCallMessage: store.toolCallMessage
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
