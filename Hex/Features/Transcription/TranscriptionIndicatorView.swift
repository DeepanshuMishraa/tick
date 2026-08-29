import ComposableArchitecture
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

// MARK: - Liquid Notch Shape (Filled body attached to top screen bezel)

struct LiquidNotchShape: Shape {
  var shoulderWidth: CGFloat = 16
  var cornerRadius: CGFloat = 18

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let w = rect.width
    let h = rect.height
    guard w > 0, h > 0 else { return path }

    let sw = min(shoulderWidth, w / 4, h)
    let cr = min(cornerRadius, (w - 2 * sw) / 2, h)

    // Top-left at (0, 0)
    path.move(to: CGPoint(x: 0, y: 0))

    // Smooth concave shoulder flare from (0,0) down to (sw, sw)
    path.addCurve(
      to: CGPoint(x: sw, y: sw),
      control1: CGPoint(x: sw * 0.45, y: 0),
      control2: CGPoint(x: sw, y: sw * 0.45)
    )

    // Left edge down to (sw, h - cr)
    path.addLine(to: CGPoint(x: sw, y: h - cr))

    // Bottom-left convex corner to (sw + cr, h)
    path.addCurve(
      to: CGPoint(x: sw + cr, y: h),
      control1: CGPoint(x: sw, y: h - cr * 0.45),
      control2: CGPoint(x: sw + cr * 0.45, y: h)
    )

    // Bottom edge to (w - sw - cr, h)
    path.addLine(to: CGPoint(x: w - sw - cr, y: h))

    // Bottom-right convex corner to (w - sw, h - cr)
    path.addCurve(
      to: CGPoint(x: w - sw, y: h - cr),
      control1: CGPoint(x: w - sw - cr * 0.45, y: h),
      control2: CGPoint(x: w - sw, y: h - cr * 0.45)
    )

    // Right edge up to (w - sw, sw)
    path.addLine(to: CGPoint(x: w - sw, y: sw))

    // Smooth concave shoulder flare from (w - sw, sw) up to (w, 0)
    path.addCurve(
      to: CGPoint(x: w, y: 0),
      control1: CGPoint(x: w - sw, y: sw * 0.45),
      control2: CGPoint(x: w - sw * 0.45, y: 0)
    )

    // Close top along screen bezel
    path.closeSubpath()
    return path
  }
}

// MARK: - Liquid Notch Outline Shape (Exposed perimeter only, NO top bezel stroke)

struct LiquidNotchOutlineShape: Shape {
  var shoulderWidth: CGFloat = 16
  var cornerRadius: CGFloat = 18

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let w = rect.width
    let h = rect.height
    guard w > 0, h > 0 else { return path }

    let sw = min(shoulderWidth, w / 4, h)
    let cr = min(cornerRadius, (w - 2 * sw) / 2, h)

    // Start at top-left shoulder (0, 0)
    path.move(to: CGPoint(x: 0, y: 0))

    // Shoulder flare from (0,0) down to (sw, sw)
    path.addCurve(
      to: CGPoint(x: sw, y: sw),
      control1: CGPoint(x: sw * 0.45, y: 0),
      control2: CGPoint(x: sw, y: sw * 0.45)
    )

    // Left vertical edge down to (sw, h - cr)
    path.addLine(to: CGPoint(x: sw, y: h - cr))

    // Bottom-left rounded corner to (sw + cr, h)
    path.addCurve(
      to: CGPoint(x: sw + cr, y: h),
      control1: CGPoint(x: sw, y: h - cr * 0.45),
      control2: CGPoint(x: sw + cr * 0.45, y: h)
    )

    // Bottom horizontal edge to (w - sw - cr, h)
    path.addLine(to: CGPoint(x: w - sw - cr, y: h))

    // Bottom-right rounded corner to (w - sw, h - cr)
    path.addCurve(
      to: CGPoint(x: w - sw, y: h - cr),
      control1: CGPoint(x: w - sw - cr * 0.45, y: h),
      control2: CGPoint(x: w - sw, y: h - cr * 0.45)
    )

    // Right vertical edge up to (w - sw, sw)
    path.addLine(to: CGPoint(x: w - sw, y: sw))

    // Shoulder flare from (w - sw, sw) up to (w, 0)
    path.addCurve(
      to: CGPoint(x: w, y: 0),
      control1: CGPoint(x: w - sw, y: sw * 0.45),
      control2: CGPoint(x: w - sw * 0.45, y: 0)
    )

    // Open path: does NOT stroke the top bezel edge
    return path
  }
}

struct TranscriptionIndicatorView: View {
  @ObserveInjection var inject
  @Shared(.hexSettings) private var hexSettings: HexSettings

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
  private let extensionWidth: CGFloat = 52
  private let maxBarHeight: CGFloat = 16
  private let minBarHeight: CGFloat = 4

  @State private var geometry = NotchGeometry(hasNotch: false, notchWidth: 120, notchHeight: 32, menuBarHeight: 24)
  @State private var feedbackStartedAt = Date()

