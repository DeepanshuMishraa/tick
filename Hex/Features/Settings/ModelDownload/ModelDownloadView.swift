import ComposableArchitecture
import Inject
import SwiftUI

public struct ModelDownloadView: View {
	@ObserveInjection var inject

	@Bindable var store: StoreOf<ModelDownloadFeature>
	var shouldFlash: Bool = false

	public init(store: StoreOf<ModelDownloadFeature>, shouldFlash: Bool = false) {
		self.store = store
		self.shouldFlash = shouldFlash
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: TickSpacing.m) {
			if !store.modelBootstrapState.isModelReady,
			   let message = store.modelBootstrapState.lastError,
			   !message.isEmpty
			{
				InfoBanner(
					title: "Download failed",
					subtitle: message,
					style: .error
				)
			}
			if !store.anyModelDownloaded {
				InfoBanner(
					title: "Download a model to start transcribing",
					subtitle: "Choose a model below and tap download.",
					progress: store.isDownloading ? store.downloadProgress : nil,
					style: .info
				)
				.overlay(
					RoundedRectangle(cornerRadius: TickRadius.card)
						.stroke(Color.clear, lineWidth: 0)
						.animation(.easeInOut(duration: 0.5).repeatCount(3, autoreverses: true), value: shouldFlash)
				)
			}
			CuratedList(store: store)
			if let err = store.downloadError {
				HStack(spacing: TickSpacing.s) {
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundStyle(TickColor.error)
						.font(TickFont.caption)
					Text("Download Error: \(err)")
						.foregroundStyle(TickColor.error)
						.font(TickFont.caption)
				}
				.padding(TickSpacing.s)
				.hexGlass(cornerRadius: 8)
			}
		}
		.frame(maxWidth: 560)
		.task {
			if store.availableModels.isEmpty {
				store.send(.fetchModels)
			}
		}
		.enableInjection()
	}
}

/// Reusable info banner — yellow tint for info, red for error
struct InfoBanner: View {
	enum Style { case info, error }
	var title: String
	var subtitle: String?
	var progress: Double? = nil
	var style: Style = .info

	private var accent: Color {
		switch style {
		case .info: return TickColor.warning
		case .error: return TickColor.error
		}
	}

	private var background: Color {
		switch style {
		case .info: return TickColor.hero
		case .error: return TickColor.error.opacity(0.06)
		}
	}

	var body: some View {
		HStack(alignment: .top, spacing: TickSpacing.m) {
			ZStack {
				Circle()
					.fill(accent.opacity(0.15))
					.frame(width: 30, height: 30)
				Image(systemName: style == .info ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill")
					.font(TickFont.labelFunc(14, weight: .semibold))
					.foregroundStyle(accent)
			}

			VStack(alignment: .leading, spacing: TickSpacing.xs) {
				Text(title)
					.font(TickFont.labelFunc(13, weight: .semibold))
					.foregroundStyle(TickColor.textPrimary)
				if let subtitle {
					Text(subtitle)
						.font(TickFont.caption)
						.foregroundStyle(TickColor.textPrimary)
						.opacity(0.7)
				}
				if let progress {
					GeometryReader { proxy in
						ZStack(alignment: .leading) {
							RoundedRectangle(cornerRadius: 2)
								.fill(TickColor.canvas)
								.frame(height: 4)
							RoundedRectangle(cornerRadius: 2)
								.fill(accent)
								.frame(width: proxy.size.width * progress, height: 4)
								.animation(.easeInOut(duration: 0.2), value: progress)
						}
					}
					.frame(height: 4)
				}
			}
		}
		.padding(TickSpacing.m)
		.frame(maxWidth: .infinity, alignment: .leading)
		.hexGlass(cornerRadius: 12, interactive: true)
	}
}
