import AVFoundation
import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import Inject
import SwiftUI

private let historyLogger = HexLog.history

// MARK: - Date Extensions

extension Date {
	func relativeFormatted() -> String {
		let calendar = Calendar.current
		let now = Date()
		
		if calendar.isDateInToday(self) {
			return "Today"
		} else if calendar.isDateInYesterday(self) {
			return "Yesterday"
		} else if let daysAgo = calendar.dateComponents([.day], from: self, to: now).day, daysAgo < 7 {
			let formatter = DateFormatter()
			formatter.dateFormat = "EEEE"
			return formatter.string(from: self)
		} else {
			let formatter = DateFormatter()
			formatter.dateStyle = .medium
			formatter.timeStyle = .none
			return formatter.string(from: self)
		}
	}
}

// MARK: - Models

extension SharedReaderKey
	where Self == FileStorageKey<TranscriptionHistory>.Default
{
	static var transcriptionHistory: Self {
		Self[
			.fileStorage(.transcriptionHistoryURL),
			default: .init()
		]
	}
}

// MARK: - Storage Migration

extension URL {
	static var transcriptionHistoryURL: URL {
		get {
			URL.hexMigratedFileURL(named: "transcription_history.json")
		}
	}
}

class AudioPlayerController: NSObject, AVAudioPlayerDelegate {
	private var player: AVAudioPlayer?
	var onPlaybackFinished: (() -> Void)?

	func play(url: URL) throws -> AVAudioPlayer {
		let player = try AVAudioPlayer(contentsOf: url)
		player.delegate = self
		player.play()
		self.player = player
		return player
	}

	func stop() {
		player?.stop()
		player = nil
	}

	func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		self.player = nil
		Task { @MainActor in
			onPlaybackFinished?()
		}
	}
}

// MARK: - History Feature

@Reducer
struct HistoryFeature {
	@ObservableState
	struct State: Equatable {
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
		var playingTranscriptID: UUID?
		var audioPlayer: AVAudioPlayer?
		var audioPlayerController: AudioPlayerController?

		mutating func stopAudioPlayback() {
			audioPlayerController?.stop()
			audioPlayer = nil
			audioPlayerController = nil
			playingTranscriptID = nil
		}
	}

	enum Action {
		case playTranscript(UUID)
		case stopPlayback
		case copyToClipboard(String)
		case deleteTranscript(UUID)
		case deleteAllTranscripts
		case confirmDeleteAll
		case playbackFinished
		case navigateToSettings
	}

	@Dependency(\.pasteboard) var pasteboard
	@Dependency(\.transcriptPersistence) var transcriptPersistence

	private func deleteAudioEffect(for transcripts: [Transcript]) -> Effect<Action> {
		.run { [transcriptPersistence] _ in
			for transcript in transcripts {
				try? await transcriptPersistence.deleteAudio(transcript)
			}
		}
	}

	var body: some ReducerOf<Self> {
		Reduce { state, action in
			switch action {
			case let .playTranscript(id):
				if state.playingTranscriptID == id {
					state.stopAudioPlayback()
					return .none
				}

				state.stopAudioPlayback()

				guard let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }) else {
					return .none
				}

				do {
					let controller = AudioPlayerController()
					let player = try controller.play(url: transcript.audioPath)

					state.audioPlayer = player
					state.audioPlayerController = controller
					state.playingTranscriptID = id

					return .run { send in
						await withCheckedContinuation { continuation in
							controller.onPlaybackFinished = {
								continuation.resume()
								Task { @MainActor in
									send(.playbackFinished)
								}
							}
						}
					}
				} catch {
					historyLogger.error("Failed to play audio: \(error.localizedDescription)")
					return .none
				}

			case .stopPlayback, .playbackFinished:
				state.stopAudioPlayback()
				return .none

			case let .copyToClipboard(text):
				return .run { [pasteboard] _ in
					await pasteboard.copy(text)
				}

			case let .deleteTranscript(id):
				guard let index = state.transcriptionHistory.history.firstIndex(where: { $0.id == id }) else {
					return .none
				}

				let transcript = state.transcriptionHistory.history[index]

				if state.playingTranscriptID == id {
					state.stopAudioPlayback()
				}

				_ = state.$transcriptionHistory.withLock { history in
					history.history.remove(at: index)
				}

				return deleteAudioEffect(for: [transcript])

			case .deleteAllTranscripts:
				return .send(.confirmDeleteAll)

			case .confirmDeleteAll:
				let transcripts = state.transcriptionHistory.history
				state.stopAudioPlayback()

				state.$transcriptionHistory.withLock { history in
					history.history.removeAll()
				}

				return deleteAudioEffect(for: transcripts)
				
			case .navigateToSettings:
				return .none
			}
		}
	}
}

