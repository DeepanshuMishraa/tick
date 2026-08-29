import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct GeneralSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		VStack(alignment: .leading, spacing: TickSpacing.m) {
			TickEyebrow(text: "Appearance")
				.padding(.leading, TickSpacing.xs)

			ThemeColorCard(
				selectedColor: store.hexSettings.themeColor,
				onSelect: { store.send(.setThemeColor($0)) }
			)

			TickEyebrow(text: "General")
				.padding(.leading, TickSpacing.xs)
				.padding(.top, TickSpacing.xs)

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
			.hexGlass(cornerRadius: TickRadius.card)
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
			.hexGlass(cornerRadius: 10, interactive: true)
		}
		.menuStyle(.borderlessButton)
		.fixedSize()
		.onHover { isHovered = $0 }
	}
}

// MARK: - Theme Color Components

private struct ThemeColorCard: View {
	let selectedColor: HexThemeColor
	let onSelect: (HexThemeColor) -> Void

	var body: some View {
		HStack(alignment: .center) {
			VStack(alignment: .leading, spacing: 4) {
				Text("THEME".uppercased())
					.font(TickFont.eyebrow)
					.tracking(0.8)
					.foregroundStyle(TickColor.textTertiary)
				Text("Colour")
					.font(TickFont.body)
					.foregroundStyle(TickColor.textPrimary)
			}

			Spacer()

			HStack(alignment: .top, spacing: 10) {
				ForEach(HexThemeColor.allCases, id: \.self) { color in
					ThemeColorSwatch(
						color: color,
						isSelected: color == selectedColor,
						onSelect: { onSelect(color) }
					)
				}
			}
		}
		.padding(.horizontal, TickSpacing.l)
		.padding(.vertical, TickSpacing.m)
		.hexGlass(cornerRadius: TickRadius.card)
	}
}

private struct ThemeColorSwatch: View {
	let color: HexThemeColor
	let isSelected: Bool
	let onSelect: () -> Void
	@State private var isHovered = false

	var body: some View {
		Button(action: onSelect) {
			VStack(spacing: 4) {
				ZStack {
					if isSelected {
						Circle()
							.stroke(
								color == .multicolor
									? Color.cyan.opacity(0.85)
									: (color == .monochrome ? Color.primary.opacity(0.65) : color.swatchColor.opacity(0.85)),
								lineWidth: 2
							)
							.frame(width: 26, height: 26)
							.transition(.scale.combined(with: .opacity))
					}

					swatchCircle
						.frame(width: 18, height: 18)
						.scaleEffect(isHovered ? 1.08 : 1.0)
						.shadow(
							color: isSelected ? (color == .monochrome ? Color.white.opacity(0.2) : color.swatchColor.opacity(0.40)) : Color.clear,
							radius: 4,
							x: 0,
							y: 1
						)
				}
				.frame(width: 28, height: 28)

				if isSelected {
					Text(color.displayName)
						.font(TickFont.captionFunc(10, weight: .medium))
						.foregroundStyle(TickColor.textSecondary)
						.fixedSize()
						.transition(.opacity)
				} else {
					Text(" ")
						.font(TickFont.captionFunc(10, weight: .medium))
						.fixedSize()
						.opacity(0)
				}
			}
		}
		.buttonStyle(.plain)
		.onHover { isHovered = $0 }
		.animation(.spring(response: 0.28, dampingFraction: 0.75), value: isSelected)
		.animation(.easeInOut(duration: 0.15), value: isHovered)
	}

	@ViewBuilder
	private var swatchCircle: some View {
		if color == .multicolor {
			Circle()
				.fill(
					AngularGradient(
						gradient: Gradient(colors: [
							.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red
						]),
						center: .center
					)
				)
				.overlay(
					Circle()
						.stroke(Color.white.opacity(0.25), lineWidth: 0.5)
				)
		} else {
			Circle()
				.fill(color.swatchColor)
				.overlay(
					Circle()
						.stroke(Color.white.opacity(0.20), lineWidth: 0.5)
				)
		}
	}
}