  var body: some View {
    let baseNotchHeight = max(geometry.notchHeight + 14, 48)
    let targetHeight = isLocked ? (baseNotchHeight + 32) : baseNotchHeight
    let totalWidth = geometry.notchWidth + extensionWidth * 2

    ZStack(alignment: .top) {
      let notchShape = LiquidNotchShape(shoulderWidth: 16, cornerRadius: 18)
      let outlineShape = LiquidNotchOutlineShape(shoulderWidth: 16, cornerRadius: 18)
      let theme = hexSettings.themeColor

      if isActive {
        // Pure Dark Liquid Glass body with dynamic theme reflection
        ZStack {
          if #available(macOS 26.0, *) {
            switch theme {
            case .monochrome:
              notchShape
                .fill(Color.black.opacity(0.65))
                .glassEffect(.regular, in: notchShape)
            case .multicolor:
              notchShape
                .fill(
                  LinearGradient(
                    colors: [
                      Color.black.opacity(0.65),
                      Color.cyan.opacity(0.14),
                      Color.purple.opacity(0.12),
                      Color.pink.opacity(0.10),
                      Color.black.opacity(0.65)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                  )
                )
                .glassEffect(.regular.tint(Color.cyan.opacity(0.06)), in: notchShape)
            default:
              notchShape
                .fill(
                  LinearGradient(
                    colors: [
                      Color.black.opacity(0.65),
                      theme.swatchColor.opacity(0.18),
                      Color.black.opacity(0.70)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                  )
                )
                .glassEffect(.regular.tint(theme.swatchColor.opacity(0.08)), in: notchShape)
            }
          } else {
            let fallbackFill: Color = theme == .monochrome ? Color.black.opacity(0.75) : theme.swatchColor.opacity(0.15)
            notchShape
              .fill(fallbackFill)
              .background(notchShape.fill(.ultraThinMaterial))
          }
        }
        .clipShape(notchShape)
        .overlay(
          outlineShape
            .stroke(
              LinearGradient(
                stops: {
                  switch theme {
                  case .monochrome:
                    return [
                      .init(color: Color.white.opacity(0.24), location: 0.0),
                      .init(color: Color.white.opacity(0.08), location: 0.35),
                      .init(color: Color.white.opacity(0.18), location: 0.75),
                      .init(color: Color.white.opacity(0.28), location: 1.0)
                    ]
                  case .multicolor:
                    return [
                      .init(color: Color.white.opacity(0.40), location: 0.0),
                      .init(color: Color.cyan.opacity(0.40), location: 0.25),
                      .init(color: Color.purple.opacity(0.35), location: 0.60),
                      .init(color: Color.pink.opacity(0.35), location: 1.0)
                    ]
                  default:
                    return [
                      .init(color: Color.white.opacity(0.35), location: 0.0),
                      .init(color: theme.swatchColor.opacity(0.45), location: 0.25),
                      .init(color: Color.white.opacity(0.08), location: 0.60),
                      .init(color: theme.swatchColor.opacity(0.35), location: 1.0)
                    ]
                  }
                }(),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              ),
              lineWidth: 0.5
            )
        )
        .shadow(color: Color.black.opacity(0.30), radius: 10, x: 0, y: 5)
        .frame(width: totalWidth, height: targetHeight)
      }
      
      if isActive {
        HStack(spacing: 0) {
          // Left side: live audio waveform or idle dot
          Group {
            switch status {
            case .hidden:
              EmptyView()
            case .optionKeyPressed, .prewarming:
              IdleDot(color: Color.white.opacity(0.85))
            case .recording:
              NotchWaveform(meter: meter, color: .white)
            case .transcribing:
              NotchWaveform(meter: meter, color: .white, isTranscribing: true)
            }
          }
          .frame(width: extensionWidth, alignment: .center)
          .padding(.leading, 8)
          
          Spacer() // Covers the notch width
          
          // Right side: Active application icon
          Group {
            if let icon = appIcon {
              Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .cornerRadius(5)
                .shadow(color: .black.opacity(0.40), radius: 2.5, x: 0, y: 1)
            } else {
              Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.25))
                .cornerRadius(5)
                .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
            }
          }
          .frame(width: extensionWidth, alignment: .center)
          .padding(.trailing, 8)
        }
        .frame(width: totalWidth, height: baseNotchHeight)
        .padding(.top, 0)
        
        // Bottom row: centered app icon + app name (only shown in lock mode)
        if isLocked {
          HStack(spacing: 6) {
            if let icon = appIcon {
              Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 15, height: 15)
                .cornerRadius(3.5)
                .shadow(color: .black.opacity(0.3), radius: 1.5, x: 0, y: 1)
            } else {
              Image(systemName: "mic.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 15, height: 15)
                .background(Color.primary.opacity(0.25))
                .cornerRadius(3.5)
                .shadow(color: Color.black.opacity(0.3), radius: 1.5, x: 0, y: 1)
            }
            
            Text(sourceAppName ?? "Listening...")
              .font(TickFont.bodyFunc(11, weight: .medium))
              .foregroundColor(.white.opacity(0.95))
              .lineLimit(1)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 4)
          .hexGlass(in: Capsule(), style: .regular)
          .frame(width: totalWidth, height: 32)
          .padding(.top, baseNotchHeight)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      }
    }
    .frame(width: totalWidth, height: targetHeight)
    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isActive)
    .animation(.spring(response: 0.35, dampingFraction: 0.78), value: isLocked)
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
  /// The visible pill dimensions.
  static let pillSize = CGSize(width: 340, height: 46)
  /// Distance from the bottom edge of the screen to the bottom of the pill.
  static let bottomMargin: CGFloat = 36
  /// Padding around the pill inside the hosting window to allow soft shadows to decay naturally without clipping.
  static let shadowPadding: CGFloat = 20

