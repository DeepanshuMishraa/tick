import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct SoundSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		VStack(alignment: .leading, spacing: TickSpacing.m) {
			TickEyebrow(text: "Audio")
				.padding(.leading, TickSpacing.xs)

			VStack(spacing: TickSpacing.l) {
				HStack(alignment: .center, spacing: TickSpacing.l) {
					VStack(alignment: .leading, spacing: 4) {
						Text("EFFECTS".uppercased())
							.font(TickFont.eyebrow)
							.tracking(0.8)
							.foregroundStyle(TickColor.textTertiary)
						Text("Sound Effects")
							.font(TickFont.body)
							.foregroundStyle(TickColor.textPrimary)
						Text("Audio feedback for recording actions")
							.font(TickFont.caption)
							.foregroundStyle(TickColor.textSecondary)
					}
					Spacer()
					TickToggle(isOn: Binding(
						get: { store.hexSettings.soundEffectsEnabled },
						set: { store.send(.toggleSoundEffectsEnabled($0)) }
					))
				}

				if store.hexSettings.soundEffectsEnabled {
					VStack(alignment: .leading, spacing: TickSpacing.s) {
						HStack {
							Text("VOLUME")
								.font(TickFont.eyebrow)
								.tracking(0.8)
								.foregroundStyle(TickColor.textTertiary)
							Spacer()
							Text(formattedVolume(for: store.hexSettings.soundEffectsVolume))
								.font(TickFont.mono())
								.foregroundStyle(TickColor.textPrimary)
						}
						TickSlider(
							value: Binding(
								get: { volumePercentage(for: store.hexSettings.soundEffectsVolume) },
								set: { store.send(.setSoundEffectsVolume(actualVolume(fromPercentage: $0))) }
							),
							range: 0...1
						)
					}
				}
			}
			.padding(TickSpacing.l)
			.hexGlass(cornerRadius: TickRadius.card)
		}
		.animation(TickAnimation.ease, value: store.hexSettings.soundEffectsEnabled)
		.enableInjection()
	}
}

private func formattedVolume(for actualVolume: Double) -> String {
	let percent = volumePercentage(for: actualVolume)
	return "\(Int(round(percent * 100)))%"
}

private func volumePercentage(for actualVolume: Double) -> Double {
	guard HexSettings.baseSoundEffectsVolume > 0 else { return 0 }
	let ratio = actualVolume / HexSettings.baseSoundEffectsVolume
	return max(0, min(1, ratio))
}

private func actualVolume(fromPercentage percentage: Double) -> Double {
	let clampedPercentage = max(0, min(1, percentage))
	return clampedPercentage * HexSettings.baseSoundEffectsVolume
}
