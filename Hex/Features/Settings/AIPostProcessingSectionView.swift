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
		VStack(alignment: .leading, spacing: 16) {
			VStack(alignment: .leading, spacing: 4) {
				Text("SELECT ON-DEVICE MODEL")
					.font(TickFont.eyebrow)
					.tracking(0.8)
					.foregroundStyle(TickColor.textTertiary)
				Text("Choose the local language model used to format and refine transcriptions.")
					.font(TickFont.caption)
					.foregroundStyle(TickColor.textSecondary)
			}

			// Creative Model Selection Cards Grid
			VStack(spacing: 12) {
				ForEach(OnDeviceAIModel.allCases, id: \.self) { model in
					let isSelected = store.hexSettings.selectedAIModel == model
					AIModelSelectionCard(
						model: model,
						isSelected: isSelected,
						isDownloading: isSelected && store.isDownloadingAIModel,
						isDownloaded: isSelected && store.aiModelIsDownloaded,
						downloadProgress: store.aiModelDownloadProgress,
						installedSize: isSelected ? store.aiModelSize : nil,
						error: isSelected ? store.aiModelError : nil,
						onSelect: {
							store.send(.selectAIModel(model))
						},
						onDownload: {
							store.send(.downloadAIModel)
						},
						onCancel: {
							store.send(.cancelAIModelDownload)
						},
						onDelete: {
							store.send(.deleteAIModel)
						}
					)
				}
			}

			HStack(spacing: 6) {
				Image(systemName: "lock.shield.fill")
					.font(.system(size: 11))
					.foregroundStyle(TickColor.textTertiary)
				Text("All post-processing runs 100% on Apple Silicon. Audio and text never leave your device.")
					.font(TickFont.caption)
					.foregroundStyle(TickColor.textTertiary)
			}
			.padding(.top, 4)
		}
		.padding(.vertical, TickSpacing.s)
	}

	private static let byteCountFormatter: ByteCountFormatter = {
		let formatter = ByteCountFormatter()
		formatter.countStyle = .file
		return formatter
	}()
}

// MARK: - Creative AI Model Selection Card

private struct AIModelSelectionCard: View {
	let model: OnDeviceAIModel
	let isSelected: Bool
	let isDownloading: Bool
	let isDownloaded: Bool
	let downloadProgress: Double
	let installedSize: Int64?
	let error: String?

	let onSelect: () -> Void
	let onDownload: () -> Void
	let onCancel: () -> Void
	let onDelete: () -> Void

	@State private var isHovered = false

	private var isPrimary: Bool {
		model == .qwen3_17b
	}

	private var badgeLabel: String {
		isPrimary ? "Recommended · Maximum Precision" : "Ultra-Fast · Minimal RAM"
	}

	private var descriptionText: String {
		isPrimary
			? "Excels at deep conversational context, smart list detection, punctuation, and multi-paragraph formatting."
			: "Ultra-low latency with a featherweight 300MB memory footprint. Great for fast, succinct dictations."
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .top, spacing: 14) {
				// Radio selector icon
				Button(action: onSelect) {
					ZStack {
						Circle()
							.stroke(isSelected ? TickColor.brand : Color.primary.opacity(0.18), lineWidth: 1.5)
							.frame(width: 20, height: 20)

						if isSelected {
							Circle()
								.fill(TickColor.brand)
								.frame(width: 10, height: 10)
						}
					}
				}
				.buttonStyle(.plain)
				.padding(.top, 2)

				// Title & Badges
				VStack(alignment: .leading, spacing: 4) {
					HStack(spacing: 8) {
						Text(model.displayName)
							.font(.system(size: 15, weight: .semibold, design: .default))
							.foregroundStyle(TickColor.textPrimary)

						Text(badgeLabel)
							.font(.system(size: 10, weight: .medium, design: .default))
							.foregroundStyle(isPrimary ? TickColor.brand : TickColor.textSecondary)
							.padding(.horizontal, 7)
							.padding(.vertical, 2)
							.background(isPrimary ? TickColor.brand.opacity(0.10) : Color.primary.opacity(0.06))
							.cornerRadius(4)
					}

					Text(descriptionText)
						.font(.system(size: 12, weight: .regular, design: .default))
						.foregroundStyle(TickColor.textSecondary)
						.fixedSize(horizontal: false, vertical: true)
						.lineSpacing(2)
				}

				Spacer(minLength: 8)

				// Spec Badge
				VStack(alignment: .trailing, spacing: 3) {
					Text(model.approximateSize)
						.font(.system(size: 12, weight: .semibold, design: .monospaced))
						.foregroundStyle(TickColor.textPrimary)
					Text("Size on disk")
						.font(.system(size: 10, weight: .regular, design: .default))
						.foregroundStyle(TickColor.textTertiary)
				}
			}

