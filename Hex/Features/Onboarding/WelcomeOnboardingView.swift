import AppKit
import ComposableArchitecture
import Dependencies
import Foundation
import HexCore
import SwiftUI

public struct WelcomeOnboardingView: View {
  @Shared(.hexSettings) private var hexSettings: HexSettings
  @Dependency(\.permissions) private var permissions

  @State private var currentStep: Int = 0
  @State private var microphonePermission: PermissionStatus = .notDetermined
  @State private var accessibilityPermission: PermissionStatus = .notDetermined
  @State private var inputMonitoringPermission: PermissionStatus = .notDetermined

  // Entrance choreography states
  @State private var isAppeared: Bool = false
  @State private var timerTask: Task<Void, Never>? = nil

  public init() {}

  private var isAccessibilityGranted: Bool {
    accessibilityPermission == .granted && inputMonitoringPermission == .granted
  }

  private var isMicrophoneGranted: Bool {
    microphonePermission == .granted
  }

  private var canProceedFromPermissions: Bool {
    isMicrophoneGranted && isAccessibilityGranted
  }

  public var body: some View {
    ZStack {
      // Atmospheric ambient background
      ambientBackdrop

      VStack(spacing: 0) {
        // Step indicator dashes
        stepIndicator
          .padding(.top, 28)
          .padding(.bottom, 16)

        Spacer(minLength: 8)

        // Main animated presentation with clean transition
        if currentStep == 0 {
          welcomeStepView
            .transition(.asymmetric(
              insertion: .opacity.combined(with: .scale(scale: 0.97)),
              removal: .opacity.combined(with: .move(edge: .leading))
            ))
        } else {
          permissionsStepView
            .transition(.asymmetric(
              insertion: .opacity.combined(with: .move(edge: .trailing)),
              removal: .opacity.combined(with: .scale(scale: 0.97))
            ))
        }

        Spacer(minLength: 28)

        // Bottom action bar with elevated buttons
        bottomActionBar
          .padding(.horizontal, 44)
          .padding(.bottom, 36)
      }
      .frame(maxWidth: 800, maxHeight: 620)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
        isAppeared = true
      }
      refreshPermissions()
      startPermissionMonitoring()
    }
    .onDisappear {
      timerTask?.cancel()
    }
  }

  // MARK: - Ambient Backdrop

  private var ambientBackdrop: some View {
    ZStack {
      WindowThemeBackground()

      RadialGradient(
        colors: [
          TickColor.brand.opacity(0.18),
          TickColor.brand.opacity(0.04),
          Color.clear
        ],
        center: .center,
        startRadius: 40,
        endRadius: 440
      )
      .blur(radius: 60)
      .ignoresSafeArea()
    }
  }

  // MARK: - Step Indicator

  private var stepIndicator: some View {
    HStack(spacing: 8) {
      ForEach(0..<2) { index in
        Capsule()
          .fill(
            index == currentStep
              ? AnyShapeStyle(
                  LinearGradient(
                    colors: [TickColor.brand, TickColor.brand.opacity(0.80)],
                    startPoint: .leading,
                    endPoint: .trailing
                  )
                )
              : AnyShapeStyle(Color.primary.opacity(0.12))
          )
          .frame(width: index == currentStep ? 36 : 14, height: 4)
          .animation(.spring(response: 0.32, dampingFraction: 0.76), value: currentStep)
      }
    }
  }

  // MARK: - Step 0: Welcome View

  private var welcomeStepView: some View {
    VStack(spacing: 34) {
      // Clean, confident editorial typography
      VStack(spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("Welcome to")
            .font(TickFont.display(34, weight: .regular))
            .foregroundStyle(TickColor.textPrimary)
          Text("Tick.")
            .font(TickFont.displayItalic(34))
            .foregroundStyle(TickColor.brand)
        }

        Text("Super-fast, 100% on-device voice dictation for macOS.")
          .font(TickFont.bodyFunc(14, weight: .regular))
          .foregroundStyle(TickColor.textSecondary)
      }
      .opacity(isAppeared ? 1 : 0)
      .offset(y: isAppeared ? 0 : 10)
      .animation(.spring(response: 0.40, dampingFraction: 0.80), value: isAppeared)

      // 3 Fine Elevated Spatial Showcase Cards
      HStack(spacing: 16) {
        // Card 1: Global Hotkey
        ElevatedShowcaseCard(
          badge: "CAPTURE",
          title: "Global Hotkey",
          description: "Hold ⌥ Option anywhere to transcribe speech directly into active apps.",
          index: 0,
          isAppeared: isAppeared
        ) {
          HotkeyVisualWidget()
        }

        // Card 2: Smart Polish
        ElevatedShowcaseCard(
          badge: "INTELLIGENCE",
          title: "Smart Polish",
          description: "Automatically cuts verbal filler words and formats punctuation.",
          index: 1,
          isAppeared: isAppeared
        ) {
          TransformationVisualWidget()
        }

        // Card 3: 100% Private
        ElevatedShowcaseCard(
          badge: "PRIVACY",
          title: "100% Private",
          description: "Runs offline on Apple Silicon Neural Engine. 0KB sent to the cloud.",
          index: 2,
          isAppeared: isAppeared
        ) {
          SiliconChipVisualWidget()
        }
      }
      .padding(.horizontal, 28)
    }
  }

  // MARK: - Step 1: Permissions View

  private var permissionsStepView: some View {
    VStack(spacing: 22) {
      VStack(spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("Required")
            .font(TickFont.display(30, weight: .regular))
            .foregroundStyle(TickColor.textPrimary)
          Text("Permissions.")
            .font(TickFont.displayItalic(30))
            .foregroundStyle(TickColor.brand)
        }

        Text("Tick requires Microphone and Accessibility access to capture voice and type for you.")
          .font(TickFont.bodyFunc(13, weight: .regular))
          .foregroundStyle(TickColor.textSecondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
      }
      .opacity(isAppeared ? 1 : 0)
      .offset(y: isAppeared ? 0 : 8)
      .animation(.spring(response: 0.38, dampingFraction: 0.80), value: isAppeared)

      VStack(spacing: 14) {
        // Microphone Card
        ElevatedPermissionCard(
          icon: "mic.fill",
          eyebrow: "AUDIO CAPTURE",
          title: "Microphone Access",
          subtitle: "Allows audio recording while you hold your dictation hotkey.",
          isGranted: isMicrophoneGranted,
          buttonTitle: microphonePermission == .denied ? "Open Settings" : "Enable Microphone",
          action: {
            Task {
              if microphonePermission == .denied {
                await permissions.openMicrophoneSettings()
              } else {
                _ = await permissions.requestMicrophone()
                refreshPermissions()
              }
            }
          }
        )

        // Accessibility Card
        ElevatedPermissionCard(
          icon: "accessibility",
          eyebrow: "INPUT & AUTOMATION",
          title: "Accessibility & Input Monitoring",
          subtitle: "Required to detect your hotkey and insert transcriptions into active apps.",
          isGranted: isAccessibilityGranted,
          buttonTitle: (accessibilityPermission == .denied || inputMonitoringPermission == .denied) ? "Open Settings" : "Enable Accessibility",
          action: {
            Task {
              await permissions.requestAccessibility()
              _ = await permissions.requestInputMonitoring()
              refreshPermissions()
            }
          }
        )
      }
      .padding(.horizontal, 32)

      // Privacy note
      HStack(spacing: 6) {
        Image(systemName: "lock.fill")
          .font(.system(size: 10))
          .foregroundStyle(TickColor.textTertiary)

        Text("All processing stays strictly local to your Mac.")
          .font(TickFont.captionFunc(11, weight: .regular))
          .foregroundStyle(TickColor.textTertiary)
      }
      .padding(.top, 2)
    }
  }

  // MARK: - Bottom Action Bar with Elevated Buttons

  private var bottomActionBar: some View {
    Group {
      if currentStep == 0 {
        HStack {
          Spacer()
          ElevatedTactileButton(
            title: "Continue",
            icon: "arrow.right",
            isEnabled: true,
            action: {
              withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) {
                currentStep = 1
              }
            }
          )
          Spacer()
        }
      } else {
        HStack {
          Button(action: {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
              currentStep = 0
            }
          }) {
            HStack(spacing: 6) {
              Image(systemName: "arrow.left")
                .font(.system(size: 11, weight: .semibold))
              Text("Back")
                .font(TickFont.labelFunc(13, weight: .medium))
            }
            .foregroundStyle(TickColor.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .hexGlass(cornerRadius: 10, interactive: true)
          }
          .buttonStyle(.plain)

          Spacer()

          VStack(alignment: .trailing, spacing: 6) {
            ElevatedTactileButton(
              title: "Enter Tick",
              icon: "checkmark.circle.fill",
              isEnabled: canProceedFromPermissions,
              action: {
                guard canProceedFromPermissions else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                  $hexSettings.withLock {
                    $0.hasCompletedWelcomeOnboarding = true
                  }
                }
              }
            )

            if !canProceedFromPermissions {
              Text("Grant both permissions above to proceed")
                .font(TickFont.captionFunc(11, weight: .regular))
                .foregroundStyle(TickColor.textTertiary)
            }
          }
        }
      }
    }
  }

  // MARK: - Helpers & Polling

  private func refreshPermissions() {
    Task { @MainActor in
      microphonePermission = await permissions.microphoneStatus()
      accessibilityPermission = permissions.accessibilityStatus()
      inputMonitoringPermission = permissions.inputMonitoringStatus()
    }
  }

  private func startPermissionMonitoring() {
    timerTask?.cancel()
    timerTask = Task { @MainActor in
      Task {
        for await activation in permissions.observeAppActivation() {
          if case .didBecomeActive = activation {
            refreshPermissions()
          }
        }
      }

      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 500_000_000)
        refreshPermissions()
      }
    }
  }
}

