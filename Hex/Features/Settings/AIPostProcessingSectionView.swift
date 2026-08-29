import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct AIPostProcessingSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		VStack(alignment: .leading, spacing: TickSpacing.m) {
			TickEyebrow(text: "Intelligence")
				.padding(.leading, TickSpacing.xs)

			VStack(alignment: .leading, spacing: TickSpacing.l) {
				TickHero {
					VStack(alignment: .leading, spacing: TickSpacing.s) {
						Text("On-Device AI Post-Processing")
							.font(TickFont.display(24, weight: .semibold))
							.foregroundStyle(TickColor.textPrimary)

						Text("Cuts filler words, cleans up self-corrections, and formats your text to fit the app you're dictating into. Everything runs on your Mac.")
							.font(TickFont.body)
							.foregroundStyle(TickColor.textSecondary)
							.fixedSize(horizontal: false, vertical: true)
					}
				}

				VStack(spacing: 0) {
					// Main On/Off Toggle Row
					HStack(alignment: .center, spacing: TickSpacing.l) {
						VStack(alignment: .leading, spacing: 3) {
							Text("AI Post-Processing")
								.font(TickFont.headingFunc(15, weight: .semibold))
								.foregroundStyle(TickColor.textPrimary)
							Text("Adjusts formatting to what you said and the app you're typing into")
								.font(TickFont.caption)
								.foregroundStyle(TickColor.textSecondary)
						}
						Spacer()
						Toggle(
							"",
							isOn: Binding(
								get: { store.hexSettings.aiPostProcessingMode == .on },
								set: { store.send(.setAIPostProcessingMode($0 ? .on : .off)) }
							)
						)
						.toggleStyle(.switch)
						.labelsHidden()
					}
					.padding(.vertical, TickSpacing.m)

					// Sub-card for local model management
					if store.hexSettings.aiPostProcessingMode == .on {
						Rectangle()
							.fill(TickColor.line)
							.frame(height: 1)
							.padding(.vertical, TickSpacing.xs)

						modelManagement
					}
				}
				.padding(.horizontal, TickSpacing.l)
				.padding(.vertical, TickSpacing.s)
				.hexGlass(cornerRadius: TickRadius.card)
			}
		}
		.animation(TickAnimation.ease, value: store.hexSettings.aiPostProcessingMode)
		.enableInjection()
	}

	@ViewBuilder
	private var modelManagement: some View {
		VStack(alignment: .leading, spacing: TickSpacing.m) {
			VStack(alignment: .leading, spacing: 6) {
				Text("Processing model")
					.font(TickFont.captionFunc(12, weight: .medium))
					.foregroundStyle(TickColor.textSecondary)
				ForEach(OnDeviceAIModel.allCases, id: \.self) { model in
					Button {
						store.send(.selectAIModel(model))
					} label: {
						HStack {
							Image(systemName: store.hexSettings.selectedAIModel == model ? "checkmark.circle.fill" : "circle")
								.foregroundStyle(store.hexSettings.selectedAIModel == model ? TickColor.brand : TickColor.textTertiary)
							VStack(alignment: .leading, spacing: 2) {
								Text(model.displayName).font(TickFont.bodyFunc(14, weight: .semibold))
								Text("\(model.approximateSize) · Runs fully offline").font(TickFont.caption).foregroundStyle(TickColor.textTertiary)
							}
							Spacer()
						}
					}
					.buttonStyle(.plain)
					.padding(.vertical, 4)
				}
			}

			HStack(alignment: .center) {
				VStack(alignment: .leading, spacing: 2) {
					Text(store.hexSettings.selectedAIModel.displayName)
						.font(TickFont.bodyFunc(14, weight: .semibold))
						.foregroundStyle(TickColor.textPrimary)
					Text("\(store.hexSettings.selectedAIModel.approximateSize) · Runs fully offline")
						.font(TickFont.caption)
						.foregroundStyle(TickColor.textTertiary)
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
					HStack(spacing: 5) {
						Image(systemName: "checkmark.circle.fill")
							.foregroundStyle(TickColor.success)
						Text("Ready")
							.font(TickFont.captionFunc(12, weight: .medium))
							.foregroundStyle(TickColor.success)
					}
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
					.background(Color.green.opacity(0.12))
					.clipShape(Capsule())
				}
			}

			if store.isDownloadingAIModel {
				VStack(alignment: .leading, spacing: 4) {
					ProgressView(value: store.aiModelDownloadProgress)
						.tint(TickColor.brand)
					Text("Downloading model… \(store.aiModelDownloadProgress * 100, specifier: "%.1f")%")
						.font(TickFont.caption)
						.foregroundStyle(TickColor.textSecondary)
				}
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
					title: store.aiModelError == nil ? "Download \(store.hexSettings.selectedAIModel.displayName)" : "Retry Download",
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

			HStack(spacing: 6) {
				Image(systemName: "lock.shield.fill")
					.font(.system(size: 11))
					.foregroundStyle(TickColor.textTertiary)
				Text("All processing happens on your Mac. Voice and text never leave it.")
					.font(TickFont.caption)
					.foregroundStyle(TickColor.textTertiary)
			}
			.padding(.top, 2)
		}
		.padding(.vertical, TickSpacing.s)
	}

	private static let byteCountFormatter: ByteCountFormatter = {
		let formatter = ByteCountFormatter()
		formatter.countStyle = .file
		return formatter
	}()
}

// MARK: - Custom Text Field (Liquid Glass input capsule)

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
		.hexGlass(cornerRadius: 10, tint: isFocused ? TickColor.brandSoft : nil, interactive: true, style: .regular)
		.foregroundStyle(TickColor.textPrimary)
		.focused($isFocused)
		.onHover { isHovered = $0 }
		.animation(TickAnimation.ease, value: isFocused)
	}
}
