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

  // Entrance animations
  @State private var isIntroVisible: Bool = false
  @State private var pulsePhase: Double = 0.0
  @State private var timerSubscription: Task<Void, Never>? = nil

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
      // Dynamic ambient backdrop
      ambientBackdrop

      VStack(spacing: 0) {
        // Step progress header
        stepIndicator
          .padding(.top, 32)
          .padding(.bottom, 20)

        // Main step content with smooth transitions
        if currentStep == 0 {
          welcomeStepView
            .transition(.asymmetric(
              insertion: .opacity.combined(with: .scale(scale: 0.96)),
              removal: .opacity.combined(with: .move(edge: .leading))
            ))
        } else {
          permissionsStepView
            .transition(.asymmetric(
              insertion: .opacity.combined(with: .move(edge: .trailing)),
              removal: .opacity.combined(with: .scale(scale: 0.96))
            ))
        }

        Spacer(minLength: 16)

        // Bottom action bar
        bottomActionBar
          .padding(.horizontal, 40)
          .padding(.bottom, 36)
      }
      .frame(maxWidth: 720, maxHeight: 620)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      withAnimation(.easeOut(duration: 0.7)) {
        isIntroVisible = true
      }
      startPulseAnimation()
      refreshPermissions()
      startPermissionMonitoring()
    }
    .onDisappear {
      timerSubscription?.cancel()
    }
  }

  // MARK: - Ambient Backdrop

  private var ambientBackdrop: some View {
    ZStack {
      WindowThemeBackground()

      // Subtle luminous glow in center
      RadialGradient(
        colors: [
          TickColor.brand.opacity(0.12),
          TickColor.brand.opacity(0.04),
          Color.clear
        ],
        center: .center,
        startRadius: 40,
        endRadius: 360
      )
      .blur(radius: 40)
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
              ? TickColor.brand
              : (index < currentStep ? TickColor.brand.opacity(0.4) : Color.primary.opacity(0.10))
          )
          .frame(width: index == currentStep ? 36 : 16, height: 4)
          .animation(.spring(response: 0.35, dampingFraction: 0.75), value: currentStep)
      }
    }
  }

  // MARK: - Step 0: Welcome / Intro View

  private var welcomeStepView: some View {
    VStack(spacing: 24) {
      // Animated Hero Logo & Soundwave Orb
      ZStack {
        // Outer pulsing energy rings
        Circle()
          .stroke(TickColor.brand.opacity(0.15 + sin(pulsePhase) * 0.08), lineWidth: 1.5)
          .frame(width: 96, height: 96)
          .scaleEffect(1.0 + sin(pulsePhase) * 0.06)

        Circle()
          .stroke(TickColor.brand.opacity(0.25 + cos(pulsePhase) * 0.10), lineWidth: 1.5)
          .frame(width: 80, height: 80)

        // Glass center orb
        Circle()
          .fill(.ultraThinMaterial)
          .frame(width: 68, height: 68)
          .hexGlass(in: Circle(), tint: TickColor.brand.opacity(0.18))
          .overlay(
            Circle()
              .stroke(
                LinearGradient(
                  colors: [Color.white.opacity(0.40), TickColor.brand.opacity(0.60)],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                ),
                lineWidth: 1.0
              )
          )

        // Animated soundwave bars
        HStack(spacing: 3.5) {
          ForEach(0..<4) { barIndex in
            let barHeight: CGFloat = 10.0 + CGFloat(sin(pulsePhase + Double(barIndex) * 0.85) * 0.5 + 0.5) * 16.0
            RoundedRectangle(cornerRadius: 1.5)
              .fill(
                LinearGradient(
                  colors: [TickColor.brand, TickColor.brand.opacity(0.70)],
                  startPoint: .top,
                  endPoint: .bottom
                )
              )
              .frame(width: 3, height: barHeight)
          }
        }
      }
      .frame(height: 104)
      .opacity(isIntroVisible ? 1 : 0)
      .scaleEffect(isIntroVisible ? 1 : 0.85)
      .animation(.spring(response: 0.5, dampingFraction: 0.72), value: isIntroVisible)

      // Titles & Subtext
      VStack(spacing: 8) {
        Text("Welcome to Tick")
          .font(.system(size: 28, weight: .bold, design: .default))
          .foregroundStyle(TickColor.textPrimary)

        Text("Super-fast, 100% on-device voice dictation for macOS.")
          .font(.system(size: 14, weight: .regular, design: .default))
          .foregroundStyle(TickColor.textSecondary)
          .multilineTextAlignment(.center)
      }
      .opacity(isIntroVisible ? 1 : 0)
      .offset(y: isIntroVisible ? 0 : 8)
      .animation(.spring(response: 0.5, dampingFraction: 0.75).delay(0.08), value: isIntroVisible)

      // Feature Highlights
      VStack(spacing: 12) {
        featureRow(
          icon: "lock.shield.fill",
          title: "100% Private & On-Device",
          description: "All speech is transcribed locally on your Apple Silicon Neural Engine. Zero audio ever touches the cloud."
        )

        featureRow(
          icon: "command.square.fill",
          title: "Global Hotkey Dictation",
          description: "Hold your hotkey (⌥ Option) in any macOS app to speak naturally and insert text right at your cursor."
        )

        featureRow(
          icon: "sparkles",
          title: "Intelligent AI Formatting",
          description: "Removes filler words, formats punctuation, and aligns style seamlessly without interrupting your flow."
        )
      }
      .padding(.horizontal, 28)
      .opacity(isIntroVisible ? 1 : 0)
      .offset(y: isIntroVisible ? 0 : 12)
      .animation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.16), value: isIntroVisible)
    }
  }

  private func featureRow(icon: String, title: String, description: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 8)
          .fill(TickColor.brand.opacity(0.12))
          .frame(width: 32, height: 32)

        Image(systemName: icon)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(TickColor.brand)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 13, weight: .semibold, design: .default))
          .foregroundStyle(TickColor.textPrimary)

        Text(description)
          .font(.system(size: 12, weight: .regular, design: .default))
          .foregroundStyle(TickColor.textSecondary)
          .lineSpacing(2)
      }

      Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .hexGlass(cornerRadius: 12, style: .regular)
  }

  // MARK: - Step 1: Permissions View

  private var permissionsStepView: some View {
    VStack(spacing: 24) {
      VStack(spacing: 8) {
        Text("Required Permissions")
          .font(.system(size: 26, weight: .bold, design: .default))
          .foregroundStyle(TickColor.textPrimary)

        Text("Tick requires Microphone and Accessibility access to capture your speech and insert transcriptions into active apps.")
          .font(.system(size: 13, weight: .regular, design: .default))
          .foregroundStyle(TickColor.textSecondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      }

      VStack(spacing: 14) {
        // Microphone Card
        permissionCard(
          icon: "mic.fill",
          title: "Microphone Access",
          subtitle: "Required for capturing audio while you hold the dictation hotkey.",
          isGranted: isMicrophoneGranted,
          buttonTitle: microphonePermission == .denied ? "Open Settings" : "Grant Access",
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

        // Accessibility & Input Monitoring Card
        permissionCard(
          icon: "accessibility",
          title: "Accessibility & Input Monitoring",
          subtitle: "Required to detect your global shortcut and insert transcribed text directly into your active apps.",
          isGranted: isAccessibilityGranted,
          buttonTitle: (accessibilityPermission == .denied || inputMonitoringPermission == .denied) ? "Open Settings" : "Grant Access",
          action: {
            Task {
              await permissions.requestAccessibility()
              _ = await permissions.requestInputMonitoring()
              refreshPermissions()
            }
          }
        )
      }
      .padding(.horizontal, 28)

      // Privacy assurance footer note
      HStack(spacing: 6) {
        Image(systemName: "lock.fill")
          .font(.system(size: 10))
          .foregroundStyle(TickColor.textTertiary)

        Text("Tick never transmits or stores keystrokes or audio outside your local device.")
          .font(.system(size: 11, weight: .regular, design: .default))
          .foregroundStyle(TickColor.textTertiary)
      }
      .padding(.top, 4)
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

      Spacer()

      if isGranted {
        HStack(spacing: 5) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
          Text("Granted")
            .font(.system(size: 12, weight: .semibold, design: .default))
        }
        .foregroundStyle(TickColor.success)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(TickColor.success.opacity(0.12))
        .clipShape(Capsule())
      } else {
        Button(action: action) {
          Text(buttonTitle)
            .font(.system(size: 12, weight: .semibold, design: .default))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
              LinearGradient(
                colors: [TickColor.brand, TickColor.brand.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
              )
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(16)
    .hexGlass(cornerRadius: 14, style: .regular)
  }

  // MARK: - Bottom Action Bar

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
        Button(action: {
          withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            currentStep = 1
          }
        }) {
          HStack(spacing: 8) {
            Text("Continue")
              .font(.system(size: 14, weight: .semibold, design: .default))
            Image(systemName: "arrow.right")
              .font(.system(size: 12, weight: .bold))
          }
          .foregroundStyle(Color.white)
          .padding(.horizontal, 24)
          .padding(.vertical, 10)
          .background(
            LinearGradient(
              colors: [TickColor.brand, TickColor.brand.opacity(0.85)],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .clipShape(RoundedRectangle(cornerRadius: 10))
          .shadow(color: TickColor.brand.opacity(0.3), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
      } else {
        VStack(alignment: .trailing, spacing: 6) {
          Button(action: {
            guard canProceedFromPermissions else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
              $hexSettings.withLock {
                $0.hasCompletedWelcomeOnboarding = true
              }
            }
          }) {
            HStack(spacing: 8) {
              Text("Enter Tick")
                .font(.system(size: 14, weight: .semibold, design: .default))
              Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(canProceedFromPermissions ? Color.white : TickColor.textTertiary)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(
              canProceedFromPermissions
                ? LinearGradient(
                    colors: [TickColor.brand, TickColor.brand.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                  )
                : LinearGradient(
                    colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
                    startPoint: .top,
                    endPoint: .bottom
                  )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: canProceedFromPermissions ? TickColor.brand.opacity(0.35) : Color.clear, radius: 8, x: 0, y: 3)
          }
          .buttonStyle(.plain)
          .disabled(!canProceedFromPermissions)

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

  private func startPulseAnimation() {
    withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
      pulsePhase = .pi * 2
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
    timerSubscription?.cancel()
    timerSubscription = Task { @MainActor in
      // Listen for app activation events
      Task {
        for await activation in permissions.observeAppActivation() {
          if case .didBecomeActive = activation {
            refreshPermissions()
          }
        }
      }

      // Also actively poll while on this screen
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 600_000_000)
        refreshPermissions()
      }
    }
  }
}