// MARK: - Elevated Showcase Card (Emil Kowalski Physics & Refined Proportions)

private struct ElevatedShowcaseCard<VisualContent: View>: View {
  let badge: String
  let title: String
  let description: String
  let index: Int
  let isAppeared: Bool
  @ViewBuilder let visual: () -> VisualContent

  @State private var isHovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Top visual hero container
      ZStack {
        RoundedRectangle(cornerRadius: 10)
          .fill(
            LinearGradient(
              colors: [
                TickColor.brand.opacity(isHovered ? 0.12 : 0.06),
                Color.black.opacity(0.15)
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .frame(height: 72)
          .overlay(
            RoundedRectangle(cornerRadius: 10)
              .stroke(
                LinearGradient(
                  colors: [
                    Color.white.opacity(isHovered ? 0.30 : 0.14),
                    TickColor.brand.opacity(isHovered ? 0.25 : 0.06)
                  ],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
              )
          )

        visual()
      }
      .padding(.top, 2)

      // Category badge
      HStack {
        Text(badge)
          .font(TickFont.mono(9, weight: .medium))
          .tracking(0.6)
          .foregroundStyle(isHovered ? TickColor.brand : TickColor.textTertiary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(TickColor.brand.opacity(isHovered ? 0.12 : 0.06))
          .cornerRadius(4)

        Spacer()
      }

      // Title & Text
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(TickFont.headingFunc(14, weight: .semibold))
          .foregroundStyle(TickColor.textPrimary)

        Text(description)
          .font(TickFont.bodyFunc(11.5, weight: .regular))
          .foregroundStyle(TickColor.textSecondary)
          .lineSpacing(2)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 215, alignment: .topLeading)
    .background(
      ZStack {
        // Deep liquid glass substrate
        RoundedRectangle(cornerRadius: 16)
          .fill(
            LinearGradient(
              colors: [
                Color.white.opacity(isHovered ? 0.08 : 0.04),
                Color.black.opacity(0.18)
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )

        // Top edge specular bevel highlight
        VStack {
          LinearGradient(
            colors: [Color.white.opacity(isHovered ? 0.45 : 0.25), Color.clear],
            startPoint: .top,
            endPoint: .bottom
          )
          .frame(height: 1.5)
          Spacer()
        }
      }
    )
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .overlay(
      RoundedRectangle(cornerRadius: 16)
        .stroke(
          LinearGradient(
            colors: isHovered
              ? [TickColor.brand.opacity(0.60), Color.white.opacity(0.20), TickColor.brand.opacity(0.25)]
              : [Color.white.opacity(0.24), Color.white.opacity(0.06)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          lineWidth: isHovered ? 1.0 : 0.75
        )
    )
    .hexGlass(cornerRadius: 16, style: .regular)
    // Tactile multi-layer elevation shadows
    .shadow(color: Color.black.opacity(0.28), radius: isHovered ? 12 : 6, x: 0, y: isHovered ? 6 : 3)
    .shadow(color: isHovered ? TickColor.brand.opacity(0.22) : Color.clear, radius: 14, x: 0, y: 4)
    // Smooth physical hover lift and scale
    .offset(y: isAppeared ? (isHovered ? -3 : 0) : 16)
    .scaleEffect(isAppeared ? (isHovered ? 1.015 : 1.0) : 0.95)
    .opacity(isAppeared ? 1 : 0)
    .animation(
      .spring(response: 0.38, dampingFraction: 0.76).delay(0.06 + Double(index) * 0.06),
      value: isAppeared
    )
    .animation(.spring(response: 0.28, dampingFraction: 0.74), value: isHovered)
    .onHover { isHovered = $0 }
  }
}

// MARK: - Visual Showcase Widgets (Rich Tactile Micro-Graphics)

private struct HotkeyVisualWidget: View {
  @State private var wavePhase: Double = 0.0

  var body: some View {
    HStack(spacing: 8) {
      // 3D Keycap
      ZStack {
        RoundedRectangle(cornerRadius: 6)
          .fill(
            LinearGradient(
              colors: [Color.white.opacity(0.16), Color.white.opacity(0.06)],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .frame(width: 32, height: 28)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
          )
          .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1.5)

        Text("⌥")
          .font(TickFont.mono(14, weight: .bold))
          .foregroundStyle(TickColor.textPrimary)
      }

      Text("+")
        .font(TickFont.mono(12, weight: .medium))
        .foregroundStyle(TickColor.textTertiary)

      // Mini Waveform
      HStack(spacing: 2.5) {
        ForEach(0..<4) { i in
          let h: CGFloat = 6.0 + CGFloat(sin(wavePhase + Double(i) * 0.9) * 0.5 + 0.5) * 12.0
          RoundedRectangle(cornerRadius: 1)
            .fill(TickColor.brand)
            .frame(width: 2.5, height: h)
        }
      }
      .frame(width: 24, height: 24)
    }
    .onAppear {
      withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
        wavePhase = .pi * 2
      }
    }
  }
}

private struct TransformationVisualWidget: View {
  var body: some View {
    VStack(spacing: 4) {
      HStack(spacing: 5) {
        Text("um, let's ship...")
          .font(TickFont.mono(10, weight: .regular))
          .foregroundStyle(TickColor.textTertiary)
          .strikethrough(color: TickColor.error.opacity(0.6))

        Image(systemName: "arrow.right")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(TickColor.brand)
      }

      HStack(spacing: 4) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 9))
          .foregroundStyle(TickColor.brand)

        Text("Let's ship.")
          .font(TickFont.mono(11, weight: .semibold))
          .foregroundStyle(TickColor.textPrimary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(TickColor.brand.opacity(0.12))
      .cornerRadius(5)
    }
  }
}

private struct SiliconChipVisualWidget: View {
  var body: some View {
    HStack(spacing: 8) {
      ZStack {
        RoundedRectangle(cornerRadius: 6)
          .fill(TickColor.brand.opacity(0.14))
          .frame(width: 30, height: 30)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(TickColor.brand.opacity(0.40), lineWidth: 0.75)
          )

        Image(systemName: "cpu.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(TickColor.brand)
      }

      VStack(alignment: .leading, spacing: 1) {
        Text("APPLE SILICON")
          .font(TickFont.mono(9, weight: .bold))
          .foregroundStyle(TickColor.textPrimary)
        Text("0KB Cloud · 100% Offline")
          .font(TickFont.mono(8.5, weight: .regular))
          .foregroundStyle(TickColor.success)
      }
    }
  }
}

// MARK: - Elevated Permission Card

private struct ElevatedPermissionCard: View {
  let icon: String
  let eyebrow: String
  let title: String
  let subtitle: String
  let isGranted: Bool
  let buttonTitle: String
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      ZStack {
        RoundedRectangle(cornerRadius: 11)
          .fill(
            LinearGradient(
              colors: [
                isGranted ? TickColor.success.opacity(0.20) : TickColor.brand.opacity(0.16),
                isGranted ? TickColor.success.opacity(0.08) : TickColor.brand.opacity(0.06)
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .frame(width: 42, height: 42)
          .overlay(
            RoundedRectangle(cornerRadius: 11)
              .stroke(
                LinearGradient(
                  colors: [Color.white.opacity(0.35), (isGranted ? TickColor.success : TickColor.brand).opacity(0.30)],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
              )
          )

        Image(systemName: icon)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(isGranted ? TickColor.success : TickColor.brand)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(eyebrow)
          .font(TickFont.mono(9, weight: .medium))
          .tracking(0.6)
          .foregroundStyle(TickColor.textTertiary)

        Text(title)
          .font(TickFont.headingFunc(14, weight: .semibold))
          .foregroundStyle(TickColor.textPrimary)

        Text(subtitle)
          .font(TickFont.bodyFunc(12, weight: .regular))
          .foregroundStyle(TickColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      if isGranted {
        HStack(spacing: 5) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
          Text("Ready")
            .font(TickFont.labelFunc(12, weight: .semibold))
        }
        .foregroundStyle(TickColor.success)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(TickColor.success.opacity(0.12))
        .clipShape(Capsule())
        .overlay(
          Capsule()
            .stroke(TickColor.success.opacity(0.35), lineWidth: 0.75)
        )
      } else {
        ElevatedTactileButton(
          title: buttonTitle,
          icon: "arrow.up.right",
          isCompact: true,
          isEnabled: true,
          action: action
        )
      }
    }
    .padding(16)
    .background(
      ZStack {
        RoundedRectangle(cornerRadius: 16)
          .fill(
            LinearGradient(
              colors: [
                Color.white.opacity(isHovered ? 0.08 : 0.04),
                Color.black.opacity(0.16)
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )

        VStack {
          LinearGradient(
            colors: [Color.white.opacity(isHovered ? 0.40 : 0.22), Color.clear],
            startPoint: .top,
            endPoint: .bottom
          )
          .frame(height: 1.5)
          Spacer()
        }
      }
    )
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .overlay(
      RoundedRectangle(cornerRadius: 16)
        .stroke(
          LinearGradient(
            colors: isGranted
              ? [Color.white.opacity(0.20), Color.white.opacity(0.06)]
              : (isHovered
                  ? [TickColor.brand.opacity(0.55), Color.white.opacity(0.18)]
                  : [Color.white.opacity(0.22), Color.white.opacity(0.05)]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          lineWidth: 0.75
        )
    )
    .hexGlass(cornerRadius: 16, style: .regular)
    .shadow(color: Color.black.opacity(0.25), radius: isHovered ? 8 : 4, x: 0, y: isHovered ? 4 : 2)
    .offset(y: isHovered ? -1.5 : 0)
    .animation(.spring(response: 0.26, dampingFraction: 0.75), value: isHovered)
    .onHover { isHovered = $0 }
  }
}

// MARK: - Elevated Tactile 3D Glass Button

private struct ElevatedTactileButton: View {
  let title: String
  let icon: String?
  var isCompact: Bool = false
  var isEnabled: Bool = true
  let action: () -> Void

  @State private var isHovered = false
  @State private var isPressed = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: isCompact ? 5 : 8) {
        Text(title)
          .font(TickFont.labelFunc(isCompact ? 12 : 14, weight: .semibold))

        if let icon {
          Image(systemName: icon)
            .font(.system(size: isCompact ? 10 : 12, weight: .bold))
        }
      }
      .foregroundStyle(isEnabled ? Color.white : TickColor.textTertiary)
      .padding(.horizontal, isCompact ? 14 : 24)
      .padding(.vertical, isCompact ? 7 : 10)
      .background(
        ZStack {
          if isEnabled {
            // Elevated physical gradient
            LinearGradient(
              colors: [
                TickColor.brand.opacity(isHovered ? 1.0 : 0.92),
                TickColor.brand.opacity(0.80)
              ],
              startPoint: .top,
              endPoint: .bottom
            )

            // Top specular bevel line
            VStack {
              LinearGradient(
                colors: [Color.white.opacity(0.48), Color.white.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
              )
              .frame(height: 1.5)
              Spacer()
            }
          } else {
            LinearGradient(
              colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
              startPoint: .top,
              endPoint: .bottom
            )
          }
        }
      )
      .clipShape(RoundedRectangle(cornerRadius: isCompact ? 8 : 10))
      .overlay(
        RoundedRectangle(cornerRadius: isCompact ? 8 : 10)
          .stroke(
            isEnabled
              ? LinearGradient(
                  colors: [Color.white.opacity(0.55), TickColor.brand.opacity(0.35)],
                  startPoint: .top,
                  endPoint: .bottom
                )
              : LinearGradient(
                  colors: [Color.white.opacity(0.08), Color.clear],
                  startPoint: .top,
                  endPoint: .bottom
                ),
            lineWidth: 1.0
          )
      )
      // Dual-layer elevated drop shadows
      .shadow(
        color: isEnabled ? Color.black.opacity(0.25) : Color.clear,
        radius: isHovered ? 4 : 2,
        x: 0,
        y: isHovered ? 3 : 1.5
      )
      .shadow(
        color: isEnabled ? TickColor.brand.opacity(isHovered ? 0.45 : 0.28) : Color.clear,
        radius: isHovered ? 12 : 6,
        x: 0,
        y: isHovered ? 5 : 3
      )
      .scaleEffect(isPressed ? 0.975 : (isHovered && isEnabled ? 1.02 : 1.0))
      .offset(y: isPressed ? 1.0 : (isHovered && isEnabled ? -1.0 : 0))
      .animation(.spring(response: 0.24, dampingFraction: 0.74), value: isHovered)
      .animation(.spring(response: 0.18, dampingFraction: 0.82), value: isPressed)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .onHover { isHovered = $0 }
  }
}
