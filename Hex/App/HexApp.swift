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

    // Poll the store every 150ms during recording for fluid animation
    let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        Image(nsImage: .tickMenuBarIcon(isRecording: isRecording, phase: phase))
            .onReceive(timer) { _ in
                let recordingNow = HexApp.appStore.state.transcription.isRecording
                isRecording = recordingNow
                if isRecording {
                    phase = (phase + 0.35).truncatingRemainder(dividingBy: .pi * 2)
                }
            }
    }
}

extension NSImage {
    static func tickMenuBarIcon(isRecording: Bool = false, phase: Double = 0) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            let bars: [(x: CGFloat, h: CGFloat)]
            if isRecording {
                let h0 = 4.0 + CGFloat(sin(phase) * 0.5 + 0.5) * 10.0
                let h1 = 4.0 + CGFloat(sin(phase + 0.7) * 0.5 + 0.5) * 10.0
                let h2 = 4.0 + CGFloat(sin(phase + 1.4) * 0.5 + 0.5) * 10.0
                bars = [(2.5, h0), (7.5, h1), (12.5, h2)]
            } else {
                bars = [(2.5, 8.5), (7.5, 15.0), (12.5, 11.0)]
            }

            for bar in bars {
                let y = (18.0 - bar.h) / 2.0
                let barRect = CGRect(x: bar.x, y: y, width: 3.0, height: bar.h)
                let path = CGPath(roundedRect: barRect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
                context.addPath(path)
            }

            NSColor.black.setFill()
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

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
