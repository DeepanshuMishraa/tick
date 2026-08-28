import ComposableArchitecture
import Inject
import SwiftUI

struct LanguageSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		VStack(alignment: .leading, spacing: TickSpacing.m) {
			TickEyebrow(text: "Language")
				.padding(.leading, TickSpacing.xs)

			rowBody
				.padding(TickSpacing.l)
				.hexGlass(cornerRadius: TickRadius.card)
		}
		.enableInjection()
	}

	private var rowBody: some View {
		HStack(alignment: .center, spacing: TickSpacing.l) {
			VStack(alignment: .leading, spacing: 4) {
				Text("OUTPUT LANGUAGE".uppercased())
					.font(TickFont.eyebrow)
					.tracking(0.8)
					.foregroundStyle(TickColor.textTertiary)
				Text("The language to transcribe into")
					.font(TickFont.body)
					.foregroundStyle(TickColor.textPrimary)
			}
			Spacer()
			languagePicker
		}
	}

	private var languagePicker: some View {
		let autoOption: (String, String, String) = ("", "Auto-Detect", "globe")
		let languageOptions: [(String, String, String)] = store.languages.map { lang in
			(lang.code ?? "", lang.name, "globe")
		}
		return CustomMenuPicker(
			selection: Binding(
				get: { store.hexSettings.outputLanguage ?? "" },
				set: { store.send(.setOutputLanguage($0.isEmpty ? nil : $0)) }
			),
			options: [autoOption] + languageOptions
		)
	}
}
