import AppKit
import Foundation
import PermissionFlow
import Sparkle

/// Drag-to-authorize helper panel shown next to System Settings.
@MainActor
final class PermissionPanel {
  static let shared = PermissionPanel()
  private var controller: PermissionFlowController?

  func open(pane: Int32) {
    let flowPane: PermissionFlowPane = pane == 1 ? .inputMonitoring : .accessibility
    if flowPane == .accessibility {
      // The system trust prompt alone is insufficient on modern macOS, so the
      // prompt is raised and the panel opened together.
      // Literal value of kAXTrustedCheckOptionPrompt, which Swift 6 flags as shared mutable state.
      let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
    }
    let controller = PermissionFlow.makeController(
      configuration: PermissionFlowConfiguration(
        requiredAppURLs: [Bundle.main.bundleURL],
        promptForAccessibilityTrust: false
      )
    )
    self.controller = controller
    let mouse = NSEvent.mouseLocation
    controller.authorize(
      pane: flowPane,
      suggestedAppURLs: [Bundle.main.bundleURL],
      sourceFrameInScreen: CGRect(x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32)
    )
  }

  func dismiss() {
    controller?.closePanel()
    controller = nil
  }
}

/// Sparkle updater. The feed URL and public key come from Info.plist.
final class Updater: @unchecked Sendable {
  static let shared = Updater()
  private let lock = NSLock()
  private var controller: SPUStandardUpdaterController?

  @MainActor
  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard controller == nil else { return }
    controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  }

  @MainActor
  func check() {
    start()
    lock.lock()
    let controller = controller
    lock.unlock()
    controller?.updater.checkForUpdates()
  }

  var canCheck: Bool {
    lock.lock()
    defer { lock.unlock() }
    return controller?.updater.canCheckForUpdates ?? false
  }
}
