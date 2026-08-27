import HexCore
import Inject
import SwiftUI

// MARK: - Transcription Indicator (Notch)
//
// A small, minimal indicator that lives inside the macOS notch (the
// hardware camera housing at the top-center of the screen). It shows a
// 4-bar waveform that responds to the audio meter, and a small pulse
// dot for idle states. The container has a black fill to blend seamlessly
// with the notch's own black housing — so it looks like the waveform is
// drawn on the notch itself.
//
// Behaviour matrix:
//   .hidden        — invisible
//   .optionKeyPressed / .prewarming — small idle pulse, no waveform
//   .recording      — 4 bars reacting to the live audio meter
//   .transcribing   — 4 bars on a slow animated sine wave

// MARK: - Notch Geometry

private struct NotchGeometry: Equatable {
  var hasNotch: Bool
  var notchWidth: CGFloat
  var notchHeight: CGFloat
  var menuBarHeight: CGFloat
}

@MainActor
private func getNotchGeometry() -> NotchGeometry {
  let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
    ?? NSScreen.main
    ?? NSScreen.screens[0]
  
  if #available(macOS 12.0, *),
     let topLeft = screen.auxiliaryTopLeftArea,
     let topRight = screen.auxiliaryTopRightArea {
    let width = topRight.origin.x - (topLeft.origin.x + topLeft.size.width)
    let height = max(topLeft.size.height, topRight.size.height)
    let notchHeight = max(height, 32)
    let menuBarHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 24
    return NotchGeometry(
      hasNotch: true,
      notchWidth: width,
      notchHeight: notchHeight,
      menuBarHeight: menuBarHeight
    )
  } else {
    // Non-notched screen fallback (simulate a notch)
    return NotchGeometry(
      hasNotch: false,
      notchWidth: 120,
      notchHeight: 32,
      menuBarHeight: 24
    )
  }
}

struct TranscriptionIndicatorView: View {
  @ObserveInjection var inject

  enum Status {
    case hidden
    case optionKeyPressed
    case recording
    case transcribing
    case prewarming
  }

  var status: Status
  var isLocked: Bool
  var meter: Meter
  var sourceAppBundleID: String? = nil
  var sourceAppName: String? = nil
  var feedback: TranscriptionFeature.State.Feedback? = nil
  var onCopy: () -> Void = {}

