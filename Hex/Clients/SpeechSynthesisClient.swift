//
//  SpeechSynthesisClient.swift
//  Hex
//

import AppKit
import AVFoundation
import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
#if canImport(SwiftEdgeTTS)
import SwiftEdgeTTS
#endif

private let ttsLogger = HexLog.sound

@DependencyClient
struct SpeechSynthesisClient {
	var speak: @Sendable (String) async throws -> Void
	var stopSpeaking: @Sendable () async -> Void
	var isSpeaking: @Sendable () async -> Bool = { false }
}

extension SpeechSynthesisClient: DependencyKey {
	static var liveValue: Self {
		let live = SpeechSynthesisClientLive()
		return .init(
			speak: { text in try await live.speak(text) },
			stopSpeaking: { await live.stopSpeaking() },
			isSpeaking: { await live.isSpeaking() }
		)
	}
}

extension DependencyValues {
	var speechSynthesis: SpeechSynthesisClient {
		get { self[SpeechSynthesisClient.self] }
		set { self[SpeechSynthesisClient.self] = newValue }
	}
}

actor SpeechSynthesisClientLive {
	@Shared(.hexSettings) var hexSettings: HexSettings

	private var player: AVAudioPlayer?
	private var currentTask: Task<Void, Error>?

	func speak(_ text: String) async throws {
		guard hexSettings.ttsEnabled, !text.isEmpty else { return }

		// Stop any ongoing speech
		await stopSpeaking()

		let voice = hexSettings.ttsVoice.isEmpty ? "en-US-JennyNeural" : hexSettings.ttsVoice

		// Try Edge TTS first, fall back to NSSpeechSynthesizer
		do {
			try await speakWithEdgeTTS(text: text, voice: voice)
		} catch {
			ttsLogger.warning("Edge TTS failed (\(error.localizedDescription)), falling back to system TTS")
			speakWithSystemTTS(text: text)
		}
	}

	func stopSpeaking() {
		player?.stop()
		player = nil
		currentTask?.cancel()
		currentTask = nil
	}

	func isSpeaking() -> Bool {
		player?.isPlaying == true
	}

	// MARK: - Edge TTS (via SwiftEdgeTTS if available)

	private func speakWithEdgeTTS(text: String, voice: String) async throws {
#if canImport(SwiftEdgeTTS)
		let tempDir = FileManager.default.temporaryDirectory
		let outputURL = tempDir.appendingPathComponent("tts-\(UUID().uuidString).mp3")

		let ttsService = EdgeTTSService()
		let audioURL = try await ttsService.synthesize(
			text: text,
			voice: voice,
			outputURL: outputURL,
			rate: "+0%",
			volume: "+0%",
			pitch: "+0Hz"
		)

		let audioData = try Data(contentsOf: audioURL)
		try await playAudioData(audioData)

		// Clean up temp file
		try? FileManager.default.removeItem(at: audioURL)
#else
		// If SwiftEdgeTTS is not available, throw to trigger fallback
		throw TTSError.edgeTTSUnavailable
#endif
	}

	// MARK: - System TTS Fallback

	private nonisolated func speakWithSystemTTS(text: String) {
		let synth = NSSpeechSynthesizer()
		synth.setVoice(nil) // Use system default voice
		synth.startSpeaking(text)
	}

	// MARK: - Audio Playback

	private func playAudioData(_ data: Data) async throws {
		let player = try AVAudioPlayer(data: data)
		player.prepareToPlay()
		self.player = player
		player.play()

		// Wait for playback to finish or be interrupted
		while player.isPlaying {
			try await Task.sleep(for: .milliseconds(100))
			try Task.checkCancellation()
		}
	}
}

enum TTSError: Error, LocalizedError {
	case edgeTTSUnavailable

	var errorDescription: String? {
		switch self {
		case .edgeTTSUnavailable:
			return "Edge TTS is not available on this system"
		}
	}
}
