//
//  SoundEffect.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import AVFoundation
import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import SwiftUI

// Thank you. Never mind then.What a beautiful idea.
public enum SoundEffect: String, CaseIterable {
  case pasteTranscript
  case startRecording
  case stopRecording
  case startContinuous
  case stopContinuous
  case cancel
  case error

  public var fileName: String {
    switch self {
    case .startRecording:
      return "push"
    case .stopRecording, .stopContinuous:
      return "enda"
    case .startContinuous:
      return "continous"
    case .cancel, .error:
      return "enda"
    case .pasteTranscript:
      return self.rawValue
    }
  }

  var fileExtension: String {
    "mp3"
  }
}

@DependencyClient
public struct SoundEffectsClient {
  public var play: @Sendable (SoundEffect) -> Void
  public var stop: @Sendable (SoundEffect) -> Void
  public var stopAll: @Sendable () -> Void
  public var preloadSounds: @Sendable () async -> Void
}

extension SoundEffectsClient: DependencyKey {
  public static var liveValue: SoundEffectsClient {
    let live = SoundEffectsClientLive()
    return SoundEffectsClient(
      play: { soundEffect in
        Task { await live.play(soundEffect) }
      },
      stop: { soundEffect in
        Task { await live.stop(soundEffect) }
      },
      stopAll: {
        Task { await live.stopAll() }
      },
      preloadSounds: {
        await live.preloadSounds()
      }
    )
  }
}

public extension DependencyValues {
  var soundEffects: SoundEffectsClient {
    get { self[SoundEffectsClient.self] }
    set { self[SoundEffectsClient.self] = newValue }
  }
}

actor SoundEffectsClientLive {
  private let logger = HexLog.sound
  private let baselineVolume = HexSettings.baseSoundEffectsVolume

  @Shared(.hexSettings) var hexSettings: HexSettings
  private var players: [SoundEffect: AVAudioPlayer] = [:]

  func play(_ soundEffect: SoundEffect) {
    guard hexSettings.soundEffectsEnabled else { return }

    // Playback can race app startup. Load the requested cue on demand so the
    // first hotkey press never depends on preload timing.
    if players[soundEffect] == nil {
      loadSound(soundEffect)
    }
    guard let player = players[soundEffect] else {
      logger.error("Requested sound \(soundEffect.rawValue) could not be loaded")
      return
    }
    let clampedVolume = min(max(hexSettings.soundEffectsVolume, 0), baselineVolume)
    player.volume = Float(clampedVolume)
    player.stop()
    player.currentTime = 0
    player.play()
  }

  func stop(_ soundEffect: SoundEffect) {
    players[soundEffect]?.stop()
  }

  func stopAll() {
    players.values.forEach { $0.stop() }
  }

  func preloadSounds() async {
    guard !isSetup else { return }

    for soundEffect in SoundEffect.allCases {
      loadSound(soundEffect)
    }

    isSetup = true
  }

  private var isSetup = false

  private func loadSound(_ soundEffect: SoundEffect) {
    guard let url = Bundle.main.url(
      forResource: soundEffect.fileName,
      withExtension: soundEffect.fileExtension
    ) else {
      logger.error("Missing sound resource \(soundEffect.fileName).\(soundEffect.fileExtension)")
      return
    }

    do {
      let player = try AVAudioPlayer(contentsOf: url)
      player.prepareToPlay()
      players[soundEffect] = player
    } catch {
      logger.error("Failed to load sound \(soundEffect.rawValue): \(error.localizedDescription)")
    }
  }
}
