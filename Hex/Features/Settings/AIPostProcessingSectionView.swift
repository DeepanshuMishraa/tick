import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct AIPostProcessingSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		VStack(alignment: .leading, spacing: TickSpacing.xl) {
			// MARK: - Centralized AI Providers Section
			VStack(alignment: .leading, spacing: TickSpacing.m) {
				TickEyebrow(text: "AI Providers")
					.padding(.leading, TickSpacing.xs)

				VStack(alignment: .leading, spacing: TickSpacing.l) {
					// Cream hero with editorial display
					TickHero {
						VStack(alignment: .leading, spacing: TickSpacing.m) {
							HStack(alignment: .firstTextBaseline) {
								Text("Centralised AI Configuration ")
									.font(TickFont.display(28, weight: .regular))
									.foregroundStyle(TickColor.textPrimary)
								+ Text("for all modes")
									.font(TickFont.displayItalic(28))
									.foregroundStyle(TickColor.brand)
							}
							Text("Configure credentials and model choices for dictation post-processing and autonomous mode. Dictation post-processing is always on and app-aware by default.")
								.font(TickFont.body)
								.foregroundStyle(TickColor.textPrimary)
								.opacity(0.7)
						}
					}

					VStack(spacing: 0) {
						// Active Provider selector
						HStack(alignment: .center, spacing: TickSpacing.l) {
							VStack(alignment: .leading, spacing: 4) {
								Text("ACTIVE AI PROVIDER")
									.font(TickFont.eyebrow)
									.tracking(0.8)
									.foregroundStyle(TickColor.textTertiary)
								Text("Select which provider to use for transcriptions & tools")
									.font(TickFont.caption)
									.foregroundStyle(TickColor.textSecondary)
							}
							Spacer()
							Picker("Provider", selection: Binding(
								get: { store.hexSettings.aiProvider },
								set: { store.send(.setAIProvider($0)) }
							)) {
								Text("Groq").tag(AIProvider.groq)
								Text("Google Gemini").tag(AIProvider.google)
							}
							.pickerStyle(.segmented)
							.frame(width: 240)
						}
						.padding(.vertical, TickSpacing.m)

						Rectangle().fill(TickColor.line).frame(height: 1)

						if store.hexSettings.aiProvider == .groq {
							// Groq Section
							VStack(alignment: .leading, spacing: TickSpacing.s) {
								HStack {
									Text("Groq Credentials")
										.font(TickFont.bodyFunc(14, weight: .semibold))
										.foregroundStyle(TickColor.textPrimary)
									Spacer()
								}
								.padding(.top, TickSpacing.s)

								HStack(spacing: TickSpacing.m) {
									VStack(alignment: .leading, spacing: 4) {
										Text("GROQ API KEY")
											.font(TickFont.eyebrow)
											.tracking(0.8)
											.foregroundStyle(TickColor.textTertiary)
										CustomTextField(
											placeholder: "Enter your Groq API key",
											text: Binding(
												get: { store.hexSettings.groqAPIKey ?? "" },
												set: { store.send(.setGroqAPIKey($0)) }
											),
											isSecure: true
										)
									}
									.frame(maxWidth: .infinity)

									VStack(alignment: .leading, spacing: 4) {
										Text("GROQ MODEL")
											.font(TickFont.eyebrow)
											.tracking(0.8)
											.foregroundStyle(TickColor.textTertiary)
										CustomMenuPicker(
											selection: Binding(
												get: { store.hexSettings.aiPostProcessingModel },
												set: { store.send(.setAIPostProcessingModel($0)) }
											),
											options: [
												("llama-3.3-70b-versatile", "Llama 3.3 70B", "brain"),
												("qwen/qwen3-32b", "Qwen 3 32B", "cpu"),
												("qwen/qwen3.6-27b", "Qwen 3.6 27B", "network")
											]
										)
									}
								}

								HStack {
									TickPrimaryButton(
										title: store.isValidatingGroqKey ? "Validating…" : "Validate Key",
										icon: "checkmark"
									) {
										store.send(.validateGroqAPIKey)
									}
									.disabled((store.hexSettings.groqAPIKey ?? "").isEmpty || store.isValidatingGroqKey)

									if let status = store.groqKeyValidationStatus {
										HStack(spacing: 4) {
											Image(systemName: status == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
											Text(status == .success ? "Valid" : (status.failureMessage ?? "Invalid"))
										}
										.font(TickFont.caption)
										.foregroundStyle(status == .success ? TickColor.success : TickColor.error)
									}
								}
							}
							.padding(.vertical, TickSpacing.m)
						} else {
							// Google Gemini Section
							VStack(alignment: .leading, spacing: TickSpacing.s) {
								HStack {
									Text("Google Gemini Credentials")
										.font(TickFont.bodyFunc(14, weight: .semibold))
										.foregroundStyle(TickColor.textPrimary)
									Spacer()
								}
								.padding(.top, TickSpacing.s)

								HStack(spacing: TickSpacing.m) {
									VStack(alignment: .leading, spacing: 4) {
										Text("GOOGLE API KEY")
											.font(TickFont.eyebrow)
											.tracking(0.8)
											.foregroundStyle(TickColor.textTertiary)
										CustomTextField(
											placeholder: "Enter your Google API key",
											text: Binding(
												get: { store.hexSettings.googleAPIKey ?? "" },
												set: { store.send(.setGoogleAPIKey($0)) }
											),
											isSecure: true
										)
									}
									.frame(maxWidth: .infinity)

									VStack(alignment: .leading, spacing: 4) {
										Text("GEMINI MODEL")
											.font(TickFont.eyebrow)
											.tracking(0.8)
											.foregroundStyle(TickColor.textTertiary)
										CustomMenuPicker(
											selection: Binding(
												get: { store.hexSettings.googleModel },
												set: { store.send(.setGoogleModel($0)) }
											),
											options: [
												("gemini-2.5-pro-exp-03-25", "Gemini 2.5 Pro", "brain"),
												("gemini-2.5-flash-preview-04-17", "Gemini 2.5 Flash", "cpu"),
												("gemini-2.0-flash", "Gemini 2.0 Flash", "network"),
												("gemini-2.0-flash-lite", "Gemini 2.0 Flash Lite", "bolt")
											]
										)
									}
								}

								HStack {
									TickPrimaryButton(
										title: store.isValidatingGoogleKey ? "Validating…" : "Validate Key",
										icon: "checkmark"
									) {
										store.send(.validateGoogleAPIKey)
									}
									.disabled((store.hexSettings.googleAPIKey ?? "").isEmpty || store.isValidatingGoogleKey)

									if let status = store.googleKeyValidationStatus {
										HStack(spacing: 4) {
											Image(systemName: status == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
											Text(status == .success ? "Valid" : (status.failureMessage ?? "Invalid"))
										}
										.font(TickFont.caption)
										.foregroundStyle(status == .success ? TickColor.success : TickColor.error)
									}
								}
							}
							.padding(.vertical, TickSpacing.m)
						}
					}
					.padding(.horizontal, TickSpacing.l)
					.padding(.vertical, TickSpacing.s)
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

			// MARK: - Autonomous Mode Section
			VStack(alignment: .leading, spacing: TickSpacing.m) {
				TickEyebrow(text: "Autonomous Mode")
					.padding(.leading, TickSpacing.xs)

				VStack(alignment: .leading, spacing: TickSpacing.l) {
					HStack {
						Image(systemName: "keyboard")
							.font(.system(size: 14))
							.foregroundStyle(TickColor.brandMid)
						Text("Press ")
							.font(TickFont.body)
							.foregroundStyle(TickColor.textPrimary)
						+ Text("⌘")
							.font(.system(size: 15, weight: .bold))
							.foregroundStyle(TickColor.brandMid)
						+ Text(" + ")
							.font(TickFont.body)
							.foregroundStyle(TickColor.textPrimary)
						+ Text("⌥")
							.font(.system(size: 15, weight: .bold))
							.foregroundStyle(TickColor.brandMid)
						+ Text(" (right)")
							.font(TickFont.body)
							.foregroundStyle(TickColor.textPrimary)
						+ Text(" to toggle autonomous mode")
							.font(TickFont.body)
							.foregroundStyle(TickColor.textPrimary)
						Spacer()
					}
					Text("Press the hotkey three times quickly to enter autonomous recording mode with AI tool detection.")
						.font(TickFont.caption)
						.foregroundStyle(TickColor.textSecondary)

					Divider()

					// Tools section
					VStack(alignment: .leading, spacing: TickSpacing.s) {
						Text("TOOLS").font(TickFont.eyebrow).tracking(0.8).foregroundStyle(TickColor.textTertiary)
						Text("Enable tools the AI can invoke during autonomous recording.").font(TickFont.caption).foregroundStyle(TickColor.textSecondary)
						ToolTogglesView(store: store)
					}

					Divider()

					// TTS section
					VStack(alignment: .leading, spacing: TickSpacing.s) {
						Text("TTS CONFIRMATION").font(TickFont.eyebrow).tracking(0.8).foregroundStyle(TickColor.textTertiary)
						Toggle(isOn: Binding(get: { store.hexSettings.ttsEnabled }, set: { _ in store.send(.toggleTTS) })) {
							Text("Speak confirmation aloud").font(TickFont.body).foregroundStyle(TickColor.textPrimary)
						}.toggleStyle(.switch)
						if store.hexSettings.ttsEnabled {
							HStack {
								Text("Voice:").font(TickFont.body).foregroundStyle(TickColor.textPrimary)
								CustomMenuPicker(selection: Binding(get: { store.hexSettings.ttsVoice }, set: { store.send(.setTTSVoice($0)) }), options: [
									("en-US-JennyNeural", "Jenny (US)", "person.fill"),
									("en-US-GuyNeural", "Guy (US)", "person.fill"),
									("en-GB-SoniaNeural", "Sonia (UK)", "person.fill"),
									("en-GB-RyanNeural", "Ryan (UK)", "person.fill"),
									("en-AU-NatashaNeural", "Natasha (AU)", "person.fill"),
									("en-CA-ClaraNeural", "Clara (CA)", "person.fill"),
									("en-IN-NeerjaNeural", "Neerja (IN)", "person.fill"),
								])
								Button(action: { store.send(.previewTTSVoice) }) {
									Image(systemName: "play.circle.fill").font(.system(size: 14))
								}
								.buttonStyle(.plain)
								.help("Preview this voice")
							}
						}
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
		.enableInjection()
	}
}

extension SettingsFeature.APIKeyValidationStatus {
	var failureMessage: String? {
		if case .failure(let msg) = self { return msg }
		return nil
	}
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

// MARK: - Tool Toggles View

struct ToolTogglesView: View {
	@Bindable var store: StoreOf<SettingsFeature>

	private let toolDefinitions: [(id: String, name: String, icon: String)] = [
		("add_todo", "Add to Reminders", "plus.circle"),
		("get_todos", "Get Reminders", "list.bullet"),
		("set_reminder", "Set Reminder", "alarm"),
		("get_reminders", "Get Upcoming Reminders", "bell"),
		("search_web", "Search Web", "magnifyingglass"),
		("open_app", "Open Application", "app.badge"),
		("create_note", "Create Note", "note.text"),
	]

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			ForEach(toolDefinitions, id: \.id) { def in
				Toggle(
					isOn: Binding(
						get: { store.hexSettings.enabledToolIDs.contains(def.id) },
						set: { _ in store.send(.toggleTool(def.id)) }
					)
				) {
					HStack(spacing: 8) {
						Image(systemName: def.icon)
							.font(.system(size: 12))
							.foregroundStyle(.secondary)
							.frame(width: 16)
						Text(def.name)
							.font(TickFont.body)
							.foregroundStyle(TickColor.textPrimary)
					}
				}
				.toggleStyle(.switch)
			}
		}
	}
}
