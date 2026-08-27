import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct GeneralSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		VStack(alignment: .leading, spacing: TickSpacing.m) {
			TickEyebrow(text: "General")
				.padding(.leading, TickSpacing.xs)

			VStack(spacing: 0) {
				row(
					eyebrow: "Launch",
					title: "Open on Login",
					subtitle: nil,
					isOn: Binding(
						get: { store.hexSettings.openOnLogin },
						set: { store.send(.toggleOpenOnLogin($0)) }
					)
				)
				divider()
				row(
					eyebrow: "App",
					title: "Show Dock Icon",
					subtitle: nil,
					isOn: Binding(
						get: { store.hexSettings.showDockIcon },
						set: { store.send(.toggleShowDockIcon($0)) }
					)
				)
				divider()
				row(
					eyebrow: "Power",
					title: "Prevent System Sleep",
					subtitle: "Keep Mac awake while recording",
					isOn: Binding(
						get: { store.hexSettings.preventSystemSleep },
						set: { store.send(.togglePreventSystemSleep($0)) }
					)
				)
				divider()
				row(
					eyebrow: "Performance",
					title: "Super Fast Mode",
					subtitle: "Keep microphone warm for near-instant capture",
					isOn: Binding(
						get: { store.hexSettings.superFastModeEnabled },
						set: { store.send(.toggleSuperFastMode($0)) }
					)
				)
				divider()
				audioBehaviorRow
			}
			.padding(.horizontal, TickSpacing.l)
			.padding(.vertical, TickSpacing.m)
			.background(
				RoundedRectangle(cornerRadius: TickRadius.card)
					.fill(TickColor.surface)
					.overlay(
						RoundedRectangle(cornerRadius: TickRadius.card)
							.stroke(TickColor.cardBorder, lineWidth: 1)
					)
			)
		}
		.enableInjection()
	}

	@ViewBuilder
	private func row(eyebrow: String, title: String, subtitle: String?, isOn: Binding<Bool>) -> some View {
		HStack(alignment: .center, spacing: TickSpacing.l) {
			VStack(alignment: .leading, spacing: 4) {
				Text(eyebrow.uppercased())
					.font(TickFont.eyebrow)
					.tracking(0.8)
					.foregroundStyle(TickColor.textTertiary)
				Text(title)
					.font(TickFont.body)
					.foregroundStyle(TickColor.textPrimary)
				if let subtitle {
					Text(subtitle)
						.font(TickFont.caption)
						.foregroundStyle(TickColor.textSecondary)
				}
			}
			Spacer()
			TickToggle(isOn: isOn)
		}
		.padding(.vertical, TickSpacing.s)
	}

	@ViewBuilder
	private var audioBehaviorRow: some View {
		HStack(alignment: .center, spacing: TickSpacing.l) {
			VStack(alignment: .leading, spacing: 4) {
				Text("AUDIO BEHAVIOR".uppercased())
					.font(TickFont.eyebrow)
					.tracking(0.8)
					.foregroundStyle(TickColor.textTertiary)
				Text("While recording")
					.font(TickFont.body)
					.foregroundStyle(TickColor.textPrimary)
				Text("Pick how audio is handled when you start a recording")
					.font(TickFont.caption)
					.foregroundStyle(TickColor.textSecondary)
			}
			Spacer()
			CustomMenuPicker(
				selection: Binding(
					get: { store.hexSettings.recordingAudioBehavior },
					set: { store.send(.setRecordingAudioBehavior($0)) }
				),
				options: [
					(.pauseMedia, "Pause Media", "pause.fill"),
					(.mute, "Mute Volume", "speaker.slash.fill"),
					(.doNothing, "Do Nothing", "hand.raised.slash.fill")
				]
			)
		}
		.padding(.vertical, TickSpacing.s)
	}

	private func divider() -> some View {
		Rectangle()
			.fill(TickColor.line)
			.frame(height: 1)
	}
}

// MARK: - Custom Menu Picker (not a native macOS popup)

struct CustomMenuPicker<Option: Hashable>: View {
	@Binding var selection: Option
	let options: [(Option, String, String)]
	@State private var isOpen = false
	@State private var isHovered = false

	private var currentLabel: String {
		options.first(where: { $0.0 == selection })?.1 ?? "Select"
	}

	private var currentIcon: String {
		options.first(where: { $0.0 == selection })?.2 ?? "circle"
	}

	var body: some View {
		Menu {
			ForEach(options, id: \.0) { option, label, icon in
				Button {
					selection = option
				} label: {
					Label(label, systemImage: icon)
				}
			}
		} label: {
			HStack(spacing: TickSpacing.xs) {
				Image(systemName: currentIcon)
					.font(TickFont.labelFunc(12, weight: .medium))
				Text(currentLabel)
					.font(TickFont.labelFunc(13, weight: .medium))
				Image(systemName: "chevron.down")
					.font(TickFont.headingFunc(9, weight: .bold))
			}
			.foregroundStyle(TickColor.textPrimary)
			.padding(.horizontal, TickSpacing.m)
			.padding(.vertical, TickSpacing.s)
			.background(
				RoundedRectangle(cornerRadius: 10)
					.fill(TickColor.canvas)
					.overlay(
						RoundedRectangle(cornerRadius: 10)
							.stroke(isHovered ? TickColor.brand.opacity(0.4) : TickColor.line, lineWidth: 1)
					)
			)
		}
		.menuStyle(.borderlessButton)
		.fixedSize()
		.onHover { isHovered = $0 }
	}
}
