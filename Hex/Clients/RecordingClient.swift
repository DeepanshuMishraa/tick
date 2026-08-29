//
//  RecordingClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import AppKit
import AVFoundation
import ComposableArchitecture
import CoreAudio
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let recordingLogger = HexLog.recording
private let mediaLogger = HexLog.media
private typealias CoreAudioPropertyListenerBlock = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

/// Represents an audio input device
struct AudioInputDevice: Identifiable, Equatable {
  var id: String
  var name: String
}

@DependencyClient
struct RecordingClient {
  var startRecording: @Sendable () async -> Void = {}
  var stopRecording: @Sendable () async -> URL = { URL(fileURLWithPath: "") }
  var requestMicrophoneAccess: @Sendable () async -> Bool = { false }
  var observeAudioLevel: @Sendable () async -> AsyncStream<Meter> = { AsyncStream { _ in } }
  var getAvailableInputDevices: @Sendable () async -> [AudioInputDevice] = { [] }
  var getDefaultInputDeviceName: @Sendable () async -> String? = { nil }
  var warmUpRecorder: @Sendable () async -> Void = {}
  var cleanup: @Sendable () async -> Void = {}
}

extension RecordingClient: DependencyKey {
  static var liveValue: Self {
    let live = RecordingClientLive()
    Task {
      await live.startObservingSystemChanges()
    }
    return Self(
      startRecording: { await live.startRecording() },
      stopRecording: { await live.stopRecording() },
      requestMicrophoneAccess: { await live.requestMicrophoneAccess() },
      observeAudioLevel: { await live.observeAudioLevel() },
      getAvailableInputDevices: { await live.getAvailableInputDevices() },
      getDefaultInputDeviceName: { await live.getDefaultInputDeviceName() },
      warmUpRecorder: { await live.warmUpRecorder() },
      cleanup: { await live.cleanup() }
    )
  }
}

/// Simple structure representing audio metering values.
struct Meter: Equatable {
  let averagePower: Double
  let peakPower: Double
}

// MARK: - RecordingClientLive Implementation

