import ComposableArchitecture
import HexCore
import SwiftUI

private let appLogger = HexLog.app
private let cacheLogger = HexLog.caches

class HexAppDelegate: NSObject, NSApplicationDelegate {
	var invisibleWindow: InvisibleWindow?
	var settingsWindow: NSWindow?
	var statusItem: NSStatusItem!
	private var launchedAtLogin = false

	@Dependency(\.soundEffects) var soundEffect
	@Dependency(\.recording) var recording
	@Shared(.hexSettings) var hexSettings: HexSettings

	func applicationDidFinishLaunching(_: Notification) {
		DiagnosticsLogging.bootstrapIfNeeded()
		TickFonts.registerIfNeeded()
		configureLocalCaches()
		if isTesting {
			appLogger.debug("Running in testing mode")
			return
		}

		Task {
			await soundEffect.preloadSounds()
		}
		launchedAtLogin = wasLaunchedAtLogin()
		appLogger.info("Application did finish launching")
		appLogger.notice("launchedAtLogin = \(self.launchedAtLogin)")

		updateAppMode()

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleAppModeUpdate),
			name: .updateAppMode,
			object: nil
		)

		startLifecycleTasksIfNeeded()
		presentMainView()

		guard shouldOpenForegroundUIOnLaunch else {
			appLogger.notice("Suppressing foreground windows for login launch")
			return
		}

		presentSettingsView()
		NSApp.activate(ignoringOtherApps: true)
	}

	private var shouldOpenForegroundUIOnLaunch: Bool {
		!(launchedAtLogin && !hexSettings.showDockIcon)
	}

	private func wasLaunchedAtLogin() -> Bool {
		guard let event = NSAppleEventManager.shared().currentAppleEvent else {
			return false
		}

		return event.eventID == AEEventID(kAEOpenApplication)
			&& event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == AEEventClass(keyAELaunchedAsLogInItem)
	}

	private func startLifecycleTasksIfNeeded() {
		Task { @MainActor in
			await HexApp.appStore.send(.task).finish()
		}
	}

    private func configureLocalCaches() {
        do {
            let cache = try URL.hexApplicationSupport.appendingPathComponent("cache", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            setenv("XDG_CACHE_HOME", cache.path, 1)
            cacheLogger.info("XDG_CACHE_HOME set to \(cache.path)")
        } catch {
            cacheLogger.error("Failed to configure local caches: \(error.localizedDescription)")
        }
    }

	func presentMainView() {
		guard invisibleWindow == nil else {
			return
		}
		let transcriptionStore = HexApp.appStore.scope(state: \.transcription, action: \.transcription)
		let transcriptionView = TranscriptionView(store: transcriptionStore)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		invisibleWindow = InvisibleWindow.fromView(transcriptionView)
		// The transcription overlay must never become key: doing so clears the
		// focused text field that should receive the finished transcription.
		invisibleWindow?.orderFrontRegardless()
	}

	func presentSettingsView() {
		if let settingsWindow = settingsWindow {
			settingsWindow.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		let settingsView = AppView(store: HexApp.appStore)
			.frame(minWidth: 920, minHeight: 620)
			.background(Color.clear)

		let settingsWindow = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 1100, height: 720),
			styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)
		settingsWindow.title = "Tick"
		settingsWindow.titleVisibility = .hidden
		settingsWindow.titlebarAppearsTransparent = true
		settingsWindow.isOpaque = false
		settingsWindow.backgroundColor = .clear
		settingsWindow.hasShadow = true
		settingsWindow.titlebarSeparatorStyle = .none
		settingsWindow.isMovableByWindowBackground = true
		settingsWindow.contentView = makeAdaptiveWindowContentView(rootView: settingsView, frame: settingsWindow.contentRect(forFrameRect: settingsWindow.frame))
		settingsWindow.isReleasedWhenClosed = false
		settingsWindow.center()
		settingsWindow.toolbarStyle = .unified
		settingsWindow.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		self.settingsWindow = settingsWindow
	}

	/// Hosts the full app surface in the platform's actual window material.
	/// SwiftUI's `glassEffect` is for controls and content surfaces; it cannot
	/// make an NSWindow reveal the desktop behind it by itself.
	private func makeAdaptiveWindowContentView<Content: View>(rootView: Content, frame: NSRect) -> NSView {
		let hostingView = NSHostingView(rootView: rootView)
		hostingView.frame = NSRect(origin: .zero, size: frame.size)
		hostingView.autoresizingMask = [.width, .height]

		if #available(macOS 26.0, *) {
			let glassView = NSGlassEffectView(frame: NSRect(origin: .zero, size: frame.size))
			glassView.style = .regular
			glassView.tintColor = .clear
			glassView.autoresizingMask = [.width, .height]
			glassView.contentView = hostingView
			return glassView
		}

		let vibrancyView = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
		vibrancyView.material = .underWindowBackground
		vibrancyView.blendingMode = .behindWindow
		vibrancyView.state = .active
		vibrancyView.autoresizingMask = [.width, .height]
		vibrancyView.addSubview(hostingView)
		return vibrancyView
	}

	@objc private func handleAppModeUpdate() {
		Task {
			await updateAppMode()
		}
	}

	@MainActor
	private func updateAppMode() {
		appLogger.debug("showDockIcon = \(self.hexSettings.showDockIcon)")
		if self.hexSettings.showDockIcon {
			NSApp.setActivationPolicy(.regular)
		} else {
			NSApp.setActivationPolicy(.accessory)
		}
	}

	func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
		presentSettingsView()
		return true
	}

	func applicationWillTerminate(_: Notification) {
		Task {
			await recording.cleanup()
		}
	}
}
