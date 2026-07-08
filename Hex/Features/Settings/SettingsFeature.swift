import AVFoundation
import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import IdentifiedCollections
import Sauce
import ServiceManagement
import SwiftUI

private let settingsLogger = HexLog.settings

private enum HotKeyCaptureTarget {
  case recording
  case pasteLastTranscript
}

extension SharedReaderKey
  where Self == InMemoryKey<Bool>.Default
{
  static var isSettingHotKey: Self {
    Self[.inMemory("isSettingHotKey"), default: false]
  }
  
  static var isSettingPasteLastTranscriptHotkey: Self {
    Self[.inMemory("isSettingPasteLastTranscriptHotkey"), default: false]
  }

  static var isRemappingScratchpadFocused: Self {
    Self[.inMemory("isRemappingScratchpadFocused"), default: false]
  }
}

// MARK: - Settings Feature

@Reducer
struct SettingsFeature {
  @ObservableState
  struct State {
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isSettingHotKey) var isSettingHotKey: Bool = false
    @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool = false
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
    @Shared(.hotkeyPermissionState) var hotkeyPermissionState: HotkeyPermissionState

    var languages: IdentifiedArrayOf<Language> = []
    var currentModifiers: Modifiers = .init(modifiers: [])
    var currentPasteLastModifiers: Modifiers = .init(modifiers: [])
    var remappingScratchpadText: String = ""
    
    // Available microphones
    var availableInputDevices: [AudioInputDevice] = []
    var defaultInputDeviceName: String?

    // Model Management
    var modelDownload = ModelDownloadFeature.State()
    var shouldFlashModelSection = false
    
