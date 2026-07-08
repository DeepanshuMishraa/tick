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

  enum ToolCallUIStatus: Equatable {
    case executing
    case completed
    case failed
  }

  enum Status: Equatable {
    case hidden
    case optionKeyPressed
    case recording
    case autonomousRecording
    case transcribing
    case autonomousTranscribing
    case prewarming
    case toolCalling(name: String, phase: ToolCallUIStatus)
    case autonomous
  }

  var status: Status
  var isLocked: Bool
  var meter: Meter
  var sourceAppBundleID: String? = nil
  var sourceAppName: String? = nil
  var toolCallMessage: String = ""

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

  var body: some View {
    let targetHeight: CGFloat = {
      if case .toolCalling = status {
        return geometry.notchHeight + 60
      }
      if case .autonomous = status {
        return geometry.notchHeight
      }
      return isLocked ? (geometry.notchHeight + 30) : geometry.notchHeight
    }()
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
        // Check if tool calling (expanded notch with message)
        if case .toolCalling(let toolName, let phase) = status {
          VStack(spacing: 4) {
            // Top row: tool icon + tool name + status indicator
            HStack(spacing: 0) {
              // Left side: tool icon
              Group {
                ToolCallIcon(phase: phase)
              }
              .frame(width: extensionWidth, alignment: .center)
              
              Spacer() // Covers the notch width
              
              // Right side: status indicator
              Group {
                switch phase {
                case .executing:
                  DotMatrixLoader()
                    .frame(width: 24, height: 12)
                case .completed:
                  Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.green)
                case .failed:
                  Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.red)
                }
              }
              .frame(width: extensionWidth, alignment: .center)
            }
            .frame(width: geometry.notchWidth + extensionWidth * 2, height: geometry.notchHeight)
            
            // Bottom row: tool call message
            Text(toolCallMessage.isEmpty ? toolName : toolCallMessage)
              .font(TickFont.bodyFunc(11))
              .foregroundColor(.white.opacity(0.9))
              .lineLimit(2)
              .multilineTextAlignment(.center)
              .frame(maxWidth: geometry.notchWidth + extensionWidth, alignment: .center)
          }
        } else {
          HStack(spacing: 0) {
            Group {
              switch status {
              case .hidden:
                EmptyView()
              case .optionKeyPressed, .prewarming:
                IdleDot(color: TickColor.brandMid.opacity(0.8))
              case .recording:
                NotchWaveform(meter: meter, color: .white)
              case .autonomousRecording:
                NotchWaveform(meter: meter, color: TickColor.brandMid, isAutonomous: true)
              case .transcribing:
                NotchWaveform(meter: meter, color: .white, isTranscribing: true)
              case .autonomousTranscribing:
                NotchWaveform(meter: meter, color: TickColor.brandMid, isTranscribing: true, isAutonomous: true)
              case .toolCalling:
                EmptyView()
              case .autonomous:
                AutonomousIcon()
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
        }
        
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
    }
    .onChange(of: status) {
      updateGeometry()
    }
    .enableInjection()
  }

  private var isActive: Bool {
    status != .hidden
  }

  private func updateGeometry() {
    geometry = getNotchGeometry()
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
  var isAutonomous: Bool = false

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
    if isAutonomous {
      let colors: [Color] = [
        TickColor.brandMid,
        TickColor.brandMid.opacity(0.85),
        TickColor.brandMid.opacity(0.65),
        TickColor.brandMid.opacity(0.9)
      ]
      return colors[index % colors.count]
    }
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

#Preview {
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

// MARK: - Tool Call Icon

struct ToolCallIcon: View {
  let phase: TranscriptionIndicatorView.ToolCallUIStatus

  var body: some View {
    Image(systemName: iconName)
      .font(.system(size: 14, weight: .semibold))
      .foregroundColor(iconColor)
      .shadow(color: iconColor.opacity(0.4), radius: 2, x: 0, y: 0)
  }

  private var iconName: String {
    switch phase {
    case .executing: return "wand.and.stars"
    case .completed: return "checkmark.circle.fill"
    case .failed: return "xmark.circle.fill"
    }
  }

  private var iconColor: Color {
    switch phase {
    case .executing: return TickColor.brandMid
    case .completed: return .green
    case .failed: return .red
    }
  }
}

// MARK: - Dot Matrix Loader

struct DotMatrixLoader: View {
  @State private var phase: Double = 0
  private let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()
  private let dotCount = 5

  var body: some View {
    HStack(spacing: 3) {
      ForEach(0..<dotCount, id: \.self) { index in
        Circle()
          .fill(Color.white)
          .frame(width: 4, height: 4)
          .opacity(opacity(for: index))
          .scaleEffect(scale(for: index))
      }
    }
    .onReceive(timer) { _ in
      withAnimation(.easeInOut(duration: 0.15)) {
        phase += 0.25
      }
    }
  }

  private func opacity(for index: Int) -> CGFloat {
    let normalized = sin(phase + Double(index) * 1.2)
    return CGFloat(max(0.2, (normalized + 1) / 2))
  }

  private func scale(for index: Int) -> CGFloat {
    let normalized = sin(phase + Double(index) * 1.2)
    return CGFloat(max(0.5, (normalized + 1) / 2))
  }
}

// MARK: - Autonomous Icon

struct AutonomousIcon: View {
  @State private var isAnimating = false

  var body: some View {
    Image(systemName: "wand.and.stars")
      .font(.system(size: 12, weight: .semibold))
      .foregroundColor(TickColor.brandMid)
      .opacity(isAnimating ? 1.0 : 0.5)
      .scaleEffect(isAnimating ? 1.0 : 0.85)
      .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isAnimating)
      .onAppear { isAnimating = true }
  }
}
