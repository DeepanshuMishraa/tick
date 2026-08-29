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

  // Entrance & breathing animation phases
  @State private var isVisible: Bool = false
  @State private var wavePhase: Double = 0.0
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
        // Step progress header
        stepIndicator
          .padding(.top, 28)
          .padding(.bottom, 16)

        // Main animated presentation
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

        Spacer(minLength: 12)

        // Bottom action bar
        bottomActionBar
          .padding(.horizontal, 48)
          .padding(.bottom, 32)
      }
      .frame(maxWidth: 740, maxHeight: 600)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
        isVisible = true
      }
      startWaveAnimation()
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

      // Multi-layer organic ambient chromatic glow
      RadialGradient(
        colors: [
          TickColor.brand.opacity(0.18),
          TickColor.brand.opacity(0.05),
          Color.clear
        ],
        center: .center,
        startRadius: 20,
        endRadius: 400
      )
      .blur(radius: 50)
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
                    colors: [TickColor.brand, TickColor.brand.opacity(0.8)],
                    startPoint: .leading,
                    endPoint: .trailing
                  )
                )
              : AnyShapeStyle(Color.primary.opacity(0.10))
          )
          .frame(width: index == currentStep ? 32 : 14, height: 4)
          .animation(.spring(response: 0.35, dampingFraction: 0.75), value: currentStep)
      }
    }
  }

  // MARK: - Step 0: Welcome Masterpiece View

  private var welcomeStepView: some View {
    VStack(spacing: 20) {
      // Acoustic Core / Waveform Centerpiece
      acousticCenterpiece
        .frame(height: 96)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.88)
        .animation(.spring(response: 0.55, dampingFraction: 0.75), value: isVisible)

      // Hero Typography
      VStack(spacing: 6) {
        Text("Tick")
          .font(.system(size: 32, weight: .bold, design: .default))
          .foregroundStyle(TickColor.textPrimary)

        Text("Voice to text, designed for focus.")
          .font(.system(size: 14, weight: .medium, design: .default))
          .foregroundStyle(TickColor.textSecondary)
      }
      .opacity(isVisible ? 1 : 0)
      .offset(y: isVisible ? 0 : 8)
      .animation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.06), value: isVisible)

      // 3 Spatial Feature Pillar Cards
      HStack(spacing: 14) {
        pillarCard(
          icon: "lock.shield.fill",
          title: "100% Private",
          subtitle: "On-Device Neural Engine",
          detail: "Zero audio or keystrokes ever touch the cloud."
        )

        pillarCard(
          icon: "command.square.fill",
          title: "Global Hotkey",
          subtitle: "⌥ Option Anywhere",
          detail: "Hold to dictate instantly across any macOS application."
        )

        pillarCard(
          icon: "sparkles",
          title: "Intelligent Polish",
          subtitle: "Smart Real-Time AI",
          detail: "Cleans filler words, self-corrections, and punctuation."
        )
      }
      .padding(.horizontal, 36)
      .opacity(isVisible ? 1 : 0)
      .offset(y: isVisible ? 0 : 12)
      .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.12), value: isVisible)
    }
  }

  private var acousticCenterpiece: some View {
    ZStack {
      // Dynamic breathing rings
      Circle()
        .stroke(TickColor.brand.opacity(0.12 + sin(wavePhase) * 0.06), lineWidth: 1.5)
        .frame(width: 92, height: 92)
        .scaleEffect(1.0 + sin(wavePhase) * 0.05)

      Circle()
        .stroke(TickColor.brand.opacity(0.20 + cos(wavePhase) * 0.08), lineWidth: 1.5)
        .frame(width: 76, height: 76)

      // Glass core disk with specular top bevel
      Circle()
        .fill(.ultraThinMaterial)
        .frame(width: 62, height: 62)
        .hexGlass(in: Circle(), tint: TickColor.brand.opacity(0.20))
        .overlay(
          Circle()
            .stroke(
              LinearGradient(
                colors: [Color.white.opacity(0.50), TickColor.brand.opacity(0.40)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              ),
              lineWidth: 1.0
            )
        )
        .shadow(color: TickColor.brand.opacity(0.25), radius: 12, x: 0, y: 4)

      // Animated multi-frequency waveform bars
      HStack(spacing: 3.5) {
        ForEach(0..<5) { bar in
          let height: CGFloat = 8.0 + CGFloat(sin(wavePhase + Double(bar) * 0.75) * 0.5 + 0.5) * 16.0
          RoundedRectangle(cornerRadius: 1.5)
            .fill(
              LinearGradient(
                colors: [TickColor.brand, TickColor.brand.opacity(0.70)],
                startPoint: .top,
                endPoint: .bottom
              )
            )
            .frame(width: 3, height: height)
        }
      }
    }
  }

  private func pillarCard(icon: String, title: String, subtitle: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 8)
          .fill(TickColor.brand.opacity(0.12))
          .frame(width: 32, height: 32)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
          )

        Image(systemName: icon)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(TickColor.brand)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 13, weight: .semibold, design: .default))
          .foregroundStyle(TickColor.textPrimary)

        Text(subtitle)
          .font(.system(size: 11, weight: .medium, design: .default))
          .foregroundStyle(TickColor.brand)

        Text(detail)
          .font(.system(size: 11, weight: .regular, design: .default))
          .foregroundStyle(TickColor.textSecondary)
          .lineSpacing(2)
          .padding(.top, 2)
      }

      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
    .hexGlass(cornerRadius: 14, style: .regular)
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .stroke(
          LinearGradient(
            colors: [Color.white.opacity(0.20), Color.white.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          lineWidth: 0.75
        )
    )
  }

  // MARK: - Step 1: Permissions Masterpiece View

  private var permissionsStepView: some View {
    VStack(spacing: 20) {
      VStack(spacing: 6) {
        Text("Required Permissions")
          .font(.system(size: 26, weight: .bold, design: .default))
          .foregroundStyle(TickColor.textPrimary)

        Text("Tick requires Microphone and Accessibility access to capture your speech and insert transcriptions into active apps.")
          .font(.system(size: 13, weight: .regular, design: .default))
          .foregroundStyle(TickColor.textSecondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 36)
      }

      VStack(spacing: 12) {
        // Microphone Card
        permissionCard(
          icon: "mic.fill",
          title: "Microphone Access",
          subtitle: "Required for capturing audio while you hold the dictation hotkey.",
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
        permissionCard(
          icon: "accessibility",
          title: "Accessibility & Input Monitoring",
          subtitle: "Required to detect your global shortcut and insert transcribed text directly into your active apps.",
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
      .padding(.horizontal, 36)

      // Privacy assurance footer note
      HStack(spacing: 6) {
        Image(systemName: "lock.fill")
          .font(.system(size: 10))
          .foregroundStyle(TickColor.textTertiary)

        Text("Tick never transmits or stores keystrokes or audio outside your local Mac.")
          .font(.system(size: 11, weight: .regular, design: .default))
          .foregroundStyle(TickColor.textTertiary)
      }
      .padding(.top, 2)
    }
  }

  private func permissionCard(
    icon: String,
    title: String,
    subtitle: String,
    isGranted: Bool,
    buttonTitle: String,
    action: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .center, spacing: 16) {
      ZStack {
        RoundedRectangle(cornerRadius: 10)
          .fill(isGranted ? TickColor.success.opacity(0.14) : TickColor.brand.opacity(0.12))
          .frame(width: 40, height: 40)
          .overlay(
            RoundedRectangle(cornerRadius: 10)
              .stroke(isGranted ? TickColor.success.opacity(0.3) : Color.white.opacity(0.15), lineWidth: 0.75)
          )

        Image(systemName: icon)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(isGranted ? TickColor.success : TickColor.brand)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 14, weight: .semibold, design: .default))
          .foregroundStyle(TickColor.textPrimary)

        Text(subtitle)
          .font(.system(size: 12, weight: .regular, design: .default))
          .foregroundStyle(TickColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      if isGranted {
        HStack(spacing: 5) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
          Text("Ready")
            .font(.system(size: 12, weight: .semibold, design: .default))
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
        ElevatedActionButton(
          title: buttonTitle,
          icon: "arrow.up.right",
          action: action
        )
      }
    }
    .padding(16)
    .hexGlass(cornerRadius: 14, style: .regular)
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .stroke(
          LinearGradient(
            colors: isGranted
              ? [Color.white.opacity(0.18), Color.white.opacity(0.06)]
              : [TickColor.brand.opacity(0.40), Color.white.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          lineWidth: 0.75
        )
    )
  }

  // MARK: - Bottom Action Bar with Elevated Buttons

  private var bottomActionBar: some View {
    HStack {
      if currentStep == 1 {
        Button(action: {
          withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            currentStep = 0
          }
        }) {
          HStack(spacing: 6) {
            Image(systemName: "arrow.left")
              .font(.system(size: 12, weight: .semibold))
            Text("Back")
              .font(.system(size: 13, weight: .medium, design: .default))
          }
          .foregroundStyle(TickColor.textSecondary)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .hexGlass(cornerRadius: 8, interactive: true)
        }
        .buttonStyle(.plain)
      }

      Spacer()

      if currentStep == 0 {
        ElevatedPrimaryButton(
          title: "Get Started",
          icon: "arrow.right",
          action: {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
              currentStep = 1
            }
          }
        )
      } else {
        VStack(alignment: .trailing, spacing: 6) {
          ElevatedPrimaryButton(
            title: "Enter Tick",
            icon: "checkmark.circle.fill",
            isEnabled: canProceedFromPermissions,
            action: {
              guard canProceedFromPermissions else { return }
              withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                $hexSettings.withLock {
                  $0.hasCompletedWelcomeOnboarding = true
                }
              }
            }
          )

          if !canProceedFromPermissions {
            Text("Grant required permissions to continue")
              .font(.system(size: 11, weight: .regular, design: .default))
              .foregroundStyle(TickColor.textTertiary)
          }
        }
      }
    }
  }

  // MARK: - Helpers & Polling

  private func startWaveAnimation() {
    withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
      wavePhase = .pi * 2
    }
  }

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