  private var appIcon: NSImage? {
    guard let bundleID = sourceAppBundleID else { return nil }
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
      return app.icon
    }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      return NSWorkspace.shared.icon(forFile: url.path)
    }
    return nil
  }

  // MARK: - Sizing
  private let extensionWidth: CGFloat = 40
  private let maxBarHeight: CGFloat = 14
  private let minBarHeight: CGFloat = 3

  @State private var geometry = NotchGeometry(hasNotch: false, notchWidth: 120, notchHeight: 32, menuBarHeight: 24)
  @State private var feedbackStartedAt = Date()

  var body: some View {
    let targetHeight = isLocked ? (geometry.notchHeight + 30) : geometry.notchHeight
    ZStack(alignment: .top) {
      // Black housing that blends with the notch's own black bezel.
      // The height animates from 0 to target height for a premium slide-down effect.
      UnevenRoundedRectangle(
        topLeadingRadius: 0,
        bottomLeadingRadius: 12,
        bottomTrailingRadius: 12,
        topTrailingRadius: 0
      )
      .fill(Color.black)
      .frame(width: geometry.notchWidth + extensionWidth * 2, height: isActive ? targetHeight : 0)
      
      if isActive {
        HStack(spacing: 0) {
          Group {
            switch status {
            case .hidden:
              EmptyView()
            case .optionKeyPressed, .prewarming:
              IdleDot(color: TickColor.brandMid.opacity(0.8))
            case .recording:
              NotchWaveform(meter: meter, color: .white)
            case .transcribing:
              NotchWaveform(meter: meter, color: .white, isTranscribing: true)
            }
          }
          .frame(width: extensionWidth, alignment: .center)
          
          Spacer() // Covers the notch width
          
          // Right side: Active application icon
          Group {
            if let icon = appIcon {
              Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .cornerRadius(4)
                .overlay(
                  RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 0.8)
            } else {
              Image(systemName: "mic.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(TickColor.brandMid)
                .cornerRadius(4)
                .shadow(color: TickColor.brandMid.opacity(0.3), radius: 1.5, x: 0, y: 0.8)
            }
          }
          .frame(width: extensionWidth, alignment: .center)
        }
        .frame(width: geometry.notchWidth + extensionWidth * 2, height: geometry.notchHeight)
        .padding(.top, 0)
        
        // Bottom row: centered app icon + app name (only shown in lock mode)
        if isLocked {
          HStack(spacing: 6) {
            if let icon = appIcon {
              Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .cornerRadius(3.5)
                .overlay(
                  RoundedRectangle(cornerRadius: 3.5)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 1.5, x: 0, y: 1)
            } else {
              Image(systemName: "mic.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 16, height: 16)
                .background(TickColor.brandMid)
                .cornerRadius(3.5)
                .shadow(color: TickColor.brandMid.opacity(0.3), radius: 1.5, x: 0, y: 1)
            }
            
            Text(sourceAppName ?? "Listening")
              .font(TickFont.bodyFunc(10.5))
              .foregroundColor(.white.opacity(0.9))
              .lineLimit(1)
          }
          .frame(width: geometry.notchWidth + extensionWidth * 2, height: 30)
          .padding(.top, geometry.notchHeight)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      }
    }
    .frame(width: geometry.notchWidth + extensionWidth * 2, height: targetHeight)
    .clipped()
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isActive)
    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isLocked)
    .onAppear {
      updateGeometry()
      updateFeedbackInteraction()
    }
    .onChange(of: status) {
      updateGeometry()
    }
    .onChange(of: feedback) {
      feedbackStartedAt = Date()
      updateGeometry()
      updateFeedbackInteraction()
    }
    .enableInjection()
  }

  private var isActive: Bool {
    status != .hidden
  }

  private func updateGeometry() {
    geometry = getNotchGeometry()
  }

  private func updateFeedbackInteraction() {
    HexLog.app.debug("updateFeedbackInteraction called; feedback=\(String(describing: self.feedback), privacy: .public)")
    guard let window = InvisibleWindow.current else {
      HexLog.app.error("Copy pill: invisibleWindow has not been created yet")
      return
    }
    let duration: TimeInterval
    switch feedback {
    case .copied:
      duration = 1.8
    case .dictionaryAdded, .pasteUnavailable:
      duration = 4.0
    case nil:
      duration = 0
    }
    window.updateCopyPill(
      feedback: feedback,
      startedAt: feedbackStartedAt,
      duration: duration,
      onCopy: onCopy
    )
  }
}

extension TranscriptionFeature.State.Feedback {
  /// True when the transcription couldn't be inserted into a focused input.
  var isPasteUnavailable: Bool {
    if case .pasteUnavailable = self { return true }
    return false
  }

  var iconName: String {
    switch self {
    case .dictionaryAdded: return "checkmark"
    case .pasteUnavailable: return "exclamationmark"
    case .copied: return "doc.on.clipboard.fill"
    }
  }

  var title: String {
    switch self {
    case .dictionaryAdded: return "Added to Dictionary"
    case .pasteUnavailable: return "Couldn't paste"
    case .copied: return "Copied to Clipboard"
    }
  }

  var detail: String {
    switch self {
    case let .dictionaryAdded(match, replacement):
      return "\u{201c}\(match)\u{201d} → \u{201c}\(replacement)\u{201d}"
    case let .pasteUnavailable(_, reason):
      switch reason {
      case .noFocusedInput:
        return "No input field focused"
      case .insertionRejected:
        return "Paste rejected by this app"
      }
    case .copied:
      return "Your transcription is ready to paste"
    }
  }
}

