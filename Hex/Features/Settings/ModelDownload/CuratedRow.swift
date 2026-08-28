import ComposableArchitecture
import Inject
import SwiftUI

struct CuratedRow: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<ModelDownloadFeature>
	let model: CuratedModelInfo

	var isSelected: Bool {
		let selected = store.hexSettings.selectedModel
		if model.internalName.contains("*") || model.internalName.contains("?") {
			return fnmatch(model.internalName, selected, 0) == 0
		}
		if selected.contains("*") || selected.contains("?") {
			return fnmatch(selected, model.internalName, 0) == 0
		}
		return model.internalName == selected
	}

	var body: some View {
		Button(action: { store.send(.selectModel(model.internalName)) }) {
			HStack(alignment: .center, spacing: TickSpacing.m) {
				// Selection dot
				ZStack {
					Circle()
						.stroke(isSelected ? Color.primary.opacity(0.8) : Color.primary.opacity(0.2), lineWidth: 1.5)
						.frame(width: 16, height: 16)
					if isSelected {
						Circle()
							.fill(Color.primary)
							.frame(width: 8, height: 8)
					}
				}

				VStack(alignment: .leading, spacing: 4) {
					HStack(spacing: 8) {
						Text(model.displayName)
							.font(TickFont.body)
							.foregroundStyle(TickColor.textPrimary)
						if let badge = model.badge {
							Text(badge.uppercased())
								.font(TickFont.headingFunc(9, weight: .bold))
								.foregroundStyle(TickColor.textSecondary)
								.padding(.horizontal, 6)
								.padding(.vertical, 2)
								.hexGlass(cornerRadius: 4, style: .regular)
						}
					}
					HStack(spacing: TickSpacing.m) {
						HStack(spacing: 4) {
							StarRatingView(model.accuracyStars)
							Text("Accuracy")
								.font(TickFont.caption)
								.foregroundStyle(TickColor.textTertiary)
						}
						HStack(spacing: 4) {
							StarRatingView(model.speedStars)
							Text("Speed")
								.font(TickFont.caption)
								.foregroundStyle(TickColor.textTertiary)
						}
					}
				}

				Spacer(minLength: 12)

				HStack(spacing: TickSpacing.m) {
					Text(model.storageSize)
						.foregroundStyle(TickColor.textTertiary)
						.font(TickFont.mono())

					ZStack {
						if store.isDownloading, store.downloadingModelName == model.internalName {
							ProgressView(value: store.downloadProgress)
								.progressViewStyle(.circular)
								.controlSize(.small)
								.tint(Color.primary)
								.frame(width: 24, height: 24)
						} else if model.isDownloaded {
							Image(systemName: "checkmark.circle.fill")
								.foregroundStyle(TickColor.success)
								.frame(width: 22, height: 22)
						} else {
							Button {
								store.send(.selectModel(model.internalName))
								store.send(.downloadSelectedModel)
							} label: {
								Image(systemName: "arrow.down.circle")
									.font(TickFont.labelFunc(18, weight: .medium))
									.foregroundStyle(TickColor.textSecondary)
							}
							.buttonStyle(.plain)
							.frame(width: 24, height: 24)
						}
					}
				}
			}
			.padding(TickSpacing.m)
			.hexGlass(cornerRadius: 12, tint: isSelected ? Color.primary.opacity(0.04) : nil, interactive: true, style: .regular)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.contextMenu {
			if store.isDownloading, store.downloadingModelName == model.internalName {
				Button("Cancel Download", role: .destructive) { store.send(.cancelDownload) }
			}
			if model.isDownloaded || (store.isDownloading && store.downloadingModelName == model.internalName) {
				Button("Show in Finder") { store.send(.openModelLocation) }
			}
			if model.isDownloaded {
				Button("Delete", role: .destructive) {
					store.send(.selectModel(model.internalName))
					store.send(.deleteSelectedModel)
				}
			}
		}
		.enableInjection()
	}
}
