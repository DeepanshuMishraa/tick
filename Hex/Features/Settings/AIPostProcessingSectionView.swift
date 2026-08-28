import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct AIPostProcessingSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		VStack(alignment: .leading, spacing: TickSpacing.m) {
			TickEyebrow(text: "Tick On-Device AI Post-Processing")
				.padding(.leading, TickSpacing.xs)

			VStack(alignment: .leading, spacing: TickSpacing.l) {
				TickHero {
					VStack(alignment: .leading, spacing: TickSpacing.m) {
						HStack(alignment: .firstTextBaseline) {
							Text("Clean and format transcriptions ")
								.font(TickFont.display(28, weight: .regular))
								.foregroundStyle(TickColor.textPrimary)
							+ Text("on your Mac")
								.font(TickFont.displayItalic(28))
								.foregroundStyle(TickColor.brand)
						}
						Text("Fixes grammar, removes filler words, understands lists, and formats text for the app you're typing in. Nothing is sent to the cloud.")
							.font(TickFont.body)
							.foregroundStyle(TickColor.textPrimary)
							.opacity(0.7)
					}
				}

				VStack(spacing: 0) {
					HStack(alignment: .center, spacing: TickSpacing.l) {
						VStack(alignment: .leading, spacing: 4) {
							Text("MODE")
								.font(TickFont.eyebrow)
								.tracking(0.8)
								.foregroundStyle(TickColor.textTertiary)
							Text("Off / On / App-Aware")
								.font(TickFont.body)
								.foregroundStyle(TickColor.textPrimary)
							Text("App-Aware adapts formatting to the active application and website.")
								.font(TickFont.caption)
								.foregroundStyle(TickColor.textSecondary)
						}
						Spacer()
						CustomMenuPicker(
							selection: Binding(
								get: { store.hexSettings.aiPostProcessingMode },
								set: { store.send(.setAIPostProcessingMode($0)) }
							),
							options: [
								(.off, "Off", "nosign"),
								(.on, "On", "sparkles"),
								(.appAware, "App-Aware", "app.badge")
							]
						)
					}
					.padding(.vertical, TickSpacing.s)

					if store.hexSettings.aiPostProcessingMode != .off {
						Rectangle().fill(TickColor.line).frame(height: 1)
						modelManagement
					}
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
		}
		.animation(TickAnimation.ease, value: store.hexSettings.aiPostProcessingMode)
		.enableInjection()
	}

	@ViewBuilder
	private var modelManagement: some View {
		VStack(alignment: .leading, spacing: TickSpacing.s) {
			HStack(alignment: .firstTextBaseline) {
				VStack(alignment: .leading, spacing: 4) {
					Text("LOCAL MODEL")
						.font(TickFont.eyebrow)
						.tracking(0.8)
						.foregroundStyle(TickColor.textTertiary)
					Text(OnDeviceAIModel.displayName)
						.font(TickFont.body)
						.foregroundStyle(TickColor.textPrimary)
					Text("\(OnDeviceAIModel.approximateSize) download · runs fully offline")
						.font(TickFont.caption)
						.foregroundStyle(TickColor.textSecondary)
				}
				Spacer()
				if store.isDownloadingAIModel {
					Button {
						store.send(.cancelAIModelDownload)
					} label: {
						Label("Cancel", systemImage: "xmark")
					}
					.buttonStyle(.borderless)
				} else if store.aiModelIsDownloaded {
					Label("Ready", systemImage: "checkmark.circle.fill")
					.foregroundStyle(TickColor.success)
				}
			}

			if store.isDownloadingAIModel {
				ProgressView(value: store.aiModelDownloadProgress)
					.tint(TickColor.brand)
				Text("Downloading… \(store.aiModelDownloadProgress * 100, specifier: "%.1f")%")
					.font(TickFont.caption)
					.foregroundStyle(TickColor.textSecondary)
			} else if store.aiModelIsDownloaded {
				HStack {
					if let size = store.aiModelSize {
						Text("Installed size: \(Self.byteCountFormatter.string(fromByteCount: size))")
							.font(TickFont.caption)
							.foregroundStyle(TickColor.textTertiary)
					}
					Spacer()
					TickSecondaryButton(title: "Delete Model", icon: "trash") {
						store.send(.deleteAIModel)
					}
				}
			} else {
				TickPrimaryButton(
					title: store.aiModelError == nil ? "Download Qwen3 1.7B" : "Retry Download",
					icon: "arrow.down.circle"
				) {
					store.send(.downloadAIModel)
				}
			}

			if let error = store.aiModelError {
				Label(error, systemImage: "exclamationmark.triangle.fill")
					.font(TickFont.caption)
					.foregroundStyle(TickColor.error)
			}

			Text("Privacy: transcription text stays on this Mac. Tick never sends it to a cloud API.")
				.font(TickFont.caption)
				.foregroundStyle(TickColor.textTertiary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(.vertical, TickSpacing.s)
	}

	private static let byteCountFormatter: ByteCountFormatter = {
		let formatter = ByteCountFormatter()
		formatter.countStyle = .file
		return formatter
	}()
}

// MARK: - Custom Text Field (cream background, subtle, no native chrome)

struct CustomTextField: View {
	let placeholder: String
	@Binding var text: String
	var isSecure: Bool = false
	@State private var isHovered = false
	@FocusState private var isFocused: Bool

	var body: some View {
		Group {
			if isSecure {
				SecureField(placeholder, text: $text)
			} else {
				TextField(placeholder, text: $text)
			}
		}
		.font(TickFont.body)
		.padding(.horizontal, TickSpacing.m)
		.padding(.vertical, TickSpacing.s + 2)
		.background(
			RoundedRectangle(cornerRadius: 10)
				.fill(TickColor.canvas)
				.overlay(
					RoundedRectangle(cornerRadius: 10)
						.stroke(isFocused ? TickColor.brand : (isHovered ? TickColor.lineStrong : TickColor.line), lineWidth: 1)
				)
		)
		.foregroundStyle(TickColor.textPrimary)
		.focused($isFocused)
		.onHover { isHovered = $0 }
		.animation(TickAnimation.ease, value: isFocused)
	}
}
