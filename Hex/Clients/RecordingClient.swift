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
struct AudioInputDevice: Identifiable, Equatable, Sendable {
  var id: String
  var name: String
}

struct AudioInputDeviceSnapshot: Equatable, Sendable {
  var devices: [AudioInputDevice]
  var unavailableBluetoothDevices: [AudioInputDevice]
  var defaultDeviceName: String?
}

struct RecordingAudioChunk: Sendable {
  let samples: [Float]
}

@DependencyClient
struct RecordingClient {
  var startRecording: @Sendable () async -> Void = {}
  var stopRecording: @Sendable () async -> URL = { URL(fileURLWithPath: "") }
  var requestMicrophoneAccess: @Sendable () async -> Bool = { false }
  var observeAudioLevel: @Sendable () async -> AsyncStream<Meter> = { AsyncStream { _ in } }
  var observeInputDevices: @Sendable () async -> AsyncStream<AudioInputDeviceSnapshot> = {
    AsyncStream { $0.finish() }
  }
  var warmUpRecorder: @Sendable () async -> Void = {}
  var setAudioChunkHandler: @Sendable (@escaping @Sendable (RecordingAudioChunk) -> Void) async -> Void
  var clearAudioChunkHandler: @Sendable () async -> Void = {}
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
      observeInputDevices: { await live.observeInputDevices() },
      warmUpRecorder: { await live.warmUpRecorder() },
      setAudioChunkHandler: { await live.setAudioChunkHandler($0) },
      clearAudioChunkHandler: { await live.clearAudioChunkHandler() },
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
  private enum CaptureEnvironmentChange: String, Hashable {
    case systemWake
    case displayWake
    case captureDeviceConnected
    case captureDeviceDisconnected
    case defaultInputChanged
    case defaultOutputChanged
    case audioDevicesChanged

    var affectsInputDevices: Bool {
      switch self {
      case .systemWake, .displayWake, .captureDeviceConnected, .captureDeviceDisconnected,
           .defaultInputChanged, .audioDevicesChanged:
        return true
      case .defaultOutputChanged:
        return false
      }
    }
  }

  private struct AudioHardwareObserver {
    let selector: AudioObjectPropertySelector
    let change: CaptureEnvironmentChange
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
  private var pendingEnvironmentChanges: Set<CaptureEnvironmentChange> = []
  private var environmentChangeDebounceTask: Task<Void, Never>?
  private var inputDeviceSettleTask: Task<Void, Never>?
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
  private var inputDeviceContinuations: [UUID: AsyncStream<AudioInputDeviceSnapshot>.Continuation] = [:]
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
  
