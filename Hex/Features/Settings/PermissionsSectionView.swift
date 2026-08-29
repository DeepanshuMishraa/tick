import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct PermissionsSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	let microphonePermission: PermissionStatus
	let accessibilityPermission: PermissionStatus
	let inputMonitoringPermission: PermissionStatus

	var body: some View {
		TickHero {
			VStack(alignment: .leading, spacing: TickSpacing.l) {
				VStack(alignment: .leading, spacing: TickSpacing.s) {
					HStack(alignment: .firstTextBaseline) {
						Text("Tick needs a few ")
							.font(TickFont.display(26, weight: .regular))
							.foregroundStyle(TickColor.textPrimary)
						+ Text("permissions")
							.font(TickFont.displayItalic(26))
							.foregroundStyle(TickColor.brand)
					}
					Text("Grant these to start transcribing.")
						.font(TickFont.body)
						.foregroundStyle(TickColor.textPrimary)
						.opacity(0.7)
				}

				VStack(spacing: TickSpacing.s) {
					permissionRow(
						eyebrow: "Audio",
						title: "Microphone",
						subtitle: "For voice capture",
						icon: "mic.fill",
						status: microphonePermission,
						action: { store.send(.requestMicrophone) }
					)

					permissionRow(
						eyebrow: "Input",
						title: "Accessibility & Input Monitoring",
						subtitle: "For hotkey detection",
						icon: "accessibility",
						status: combinedAccessibilityStatus,
						action: {
							// PermissionFlow shows a single floating panel at a time,
							// so request only the currently missing permission.
							if accessibilityPermission != .granted {
								store.send(.requestAccessibility)
							} else if inputMonitoringPermission != .granted {
								store.send(.requestInputMonitoring)
							}
						}
					)
				}
			}
		}
		.enableInjection()
	}

	private func permissionRow(
		eyebrow: String,
		title: String,
		subtitle: String,
		icon: String,
		status: PermissionStatus,
		action: @escaping () -> Void
	) -> some View {
		HStack(alignment: .center, spacing: TickSpacing.m) {
			ZStack {
				RoundedRectangle(cornerRadius: 10)
					.fill(.clear)
					.frame(width: 36, height: 36)
					.hexGlass(cornerRadius: 10, tint: status == .granted ? TickColor.brand.opacity(0.12) : nil)
				Image(systemName: icon)
					.font(TickFont.labelFunc(14, weight: .medium))
					.foregroundStyle(status == .granted ? TickColor.brand : TickColor.textSecondary)
			}

			VStack(alignment: .leading, spacing: 2) {
				Text(eyebrow.uppercased())
					.font(TickFont.eyebrow)
					.tracking(0.8)
					.foregroundStyle(TickColor.textTertiary)
				Text(title)
					.font(TickFont.body)
					.foregroundStyle(TickColor.textPrimary)
				Text(subtitle)
					.font(TickFont.caption)
					.foregroundStyle(TickColor.textSecondary)
			}

			Spacer()

			switch status {
			case .granted:
				Label("Granted", systemImage: "checkmark")
					.font(TickFont.labelFunc(12, weight: .medium))
					.foregroundStyle(TickColor.success)
					.padding(.horizontal, TickSpacing.m)
					.padding(.vertical, TickSpacing.xs)
					.hexGlass(in: Capsule(), tint: TickColor.success.opacity(0.12))
			case .denied, .notDetermined:
				TickPrimaryButton(title: "Grant", icon: nil, action: action)
			}
		}
		.padding(TickSpacing.m)
		.hexGlass(cornerRadius: 12)
	}

	private var combinedAccessibilityStatus: PermissionStatus {
		if accessibilityPermission == .granted && inputMonitoringPermission == .granted {
			return .granted
		}
		if accessibilityPermission == .denied || inputMonitoringPermission == .denied {
			return .denied
		}
		return .notDetermined
	}
}
