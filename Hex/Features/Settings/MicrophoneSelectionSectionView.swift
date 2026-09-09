import ComposableArchitecture
import Inject
import SwiftUI

struct MicrophoneSelectionSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		VStack(alignment: .leading, spacing: TickSpacing.m) {
			TickEyebrow(text: "Microphone")
				.padding(.leading, TickSpacing.xs)

			VStack(spacing: TickSpacing.m) {
				HStack(alignment: .center, spacing: TickSpacing.l) {
					VStack(alignment: .leading, spacing: 4) {
						Text("INPUT DEVICE".uppercased())
							.font(TickFont.eyebrow)
							.tracking(0.8)
							.foregroundStyle(TickColor.textTertiary)
						Text(store.defaultInputDeviceName.map { "System Default (\($0))" } ?? "System Default")
							.font(TickFont.body)
							.foregroundStyle(TickColor.textPrimary)
						Text("Override the system default microphone")
							.font(TickFont.caption)
							.foregroundStyle(TickColor.textSecondary)
					}
					Spacer()
					CustomMenuPicker(
						selection: Binding(
							get: { store.hexSettings.selectedMicrophoneID },
							set: { store.send(.setSelectedMicrophoneID($0)) }
						),
						options: [
							(nil as String?, "System Default", "mic")
						] + store.availableInputDevices.map { (Optional($0.id), $0.name, "mic.fill") }
					)
				}

				if let selectedID = store.hexSettings.selectedMicrophoneID,
				   !store.availableInputDevices.contains(where: { $0.id == selectedID }) {
					HStack(spacing: TickSpacing.s) {
						Image(systemName: "exclamationmark.triangle.fill")
							.foregroundStyle(TickColor.warning)
							.font(TickFont.captionFunc(12))
						Text("Selected device not connected. System default will be used.")
							.font(TickFont.caption)
							.foregroundStyle(TickColor.warning)
					}
					.padding(TickSpacing.m)
					.hexGlass(cornerRadius: 8, tint: TickColor.warning.opacity(0.08))
				}

				if !store.unavailableBluetoothInputDevices.isEmpty {
					HStack(alignment: .top, spacing: TickSpacing.s) {
						Image(systemName: "headphones")
							.foregroundStyle(TickColor.textSecondary)
							.font(TickFont.captionFunc(12))
						Text("Microphone profile unavailable in macOS: \(store.unavailableBluetoothInputDevices.map(\.name).joined(separator: ", ")). The headset has a microphone, but macOS currently exposes only its stereo output profile. Hex will add the microphone automatically if the hands-free profile appears.")
							.font(TickFont.caption)
							.foregroundStyle(TickColor.textSecondary)
							.fixedSize(horizontal: false, vertical: true)
					}
					.padding(TickSpacing.m)
					.hexGlass(cornerRadius: 8)
				}
			}
			.padding(TickSpacing.l)
			.hexGlass(cornerRadius: TickRadius.card)
		}
		.enableInjection()
	}
}