// MARK: - Floating Copy Pill
//
// When paste isn't possible (no focused input / rejected insertion), the
// ENTIRE notification — status icon, text, dismiss-countdown slider and the
// Copy affordance — floats at the bottom-center of the screen in one minimal
// pill. Unlike the notch, the pill lives in its own small interactive panel
// (see InvisibleWindow.FeedbackButtonWindow), so clicks land on the SwiftUI
// button natively instead of being routed through an invisible hit-overlay.
//
// FloatingCopyLayout is the shared geometry between the two files so the
// panel always frames the pill exactly.

@MainActor
enum FloatingCopyLayout {
  /// Fixed pill footprint; content fills it edge-to-edge.
  static let pillSize = CGSize(width: 340, height: 46)
  /// Distance from the bottom edge of the screen to the bottom of the pill.
  static let bottomMargin: CGFloat = 36

  /// The pill's rect on a given screen (AppKit coordinates, origin bottom-left).
  static func pillFrame(onScreen screenFrame: NSRect) -> NSRect {
    NSRect(
      x: screenFrame.midX - pillSize.width / 2,
      y: screenFrame.minY + bottomMargin,
      width: pillSize.width,
      height: pillSize.height
    )
  }
}

struct FloatingCopyPillView: View {
  let feedback: TranscriptionFeature.State.Feedback
  let startedAt: Date
  let duration: TimeInterval
  let onCopy: () -> Void

  @State private var isHovered = false
  @State private var isCopyHovered = false
  @State private var hasLocallyCopied = false

  private var isCopiedState: Bool {
    hasLocallyCopied || feedback == .copied
  }

  private var isDictionaryState: Bool {
    if case .dictionaryAdded = feedback { return true }
    return false
  }

  private var pillTitle: String {
    if isCopiedState {
      return "Copied to clipboard"
    }
    switch feedback {
    case .dictionaryAdded:
      return "Added to Dictionary"
    case let .pasteUnavailable(_, reason):
      switch reason {
      case .noFocusedInput:
        return "No input focused"
      case .insertionRejected:
        return "Paste rejected by app"
      }
    default:
      return "No input focused"
    }
  }

