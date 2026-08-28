import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct HistorySectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		VStack(alignment: .leading, spacing: TickSpacing.m) {
			TickEyebrow(text: "History")
				.padding(.leading, TickSpacing.xs)

			VStack(spacing: 0) {
				HStack(alignment: .center, spacing: TickSpacing.l) {
					VStack(alignment: .leading, spacing: 4) {
						Text("STORAGE".uppercased())
							.font(TickFont.eyebrow)
							.tracking(0.8)
							.foregroundStyle(TickColor.textTertiary)
						Text("Save Transcription History")
							.font(TickFont.body)
							.foregroundStyle(TickColor.textPrimary)
						Text("Keep transcriptions and audio recordings for later access")
							.font(TickFont.caption)
							.foregroundStyle(TickColor.textSecondary)
					}
					Spacer()
					TickToggle(isOn: Binding(
						get: { store.hexSettings.saveTranscriptionHistory },
						set: { store.send(.toggleSaveTranscriptionHistory($0)) }
					))
				}
				.padding(.vertical, TickSpacing.s)

				if store.hexSettings.saveTranscriptionHistory {
					Rectangle().fill(TickColor.line).frame(height: 1)

					HStack(alignment: .center, spacing: TickSpacing.l) {
						VStack(alignment: .leading, spacing: 4) {
							Text("MAX ENTRIES".uppercased())
								.font(TickFont.eyebrow)
								.tracking(0.8)
								.foregroundStyle(TickColor.textTertiary)
							Text("Limit how many transcripts to keep")
								.font(TickFont.body)
								.foregroundStyle(TickColor.textPrimary)
							Text("Oldest entries are deleted automatically when limit is reached")
								.font(TickFont.caption)
								.foregroundStyle(TickColor.textSecondary)
						}
						Spacer()
						CustomMenuPicker(
							selection: Binding(
								get: { store.hexSettings.maxHistoryEntries ?? 0 },
								set: { store.send(.setMaxHistoryEntries($0 == 0 ? nil : $0)) }
							),
							options: [
								(0, "Unlimited", "infinity"),
								(50, "50", "50.square"),
								(100, "100", "100.square"),
								(200, "200", "200.square"),
								(500, "500", "500.square"),
								(1000, "1000", "1000.square")
							]
						)
					}
					.padding(.vertical, TickSpacing.s)

					Rectangle().fill(TickColor.line).frame(height: 1)

					PasteLastTranscriptHotkeyRow(store: store)
						.padding(.vertical, TickSpacing.s)
				}
			}
			.padding(.horizontal, TickSpacing.l)
			.padding(.vertical, TickSpacing.m)
			.hexGlass(cornerRadius: TickRadius.card)
		}
		.animation(TickAnimation.ease, value: store.hexSettings.saveTranscriptionHistory)
		.enableInjection()
	}
}

private struct PasteLastTranscriptHotkeyRow: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		let pasteHotkey = store.hexSettings.pasteLastTranscriptHotkey

		VStack(alignment: .leading, spacing: TickSpacing.m) {
			VStack(alignment: .leading, spacing: 4) {
				Text("PASTE LAST TRANSCRIPT".uppercased())
					.font(TickFont.eyebrow)
					.tracking(0.8)
					.foregroundStyle(TickColor.textTertiary)
				Text("Shortcut to instantly paste your last transcription")
					.font(TickFont.body)
					.foregroundStyle(TickColor.textPrimary)
			}

			let key = store.isSettingPasteLastTranscriptHotkey ? nil : pasteHotkey?.key
			let modifiers = store.isSettingPasteLastTranscriptHotkey
				? store.currentPasteLastModifiers
				: (pasteHotkey?.modifiers ?? .init(modifiers: []))

			HStack {
				Spacer()
				ZStack {
					HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingPasteLastTranscriptHotkey)

					if !store.isSettingPasteLastTranscriptHotkey, pasteHotkey == nil {
						Text("Not set")
							.font(TickFont.caption)
							.foregroundStyle(TickColor.textTertiary)
					}
				}
				.contentShape(Rectangle())
				.onTapGesture {
					store.send(.startSettingPasteLastTranscriptHotkey)
				}
				Spacer()
			}

			if store.isSettingPasteLastTranscriptHotkey {
				Text("Use at least one modifier (⌘, ⌥, ⇧, ⌃) plus a key.")
					.font(TickFont.caption)
					.foregroundStyle(TickColor.textTertiary)
					.frame(maxWidth: .infinity, alignment: .center)
			} else if pasteHotkey != nil {
				Button {
					store.send(.clearPasteLastTranscriptHotkey)
				} label: {
					Label("Clear shortcut", systemImage: "xmark.circle")
						.font(TickFont.caption)
				}
				.buttonStyle(.plain)
				.foregroundStyle(TickColor.textTertiary)
				.frame(maxWidth: .infinity, alignment: .center)
			}
		}
	}
}