  /// Total hosting window size.
  static let windowSize = CGSize(
    width: pillSize.width + shadowPadding * 2,
    height: pillSize.height + shadowPadding * 2
  )

  /// The panel's rect on a given screen (AppKit coordinates, origin bottom-left).
  static func pillFrame(onScreen screenFrame: NSRect) -> NSRect {
    NSRect(
      x: screenFrame.midX - windowSize.width / 2,
      y: screenFrame.minY + bottomMargin - shadowPadding,
      width: windowSize.width,
      height: windowSize.height
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
    case let .dictionaryAdded(match, _):
      return "\(match) is turned to"
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
    case let .dictionaryAdded(_, replacement):
      return "\u{201c}\(replacement)\u{201d}"
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

      ZStack {
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
                  .fill(.clear)
                  .frame(width: 24, height: 24)
                  .hexGlass(in: Circle())
                Image(systemName: "checkmark")
                  .font(.system(size: 11, weight: .bold))
                  .foregroundStyle(Color(red: 0.20, green: 0.78, blue: 0.45))
              } else if isDictionaryState {
                Circle()
                  .fill(.clear)
                  .frame(width: 24, height: 24)
                  .hexGlass(in: Circle())
                  .overlay(
                    Circle()
                      .strokeBorder(TickColor.brandMid.opacity(0.3), lineWidth: 0.5)
                  )
                Image(systemName: "character.book.closed.fill")
                  .font(.system(size: 11.5, weight: .medium))
                  .foregroundStyle(TickColor.brandMid)
              } else {
                Circle()
                  .fill(.clear)
                  .frame(width: 24, height: 24)
                  .hexGlass(in: Circle())
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
              .hexGlass(in: Capsule(), interactive: true)
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
              .hexGlass(in: Capsule(), interactive: true)
              .overlay(Capsule().strokeBorder(TickColor.brandMid.opacity(0.25), lineWidth: 0.5))
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
              .hexGlass(in: Capsule(), interactive: true)
              .overlay(Capsule().strokeBorder(Color.white.opacity(isCopyHovered ? 0.25 : 0.12), lineWidth: 0.5))
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
                      : [TickColor.brand.opacity(0.95), TickColor.brand.opacity(0.50)],
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
        .hexGlass(in: Capsule(), interactive: true)
        .shadow(color: Color.black.opacity(0.28), radius: 10, x: 0, y: 3)
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isDictionaryState ? "Added word to dictionary" : "Copy transcription to clipboard")
    }
    .frame(width: FloatingCopyLayout.windowSize.width, height: FloatingCopyLayout.windowSize.height)
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
  @Shared(.hexSettings) private var hexSettings: HexSettings
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

  // Spectrum colors for recording (vibrant modern liquid spectrum)
  private let recordingColors: [Color] = [
    Color(red: 0.180, green: 0.800, blue: 0.700), // Luminous teal
    Color(red: 0.200, green: 0.550, blue: 0.950), // Electric cyan-blue
    Color(red: 0.380, green: 0.420, blue: 0.950), // Royal indigo
    Color(red: 0.900, green: 0.920, blue: 1.000)  // Crisp crystal white
  ]

  // Spectrum colors for transcribing (teal -> cyan -> indigo -> ice)
  private let transcribingColors: [Color] = [
    Color(red: 0.180, green: 0.700, blue: 0.700), // Teal
    Color(red: 0.141, green: 0.500, blue: 0.900), // Blue
    Color(red: 0.350, green: 0.450, blue: 0.950), // Indigo
    Color(red: 0.700, green: 0.800, blue: 1.000)  // Ice blue
  ]

  private func barColor(for index: Int) -> Color {
    let theme = hexSettings.themeColor
    if theme == .monochrome {
      let colors: [Color] = [
        Color.white.opacity(0.85),
        Color.white.opacity(1.0),
        Color.white.opacity(0.90),
        Color.white.opacity(0.75)
      ]
      return colors[index % colors.count]
    }
    if theme == .multicolor {
      let colors = isTranscribing ? transcribingColors : recordingColors
      return colors[index % colors.count]
    }
    let accent = theme.swatchColor
    let colors: [Color] = [
      accent.opacity(0.85),
      Color.white.opacity(0.95),
      accent.opacity(1.0),
      accent.opacity(0.70)
    ]
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