  private var pillDetail: String {
    if isCopiedState {
      return "Ready to paste anywhere"
    }
    switch feedback {
    case let .dictionaryAdded(match, replacement):
      return "\u{201c}\(match)\u{201d} → \u{201c}\(replacement)\u{201d}"
    case .pasteUnavailable:
      return "Click to copy transcript"
    default:
      return ""
    }
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 0.04)) { context in
      let elapsed = context.date.timeIntervalSince(startedAt)
      let progress = max(0, min(1, 1 - elapsed / max(duration, 0.1)))

      // The whole pill is one tappable surface: any click copies when copyable.
      Button(action: {
        if case .pasteUnavailable = feedback {
          withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
            hasLocallyCopied = true
          }
          onCopy()
        }
      }) {
        VStack(spacing: 0) {
          HStack(spacing: 10) {
            // Leading status icon glyph
            ZStack {
              if isCopiedState {
                Circle()
                  .fill(Color(red: 0.20, green: 0.78, blue: 0.45).opacity(0.20))
                  .frame(width: 24, height: 24)
                Image(systemName: "checkmark")
                  .font(.system(size: 11, weight: .bold))
                  .foregroundStyle(Color(red: 0.20, green: 0.78, blue: 0.45))
              } else if isDictionaryState {
                Circle()
                  .fill(TickColor.brand.opacity(0.22))
                  .frame(width: 24, height: 24)
                  .overlay(
                    Circle()
                      .strokeBorder(TickColor.brandMid.opacity(0.3), lineWidth: 0.5)
                  )
                Image(systemName: "character.book.closed.fill")
                  .font(.system(size: 11.5, weight: .medium))
                  .foregroundStyle(TickColor.brandMid)
              } else {
                Circle()
                  .fill(Color.white.opacity(0.10))
                  .frame(width: 24, height: 24)
                  .overlay(
                    Circle()
                      .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                  )
                Image(systemName: "character.cursor.ibeam")
                  .font(.system(size: 11.5, weight: .medium))
                  .foregroundStyle(Color.white.opacity(0.90))
              }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isCopiedState)

            // Clean text hierarchy
            VStack(alignment: .leading, spacing: 1) {
              Text(pillTitle)
                .font(TickFont.labelFunc(12, weight: (isCopiedState || isDictionaryState) ? .semibold : .medium))
                .foregroundStyle(Color.white.opacity(0.95))
                .lineLimit(1)
              Text(pillDetail)
                .font(TickFont.captionFunc(10, weight: .regular))
                .foregroundStyle(
                  isCopiedState
                    ? Color(red: 0.20, green: 0.78, blue: 0.45).opacity(0.90)
                    : (isDictionaryState ? Color.white.opacity(0.70) : Color.white.opacity(0.55))
                )
                .lineLimit(1)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isCopiedState)

            Spacer(minLength: 8)

            // Trailing action affordance
            if isCopiedState {
              HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                  .font(.system(size: 10, weight: .bold))
                Text("Copied")
                  .font(TickFont.labelFunc(11, weight: .semibold))
              }
              .foregroundStyle(Color(red: 0.20, green: 0.78, blue: 0.45))
              .padding(.horizontal, 9)
              .padding(.vertical, 4.5)
              .background(
                Capsule()
                  .fill(Color(red: 0.20, green: 0.78, blue: 0.45).opacity(0.15))
              )
              .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if isDictionaryState {
              HStack(spacing: 4) {
                Image(systemName: "checkmark")
                  .font(.system(size: 9.5, weight: .bold))
                Text("Learned")
                  .font(TickFont.labelFunc(11, weight: .semibold))
              }
              .foregroundStyle(TickColor.brandMid)
              .padding(.horizontal, 9)
              .padding(.vertical, 4.5)
              .background(
                Capsule()
                  .fill(TickColor.brand.opacity(0.20))
                  .overlay(
                    Capsule()
                      .strokeBorder(TickColor.brandMid.opacity(0.25), lineWidth: 0.5)
                  )
              )
              .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
              HStack(spacing: 4.5) {
                Image(systemName: "doc.on.doc")
                  .font(.system(size: 9.5, weight: .semibold))
                Text("Copy")
                  .font(TickFont.labelFunc(11, weight: .semibold))
              }
              .foregroundStyle(Color.white.opacity(isCopyHovered ? 1.0 : 0.90))
              .padding(.horizontal, 9)
              .padding(.vertical, 4.5)
              .background(
                Capsule()
                  .fill(Color.white.opacity(isCopyHovered ? 0.20 : 0.12))
                  .overlay(
                    Capsule()
                      .strokeBorder(Color.white.opacity(isCopyHovered ? 0.25 : 0.12), lineWidth: 0.5)
                  )
              )
              .onHover { hovered in
                withAnimation(.easeOut(duration: 0.12)) {
                  isCopyHovered = hovered
                }
              }
              .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
          }
          .padding(.horizontal, 12)
          .padding(.top, 7)
          .padding(.bottom, 5)

          // Hairline countdown progress bar
          GeometryReader { proxy in
            let trackWidth = proxy.size.width
            ZStack(alignment: .leading) {
              Capsule()
                .fill(Color.white.opacity(0.06))

              Capsule()
                .fill(
                  LinearGradient(
                    colors: isCopiedState
                      ? [Color(red: 0.20, green: 0.78, blue: 0.45).opacity(0.90), Color(red: 0.20, green: 0.78, blue: 0.45).opacity(0.45)]
                      : (isDictionaryState
                          ? [TickColor.brandMid.opacity(0.95), TickColor.brand.opacity(0.70)]
                          : [TickColor.brandMid.opacity(0.90), TickColor.brand.opacity(0.60)]),
                    startPoint: .leading,
                    endPoint: .trailing
                  )
                )
                .frame(width: max(0, trackWidth * progress))
                .animation(.linear(duration: 0.04), value: progress)
            }
          }
          .frame(height: 1.5)
          .padding(.horizontal, 14)
          .padding(.bottom, 3)
        }
        .frame(width: FloatingCopyLayout.pillSize.width, height: FloatingCopyLayout.pillSize.height)
        .background(
          Capsule()
            .fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.94))
            .overlay(
              Capsule()
                .strokeBorder(
                  LinearGradient(
                    stops: [
                      .init(color: Color.white.opacity(0.24), location: 0.0),
                      .init(color: Color.white.opacity(0.10), location: 0.4),
                      .init(color: Color.white.opacity(0.04), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                  ),
                  lineWidth: 1
                )
            )
            .shadow(color: Color.black.opacity(0.32), radius: 14, x: 0, y: 4)
        )
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isDictionaryState ? "Added word to dictionary" : "Copy transcription to clipboard")
    }
  }
}

