//
//  InvisibleWindow.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import AppKit
import HexCore
import SwiftUI

/// This allows us to render SwiftUI views anywhere on the screen, without dealing with the awkward
/// rendering issues that come with normal MacOS windows. Essentially, we create one giant invisible
/// window that covers the entire screen, and render our SwiftUI views into it.
///
/// I'm pretty sure this is what CleanShot X and other apps do to render their floating widgets.
/// But if there's a better way to do this, I'd love to know!
class InvisibleWindow: NSPanel {
  /// Shared reference so overlay subviews can route updates (like the floating
  /// copy pill) directly. `NSApp.delegate` cannot be used for this: SwiftUI's
  /// app lifecycle swaps in its own delegate object, so casting `NSApp.delegate`
  /// to `HexAppDelegate` silently fails and notifications get dropped.
  static var current: InvisibleWindow?

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  private var currentScreen: NSScreen?
  private var mouseMonitor: Any?
  private var feedbackButtonWindow: FeedbackButtonWindow?

  init() {
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let styleMask: NSWindow.StyleMask = [.fullSizeContentView, .borderless, .utilityWindow, .nonactivatingPanel]

    super.init(contentRect: screen.frame,
               styleMask: styleMask,
               backing: .buffered,
               defer: false)

    level = .statusBar
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    hidesOnDeactivate = false // Prevent hiding when app loses focus
    canHide = false
    ignoresMouseEvents = true // The notch indicator never blocks clicks
    collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]

    InvisibleWindow.current = self

    // Set initial frame
    updateToScreenWithMouse()

    // Start observing screen changes
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenDidChange),
      name: NSWindow.didChangeScreenNotification,
      object: nil
    )

    // Also observe screen parameters for resolution changes
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenDidChange),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )

    // Monitor mouse movements to detect screen boundary crossings
    mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
      self?.checkForScreenChange()
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let monitor = mouseMonitor {
      NSEvent.removeMonitor(monitor)
    }
    feedbackButtonWindow?.orderOut(nil)
    if InvisibleWindow.current === self {
      InvisibleWindow.current = nil
    }
  }

  /// Shows the floating bottom-center Copy pill in its own tiny interactive
  /// panel. Passing a nil feedback hides the pill.
  ///
  /// This replaced an earlier approach of overlaying an invisible hit-rect on
  /// top of the visuals: hosting the SwiftUI pill directly in this panel means
  /// every pixel of the visible control receives real click events, with zero
  /// coordinate syncing to go wrong.
  @MainActor
  func updateCopyPill(
    feedback: TranscriptionFeature.State.Feedback?,
    startedAt: Date,
    duration: TimeInterval,
    onCopy: @escaping () -> Void
  ) {
    guard let feedback else {
      if feedbackButtonWindow != nil {
        HexLog.overlay.debug("Hiding floating copy pill")
      }
      feedbackButtonWindow?.orderOut(nil)
      feedbackButtonWindow = nil
      return
    }

    let mouseLocation = NSEvent.mouseLocation
    let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
      ?? currentScreen
      ?? NSScreen.main
      ?? NSScreen.screens[0]

    let pillFrame = FloatingCopyLayout.pillFrame(onScreen: screen.frame)
    HexLog.overlay.notice("Showing floating copy pill frame=\(String(describing: pillFrame), privacy: .public)")

    if let feedbackButtonWindow {
      feedbackButtonWindow.update(
        frame: pillFrame,
        feedback: feedback,
        startedAt: startedAt,
        duration: duration,
        onCopy: onCopy
      )
    } else {
      let window = FeedbackButtonWindow(
        frame: pillFrame,
        feedback: feedback,
        startedAt: startedAt,
        duration: duration,
        onCopy: onCopy
      )
      feedbackButtonWindow = window
      window.orderFrontRegardless()
    }
  }

  private func updateToScreenWithMouse() {
    let mouseLocation = NSEvent.mouseLocation
    guard let screenWithMouse = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else { return }
    currentScreen = screenWithMouse
    setFrame(screenWithMouse.frame, display: true)
  }

  private func checkForScreenChange() {
    let mouseLocation = NSEvent.mouseLocation
    guard let newScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else { return }
    
    // Only update if screen actually changed
    if newScreen !== currentScreen {
      currentScreen = newScreen
      setFrame(newScreen.frame, display: true)
    }
  }

  @objc private func screenDidChange(_: Notification) {
    updateToScreenWithMouse()
  }
}

/// The floating Copy pill is hosted directly in this tiny transparent panel,
/// so the SwiftUI button inside receives real click events — no hit-test or
/// coordinate juggling. This works even though the main indicator window is
/// intentionally click-through.
@MainActor
private final class FeedbackButtonWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(
    frame: NSRect,
    feedback: TranscriptionFeature.State.Feedback,
    startedAt: Date,
    duration: TimeInterval,
    onCopy: @escaping () -> Void
  ) {
    super.init(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    ignoresMouseEvents = false
    hidesOnDeactivate = false
    canHide = false
    becomesKeyOnlyIfNeeded = true
    acceptsMouseMovedEvents = true
    isMovableByWindowBackground = false
    collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]

    update(
      frame: frame,
      feedback: feedback,
      startedAt: startedAt,
      duration: duration,
      onCopy: onCopy
    )
  }

  func update(
    frame: NSRect,
    feedback: TranscriptionFeature.State.Feedback,
    startedAt: Date,
    duration: TimeInterval,
    onCopy: @escaping () -> Void
  ) {
    setFrame(frame, display: true)
    contentView = NSHostingView(
      rootView: FloatingCopyPillView(
        feedback: feedback,
        startedAt: startedAt,
        duration: duration,
        onCopy: onCopy
      )
    )
    orderFrontRegardless()
  }
}

extension InvisibleWindow: NSWindowDelegate {
  static func fromView<V: View>(_ view: V) -> InvisibleWindow {
    let window = InvisibleWindow()
    window.contentView = NSHostingView(rootView: view)
    window.delegate = window
    return window
  }
}
