import ComposableArchitecture
import HexCore
import Inject
import Sparkle
import AppKit
import SwiftUI

// MARK: - App

@main
struct HexApp: App {
	static let appStore = Store(initialState: AppFeature.State()) {
		AppFeature()
	}

	@NSApplicationDelegateAdaptor(HexAppDelegate.self) var appDelegate

	init() {
		TickFonts.registerIfNeeded()
	}

    var body: some Scene {
        MenuBarExtra {
            CheckForUpdatesView()
            MenuBarCopyLastTranscriptButton()
            MenuBarMicrophoneMenu()
            Button("Settings") {
                appDelegate.presentSettingsView()
            }.keyboardShortcut(",")
			Divider()
			Button("Quit") {
				NSApplication.shared.terminate(nil)
			}.keyboardShortcut("q")
        } label: {
			MenuBarRecordingIcon()
		}
		.menuBarExtraStyle(.menu)

		WindowGroup {}.defaultLaunchBehavior(.suppressed)
			.commands {
				CommandGroup(after: .appInfo) {
					CheckForUpdatesView()
					Button("Settings") {
						appDelegate.presentSettingsView()
					}.keyboardShortcut(",")
				}
				CommandGroup(replacing: .help) {}
			}
	}
}

// MARK: - Microphone menu

struct MenuBarMicrophoneMenu: View {
    @Dependency(\.recording) private var recording
    @Shared(.hexSettings) private var hexSettings: HexSettings

    @State private var inputDevices: [AudioInputDevice] = []
    @State private var defaultInputDeviceName: String?

    var body: some View {
        Menu("Microphone") {
            Button {
                selectMicrophone(nil)
            } label: {
                menuLabel(
                    title: defaultInputDeviceName.map { "System Default (\($0))" } ?? "System Default",
                    isSelected: hexSettings.selectedMicrophoneID == nil
                )
            }

            if !inputDevices.isEmpty {
                Divider()

                ForEach(inputDevices) { device in
                    Button {
                        selectMicrophone(device.id)
                    } label: {
                        menuLabel(
                            title: device.name,
                            isSelected: hexSettings.selectedMicrophoneID == device.id
                        )
                    }
                }
            } else {
                Text("No microphones found")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            refreshDevices()
        }
    }

    private func menuLabel(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func selectMicrophone(_ id: String?) {
        $hexSettings.withLock { $0.selectedMicrophoneID = id }
    }

    private func refreshDevices() {
        Task {
            async let devices = recording.getAvailableInputDevices()
            async let defaultName = recording.getDefaultInputDeviceName()
            inputDevices = await devices
            defaultInputDeviceName = await defaultName
        }
    }
}

// MARK: - Animated Menu Bar Recording Icon
// When idle, shows the static Tick icon.
// When recording, animates 4 thin white bars (a tiny waveform) that pulse
// to signal active recording. The menu bar item itself acts as the visual
// feedback — no floating window needed.

struct MenuBarRecordingIcon: View {
    @State private var isRecording = false
    @State private var phase: Double = 0

    // Poll the store every 200ms — cheap enough for a menu bar icon.
    let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            glassBar(height: isRecording ? recordingBarHeight(for: 0) : 9, opacity: 0.80)
            glassBar(height: isRecording ? recordingBarHeight(for: 1) : 15, opacity: 1.0)
            glassBar(height: isRecording ? recordingBarHeight(for: 2) : 11, opacity: 0.85)
        }
        .frame(width: 18, height: 18)
        .onReceive(timer) { _ in
            let recordingNow = HexApp.appStore.state.transcription.isRecording
            if recordingNow != isRecording {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                    isRecording = recordingNow
                }
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }

    @ViewBuilder
    private func glassBar(height: CGFloat, opacity: Double) -> some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Color.primary.opacity(opacity), location: 0.0),
                        .init(color: Color.primary.opacity(opacity * 0.45), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 2.75, height: height)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.40), location: 0.0),
                                .init(color: Color.clear, location: 0.75)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            )
    }

    private func recordingBarHeight(for index: Int) -> CGFloat {
        let offset = Double(index) * 0.7
        let val = sin(phase + offset) * 0.5 + 0.5
        return 4 + CGFloat(val) * 11
    }
}

extension NSImage {
    fileprivate func resized(to target: NSSize) -> NSImage {
        let img = NSImage(size: target)
        img.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: self.size),
                   operation: .copy, fraction: 1.0)
        img.unlockFocus()
        return img
    }
}