// MARK: - Idle Dot
//
// A single small dot for the optionKeyPressed / prewarming states.

struct IdleDot: View {
  let color: Color
  @State private var isPulsing = false

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 5, height: 5)
      .scaleEffect(isPulsing ? 1.0 : 0.7)
      .opacity(isPulsing ? 1.0 : 0.4)
      .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
      .onAppear { isPulsing = true }
  }
}

// MARK: - Three Dots Indicator
//
// A pulsing 3-dot indicator for lock mode recording.

struct ThreeDotsIndicator: View {
  @State private var activeDotIndex = 0
  private let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

  var body: some View {
    HStack(spacing: 3) {
      ForEach(0..<3) { index in
        Circle()
          .fill(Color.white)
          .frame(width: 4, height: 4)
          .opacity(activeDotIndex == index ? 1.0 : 0.4)
      }
    }
    .onReceive(timer) { _ in
      withAnimation(.easeInOut(duration: 0.25)) {
        activeDotIndex = (activeDotIndex + 1) % 3
      }
    }
  }
}

// MARK: - Notch Waveform
//
// Four small white bars that react to the live audio meter in real time.
// When audio is loud, the bars grow; when quiet, they shrink. A fast
// attack / slow release on each bar gives it the feel of a real audio
// meter rather than a flat/static display.

struct NotchWaveform: View {
  let meter: Meter
  let color: Color
  var isTranscribing: Bool = false

  private let barCount = 4
  private let barWidth: CGFloat = 2.0
  private let barSpacing: CGFloat = 2.5
  private let maxBarHeight: CGFloat = 14
  private let minBarHeight: CGFloat = 3
  
  // Specific multipliers for each of the 4 bars to form a natural vocal shape
  private let barMultipliers: [Double] = [0.5, 1.0, 0.8, 0.4]

  // Spectrum colors for recording (vibrant Apple-Intelligence-style warmth)
  private let recordingColors: [Color] = [
    Color(red: 0.486, green: 0.227, blue: 0.929), // Brand violet (#7c3aed)
    Color(red: 0.843, green: 0.176, blue: 0.612), // Magenta / purple
    Color(red: 0.941, green: 0.302, blue: 0.302), // Vibrant coral / red
    Color(red: 0.961, green: 0.565, blue: 0.239)  // Sunset orange
  ]

  // Spectrum colors for transcribing (teal -> indigo -> violet cool spectrum)
  private let transcribingColors: [Color] = [
    Color(red: 0.180, green: 0.620, blue: 0.620), // Teal (#2e9e9e)
    Color(red: 0.141, green: 0.478, blue: 0.843), // Blue (#247ad7)
    Color(red: 0.478, green: 0.298, blue: 0.898), // Indigo (#7a4ce5)
    Color(red: 0.706, green: 0.557, blue: 0.969)  // Light violet (#b48ef7)
  ]

  private func barColor(for index: Int) -> Color {
    let colors = isTranscribing ? transcribingColors : recordingColors
    return colors[index % colors.count]
  }
  
  @State private var smoothedLevels: [Double] = []
  @State private var phase: Double = 0

  private let timer = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()

  var body: some View {
    HStack(spacing: barSpacing) {
      ForEach(0..<barCount, id: \.self) { index in
        Capsule()
          .fill(barColor(for: index))
          .frame(width: barWidth, height: barHeight(for: index))
      }
    }
    .onAppear { ensureLevels() }
    .onChange(of: meter) { _, newMeter in
      if !isTranscribing {
        updateLevels(for: newMeter)
      }
    }
    .onReceive(timer) { _ in
      if isTranscribing {
        phase += 0.15
      }
    }
    .animation(.linear(duration: 0.05), value: smoothedLevels)
    .animation(.linear(duration: 0.05), value: phase)
  }