    // API Key Validation
    var isValidatingGroqKey = false
    var groqKeyValidationStatus: APIKeyValidationStatus?
    var isValidatingGoogleKey = false
    var googleKeyValidationStatus: APIKeyValidationStatus?
  }
  
  enum APIKeyValidationStatus: Equatable {
    case success
    case failure(String)
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)

    // Existing
    case task
    case startSettingHotKey
    case startSettingPasteLastTranscriptHotkey
    case clearPasteLastTranscriptHotkey
    case keyEvent(KeyEvent)
    case toggleOpenOnLogin(Bool)
    case toggleShowDockIcon(Bool)
    case togglePreventSystemSleep(Bool)
    case setRecordingAudioBehavior(RecordingAudioBehavior)
    case toggleSuperFastMode(Bool)

    // Permission delegation (forwarded to AppFeature)
    case requestMicrophone
    case requestAccessibility
    case requestInputMonitoring

    // Microphone selection
    case loadAvailableInputDevices
    case availableInputDevicesLoaded([AudioInputDevice], String?)

    // Model Management
    case modelDownload(ModelDownloadFeature.Action)
    
    // History Management
    case toggleSaveTranscriptionHistory(Bool)

    // Modifier configuration
    case setModifierSide(Modifier.Kind, Modifier.Side)

    // Word remappings
    case addWordRemoval
    case removeWordRemoval(UUID)
    case addWordRemapping
    case removeWordRemapping(UUID)
    case setRemappingScratchpadFocused(Bool)

    // AI Post-Processing
    case setAIPostProcessingMode(AIPostProcessingMode)
    case setAIPostProcessingModel(String)
    case setAIProvider(AIProvider)
    case setGroqAPIKey(String)
    case setGoogleAPIKey(String)
    case setGoogleModel(String)
    case validateGroqAPIKey
    case groqAPIKeyValidationResult(Result<Bool, Error>)

    // Autonomous / TTS
    case toggleTTS
    case setTTSVoice(String)
    case previewTTSVoice
    case validateGoogleAPIKey
    case googleAPIKeyValidationResult(Result<Bool, Error>)
    case toggleTool(String)

    // Direct settings mutations
    case toggleUseClipboardPaste(Bool)
    case toggleCopyToClipboard(Bool)
    case toggleDoubleTapLockEnabled(Bool)
    case toggleUseDoubleTapOnly(Bool)
    case setMinimumKeyTime(Double)
    case setMaxHistoryEntries(Int?)
    case setOutputLanguage(String?)
    case setSelectedMicrophoneID(String?)
    case setSoundEffectsVolume(Double)
    case toggleSoundEffectsEnabled(Bool)
    case toggleWordRemovalsEnabled(Bool)
    case setWordRemovals([WordRemoval])
    case setWordRemappings([WordRemapping])

    // Delegate — sent to the parent AppFeature to update shared permission state
    case delegate(Delegate)

    enum Delegate: Equatable {
      case permissionChanged(mic: PermissionStatus)
    }
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.continuousClock) var clock
  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.permissions) var permissions
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.aiPostProcessing) var aiPostProcessing

  private func deleteAudioEffect(for transcripts: [Transcript]) -> Effect<Action> {
    .run { [transcriptPersistence] _ in
      for transcript in transcripts {
        try? await transcriptPersistence.deleteAudio(transcript)
      }
    }
  }

  private func beginCapture(_ target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.$isSettingHotKey.withLock { $0 = true }
      state.currentModifiers = .init(modifiers: [])
    case .pasteLastTranscript:
      state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = true }
      state.currentPasteLastModifiers = .init(modifiers: [])
    }
  }

  private func endCapture(_ target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.$isSettingHotKey.withLock { $0 = false }
      state.currentModifiers = .init(modifiers: [])
    case .pasteLastTranscript:
      state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = false }
      state.currentPasteLastModifiers = .init(modifiers: [])
    }
  }

  private func captureModifiers(for target: HotKeyCaptureTarget, state: State) -> Modifiers {
    switch target {
    case .recording:
      state.currentModifiers
    case .pasteLastTranscript:
      state.currentPasteLastModifiers
    }
  }

  private func updateCaptureModifiers(_ modifiers: Modifiers, for target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.currentModifiers = modifiers
    case .pasteLastTranscript:
      state.currentPasteLastModifiers = modifiers
    }
  }

  private func applyCapturedHotKey(key: Key?, modifiers: Modifiers, for target: HotKeyCaptureTarget, state: inout State) {
    switch target {
    case .recording:
      state.$hexSettings.withLock {
        $0.hotkey.key = key
        $0.hotkey.modifiers = modifiers.erasingSides()
      }
    case .pasteLastTranscript:
      guard let key else { return }
      state.$hexSettings.withLock {
        $0.pasteLastTranscriptHotkey = HotKey(key: key, modifiers: modifiers.erasingSides())
      }
    }
  }

  private func handleCapture(_ keyEvent: KeyEvent, for target: HotKeyCaptureTarget, state: inout State) -> Effect<Action> {
    if keyEvent.key == .escape {
      endCapture(target, state: &state)
      return .none
    }

    let updatedModifiers = keyEvent.modifiers.union(captureModifiers(for: target, state: state))
    updateCaptureModifiers(updatedModifiers, for: target, state: &state)

    if target == .pasteLastTranscript, keyEvent.key != nil, updatedModifiers.isEmpty {
      return .none
    }

    if let key = keyEvent.key {
      applyCapturedHotKey(key: key, modifiers: updatedModifiers, for: target, state: &state)
      endCapture(target, state: &state)
      return .none
    }

    if target == .recording, keyEvent.modifiers.isEmpty {
      applyCapturedHotKey(key: nil, modifiers: updatedModifiers, for: target, state: &state)
      endCapture(target, state: &state)
    }

    return .none
  }

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.modelDownload, action: \.modelDownload) {
      ModelDownloadFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        let didNormalizeDoubleTapOnly = !state.hexSettings.doubleTapLockEnabled && state.hexSettings.useDoubleTapOnly
        if didNormalizeDoubleTapOnly {
          state.$hexSettings.withLock {
            $0.useDoubleTapOnly = false
          }
        }

        return .none

      case .task:
        if let url = Bundle.main.url(forResource: "languages", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let languages = try? JSONDecoder().decode([Language].self, from: data)
        {
          state.languages = IdentifiedArray(uniqueElements: languages)
        } else {
          settingsLogger.error("Failed to load languages JSON from bundle")
        }

        // Listen for key events and load microphones (existing + new)
        return .run { send in
          await send(.modelDownload(.fetchModels))
          await send(.loadAvailableInputDevices)
          
          // Set up periodic refresh of available devices (every 120 seconds)
          // Using a longer interval to reduce resource usage
          let deviceRefreshTask = Task { @MainActor in
            for await _ in clock.timer(interval: .seconds(120)) {
              // Only refresh when the app is active to save resources
              if NSApplication.shared.isActive {
                send(.loadAvailableInputDevices)
              }
            }
          }
          
          // Listen for device connection/disconnection notifications
          // Using a simpler debounced approach with a single task
          var deviceUpdateTask: Task<Void, Never>?
          
          // Helper function to debounce device updates
          func debounceDeviceUpdate() {
            deviceUpdateTask?.cancel()
            deviceUpdateTask = Task {
              try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
              if !Task.isCancelled {
                await send(.loadAvailableInputDevices)
              }
            }
          }
          
          let deviceConnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasConnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }
          
          let deviceDisconnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasDisconnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }
          
          // Be sure to clean up resources when the task is finished
          defer {
            deviceUpdateTask?.cancel()
            NotificationCenter.default.removeObserver(deviceConnectionObserver)
            NotificationCenter.default.removeObserver(deviceDisconnectionObserver)
          }

          for try await keyEvent in await keyEventMonitor.listenForKeyPress() {
            await send(.keyEvent(keyEvent))
          }
          
          deviceRefreshTask.cancel()
        }

      case .startSettingHotKey:
        beginCapture(.recording, state: &state)
        return .none

      case .addWordRemoval:
        state.$hexSettings.withLock {
          $0.wordRemovals.append(.init(pattern: ""))
        }
        return .none

      case let .removeWordRemoval(id):
        state.$hexSettings.withLock {
          $0.wordRemovals.removeAll { $0.id == id }
        }
        return .none

      case .addWordRemapping:
        state.$hexSettings.withLock {
          $0.wordRemappings.append(.init(match: "", replacement: ""))
        }
        return .none

      case let .removeWordRemapping(id):
        state.$hexSettings.withLock {
          $0.wordRemappings.removeAll { $0.id == id }
        }
        return .none

      case let .setRemappingScratchpadFocused(isFocused):
        state.$isRemappingScratchpadFocused.withLock { $0 = isFocused }
        return .none

      case .startSettingPasteLastTranscriptHotkey:
        beginCapture(.pasteLastTranscript, state: &state)
        return .none
        
      case .clearPasteLastTranscriptHotkey:
        state.$hexSettings.withLock { $0.pasteLastTranscriptHotkey = nil }
        return .none

      case let .keyEvent(keyEvent):
        if state.isSettingPasteLastTranscriptHotkey {
          return handleCapture(keyEvent, for: .pasteLastTranscript, state: &state)
        }

        guard state.isSettingHotKey else { return .none }
        return handleCapture(keyEvent, for: .recording, state: &state)

      case let .toggleOpenOnLogin(enabled):
        state.$hexSettings.withLock { $0.openOnLogin = enabled }
        return .run { _ in
          if enabled {
            try? SMAppService.mainApp.register()
          } else {
            try? SMAppService.mainApp.unregister()
          }
        }

      case let .toggleShowDockIcon(enabled):
        state.$hexSettings.withLock { $0.showDockIcon = enabled }
        return .run { _ in
          await MainActor.run {
            NotificationCenter.default.post(name: .updateAppMode, object: nil)
          }
        }

      case let .togglePreventSystemSleep(enabled):
        state.$hexSettings.withLock { $0.preventSystemSleep = enabled }
        return .none

      case let .setRecordingAudioBehavior(behavior):
        state.$hexSettings.withLock { $0.recordingAudioBehavior = behavior }
        return .none

      case let .toggleSuperFastMode(enabled):
        state.$hexSettings.withLock { $0.superFastModeEnabled = enabled }
        return .run { _ in
          await recording.warmUpRecorder()
        }

      // Permission requests
      // After the system dialog completes, re-query the status and send a
      // delegate action to the parent AppFeature so the UI updates immediately
      // (instead of waiting for the next app activation).

      case .requestMicrophone:
        settingsLogger.info("User requested microphone permission from settings")
        return .run { send in
          _ = await permissions.requestMicrophone()
          let status = await permissions.microphoneStatus()
          await send(.delegate(.permissionChanged(mic: status)))
        }

      case .requestAccessibility:
        settingsLogger.info("User requested accessibility permission from settings")
        return .run { _ in
          await permissions.requestAccessibility()
          // The parent AppFeature will re-check all permissions on next
          // app activation (didBecomeActiveNotification). We don't need to
          // fire a delegate here because the state is in AppFeature, not
          // SettingsFeature.
        }

      case .requestInputMonitoring:
        settingsLogger.info("User requested input monitoring permission from settings")
        return .run { _ in
          _ = await permissions.requestInputMonitoring()
        }

      // Model Management
      case let .modelDownload(.selectModel(newModel)):
        // Also store it in hexSettings:
        state.$hexSettings.withLock {
          $0.selectedModel = newModel
        }
        // Then continue with the child's normal logic:
        return .none

      case .modelDownload:
        return .none
      
      // Microphone device selection
      case .loadAvailableInputDevices:
        return .run { send in
          let devices = await recording.getAvailableInputDevices()
          let defaultName = await recording.getDefaultInputDeviceName()
          await send(.availableInputDevicesLoaded(devices, defaultName))
        }
        
      case let .availableInputDevicesLoaded(devices, defaultName):
        state.availableInputDevices = devices
        state.defaultInputDeviceName = defaultName
        return .none
        
      case let .toggleSaveTranscriptionHistory(enabled):
        state.$hexSettings.withLock { $0.saveTranscriptionHistory = enabled }
        
        // If disabling history, delete all existing entries
        if !enabled {
          let transcripts = state.transcriptionHistory.history
          
          // Clear the history
          state.$transcriptionHistory.withLock { history in
            history.history.removeAll()
          }

          return deleteAudioEffect(for: transcripts)
        }
        
        return .none

      case let .setModifierSide(kind, side):
        guard state.hexSettings.hotkey.key == nil else { return .none }
        state.$hexSettings.withLock {
          $0.hotkey.modifiers = $0.hotkey.modifiers.setting(kind: kind, to: side)
        }
        return .none

      case let .setAIPostProcessingMode(mode):
        state.$hexSettings.withLock { $0.aiPostProcessingMode = mode }
        return .none

      case let .setAIPostProcessingModel(model):
        state.$hexSettings.withLock { $0.aiPostProcessingModel = model }
        return .none

      case let .setAIProvider(provider):
        state.$hexSettings.withLock { $0.aiProvider = provider }
        return .none

      case let .setGoogleAPIKey(key):
        state.$hexSettings.withLock { $0.googleAPIKey = key.isEmpty ? nil : key }
        state.googleKeyValidationStatus = nil
        return .none

      case let .setGoogleModel(model):
        state.$hexSettings.withLock { $0.googleModel = model }
        return .none

      case let .setGroqAPIKey(key):
        state.$hexSettings.withLock { $0.groqAPIKey = key.isEmpty ? nil : key }
        state.groqKeyValidationStatus = nil // Reset validation status when key changes
        return .none
      
      case .validateGroqAPIKey:
        guard let apiKey = state.hexSettings.groqAPIKey, !apiKey.isEmpty else {
          state.groqKeyValidationStatus = .failure("API key is empty")
          return .none
        }
        
        state.isValidatingGroqKey = true
        state.groqKeyValidationStatus = nil
        
        let model = state.hexSettings.aiPostProcessingModel
        return .run { send in
          await send(.groqAPIKeyValidationResult(
            Result { try await aiPostProcessing.validateAPIKey(apiKey, .groq, model) }
          ))
        }
      
      case let .groqAPIKeyValidationResult(.success(isValid)):
        state.isValidatingGroqKey = false
        if isValid {
          state.groqKeyValidationStatus = .success
          settingsLogger.info("Groq API key validated successfully")
        } else {
          state.groqKeyValidationStatus = .failure("Invalid API key")
          settingsLogger.warning("Groq API key validation failed")
        }
        return .none
      
      case let .groqAPIKeyValidationResult(.failure(error)):
        state.isValidatingGroqKey = false
        state.groqKeyValidationStatus = .failure(error.localizedDescription)
        settingsLogger.error("Groq API key validation error: \(error.localizedDescription)")
        return .none

      // Autonomous / TTS actions
      case .toggleTTS:
        state.$hexSettings.withLock { $0.ttsEnabled.toggle() }
        return .none

      case let .setTTSVoice(voice):
        state.$hexSettings.withLock { $0.ttsVoice = voice }
        return .none

      case .previewTTSVoice:
        let voice = state.hexSettings.ttsVoice
        return .run { _ in
          @Dependency(\.speechSynthesis) var speechSynthesis
          try? await speechSynthesis.speak("Hello! This is the \(voice) voice.")
        }

      case .validateGoogleAPIKey:
        guard let apiKey = state.hexSettings.googleAPIKey, !apiKey.isEmpty else {
          state.googleKeyValidationStatus = .failure("API key is empty")
          return .none
        }
        
        state.isValidatingGoogleKey = true
        state.googleKeyValidationStatus = nil
        
        let model = state.hexSettings.googleModel
        return .run { send in
          await send(.googleAPIKeyValidationResult(
            Result { try await aiPostProcessing.validateAPIKey(apiKey, .google, model) }
          ))
        }

      case let .googleAPIKeyValidationResult(.success(isValid)):
        state.isValidatingGoogleKey = false
        if isValid {
          state.googleKeyValidationStatus = .success
          settingsLogger.info("Google API key validated successfully")
        } else {
          state.googleKeyValidationStatus = .failure("Invalid API key")
          settingsLogger.warning("Google API key validation failed")
        }
        return .none

      case let .googleAPIKeyValidationResult(.failure(error)):
        state.isValidatingGoogleKey = false
        state.googleKeyValidationStatus = .failure(error.localizedDescription)
        settingsLogger.error("Google API key validation error: \(error.localizedDescription)")
        return .none

      case let .toggleTool(toolID):
        state.$hexSettings.withLock { settings in
          if settings.enabledToolIDs.contains(toolID) {
            settings.enabledToolIDs.removeAll { $0 == toolID }
          } else {
            settings.enabledToolIDs.append(toolID)
          }
        }
        return .none

      // Direct settings mutations
      case let .toggleUseClipboardPaste(enabled):
        state.$hexSettings.withLock { $0.useClipboardPaste = enabled }
        return .none

      case let .toggleCopyToClipboard(enabled):
        state.$hexSettings.withLock { $0.copyToClipboard = enabled }
        return .none

      case let .toggleDoubleTapLockEnabled(enabled):
        state.$hexSettings.withLock { $0.doubleTapLockEnabled = enabled }
        return .none

      case let .toggleUseDoubleTapOnly(enabled):
        state.$hexSettings.withLock { $0.useDoubleTapOnly = enabled }
        return .none

      case let .setMinimumKeyTime(time):
        state.$hexSettings.withLock { $0.minimumKeyTime = time }
        return .none

      case let .setMaxHistoryEntries(entries):
        state.$hexSettings.withLock { $0.maxHistoryEntries = entries }
        return .none

      case let .setOutputLanguage(language):
        state.$hexSettings.withLock { $0.outputLanguage = language }
        return .none

      case let .setSelectedMicrophoneID(id):
        state.$hexSettings.withLock { $0.selectedMicrophoneID = id }
        return .none

      case let .setSoundEffectsVolume(volume):
        state.$hexSettings.withLock { $0.soundEffectsVolume = volume }
        return .none

      case let .toggleSoundEffectsEnabled(enabled):
        state.$hexSettings.withLock { $0.soundEffectsEnabled = enabled }
        return .none

      case let .toggleWordRemovalsEnabled(enabled):
        state.$hexSettings.withLock { $0.wordRemovalsEnabled = enabled }
        return .none

      case let .setWordRemovals(removals):
        state.$hexSettings.withLock { $0.wordRemovals = removals }
        return .none

      case let .setWordRemappings(remappings):
        state.$hexSettings.withLock { $0.wordRemappings = remappings }
        return .none

      case .delegate:
        // Delegate actions are intercepted by the parent AppFeature.
        // This child doesn't process them.
        return .none

      }
    }
  }
}