			// Download / Status Actions Bar
			if isSelected {
				Divider()
					.padding(.vertical, 2)

				HStack(alignment: .center) {
					if isDownloading {
						VStack(alignment: .leading, spacing: 4) {
							ProgressView(value: downloadProgress)
								.tint(TickColor.brand)
							Text("Downloading… \(Int(downloadProgress * 100))%")
								.font(.system(size: 11, weight: .medium, design: .monospaced))
								.foregroundStyle(TickColor.brand)
						}

						Spacer(minLength: 16)

						Button(action: onCancel) {
							Text("Cancel")
								.font(.system(size: 12, weight: .medium, design: .default))
								.foregroundStyle(TickColor.textSecondary)
								.padding(.horizontal, 10)
								.padding(.vertical, 4)
								.hexGlass(cornerRadius: 6, interactive: true)
						}
						.buttonStyle(.plain)
					} else if isDownloaded {
						HStack(spacing: 6) {
							Image(systemName: "checkmark.circle.fill")
								.font(.system(size: 13, weight: .semibold))
								.foregroundStyle(TickColor.success)
							Text("Ready · Installed")
								.font(.system(size: 12, weight: .medium, design: .default))
								.foregroundStyle(TickColor.success)
						}

						Spacer()

						Button(action: onDelete) {
							HStack(spacing: 4) {
								Image(systemName: "trash")
									.font(.system(size: 11))
								Text("Delete")
									.font(.system(size: 12, weight: .medium, design: .default))
							}
							.foregroundStyle(TickColor.error.opacity(0.85))
							.padding(.horizontal, 10)
							.padding(.vertical, 4)
							.hexGlass(cornerRadius: 6, interactive: true)
						}
						.buttonStyle(.plain)
					} else {
						if let error {
							Label(error, systemImage: "exclamationmark.triangle.fill")
								.font(.system(size: 11, weight: .medium))
								.foregroundStyle(TickColor.error)
						} else {
							Text("Model not downloaded yet")
								.font(.system(size: 12, weight: .regular, design: .default))
								.foregroundStyle(TickColor.textTertiary)
						}

						Spacer()

						Button(action: onDownload) {
							HStack(spacing: 6) {
								Image(systemName: "arrow.down.circle.fill")
									.font(.system(size: 12, weight: .semibold))
								Text(error == nil ? "Download Model" : "Retry Download")
									.font(.system(size: 12, weight: .semibold, design: .default))
							}
							.foregroundStyle(Color.white)
							.padding(.horizontal, 14)
							.padding(.vertical, 6)
							.background(
								LinearGradient(
									colors: [TickColor.brand, TickColor.brand.opacity(0.85)],
									startPoint: .top,
									endPoint: .bottom
								)
							)
							.clipShape(RoundedRectangle(cornerRadius: 7))
							.shadow(color: TickColor.brand.opacity(0.3), radius: 4, x: 0, y: 2)
						}
						.buttonStyle(.plain)
					}
				}
			}
		}
		.padding(14)
		.background(
			RoundedRectangle(cornerRadius: 12)
				.fill(isSelected ? TickColor.brand.opacity(0.04) : Color.clear)
		)
		.overlay(
			RoundedRectangle(cornerRadius: 12)
				.stroke(
					isSelected
						? LinearGradient(
							colors: [TickColor.brand.opacity(0.70), TickColor.brand.opacity(0.30)],
							startPoint: .topLeading,
							endPoint: .bottomTrailing
						)
						: LinearGradient(
							colors: [Color.white.opacity(isHovered ? 0.20 : 0.08), Color.white.opacity(isHovered ? 0.08 : 0.02)],
							startPoint: .topLeading,
							endPoint: .bottomTrailing
						),
					lineWidth: isSelected ? 1.25 : 0.75
				)
		)
		.hexGlass(cornerRadius: 12, style: .regular)
		.scaleEffect(isHovered ? 1.01 : 1.0)
		.animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
		.onHover { isHovered = $0 }
		.contentShape(Rectangle())
		.onTapGesture {
			if !isSelected {
				onSelect()
			}
		}
	}
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