// MARK: - Views

struct HistoryView: View {
	@ObserveInjection var inject
	let store: StoreOf<HistoryFeature>
	@State private var showingDeleteConfirmation = false
	@Shared(.hexSettings) var hexSettings: HexSettings
	@Namespace private var historyHoverNamespace
	@State private var hoveredHistoryID: UUID? = nil

	var body: some View {
		VStack(alignment: .leading, spacing: TickSpacing.xl) {
			// Eyebrow header with title
			HStack(alignment: .center) {
				VStack(alignment: .leading, spacing: 2) {
					TickEyebrow(text: "History")
					Text("Today")
						.font(TickFont.headingFunc(22, weight: .semibold))
						.foregroundStyle(TickColor.textPrimary)
				}
				Spacer()
				if hexSettings.saveTranscriptionHistory && !store.transcriptionHistory.history.isEmpty {
					Button(role: .destructive) {
						showingDeleteConfirmation = true
					} label: {
						Label("Delete All", systemImage: "trash")
					}
					.buttonStyle(.bordered)
					.controlSize(.small)
					.tint(TickColor.error)
				}
			}

			Group {
				if !hexSettings.saveTranscriptionHistory {
					emptyState(
						icon: "clock.arrow.circlepath",
						title: "History Disabled",
						subtitle: "Transcription history is currently disabled."
					)
				} else if store.transcriptionHistory.history.isEmpty {
					emptyState(
						icon: "text.bubble",
						title: "No Transcriptions",
						subtitle: "Your transcription history will appear here."
					)
				} else {
					LazyVStack(spacing: 2) {
						ForEach(store.transcriptionHistory.history) { transcript in
							HistoryTranscriptRow(
								transcript: transcript,
								isPlaying: store.playingTranscriptID == transcript.id,
								isHovered: hoveredHistoryID == transcript.id,
								hoverNamespace: historyHoverNamespace,
								onHover: { isHovered in
									withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
										if isHovered {
											hoveredHistoryID = transcript.id
										} else if hoveredHistoryID == transcript.id {
											hoveredHistoryID = nil
										}
									}
								},
								onPlay: { store.send(.playTranscript(transcript.id)) },
								onCopy: { store.send(.copyToClipboard(transcript.text)) },
								onDelete: { store.send(.deleteTranscript(transcript.id)) }
							)
						}
					}
					.hexGlass(cornerRadius: TickRadius.card)
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.alert("Delete All Transcripts", isPresented: $showingDeleteConfirmation) {
			Button("Delete All", role: .destructive) {
				store.send(.confirmDeleteAll)
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("Are you sure you want to delete all transcripts? This action cannot be undone.")
		}
		.enableInjection()
	}

	private func emptyState(icon: String, title: String, subtitle: String) -> some View {
		VStack(spacing: TickSpacing.m) {
			ZStack {
				Circle()
					.fill(.clear)
					.frame(width: 64, height: 64)
					.hexGlass(in: Circle())
				Image(systemName: icon)
					.font(TickFont.bodyFunc(24))
					.foregroundStyle(TickColor.textTertiary)
			}
			Text(title)
				.font(TickFont.heading)
				.foregroundStyle(TickColor.textPrimary)
			Text(subtitle)
				.font(TickFont.body)
				.foregroundStyle(TickColor.textSecondary)
				.multilineTextAlignment(.center)
		}
		.frame(maxWidth: .infinity, minHeight: 300)
		.hexGlass(cornerRadius: TickRadius.card)
	}
}

// Whisperflow-style transcript row: time on left, text in middle, actions on right
struct HistoryTranscriptRow: View {
	let transcript: Transcript
	let isPlaying: Bool
	var isHovered: Bool = false
	var hoverNamespace: Namespace.ID? = nil
	var onHover: ((Bool) -> Void)? = nil
	let onPlay: () -> Void
	let onCopy: () -> Void
	let onDelete: () -> Void

	@Environment(\.colorScheme) private var colorScheme
	@State private var showCopied = false
	@State private var copyTask: Task<Void, Error>?

	var body: some View {
		HStack(alignment: .center, spacing: TickSpacing.m) {
			// Time on left (grey, mono)
			Text(transcript.timestamp.formatted(date: .omitted, time: .shortened))
				.font(TickFont.mono())
				.foregroundStyle(TickColor.textTertiary)
				.frame(width: 64, alignment: .leading)

			// App icon + name
			if let bundleID = transcript.sourceAppBundleID,
			   let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
				Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
					.resizable()
					.frame(width: 14, height: 14)
			}

			// Text
			Text(transcript.text)
				.font(TickFont.body)
				.foregroundStyle(isPlaying ? TickColor.textTertiary : TickColor.textPrimary)
				.lineLimit(1)
				.frame(maxWidth: .infinity, alignment: .leading)

			// Duration
			Text(String(format: "%.1fs", transcript.duration))
				.font(TickFont.mono(11))
				.foregroundStyle(TickColor.textTertiary)

			// Actions
			HStack(spacing: 4) {
				Button(action: {
					onCopy()
					showCopyAnimation()
				}) {
					Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
						.font(TickFont.labelFunc(12, weight: .medium))
						.foregroundStyle(showCopied ? TickColor.success : TickColor.textTertiary)
						.frame(width: 28, height: 28)
						.hexGlass(in: Circle(), interactive: true, style: .regular)
				}
				.buttonStyle(.plain)
				.help("Copy to clipboard")

				Button(action: onPlay) {
					Image(systemName: isPlaying ? "stop.fill" : "play.fill")
						.font(TickFont.labelFunc(12, weight: .medium))
						.foregroundStyle(isPlaying ? TickColor.brand : TickColor.textTertiary)
						.frame(width: 28, height: 28)
						.hexGlass(in: Circle(), interactive: true, style: .regular)
				}
				.buttonStyle(.plain)
				.help(isPlaying ? "Stop playback" : "Play audio")

				Button(action: onDelete) {
					Image(systemName: "trash")
						.font(TickFont.labelFunc(12, weight: .medium))
						.foregroundStyle(TickColor.textTertiary)
						.frame(width: 28, height: 28)
						.hexGlass(in: Circle(), interactive: true, style: .regular)
				}
				.buttonStyle(.plain)
				.help("Delete transcript")
			}
		}
		.padding(.horizontal, TickSpacing.l)
		.padding(.vertical, TickSpacing.m)
		.background {
			if isHovered {
				if let hoverNamespace {
					RoundedRectangle(cornerRadius: 10, style: .continuous)
						.fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.40))
						.hexGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), interactive: true, style: .regular)
						.matchedGeometryEffect(id: "historyTranscriptHover", in: hoverNamespace)
				} else {
					RoundedRectangle(cornerRadius: 10, style: .continuous)
						.fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.40))
						.hexGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), interactive: true, style: .regular)
				}
			}
		}
		.contentShape(Rectangle())
		.onHover { hovered in
			onHover?(hovered)
		}
		.onDisappear { copyTask?.cancel() }
	}

	private func showCopyAnimation() {
		copyTask?.cancel()
		copyTask = Task {
			withAnimation { showCopied = true }
			try await Task.sleep(for: .seconds(1.5))
			withAnimation { showCopied = false }
		}
	}
}
