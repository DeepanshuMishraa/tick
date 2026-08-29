import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct WordRemappingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	@FocusState private var isScratchpadFocused: Bool
	@State private var activeSection: ModificationSection = .removals

	var body: some View {
		VStack(alignment: .leading, spacing: TickSpacing.xl) {
			// Hero card (Whisperflow style)
			TickHero {
				VStack(alignment: .leading, spacing: TickSpacing.m) {
					(
						Text("Make Tick sound like ")
							.font(TickFont.display(28, weight: .regular))
							.foregroundStyle(TickColor.textPrimary)
						+ Text("you")
							.font(TickFont.displayItalic(28))
							.foregroundStyle(TickColor.brand)
					)
					.fixedSize(horizontal: false, vertical: true)
					Text("Tick writes your speech differently depending on the app you're in. Set your style for **messages, work chats, and email** and your transcriptions come out the way you'd type them.")
						.font(TickFont.body)
						.foregroundStyle(TickColor.textPrimary)
						.opacity(0.75)
						.fixedSize(horizontal: false, vertical: true)

					// Scratchpad
					HStack(alignment: .top, spacing: TickSpacing.m) {
						VStack(alignment: .leading, spacing: 4) {
							Text("INPUT".uppercased())
								.font(TickFont.eyebrow)
								.tracking(0.8)
								.foregroundStyle(TickColor.textPrimary)
								.opacity(0.6)
							CustomTextField(
								placeholder: "Say something…",
								text: $store.remappingScratchpadText
							)
							.focused($isScratchpadFocused)
							.onChange(of: isScratchpadFocused) { _, newValue in
								store.send(.setRemappingScratchpadFocused(newValue))
							}
						}

						VStack(alignment: .leading, spacing: 4) {
							Text("PREVIEW".uppercased())
								.font(TickFont.eyebrow)
								.tracking(0.8)
								.foregroundStyle(TickColor.textPrimary)
								.opacity(0.6)
							Text(previewText.isEmpty ? "—" : previewText)
								.font(TickFont.body)
								.foregroundStyle(TickColor.textPrimary)
								.opacity(0.75)
								.frame(maxWidth: .infinity, alignment: .leading)
								.padding(.horizontal, TickSpacing.m)
								.padding(.vertical, TickSpacing.s + 2)
								.frame(minHeight: 38)
								.hexGlass(cornerRadius: 10)
						}
					}
				}
			}

			// Section tabs (underlined)
			HStack(spacing: TickSpacing.l) {
				ForEach(ModificationSection.allCases) { section in
					ModificationTab(
						title: section.title,
						isActive: activeSection == section,
						action: {
							withAnimation(TickAnimation.ease) {
								activeSection = section
							}
						}
					)
				}
				Spacer()
			}

			switch activeSection {
			case .removals:
				removalsSection
			case .remappings:
				remappingsSection
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.onDisappear {
			store.send(.setRemappingScratchpadFocused(false))
		}
		.enableInjection()
	}

	private var removalsSection: some View {
		VStack(alignment: .leading, spacing: TickSpacing.m) {
			HStack {
				VStack(alignment: .leading, spacing: 4) {
					Text("WORD REMOVALS")
						.font(TickFont.eyebrow)
						.tracking(0.8)
						.foregroundStyle(TickColor.textTertiary)
					Text("Strip filler words from your transcriptions")
						.font(TickFont.body)
						.foregroundStyle(TickColor.textPrimary)
					Text("Remove filler words using case-insensitive regex patterns")
						.font(TickFont.caption)
						.foregroundStyle(TickColor.textSecondary)
				}
				Spacer()
				TickToggle(isOn: Binding(
					get: { store.hexSettings.wordRemovalsEnabled },
					set: { store.send(.toggleWordRemovalsEnabled($0)) }
				))
			}

			VStack(spacing: TickSpacing.s) {
				ForEach(store.hexSettings.wordRemovals) { removal in
					if let removalBinding = removalBinding(for: removal.id) {
						RemovalRow(removal: removalBinding) {
							store.send(.removeWordRemoval(removal.id))
						}
					}
				}

				TickSecondaryButton(title: "Add Removal", icon: "plus") {
					store.send(.addWordRemoval)
				}
			}
		}
		.padding(TickSpacing.l)
		.hexGlass(cornerRadius: TickRadius.card)
	}

	private var remappingsSection: some View {
		VStack(alignment: .leading, spacing: TickSpacing.m) {
			VStack(alignment: .leading, spacing: 4) {
				Text("WORD REMAPPINGS")
					.font(TickFont.eyebrow)
					.tracking(0.8)
					.foregroundStyle(TickColor.textTertiary)
				Text("Replace specific words in every transcript")
					.font(TickFont.body)
					.foregroundStyle(TickColor.textPrimary)
				Text("Matches whole words, case-insensitive, in order")
					.font(TickFont.caption)
					.foregroundStyle(TickColor.textSecondary)
			}

			VStack(spacing: TickSpacing.s) {
				ForEach(store.hexSettings.wordRemappings) { remapping in
					if let remappingBinding = remappingBinding(for: remapping.id) {
						RemappingRow(remapping: remappingBinding) {
							store.send(.removeWordRemapping(remapping.id))
						}
					}
				}

				TickSecondaryButton(title: "Add Remapping", icon: "plus") {
					store.send(.addWordRemapping)
				}
			}
		}
		.padding(TickSpacing.l)
		.hexGlass(cornerRadius: TickRadius.card)
	}

	private func removalBinding(for id: UUID) -> Binding<WordRemoval>? {
		guard let index = store.hexSettings.wordRemovals.firstIndex(where: { $0.id == id }) else { return nil }
		return Binding(
			get: { store.hexSettings.wordRemovals[index] },
			set: { newValue in
				var updated = store.hexSettings.wordRemovals
				updated[index] = newValue
				store.send(.setWordRemovals(updated))
			}
		)
	}

	private func remappingBinding(for id: UUID) -> Binding<WordRemapping>? {
		guard let index = store.hexSettings.wordRemappings.firstIndex(where: { $0.id == id }) else { return nil }
		return Binding(
			get: { store.hexSettings.wordRemappings[index] },
			set: { newValue in
				var updated = store.hexSettings.wordRemappings
				updated[index] = newValue
				store.send(.setWordRemappings(updated))
			}
		)
	}

	private var previewText: String {
		var output = store.remappingScratchpadText
		if store.hexSettings.wordRemovalsEnabled {
			output = WordRemovalApplier.apply(output, removals: store.hexSettings.wordRemovals)
		}
		output = WordRemappingApplier.apply(output, remappings: store.hexSettings.wordRemappings)
		return output
	}
}

private struct RemovalRow: View {
	@Binding var removal: WordRemoval
	var onDelete: () -> Void

	var body: some View {
		HStack(spacing: TickSpacing.s) {
			TickToggle(isOn: $removal.isEnabled)

			CustomTextField(placeholder: "Regex Pattern", text: $removal.pattern)

			Button(action: onDelete) {
				Image(systemName: "trash")
					.font(TickFont.captionFunc(13))
					.foregroundStyle(TickColor.textTertiary)
					.frame(width: 32, height: 32)
					.hexGlass(in: Circle())
			}
			.buttonStyle(.plain)
		}
	}
}

private struct RemappingRow: View {
	@Binding var remapping: WordRemapping
	var onDelete: () -> Void

	var body: some View {
		HStack(spacing: TickSpacing.s) {
			TickToggle(isOn: $remapping.isEnabled)

			CustomTextField(placeholder: "Match", text: $remapping.match)

			Image(systemName: "arrow.right")
				.foregroundStyle(TickColor.textTertiary)
				.font(TickFont.labelFunc(11, weight: .medium))

			CustomTextField(placeholder: "Replace", text: $remapping.replacement)

			Button(action: onDelete) {
				Image(systemName: "trash")
					.font(TickFont.captionFunc(13))
					.foregroundStyle(TickColor.textTertiary)
					.frame(width: 32, height: 32)
					.hexGlass(in: Circle())
			}
			.buttonStyle(.plain)
		}
	}
}

private enum ModificationSection: String, CaseIterable, Identifiable {
	case removals
	case remappings

	var id: String { rawValue }

	var title: String {
		switch self {
		case .removals: return "Word Removals"
		case .remappings: return "Word Remappings"
		}
	}
}

private struct ModificationTab: View {
	let title: String
	let isActive: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Text(title)
				.font(TickFont.labelFunc(14, weight: isActive ? .semibold : .regular))
				.foregroundStyle(isActive ? TickColor.textPrimary : TickColor.textTertiary)
				.padding(.bottom, TickSpacing.s)
				.overlay(alignment: .bottom) {
					Rectangle()
						.fill(isActive ? TickColor.textPrimary : Color.clear)
						.frame(height: 1.5)
				}
		}
		.buttonStyle(.plain)
	}
}