  func observeInputDevices() -> AsyncStream<AudioInputDeviceSnapshot> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<AudioInputDeviceSnapshot>.makeStream()
    inputDeviceContinuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeInputDeviceContinuation(id) }
    }
    continuation.yield(inputDeviceSnapshot())
    scheduleInputDeviceSettleSnapshots()
    return stream
  }

  private func removeInputDeviceContinuation(_ id: UUID) {
    inputDeviceContinuations[id] = nil
  }

  private func inputDeviceSnapshot() -> AudioInputDeviceSnapshot {
    AudioInputDeviceSnapshot(
      devices: availableInputDevices(),
      unavailableBluetoothDevices: unavailableBluetoothInputDevices(),
      defaultDeviceName: preferredInputDeviceName()
    )
  }

  private func availableInputDevices() -> [AudioInputDevice] {
    let now = Date()
    if now.timeIntervalSince(lastDeviceCheck) > 10 {
      deviceCache.removeAll()
      lastDeviceCheck = now
    }

    return getAllAudioDevices().compactMap { device in
      let details: (hasInput: Bool, name: String?)
      if let cached = deviceCache[device] {
        details = cached
      } else {
        let hasInput = deviceHasInput(deviceID: device)
        details = (hasInput, hasInput ? getDeviceName(deviceID: device) : nil)
        deviceCache[device] = details
      }
      guard details.hasInput, let name = details.name else { return nil }
      return AudioInputDevice(id: getDeviceUID(deviceID: device) ?? String(device), name: name)
    }
  }

  private func unavailableBluetoothInputDevices() -> [AudioInputDevice] {
    getAllAudioDevices().compactMap { device in
      // Reuse the input/output cache so a mic-menu snapshot never issues
      // uncached CoreAudio stream queries per device.
      let hasInput: Bool
      let hasOutput: Bool
      if let cached = deviceCache[device], cached.name != nil || !cached.hasInput {
        hasInput = cached.hasInput
        hasOutput = deviceHasOutput(deviceID: device)
      } else {
        hasInput = deviceHasInput(deviceID: device)
        if hasInput {
          deviceCache[device] = (hasInput: true, name: getDeviceName(deviceID: device))
          return nil
        }
        hasOutput = deviceHasOutput(deviceID: device)
      }
      guard !hasInput, hasOutput,
            let transport = getDeviceTransportType(deviceID: device),
            transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
            let name = getDeviceName(deviceID: device)
      else { return nil }

      return AudioInputDevice(id: getDeviceUID(deviceID: device) ?? String(device), name: name)
    }
  }

  private func preferredInputDeviceName() -> String? {
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

  private func publishInputDeviceSnapshot() {
    let snapshot = inputDeviceSnapshot()
    for continuation in inputDeviceContinuations.values {
      continuation.yield(snapshot)
    }
  }

  private func scheduleInputDeviceSettleSnapshots() {
    inputDeviceSettleTask?.cancel()
    inputDeviceSettleTask = Task { [weak self] in
      // One delayed re-publish lets Bluetooth/USB names settle without
      // storming CoreAudio + SwiftUI on every plug/wake transition.
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled, let self else { return }
      await self.publishInputDeviceSnapshot()
    }
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
        Task { await self.enqueueCaptureEnvironmentChange(.systemWake) }
      }
    )
    notificationObservers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.screensDidWakeNotification,
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.enqueueCaptureEnvironmentChange(.displayWake) }
      }
    )

    let center = NotificationCenter.default
    notificationObservers.append(
      center.addObserver(
        forName: AVCaptureDevice.wasConnectedNotification,
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.enqueueCaptureEnvironmentChange(.captureDeviceConnected) }
      }
    )
    notificationObservers.append(
      center.addObserver(
        forName: AVCaptureDevice.wasDisconnectedNotification,
        object: nil,
        queue: .main
      ) { _ in
        Task { await self.enqueueCaptureEnvironmentChange(.captureDeviceDisconnected) }
      }
    )

    installAudioHardwareObserver(
      selector: kAudioHardwarePropertyDefaultInputDevice,
      change: .defaultInputChanged
    )
    installAudioHardwareObserver(
      selector: kAudioHardwarePropertyDefaultOutputDevice,
      change: .defaultOutputChanged
    )
    installAudioHardwareObserver(
      selector: kAudioHardwarePropertyDevices,
      change: .audioDevicesChanged
    )

    recordingLogger.notice("Installed recording environment observers")
  }

  private func installAudioHardwareObserver(
    selector: AudioObjectPropertySelector,
    change: CaptureEnvironmentChange
  ) {
    let listener: CoreAudioPropertyListenerBlock = { _, _ in
      Task { self.enqueueCaptureEnvironmentChange(change) }
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
        AudioHardwareObserver(selector: selector, change: change, listener: listener)
      )
    } else {
      recordingLogger.error("Failed to install audio observer change=\(change.rawValue) status=\(status)")
    }
  }

  private func enqueueCaptureEnvironmentChange(_ change: CaptureEnvironmentChange) {
    pendingEnvironmentChanges.insert(change)
    environmentChangeDebounceTask?.cancel()
    environmentChangeDebounceTask = Task { [self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      let changes = pendingEnvironmentChanges
      pendingEnvironmentChanges.removeAll()
      await handleCaptureEnvironmentChange(changes)
    }
  }

  private func stopObservingSystemChanges() {
    guard isObservingSystemChanges else { return }
    isObservingSystemChanges = false
    environmentChangeDebounceTask?.cancel()
    environmentChangeDebounceTask = nil
    inputDeviceSettleTask?.cancel()
    inputDeviceSettleTask = nil
    pendingEnvironmentChanges.removeAll()

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
        recordingLogger.error("Failed to remove audio observer change=\(observer.change.rawValue) status=\(status)")
      }
    }
    audioHardwareObservers.removeAll()
  }

  private func handleCaptureEnvironmentChange(_ changes: Set<CaptureEnvironmentChange>) async {
    let reasons = changes.map(\.rawValue).sorted().joined(separator: ",")
    let affectsInputDevices = changes.contains { $0.affectsInputDevices }

    if changes.contains(.audioDevicesChanged) || changes.contains(.captureDeviceConnected)
      || changes.contains(.captureDeviceDisconnected)
    {
      deviceCache.removeAll()
      lastDeviceCheck = Date()
    }
    if affectsInputDevices {
      publishInputDeviceSnapshot()
      scheduleInputDeviceSettleSnapshots()
    }

    let currentInputDevice = getDefaultInputDevice()
    let currentOutputDevice = getDefaultOutputDevice()
    let isRecordingActive = recorder?.isRecording == true || superFastCapture.isRecording
    let desiredInputDevice = affectsInputDevices ? resolvePreferredInputDevice() : currentInputDevice
    let activeCaptureDevice = superFastCaptureDeviceID ?? lastPrimedDeviceID
    let captureNeedsRestart = affectsInputDevices
      && (desiredInputDevice != activeCaptureDevice || (hexSettings.superFastModeEnabled && !superFastCapture.isRunning))

    recordingLogger.notice(
      "Capture environment changed reasons=\(reasons) activeRecording=\(isRecordingActive) input=\(self.describeDevice(currentInputDevice)) output=\(self.describeDevice(currentOutputDevice)) desiredInput=\(self.describeDevice(desiredInputDevice)) restart=\(captureNeedsRestart) superFastArmed=\(self.superFastCapture.isRunning) primed=\(self.isRecorderPrimedForNextSession)"
    )

    if mutedOutputState != nil {
      _ = runSystemOutputScript("set volume output muted true")
    }

    guard affectsInputDevices, captureNeedsRestart else { return }

    if isRecordingActive {
      deferredCaptureRestartReason = reasons
      invalidatePrimedState()
      recordingLogger.notice("Deferring capture restart until current recording stops reasons=\(reasons)")
      return
    }

    deferredCaptureRestartReason = nil
    let activeInputDevice = applyPreferredInputDevice()

    if hexSettings.superFastModeEnabled {
      releaseRecorder(reason: "environment-change-\(reasons)")
      do {
        try ensureSuperFastCaptureReady(for: activeInputDevice, reason: reasons)
      } catch {
        recordingLogger.error("Failed to restart super fast capture after \(reasons): \(error.localizedDescription)")
      }
      return
    }

    stopSuperFastCapture(reason: reasons)
    let shouldReprimeRecorder = recorder != nil || isRecorderPrimedForNextSession
    releaseRecorder(reason: "environment-change-\(reasons)")

    guard shouldReprimeRecorder else {
      recordingLogger.debug("No warm recorder state to rebuild after reasons=\(reasons)")
      return
    }

    do {
      try primeRecorderForNextSession()
      recordingLogger.notice("Recorder re-primed after reasons=\(reasons)")
    } catch {
      recordingLogger.error("Failed to re-prime recorder after \(reasons): \(error.localizedDescription)")
    }
  }

  private func flushDeferredCaptureRestartIfNeeded() async {
    guard let deferredCaptureRestartReason else { return }
    recordingLogger.notice("Applying deferred capture restart reasons=\(deferredCaptureRestartReason)")
    await handleCaptureEnvironmentChange([.defaultInputChanged])
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
    var deviceName: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &deviceName) { ptr in
      ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { bytes in
        AudioObjectGetPropertyData(
          deviceID,
          &address,
          0,
          nil,
          &size,
          bytes
        )
      }
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

  private func deviceHasInput(deviceID: AudioDeviceID) -> Bool {
    deviceHasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
  }

  private func deviceHasOutput(deviceID: AudioDeviceID) -> Bool {
    deviceHasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
  }

  private func deviceHasStreams(
    deviceID: AudioDeviceID,
    scope: AudioObjectPropertyScope
  ) -> Bool {
    var address = audioPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
    var propertySize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize) == noErr else {
      return false
    }

    let rawBufferList = UnsafeMutableRawPointer.allocate(
      byteCount: Int(propertySize),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawBufferList.deallocate() }

    guard AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &propertySize,
      rawBufferList
    ) == noErr else {
      return false
    }

    let bufferList = rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) {
      $0 + Int($1.mNumberChannels)
    } > 0
  }

  private func getDeviceTransportType(deviceID: AudioDeviceID) -> AudioDevicePropertyID? {
    var transportType = AudioDevicePropertyID(0)
    var size = UInt32(MemoryLayout<AudioDevicePropertyID>.size)
    var address = audioPropertyAddress(kAudioDevicePropertyTransportType)
    guard AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      &transportType
    ) == noErr else { return nil }
    return transportType
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
    reason: String
  ) throws {
    if superFastCaptureDeviceID != deviceID || !superFastCapture.isRunning {
      recordingLogger.notice(
        "Restarting super fast capture reason=\(reason) previousInput=\(self.describeDevice(self.superFastCaptureDeviceID)) newInput=\(self.describeDevice(deviceID)) running=\(self.superFastCapture.isRunning)"
      )
      stopSuperFastCapture(reason: "input-device-or-engine-changed-\(reason)")
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

  func setAudioChunkHandler(_ handler: @escaping @Sendable (RecordingAudioChunk) -> Void) {
    superFastCapture.setAudioChunkHandler(handler)
  }

  func clearAudioChunkHandler() {
    superFastCapture.setAudioChunkHandler(nil)
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

    // NOTE: output muting is intentionally deferred until after capture
    // starts (see below) — NSAppleScript costs ~50-200ms on the hot path.

    let activeInputDevice = applyPreferredInputDevice()
    let mode = hexSettings.superFastModeEnabled ? "super-fast" : "standard"
    logRecordingStartRequest(mode: mode, inputDeviceID: activeInputDevice)
    let startRequestAt = Date()
    let audioBehavior = hexSettings.recordingAudioBehavior

    do {
      // Standard mode starts the engine on demand; Super Fast mode may keep it
      // prearmed for pre-roll. Both modes now share one PCM capture path so
      // streaming ASR and the persisted WAV receive identical samples.
      // Output muting (NSAppleScript, ~50-200ms) runs after capture starts so
      // it never adds latency to key-press-to-first-sample.
      try ensureSuperFastCaptureReady(for: activeInputDevice, reason: "startRecording")
      let recordingURL = makeSuperFastRecordingURL()
      try superFastCapture.beginRecording(to: recordingURL, requestedAt: startRequestAt)
      if audioBehavior == .mute {
        Task { [weak self] in await self?.muteAllOutputDevices() }
      }
      await reapplyOutputMuteIfNeeded(sessionID: sessionID)
      currentRecordingStartedAt = Date()
      recordingLogger.notice(
        "Streaming recording started prearmed=\(self.hexSettings.superFastModeEnabled) startup=\(self.formatDuration(self.currentRecordingStartedAt?.timeIntervalSince(startRequestAt)))"
      )
      return
    } catch {
      recordingLogger.error("Failed to start streaming capture: \(error.localizedDescription); falling back to AVAudioRecorder")
      stopSuperFastCapture(reason: "streaming-start-failed")
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
    // Snapshot the recorder synchronously on the actor so the polling Task
    // never touches actor-isolated state concurrently with stop/release.
    let recorder = self.recorder
    let continuation = meterContinuation
    meterTask?.cancel()
    meterTask = Task {
      while !Task.isCancelled, let r = recorder, r.isRecording {
        r.updateMeters()
        let averagePower = r.averagePower(forChannel: 0)
        let averageNormalized = pow(10, averagePower / 20.0)
        let peakPower = r.peakPower(forChannel: 0)
        let peakNormalized = pow(10, peakPower / 20.0)
        continuation.yield(Meter(averagePower: Double(averageNormalized), peakPower: Double(peakNormalized)))
        try? await Task.sleep(for: .milliseconds(50))
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
    for continuation in inputDeviceContinuations.values {
      continuation.finish()
    }
    inputDeviceContinuations.removeAll()
    recordingLogger.notice("RecordingClient cleaned up")
  }
}

extension DependencyValues {
  var recording: RecordingClient {
    get { self[RecordingClient.self] }
    set { self[RecordingClient.self] = newValue }
  }
}