actor RecordingClientLive {
  private struct AudioHardwareObserver {
    let selector: AudioObjectPropertySelector
    let reason: String
    let listener: CoreAudioPropertyListenerBlock
  }

  private var recorder: AVAudioRecorder?
  private let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording.wav")
  private var isRecorderPrimedForNextSession = false
  private var lastPrimedDeviceID: AudioDeviceID?
  private var recordingSessionID: UUID?
  private var currentRecordingStartedAt: Date?
  private var lastRecordingEndedAt: Date?
  private var deferredCaptureRestartReason: String?
  private var environmentChangeDebounceTask: Task<Void, Never>?
  private let recorderSettings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
  ]
  private let (meterStream, meterContinuation) = AsyncStream<Meter>.makeStream()
  private var meterTask: Task<Void, Never>?
  private lazy var superFastCapture = SuperFastCaptureController(meterContinuation: meterContinuation)
  private var superFastCaptureDeviceID: AudioDeviceID?
  private var notificationObservers: [NSObjectProtocol] = []
  private var audioHardwareObservers: [AudioHardwareObserver] = []
  private var isObservingSystemChanges = false

  @Shared(.hexSettings) var hexSettings: HexSettings

  /// Canonical macOS output state captured before Hex silences recording audio.
  private var mutedOutputState: SystemOutputState?
  private var outputRestoreTask: Task<Void, Never>?
  private var outputRestoreGeneration: UUID?

  /// Tracks the original default input device to restore after recording
  private var originalDefaultInputDeviceID: AudioDeviceID?

  private struct SystemOutputState {
    let volume: Int
    let isMuted: Bool
  }

  // Cache to store already-processed device information
  private var deviceCache: [AudioDeviceID: (hasInput: Bool, name: String?)] = [:]
  private var lastDeviceCheck = Date(timeIntervalSince1970: 0)
  
  /// Gets all available input devices on the system
  func getAvailableInputDevices() async -> [AudioInputDevice] {
    // Reset cache if it's been more than 5 minutes since last full refresh
    let now = Date()
    if now.timeIntervalSince(lastDeviceCheck) > 300 {
      deviceCache.removeAll()
      lastDeviceCheck = now
    }
    
    // Get all available audio devices
    let devices = getAllAudioDevices()
    var inputDevices: [AudioInputDevice] = []
    
    // Filter to only input devices and convert to our model
    for device in devices {
      let hasInput: Bool
      let name: String?
      
      // Check cache first to avoid expensive Core Audio calls
      if let cached = deviceCache[device] {
        hasInput = cached.hasInput
        name = cached.name
      } else {
        hasInput = deviceHasInput(deviceID: device)
        name = hasInput ? getDeviceName(deviceID: device) : nil
        deviceCache[device] = (hasInput, name)
      }
      
      if hasInput, let deviceName = name {
        // AudioDeviceID values are runtime identifiers and can change after a
        // reconnect or reboot. Persist the Core Audio UID instead so a user's
        // microphone choice survives the device being recreated.
        let stableID = getDeviceUID(deviceID: device) ?? String(device)
        inputDevices.append(AudioInputDevice(id: stableID, name: deviceName))
      }
    }
    
    return inputDevices
  }

  /// Gets the current system default input device name
  func getDefaultInputDeviceName() async -> String? {
    guard let deviceID = getBuiltInInputDevice() ?? getDefaultInputDevice() else { return nil }
    if let cached = deviceCache[deviceID], cached.hasInput, let name = cached.name {
      return name
    }
    let name = getDeviceName(deviceID: deviceID)
    if let name {
      deviceCache[deviceID] = (hasInput: true, name: name)
    }
    return name
  }
  
  // MARK: - Core Audio Helpers

  /// Creates an AudioObjectPropertyAddress with common defaults.
  private func audioPropertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: element
    )
  }

  func startObservingSystemChanges() {
    guard !isObservingSystemChanges else { return }
    isObservingSystemChanges = true

    let workspaceCenter = NSWorkspace.shared.notificationCenter
    notificationObservers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.enqueueCaptureEnvironmentChange(reason: "system-wake", forceRestart: true) }
      }
    )
    notificationObservers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.screensDidWakeNotification,
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.enqueueCaptureEnvironmentChange(reason: "display-wake", forceRestart: true) }
      }
    )

    let center = NotificationCenter.default
    notificationObservers.append(
      center.addObserver(
        forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasConnected"),
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.enqueueCaptureEnvironmentChange(reason: "capture-device-connected", forceRestart: true) }
      }
    )
    notificationObservers.append(
      center.addObserver(
        forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasDisconnected"),
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.enqueueCaptureEnvironmentChange(reason: "capture-device-disconnected", forceRestart: true) }
      }
    )

    installAudioHardwareObserver(
      selector: kAudioHardwarePropertyDefaultInputDevice,
      reason: "default-input-changed"
    )
    installAudioHardwareObserver(
      selector: kAudioHardwarePropertyDefaultOutputDevice,
      reason: "default-output-changed"
    )
    installAudioHardwareObserver(
      selector: kAudioHardwarePropertyDevices,
      reason: "audio-devices-changed"
    )

    recordingLogger.notice("Installed recording environment observers")
  }

  private func installAudioHardwareObserver(
    selector: AudioObjectPropertySelector,
    reason: String
  ) {
    let listener: CoreAudioPropertyListenerBlock = { _, _ in
      Task { await self.enqueueCaptureEnvironmentChange(reason: reason, forceRestart: true) }
    }

    var address = audioPropertyAddress(selector)
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      DispatchQueue.main,
      listener
    )

    if status == noErr {
      audioHardwareObservers.append(
        AudioHardwareObserver(selector: selector, reason: reason, listener: listener)
      )
    } else {
      recordingLogger.error("Failed to install audio observer reason=\(reason) status=\(status)")
    }
  }

  private func enqueueCaptureEnvironmentChange(reason: String, forceRestart: Bool) {
    environmentChangeDebounceTask?.cancel()
    environmentChangeDebounceTask = Task { [self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      await handleCaptureEnvironmentChange(reason: reason, forceRestart: forceRestart)
    }
  }

  private func stopObservingSystemChanges() {
    guard isObservingSystemChanges else { return }
    isObservingSystemChanges = false
    environmentChangeDebounceTask?.cancel()
    environmentChangeDebounceTask = nil

    for observer in notificationObservers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    notificationObservers.removeAll()

    for observer in audioHardwareObservers {
      var address = audioPropertyAddress(observer.selector)
      let status = AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        DispatchQueue.main,
        observer.listener
      )
      if status != noErr {
        recordingLogger.error("Failed to remove audio observer reason=\(observer.reason) status=\(status)")
      }
    }
    audioHardwareObservers.removeAll()
  }

  private func handleCaptureEnvironmentChange(reason: String, forceRestart: Bool) async {
    let currentInputDevice = getDefaultInputDevice()
    let currentOutputDevice = getDefaultOutputDevice()
    let isRecorderRecording = recorder?.isRecording == true
    let isSuperFastRecording = superFastCapture.isRecording
    let isRecordingActive = isRecorderRecording || isSuperFastRecording

    recordingLogger.notice(
      "Capture environment changed reason=\(reason) activeRecording=\(isRecordingActive) input=\(self.describeDevice(currentInputDevice)) output=\(self.describeDevice(currentOutputDevice)) superFastArmed=\(self.superFastCapture.isRunning) primed=\(self.isRecorderPrimedForNextSession)"
    )

    if isRecordingActive {
      // Bluetooth headphones can switch profiles as soon as the recorder
      // opens. Re-assert the system mute on that new route while retaining the
      // one snapshot taken before recording began.
      if mutedOutputState != nil {
        _ = runSystemOutputScript("set volume output muted true")
      }
      deferredCaptureRestartReason = reason
      invalidatePrimedState()
      recordingLogger.notice("Deferring capture restart until current recording stops reason=\(reason)")
      return
    }

    deferredCaptureRestartReason = nil
    let activeInputDevice = applyPreferredInputDevice()

    if hexSettings.superFastModeEnabled {
      releaseRecorder(reason: "environment-change-\(reason)")
      do {
        try ensureSuperFastCaptureReady(
          for: activeInputDevice,
          reason: reason,
          forceRestart: forceRestart
        )
      } catch {
        recordingLogger.error("Failed to restart super fast capture after \(reason): \(error.localizedDescription)")
      }
      return
    }

    stopSuperFastCapture(reason: reason)
    let shouldReprimeRecorder = recorder != nil || isRecorderPrimedForNextSession
    releaseRecorder(reason: "environment-change-\(reason)")

    guard shouldReprimeRecorder else {
      recordingLogger.debug("No warm recorder state to rebuild after reason=\(reason)")
      return
    }

    do {
      try primeRecorderForNextSession()
      recordingLogger.notice("Recorder re-primed after reason=\(reason)")
    } catch {
      recordingLogger.error("Failed to re-prime recorder after \(reason): \(error.localizedDescription)")
    }
  }

  private func flushDeferredCaptureRestartIfNeeded() async {
    guard let deferredCaptureRestartReason else { return }
    recordingLogger.notice("Applying deferred capture restart reason=\(deferredCaptureRestartReason)")
    await handleCaptureEnvironmentChange(
      reason: "deferred-\(deferredCaptureRestartReason)",
      forceRestart: true
    )
  }

  /// Get all available audio devices
  private func getAllAudioDevices() -> [AudioDeviceID] {
    var propertySize: UInt32 = 0
    var address = audioPropertyAddress(kAudioHardwarePropertyDevices)
    
    // Get the property data size
    var status = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize
    )
    
    if status != 0 {
      recordingLogger.error("AudioObjectGetPropertyDataSize failed: \(status)")
      return []
    }
    
    // Calculate device count
    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    
    // Get the device IDs
    status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize,
      &deviceIDs
    )
    
      if status != 0 {
        recordingLogger.error("AudioObjectGetPropertyData failed while listing devices: \(status)")
        return []
      }
    
    return deviceIDs
  }
  
  private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
    getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
  }

  /// Get a string property exposed by an audio device.
  private func getDeviceStringProperty(
    deviceID: AudioDeviceID,
    selector: AudioObjectPropertySelector
  ) -> String? {
    var address = audioPropertyAddress(selector)

    var deviceName: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let deviceNamePtr: UnsafeMutableRawPointer = .allocate(byteCount: Int(size), alignment: MemoryLayout<CFString?>.alignment)
    defer { deviceNamePtr.deallocate() }
    
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      deviceNamePtr
    )
    
    if status == 0 {
        deviceName = deviceNamePtr.load(as: CFString?.self)
    }
    
      if status != 0 {
        recordingLogger.error("Failed to fetch device name: \(status)")
        return nil
      }
    
    return deviceName as String?
  }
  
  /// Get device name for the given device ID
  private func getDeviceName(deviceID: AudioDeviceID) -> String? {
    getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
  }

  /// Check if device has input capabilities
  private func deviceHasInput(deviceID: AudioDeviceID) -> Bool {
    var address = audioPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
    
    var propertySize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(
      deviceID,
      &address,
      0,
      nil,
      &propertySize
    )
    
    if status != 0 {
      return false
    }
    
    let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
    defer { bufferList.deallocate() }
    
    let getStatus = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &propertySize,
      bufferList
    )
    
    if getStatus != 0 {
      return false
    }
    
    // Check if we have any input channels
    let buffersPointer = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffersPointer.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
  }
  
  /// Set device as the default input device
  private func setInputDevice(deviceID: AudioDeviceID) {
    var device = deviceID
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = audioPropertyAddress(kAudioHardwarePropertyDefaultInputDevice)
    
    let status = AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      size,
      &device
    )
    
    if status != 0 {
      recordingLogger.error("Failed to set default input device: \(status)")
    } else {
      recordingLogger.notice("Selected input device set to \(deviceID)")
    }
  }

  func requestMicrophoneAccess() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  // MARK: - Input Device Query

  /// Gets the current default input device ID
  private func getDefaultInputDevice() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = audioPropertyAddress(kAudioHardwarePropertyDefaultInputDevice)

    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )

    if status != 0 {
      recordingLogger.error("Failed to get default input device: \(status)")
      return nil
    }

    return deviceID
  }

  /// Finds the MacBook's built-in microphone device.
  private func getBuiltInInputDevice() -> AudioDeviceID? {
    let devices = getAllAudioDevices()
    for device in devices {
      guard deviceHasInput(deviceID: device) else { continue }
      
      // Check if it's the built-in device via transport type selector
      var transportType: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      var address = audioPropertyAddress(kAudioDevicePropertyTransportType, scope: kAudioDevicePropertyScopeInput)
      let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transportType)
      
      if status == noErr && transportType == 0x626c746e { // 'bltn'
        return device
      }
    }
    
    // Fallback: search for built-in or MacBook patterns in the device name
    for device in devices {
      guard deviceHasInput(deviceID: device) else { continue }
      if let name = getDeviceName(deviceID: device)?.lowercased() {
        if name.contains("built-in") || name.contains("macbook") || name.contains("internal") {
          return device
        }
      }
    }
    
    return nil
  }

  private func resolvePreferredInputDevice() -> AudioDeviceID? {
    let builtInDevice = getBuiltInInputDevice()

    guard let selectedID = hexSettings.selectedMicrophoneID else {
      // Hex intentionally defaults to the Mac's built-in microphone rather than
      // inheriting an external device that another app may have selected.
      return builtInDevice ?? getDefaultInputDevice()
    }

    let devices = getAllAudioDevices()
    if let selectedDevice = devices.first(where: { device in
      deviceHasInput(deviceID: device)
        && (getDeviceUID(deviceID: device) == selectedID || String(device) == selectedID)
    }) {
      return selectedDevice
    }

    recordingLogger.notice("Selected microphone \(selectedID) is unavailable; using built-in microphone")
    return builtInDevice ?? getDefaultInputDevice()
  }

  private func formatDuration(_ duration: TimeInterval?) -> String {
    guard let duration else { return "n/a" }
    return String(format: "%.3fs", duration)
  }

  private func describeDevice(_ deviceID: AudioDeviceID?) -> String {
    guard let deviceID else { return "none" }
    if let name = getDeviceName(deviceID: deviceID) {
      return "\(name) [\(deviceID)]"
    }
    return "unknown [\(deviceID)]"
  }

  private func logRecordingStartRequest(mode: String, inputDeviceID: AudioDeviceID?) {
    let idleDuration = lastRecordingEndedAt.map { Date().timeIntervalSince($0) }
    let outputDeviceID = getDefaultOutputDevice()
    recordingLogger.notice(
      "Recording requested mode=\(mode) idle=\(self.formatDuration(idleDuration)) input=\(self.describeDevice(inputDeviceID)) output=\(self.describeDevice(outputDeviceID)) primed=\(self.isRecorderPrimedForNextSession)"
    )
  }

  @discardableResult
  private func applyPreferredInputDevice() -> AudioDeviceID? {
    let targetDeviceID = resolvePreferredInputDevice()
    let currentDefaultDevice = getDefaultInputDevice()

    if let primedDevice = lastPrimedDeviceID, primedDevice != currentDefaultDevice {
      recordingLogger.notice("Default input changed from \(primedDevice) to \(currentDefaultDevice ?? 0); invalidating primed state")
      invalidatePrimedState()
    }

    // Save the original default input device if we haven't saved it yet
    if originalDefaultInputDeviceID == nil {
      originalDefaultInputDeviceID = currentDefaultDevice
    }

    if let targetDeviceID {
      if targetDeviceID != currentDefaultDevice {
        recordingLogger.notice("Switching input device from \(currentDefaultDevice ?? 0) to \(targetDeviceID)")
        setInputDevice(deviceID: targetDeviceID)
        invalidatePrimedState()
      } else {
        recordingLogger.debug("Device \(targetDeviceID) already set as default, skipping setInputDevice()")
      }
    } else {
      recordingLogger.debug("Using system default microphone")
    }

    return getDefaultInputDevice()
  }

  private func makeSuperFastRecordingURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("hex-super-fast-\(UUID().uuidString).wav")
  }

  private func ensureSuperFastCaptureReady(
    for deviceID: AudioDeviceID?,
    reason: String,
    forceRestart: Bool = false
  ) throws {
    if forceRestart || superFastCaptureDeviceID != deviceID {
      recordingLogger.notice(
        "Restarting super fast capture reason=\(reason) previousInput=\(self.describeDevice(self.superFastCaptureDeviceID)) newInput=\(self.describeDevice(deviceID)) force=\(forceRestart)"
      )
      stopSuperFastCapture(reason: forceRestart ? "restart-\(reason)" : "input-device-changed")
    }

    try superFastCapture.startIfNeeded(reason: reason)
    superFastCaptureDeviceID = deviceID
  }

  private func stopSuperFastCapture(reason: String) {
    superFastCapture.stop(reason: reason)
    superFastCaptureDeviceID = nil
  }

  private func releaseRecorder(reason: String) {
    if recorder != nil {
      recordingLogger.notice(
        "Releasing recorder reason=\(reason) primed=\(self.isRecorderPrimedForNextSession) input=\(self.describeDevice(self.lastPrimedDeviceID))"
      )
    }
    stopMeterTask()
    if recorder?.isRecording == true {
      recorder?.stop()
    }
    recorder = nil
    invalidatePrimedState()
  }

  // MARK: - Input Device Mute Detection & Fix

  /// Checks if the input device is muted at the Core Audio device level
  private func isInputDeviceMuted(_ deviceID: AudioDeviceID) -> Bool {
    var address = audioPropertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
    var muted: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)

    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
    if status != noErr {
      // Property not supported on this device
      return false
    }
    return muted == 1
  }

  /// Unmutes the input device at the Core Audio device level
  private func unmuteInputDevice(_ deviceID: AudioDeviceID) {
    var address = audioPropertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
    var muted: UInt32 = 0
    let size = UInt32(MemoryLayout<UInt32>.size)

    let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &muted)
    if status == noErr {
      recordingLogger.warning("Input device \(deviceID) was muted at device level - automatically unmuted")
    } else {
      recordingLogger.error("Failed to unmute input device \(deviceID): \(status)")
    }
  }

  /// Checks and fixes muted input device before recording
  private func ensureInputDeviceUnmuted() {
    // Check the selected device if specified, otherwise the default
    var deviceIDsToCheck: [AudioDeviceID] = []

    if let preferredID = resolvePreferredInputDevice() {
      deviceIDsToCheck.append(preferredID)
    }

    if let defaultID = getDefaultInputDevice() {
      if !deviceIDsToCheck.contains(defaultID) {
        deviceIDsToCheck.append(defaultID)
      }
    }

    for deviceID in deviceIDsToCheck {
      if isInputDeviceMuted(deviceID) {
        recordingLogger.error("⚠️ Input device \(deviceID) is MUTED at Core Audio level! This causes silent recordings.")
        unmuteInputDevice(deviceID)
      }
    }
  }

  private func muteAllOutputDevices() {
    guard mutedOutputState == nil else { return }
    guard let original = readSystemOutputState() else {
      mediaLogger.error("Unable to read the macOS system output state")
      return
    }

    // Keep the user's volume untouched. The mute flag is carried by macOS
    // across output routes, whereas forcing volume to zero can be persisted by
    // Bluetooth A2DP/HFP profile switches and later restored as zero.
    guard runSystemOutputScript("set volume output muted true") else {
      mediaLogger.error("Unable to silence the active macOS output")
      return
    }

    mutedOutputState = original
    mediaLogger.notice("Silenced active system output; captured volume=\(original.volume) muted=\(original.isMuted)")
  }

  private func scheduleOutputRestore(for original: SystemOutputState) {
    outputRestoreTask?.cancel()
    let generation = UUID()
    outputRestoreGeneration = generation
    let restoreDelays: [Duration] = [
      .milliseconds(300),
      .milliseconds(700),
      .milliseconds(1400),
      .milliseconds(2400),
    ]

    outputRestoreTask = Task { [weak self] in
      for delay in restoreDelays {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, let self else { return }
        guard await self.retryOutputRestore(original, generation: generation) else { return }
      }
      await self?.finishOutputRestore(generation: generation)
    }
  }

  private func retryOutputRestore(_ original: SystemOutputState, generation: UUID) -> Bool {
    guard outputRestoreGeneration == generation, recordingSessionID == nil else {
      return false
    }

    let muteClause = original.isMuted ? "with output muted" : "without output muted"
    guard runSystemOutputScript("set volume output volume \(original.volume) \(muteClause)") else {
      mediaLogger.error("Failed to restore the active macOS output state")
      return true
    }
    mediaLogger.notice("Restored active system output volume=\(original.volume) muted=\(original.isMuted) retryDelay=\(generation)")
    return true
  }

  private func finishOutputRestore(generation: UUID) {
    guard outputRestoreGeneration == generation else { return }
    outputRestoreGeneration = nil
    outputRestoreTask = nil
  }

  /// Bluetooth recording can switch the output profile after the initial
  /// mute. Re-assert the canonical system mute flag during that transition;
  /// never use volume zero as a substitute because that value can become the
  /// user's persisted volume on the new route.
  private func reapplyOutputMuteIfNeeded(sessionID: UUID) async {
    guard mutedOutputState != nil else { return }

    for delay in [Duration.zero, .milliseconds(250), .milliseconds(500)] {
      if delay > .zero {
        try? await Task.sleep(for: delay)
      }
      guard recordingSessionID == sessionID, mutedOutputState != nil else { return }
      _ = runSystemOutputScript("set volume output muted true")
    }
  }

  private func readSystemOutputState() -> SystemOutputState? {
    let source = """
    set currentSettings to get volume settings
    return ((output volume of currentSettings) as text) & "," & ((output muted of currentSettings) as text)
    """
    var error: NSDictionary?
    guard let value = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else {
      if let error { mediaLogger.error("Failed to read output state: \(error)") }
      return nil
    }
    let parts = value.split(separator: ",", maxSplits: 1).map(String.init)
    guard parts.count == 2, let volume = Int(parts[0]) else { return nil }
    return SystemOutputState(volume: volume, isMuted: parts[1].lowercased() == "true")
  }

  @discardableResult
  private func runSystemOutputScript(_ source: String) -> Bool {
    var error: NSDictionary?
    _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error {
      mediaLogger.error("System output command failed: \(error)")
      return false
    }
    return true
  }

  /// Gets the default output device ID
  private func getDefaultOutputDevice() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = audioPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)

    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )

    if status != 0 {
      recordingLogger.error("Failed to get default output device: \(status)")
      return nil
    }

    return deviceID
  }

  func startRecording() async {
    // Guard against re-entrant starts. The hotkey handler can emit a second
    // start while the first recording is still active; re-running the media
    // audio behavior would double-mute (and then double-restore) the output, and
    // re-opening the capture would corrupt the in-flight recording.
    if recordingSessionID != nil {
      recordingLogger.warning("startRecording() called while a recording session is already active; ignoring")
      return
    }

    // Check and fix device-level mute before recording
    ensureInputDeviceUnmuted()

    outputRestoreTask?.cancel()
    outputRestoreTask = nil
    outputRestoreGeneration = nil

    let sessionID = UUID()
    recordingSessionID = sessionID

    // Handle audio behavior based on user preference
    switch hexSettings.recordingAudioBehavior {
    case .mute:
      // Mute all output devices synchronously for zero-latency muting
      muteAllOutputDevices()

    case .doNothing:
      // No audio handling
      break
    }

    let activeInputDevice = applyPreferredInputDevice()
    let mode = hexSettings.superFastModeEnabled ? "super-fast" : "standard"
    logRecordingStartRequest(mode: mode, inputDeviceID: activeInputDevice)
    let startRequestAt = Date()

    if hexSettings.superFastModeEnabled {
      do {
        try ensureSuperFastCaptureReady(for: activeInputDevice, reason: "startRecording")
        let recordingURL = makeSuperFastRecordingURL()
        try superFastCapture.beginRecording(to: recordingURL, requestedAt: startRequestAt)
        await reapplyOutputMuteIfNeeded(sessionID: sessionID)
        currentRecordingStartedAt = Date()
        recordingLogger.notice(
          "Super fast recording started startup=\(self.formatDuration(self.currentRecordingStartedAt?.timeIntervalSince(startRequestAt)))"
        )
        return
      } catch {
        recordingLogger.error("Failed to start super fast capture: \(error.localizedDescription); falling back to AVAudioRecorder")
        stopSuperFastCapture(reason: "super-fast-start-failed")
      }
    }

    do {
      let recorder = try ensureRecorderReadyForRecording()
      let recordCallStartedAt = Date()
      guard recorder.record() else {
        recordingLogger.error("AVAudioRecorder refused to start recording")
        await abortRecordingSession()
        return
      }
      currentRecordingStartedAt = Date()
      startMeterTask()
      await reapplyOutputMuteIfNeeded(sessionID: sessionID)
      recordingLogger.notice(
        "Recording started recordCall=\(self.formatDuration(Date().timeIntervalSince(recordCallStartedAt))) totalStart=\(self.formatDuration(self.currentRecordingStartedAt?.timeIntervalSince(startRequestAt)))"
      )
    } catch {
      recordingLogger.error("Failed to start recording: \(error.localizedDescription)")
      await abortRecordingSession()
    }
  }

  func stopRecording() async -> URL {
    if let superFastURL = superFastCapture.finishRecording() {
      let stoppedAt = Date()
      let recordingDuration = currentRecordingStartedAt.map { stoppedAt.timeIntervalSince($0) }
      stopMeterTask()
      endRecordingSession()
      currentRecordingStartedAt = nil
      lastRecordingEndedAt = stoppedAt
      recordingLogger.notice(
        "Super fast recording stopped duration=\(self.formatDuration(recordingDuration))"
      )

      if !hexSettings.superFastModeEnabled {
        stopSuperFastCapture(reason: "mode-disabled-after-stop")
      }

      await flushDeferredCaptureRestartIfNeeded()
      await restoreRecordingAudioState()
      return superFastURL
    }

    let stoppedAt = Date()
    let recordingDuration = currentRecordingStartedAt.map { stoppedAt.timeIntervalSince($0) }
    let wasRecording = recorder?.isRecording == true
    recorder?.stop()
    stopMeterTask()
    endRecordingSession()
    currentRecordingStartedAt = nil
    lastRecordingEndedAt = stoppedAt
    if wasRecording {
      recordingLogger.notice("Recording stopped duration=\(self.formatDuration(recordingDuration))")
    } else {
      recordingLogger.notice("stopRecording() called while recorder was idle")
    }

    var exportedURL = recordingURL
    var didCopyRecording = false
    do {
      exportedURL = try duplicateCurrentRecording()
      didCopyRecording = true
    } catch {
      isRecorderPrimedForNextSession = false
      recordingLogger.error("Failed to copy recording: \(error.localizedDescription)")
    }

    // The exported file is complete and ready for Parakeet. Recorder
    // re-priming, capture-environment recovery, and output restoration do not
    // need to delay the first inference after key release.
    Task { [self] in
      await finishStandardStop(didCopyRecording: didCopyRecording)
    }

    recordingLogger.info("Recording file ready for transcription file=\(exportedURL.lastPathComponent, privacy: .public)")
    return exportedURL
  }

  private func finishStandardStop(didCopyRecording: Bool) async {
    if didCopyRecording {
      do {
        try primeRecorderForNextSession()
      } catch {
        isRecorderPrimedForNextSession = false
        recordingLogger.error("Failed to prime recorder: \(error.localizedDescription)")
      }
    }

    if !hexSettings.superFastModeEnabled {
      stopSuperFastCapture(reason: "standard-stop")
    }

    await flushDeferredCaptureRestartIfNeeded()
    await restoreRecordingAudioState()
  }

  private func restoreRecordingAudioState() async {
    let hasMutedDevicesToRestore = mutedOutputState != nil
    let originalInput = originalDefaultInputDeviceID

    guard hasMutedDevicesToRestore || originalInput != nil else {
      return
    }

    if let originalInput {
      let currentDefault = getDefaultInputDevice()
      if currentDefault != originalInput {
        recordingLogger.notice("Restoring system default input device to \(originalInput)")
        setInputDevice(deviceID: originalInput)
      }
    }

    if let originalOutput = mutedOutputState {
      // Restore immediately so the next transcription can begin without
      // waiting for Bluetooth route changes to settle. The retries run in the
      // background and are guarded against a newer recording session.
      mutedOutputState = nil
      let muteClause = originalOutput.isMuted ? "with output muted" : "without output muted"
      if runSystemOutputScript("set volume output volume \(originalOutput.volume) \(muteClause)") {
        mediaLogger.notice("Restored active system output volume=\(originalOutput.volume) muted=\(originalOutput.isMuted)")
      } else {
        mediaLogger.error("Failed to restore the active macOS output state")
      }
      scheduleOutputRestore(for: originalOutput)
    }

    clearRecordingAudioState()
  }

  // Actor state update helpers
  private func isCurrentSession(_ sessionID: UUID) -> Bool {
    recordingSessionID == sessionID
  }

  private func endRecordingSession() {
    recordingSessionID = nil
  }

  private func abortRecordingSession() async {
    endRecordingSession()
    await restoreRecordingAudioState()
  }

  private func invalidatePrimedState() {
    isRecorderPrimedForNextSession = false
    lastPrimedDeviceID = nil
  }

  private func clearRecordingAudioState() {
    mutedOutputState = nil
    originalDefaultInputDeviceID = nil
  }

  private enum RecorderPreparationError: Error {
    case failedToPrepareRecorder
    case missingRecordingOnDisk
  }

  private func ensureRecorderReadyForRecording() throws -> AVAudioRecorder {
    let recorder = try recorderOrCreate()

    if !isRecorderPrimedForNextSession {
      recordingLogger.notice("Recorder NOT primed, calling prepareToRecord() now")
      guard recorder.prepareToRecord() else {
        throw RecorderPreparationError.failedToPrepareRecorder
      }
    } else {
      recordingLogger.notice("Recorder already primed, skipping prepareToRecord()")
    }

    isRecorderPrimedForNextSession = false
    return recorder
  }

  private func recorderOrCreate() throws -> AVAudioRecorder {
    if let recorder {
      return recorder
    }

    let recorder = try AVAudioRecorder(url: recordingURL, settings: recorderSettings)
    recorder.isMeteringEnabled = true
    self.recorder = recorder
    return recorder
  }

  private func duplicateCurrentRecording() throws -> URL {
    let fm = FileManager.default

    guard fm.fileExists(atPath: recordingURL.path) else {
      throw RecorderPreparationError.missingRecordingOnDisk
    }

    let exportURL = recordingURL
      .deletingLastPathComponent()
      .appendingPathComponent("hex-recording-\(UUID().uuidString).wav")

    if fm.fileExists(atPath: exportURL.path) {
      try fm.removeItem(at: exportURL)
    }

    try fm.copyItem(at: recordingURL, to: exportURL)
    return exportURL
  }

  private func primeRecorderForNextSession() throws {
    let recorder = try recorderOrCreate()
    guard recorder.prepareToRecord() else {
      isRecorderPrimedForNextSession = false
      lastPrimedDeviceID = nil
      throw RecorderPreparationError.failedToPrepareRecorder
    }

    isRecorderPrimedForNextSession = true
    lastPrimedDeviceID = getDefaultInputDevice()
    recordingLogger.debug("Recorder primed for device \(self.lastPrimedDeviceID ?? 0)")
  }

  func startMeterTask() {
    meterTask = Task {
      while !Task.isCancelled, let r = self.recorder, r.isRecording {
        r.updateMeters()
        let averagePower = r.averagePower(forChannel: 0)
        let averageNormalized = pow(10, averagePower / 20.0)
        let peakPower = r.peakPower(forChannel: 0)
        let peakNormalized = pow(10, peakPower / 20.0)
        meterContinuation.yield(Meter(averagePower: Double(averageNormalized), peakPower: Double(peakNormalized)))
        try? await Task.sleep(for: .milliseconds(30))
      }
    }
  }

  func stopMeterTask() {
    meterTask?.cancel()
    meterTask = nil
  }

  func observeAudioLevel() -> AsyncStream<Meter> {
    meterStream
  }

  func warmUpRecorder() async {
    let activeInputDevice = applyPreferredInputDevice()

    if hexSettings.superFastModeEnabled {
      releaseRecorder(reason: "warm-up-super-fast")
      do {
        try ensureSuperFastCaptureReady(for: activeInputDevice, reason: "warmUpRecorder")
      } catch {
        recordingLogger.error("Failed to arm super fast capture: \(error.localizedDescription)")
      }
      return
    }

    stopSuperFastCapture(reason: "warm-up-standard")

    do {
      try primeRecorderForNextSession()
    } catch {
      recordingLogger.error("Failed to warm up recorder: \(error.localizedDescription)")
    }
  }

  /// Release recorder resources. Call on app termination.
  func cleanup() async {
    endRecordingSession()
    await restoreRecordingAudioState()
    outputRestoreTask?.cancel()
    outputRestoreTask = nil
    outputRestoreGeneration = nil
    stopObservingSystemChanges()
    stopSuperFastCapture(reason: "cleanup")
    releaseRecorder(reason: "cleanup")
    recordingLogger.notice("RecordingClient cleaned up")
  }
}

extension DependencyValues {
  var recording: RecordingClient {
    get { self[RecordingClient.self] }
    set { self[RecordingClient.self] = newValue }
  }
}