// MARK: - Slightly Elevated 3D Glass Buttons

private struct ElevatedPrimaryButton: View {
  let title: String
  let icon: String?
  var isEnabled: Bool = true
  let action: () -> Void

  @State private var isHovered = false
  @State private var isPressed = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Text(title)
          .font(.system(size: 14, weight: .semibold, design: .default))

        if let icon {
          Image(systemName: icon)
            .font(.system(size: 12, weight: .bold))
        }
      }
      .foregroundStyle(isEnabled ? Color.white : TickColor.textTertiary)
      .padding(.horizontal, 24)
      .padding(.vertical, 10)
      .background(
        ZStack {
          if isEnabled {
            // Elevated gradient background
            LinearGradient(
              colors: [
                TickColor.brand.opacity(isHovered ? 1.0 : 0.92),
                TickColor.brand.opacity(0.80)
              ],
              startPoint: .top,
              endPoint: .bottom
            )

            // Top specular highlight bevel line
            VStack {
              LinearGradient(
                colors: [Color.white.opacity(0.40), Color.white.opacity(0.0)],
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
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(
            isEnabled
              ? LinearGradient(
                  colors: [Color.white.opacity(0.50), TickColor.brand.opacity(0.40)],
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
      // Elevated dual drop shadow
      .shadow(
        color: isEnabled ? Color.black.opacity(0.20) : Color.clear,
        radius: isHovered ? 4 : 2,
        x: 0,
        y: isHovered ? 3 : 1.5
      )
      .shadow(
        color: isEnabled ? TickColor.brand.opacity(isHovered ? 0.45 : 0.28) : Color.clear,
        radius: isHovered ? 12 : 6,
        x: 0,
        y: isHovered ? 6 : 3
      )
      .scaleEffect(isPressed ? 0.98 : (isHovered && isEnabled ? 1.02 : 1.0))
      .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
      .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isPressed)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .onHover { isHovered = $0 }
  }
}

private struct ElevatedActionButton: View {
  let title: String
  let icon: String?
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title)
          .font(.system(size: 12, weight: .semibold, design: .default))

        if let icon {
          Image(systemName: icon)
            .font(.system(size: 10, weight: .bold))
        }
      }
      .foregroundStyle(Color.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .background(
        ZStack {
          LinearGradient(
            colors: [
              TickColor.brand.opacity(isHovered ? 1.0 : 0.90),
              TickColor.brand.opacity(0.78)
            ],
            startPoint: .top,
            endPoint: .bottom
          )

          VStack {
            LinearGradient(
              colors: [Color.white.opacity(0.40), Color.clear],
              startPoint: .top,
              endPoint: .bottom
            )
            .frame(height: 1.2)
            Spacer()
          }
        }
      )
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            LinearGradient(
              colors: [Color.white.opacity(0.50), TickColor.brand.opacity(0.30)],
              startPoint: .top,
              endPoint: .bottom
            ),
            lineWidth: 0.75
          )
      )
      .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1.5)
      .shadow(color: TickColor.brand.opacity(isHovered ? 0.35 : 0.20), radius: 6, x: 0, y: 3)
      .scaleEffect(isHovered ? 1.02 : 1.0)
      .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
}
