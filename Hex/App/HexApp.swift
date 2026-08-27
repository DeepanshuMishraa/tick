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
    @State private var digit: Int = 0

    // Poll the store every 200ms — cheap enough for a menu bar icon.
    let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if isRecording {
                // 4 tiny animating bars
                HStack(spacing: 2) {
                    ForEach(0..<4) { i in
                        Capsule()
                            .fill(TickColor.brand)
                            .frame(width: 2, height: barHeight(for: i))
                    }
                }
                .onAppear {
                    withAnimation(
                        .linear(duration: 0.5).repeatForever(autoreverses: false)
                    ) { phase = .pi * 2 }
                }
            } else {
                // Static app icon (pulled from existing asset)
                Image(nsImage: NSImage(named: "HexIcon")!
                    .resized(to: NSSize(width: 18, height: 18)))
            }
        }
        .onReceive(timer) { _ in
            isRecording = HexApp.appStore.state.transcription.isRecording
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let offset = Double(index) * 0.5
        let val = sin(phase + offset) * 0.5 + 0.5
        return 3 + CGFloat(val) * 8
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