  private func ensureLevels() {
    if smoothedLevels.count != barCount {
      smoothedLevels = Array(repeating: 0, count: barCount)
    }
  }

  private func updateLevels(for newMeter: Meter) {
    ensureLevels()
    
    // Decibel/amplitude scaling for vocal frequencies
    // Typically, room noise is below 0.002. Voice signals range from 0.005 to 0.12.
    let noiseFloor: Double = 0.002
    let maxHeadroom: Double = 0.12 // Lower limit so normal speaking registers high
    
    let avgNormalized = (newMeter.averagePower - noiseFloor) / (maxHeadroom - noiseFloor)
    let average = min(1.0, max(0.0, avgNormalized))
    
    let peakNormalized = (newMeter.peakPower - noiseFloor) / (maxHeadroom - noiseFloor)
    let peak = min(1.0, max(0.0, peakNormalized))
    
    // Apply power-law curve to boost low-mid volumes for organic responsiveness
    let curveAverage = pow(average, 0.7)
    let curvePeak = pow(peak, 0.7)

    var newLevels = smoothedLevels
    for i in 0..<barCount {
      let multiplier = barMultipliers[i]
      let target = curveAverage * multiplier
      let peakBoost = curvePeak > target + 0.1 ? (curvePeak - target) * 0.5 * multiplier : 0
      let newValue = max(target, peakBoost)

      // Fast snappy attack, smooth natural release
      let prev = newLevels[i]
      let smoothed = newValue > prev
        ? newValue // instant snappy attack
        : max(newValue, prev * 0.85) // smooth, elegant release (decay)
      newLevels[i] = smoothed
    }
    smoothedLevels = newLevels
  }

  private func barHeight(for index: Int) -> CGFloat {
    if isTranscribing {
      let offset = Double(index) * 0.5
      let val = sin(phase + offset) * 0.5 + 0.5
      return minBarHeight + val * (maxBarHeight - minBarHeight)
    } else {
      let level = index < smoothedLevels.count ? smoothedLevels[index] : 0
      let t = CGFloat(level)
      return minBarHeight + t * (maxBarHeight - minBarHeight)
    }
  }
}

#Preview("Notch Indicator") {
  VStack(spacing: 24) {
    TranscriptionIndicatorView(
      status: .optionKeyPressed,
      isLocked: false,
      meter: Meter(averagePower: 0, peakPower: 0)
    )
    TranscriptionIndicatorView(
      status: .recording,
      isLocked: false,
      meter: Meter(averagePower: 0.5, peakPower: 0.7)
    )
    TranscriptionIndicatorView(
      status: .recording,
      isLocked: true,
      meter: Meter(averagePower: 0.5, peakPower: 0.7),
      sourceAppName: "OpenSpotify"
    )
    TranscriptionIndicatorView(
      status: .transcribing,
      isLocked: false,
      meter: Meter(averagePower: 0.2, peakPower: 0.3)
    )
  }
  .padding(40)
  .background(Color.gray)
}

#Preview("Floating Copy Pill") {
  VStack(spacing: 30) {
    FloatingCopyPillView(
      feedback: .pasteUnavailable(text: "Hello world transcript", reason: .noFocusedInput),
      startedAt: Date(),
      duration: 4.0,
      onCopy: {}
    )
    FloatingCopyPillView(
      feedback: .pasteUnavailable(text: "Hello world transcript", reason: .insertionRejected),
      startedAt: Date(),
      duration: 4.0,
      onCopy: {}
    )
    FloatingCopyPillView(
      feedback: .dictionaryAdded(match: "teh", replacement: "the"),
      startedAt: Date(),
      duration: 4.0,
      onCopy: {}
    )
    FloatingCopyPillView(
      feedback: .copied,
      startedAt: Date(),
      duration: 1.8,
      onCopy: {}
    )
  }
  .padding(40)
  .background(Color(white: 0.15))
}
