@preconcurrency import AppKit
import AVFoundation
import CoreGraphics
import Dependencies
import Foundation
import IOKit
import IOKit.hidsystem
import PermissionFlow

private let logger = HexLog.permissions

extension PermissionClient: DependencyKey {
  public static var liveValue: Self {
    let live = PermissionClientLive()
    return Self(
      microphoneStatus: { await live.microphoneStatus() },
      accessibilityStatus: { live.accessibilityStatus() },
      inputMonitoringStatus: { live.inputMonitoringStatus() },
      requestMicrophone: { await live.requestMicrophone() },
      requestAccessibility: { await live.requestAccessibility() },
      requestInputMonitoring: { await live.requestInputMonitoring() },
      openMicrophoneSettings: { await live.openMicrophoneSettings() },
      openAccessibilitySettings: { await live.openAccessibilitySettings() },
      openInputMonitoringSettings: { await live.openInputMonitoringSettings() },
      dismissPermissionPanels: { await live.dismissPermissionPanels() },
      observeAppActivation: { live.observeAppActivation() }
    )
  }
}

/// Live implementation of the PermissionClient.
///
/// This actor manages permission checking, requesting, and app activation monitoring.
/// It uses NotificationCenter to observe app lifecycle events and provides an AsyncStream
/// for reactive permission updates.
actor PermissionClientLive {
  private let (activationStream, activationContinuation) = AsyncStream<AppActivation>.makeStream()
  private nonisolated(unsafe) var observations: [Any] = []

  init() {
    logger.debug("Initializing PermissionClient, setting up app activation observers")
    // Subscribe to app activation notifications
    let didBecomeActiveObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      logger.debug("App became active")
      Task {
        self?.activationContinuation.yield(.didBecomeActive)
      }
    }

    let willResignActiveObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      logger.debug("App will resign active")
      Task {
        self?.activationContinuation.yield(.willResignActive)
      }
    }

    observations = [didBecomeActiveObserver, willResignActiveObserver]
  }

  deinit {
    observations.forEach { NotificationCenter.default.removeObserver($0) }
  }

  // MARK: - Microphone Permissions

  func microphoneStatus() async -> PermissionStatus {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    let result: PermissionStatus
    switch status {
    case .authorized:
      result = .granted
    case .denied, .restricted:
      result = .denied
    case .notDetermined:
      result = .notDetermined
    @unknown default:
      result = .denied
    }
    logger.info("Microphone status: \(String(describing: result))")
    return result
  }

  func requestMicrophone() async -> Bool {
    logger.info("Requesting microphone permission...")
    let granted = await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        continuation.resume(returning: granted)
      }
    }
    logger.info("Microphone permission granted: \(granted)")
    return granted
  }

  func openMicrophoneSettings() async {
    logger.info("Opening microphone settings in System Preferences...")
    await MainActor.run {
      _ = NSWorkspace.shared.open(
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
      )
    }
  }

  /// Screen-coordinate rect centered on the current mouse position, used as the
  /// launch point for PermissionFlow's floating panel fly-in animation.
  @MainActor
  private func launchSourceFrame() -> CGRect {
    let location = NSEvent.mouseLocation
    return CGRect(x: location.x - 16, y: location.y - 16, width: 32, height: 32)
  }

  /// The most recently created flow controller; kept so the panel can be
  /// dismissed programmatically once permissions are granted. Only touched
  /// from @MainActor contexts.
  private nonisolated(unsafe) var activeFlowController: PermissionFlowController?

  /// Dismisses the floating drag panel if one is showing.
  func dismissPermissionPanels() async {
    await MainActor.run {
      activeFlowController?.closePanel()
      activeFlowController = nil
    }
  }

  /// Opens a drag-based privacy pane via PermissionFlow, which shows a floating
  /// helper panel that tracks the System Settings window and lets the user drag
  /// the Hex app bundle into the permission list.
  @MainActor
  private func authorizeViaPermissionFlow(_ pane: PermissionFlowPane) {
    logger.info("Starting PermissionFlow for pane: \(String(describing: pane), privacy: .public)")
    let controller = PermissionFlow.makeController(
      configuration: PermissionFlowConfiguration(
        requiredAppURLs: [Bundle.main.bundleURL],
        // Hex already triggers the AX trust prompt explicitly in
        // requestAccessibility(); avoid a second system prompt.
        promptForAccessibilityTrust: false
      )
    )
    activeFlowController = controller
    controller.authorize(
      pane: pane,
      suggestedAppURLs: [Bundle.main.bundleURL],
      sourceFrameInScreen: launchSourceFrame()
    )
  }

  // MARK: - Accessibility Permissions

  nonisolated func accessibilityStatus() -> PermissionStatus {
    // Check without prompting (kAXTrustedCheckOptionPrompt: false)
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    let result = AXIsProcessTrustedWithOptions(options) ? PermissionStatus.granted : .denied
    logger.info("Accessibility status: \(String(describing: result))")
    return result
  }

  nonisolated func inputMonitoringStatus() -> PermissionStatus {
    let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    let result = mapIOHIDAccess(access)
    logger.info("Input monitoring status: \(String(describing: result)) (IOHIDAccess: \(String(describing: access)))")
    return result
  }

  func requestAccessibility() async {
    logger.info("Requesting accessibility permission...")
    // First, trigger the system prompt (on main actor for safety)
    await MainActor.run {
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
    }

    // Also open System Settings (the prompt alone is insufficient on modern macOS)
    await openAccessibilitySettings()
  }

  func requestInputMonitoring() async -> Bool {
    logger.info("Requesting input monitoring permission...")
    let granted = await MainActor.run {
      if CGPreflightListenEventAccess() {
        return true
      }
      return CGRequestListenEventAccess()
    }

    if !granted {
      logger.info("Input monitoring not granted, opening Settings...")
      await openInputMonitoringSettings()
    } else {
      logger.info("Input monitoring permission granted: \(granted)")
    }

    return granted
  }

  func openAccessibilitySettings() async {
    logger.info("Opening accessibility settings via PermissionFlow...")
    await MainActor.run {
      authorizeViaPermissionFlow(.accessibility)
    }
  }

  func openInputMonitoringSettings() async {
    logger.info("Opening input monitoring settings via PermissionFlow...")
    await MainActor.run {
      authorizeViaPermissionFlow(.inputMonitoring)
    }
  }

  // MARK: - Reactive Monitoring

  nonisolated func observeAppActivation() -> AsyncStream<AppActivation> {
    activationStream
  }

  private nonisolated func mapIOHIDAccess(_ access: IOHIDAccessType) -> PermissionStatus {
    switch access {
    case kIOHIDAccessTypeGranted:
      return .granted
    case kIOHIDAccessTypeDenied:
      return .denied
    default:
      return .notDetermined
    }
  }
}
