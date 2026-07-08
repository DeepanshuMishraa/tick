import Foundation

public enum RecordingAudioBehavior: String, Codable, CaseIterable, Equatable, Sendable {
	case pauseMedia
	case mute
	case doNothing
}

public enum AIProvider: String, Codable, CaseIterable, Equatable, Sendable {
	case groq
	case google

	public var displayName: String {
		switch self {
		case .groq: return "Groq"
		case .google: return "Google Gemini"
		}
	}
}

public enum AIPostProcessingMode: String, Codable, CaseIterable, Equatable, Sendable {
	case off
	case on
	case appAware

	public var displayName: String {
		switch self {
		case .off: return "Off"
		case .on: return "On"
		case .appAware: return "App-Aware"
		}
	}

	public func systemPrompt(appContext: AppContext? = nil, selectedStyleIndex: Int = 2) -> String {
		switch self {
		case .off:
			return ""
		case .on:
			return Self.genericPrompt(styleIndex: selectedStyleIndex)
		case .appAware:
			return Self.appAwarePrompt(appContext: appContext, styleIndex: selectedStyleIndex)
		}
	}

	private static func styleInstructions(for styleIndex: Int) -> String {
		switch styleIndex {
		case 0: // Formal
			return """

CRITICAL WRITING STYLE REQUIREMENT (FORMAL STYLE):
- Enforce strict capitalization (standard capitalization for sentence starts, proper nouns, and "I").
- Use standard, grammatically correct punctuation (periods, commas, question marks).
- Maintain a formal and professional tone appropriate for business or academic communication.
- Structural Layout & Spacing: You MUST analyze the type of content (e.g., email, normal messaging, grocery list, structured note) and apply appropriate formatting. For emails, structure with a professional greeting, paragraphs separated by blank lines/spaces, and a clean sign-off. For lists or grocery lists, format as a structured bulleted list (using '-' or '*') with proper line breaks. For notes, use headings or bold text where helpful.
"""
		case 1: // Casual
			return """

CRITICAL WRITING STYLE REQUIREMENT (CASUAL STYLE):
- Keep sentence-initial capitalization (start of sentences and proper nouns capitalized).
- Use relaxed punctuation and a natural, conversational tone (e.g., fewer commas/periods where natural in chat, but still readable).
- Maintain a conversational, friendly, and natural voice.
- Structural Layout & Spacing: You MUST analyze the type of content (e.g., email, normal messaging, grocery list, structured note) and apply appropriate formatting. For emails, structure with a professional greeting, paragraphs separated by blank lines/spaces, and a clean sign-off. For lists or grocery lists, format as a structured bulleted list (using '-' or '*') with proper line breaks. For notes, use headings or bold text where helpful.
"""
		case 2: // Very Casual
			fallthrough
		default:
			return """

CRITICAL WRITING STYLE REQUIREMENT (VERY CASUAL STYLE):
- Enforce strict lowercase formatting: DO NOT use any capital letters at all. All letters must be in lowercase.
- Use relaxed punctuation and a natural/conversational tone.
- Keep the tone very informal, as if typing a quick message to a close friend.
- Structural Layout & Spacing: You MUST analyze the type of content (e.g., email, normal messaging, grocery list, structured note) and apply appropriate formatting. For emails, structure with a professional greeting, paragraphs separated by blank lines/spaces, and a clean sign-off. For lists or grocery lists, format as a structured bulleted list (using '-' or '*') with proper line breaks. For notes, use headings or bold text where helpful. Note that all text must remain strictly lowercase.
"""
		}
	}

	private static func genericPrompt(styleIndex: Int) -> String {
		let basePrompt = """
You are an intelligent dictation post-processor. You receive raw speech-to-text output and return clean, polished text ready to be typed into any application.

Your job:
- Detect the tone, context, and type of the transcription automatically (email, message, command, formal writing, casual note, grocery list, etc.)
- Adapt your processing and formatting strictly based on the detected context and type:
  * For emails: Structure with standard email formatting, including a greeting, body paragraphs separated by empty lines/double spaces, and a sign-off.
  * For normal messages/chat: Keep it conversational, using short paragraphs/lines with proper spacing/breaks, and using appropriate casual phrasing/emojis where fitting.
  * For grocery lists or other lists: Format as a structured list with bullet points (using '-' or '*') and clear line breaks.
  * For notes: Keep it simple, organized, and spaced nicely, using headings or bullets where appropriate.
  * For commands: Be concise and precise, extract clear intent. Specifically, if the user dictates a command message (like "git commit this is a good landing page"), transform it to the correct flag syntax: e.g., `git commit -m "this is a good landing page"`.
- Remove filler words (um, uh, you know, like, er) unless they carry meaning or add personality (in casual contexts)
- Fix spelling, grammar, and punctuation errors appropriately for the context
- Handle self-corrections intelligently: when the speaker corrects themselves (e.g., "at 3 pm oh I'm sorry at 4 pm" → "at 4 pm" or "Tuesday sorry Wednesday" → "Wednesday"), use the correction and remove the original. Common correction patterns: "sorry", "I mean", "no wait", "actually", "oh", "no"
- Add proper punctuation and capitalization suitable for the context
- Preserve the speaker's core intent, meaning, and personality

Output rules:
- Return ONLY the cleaned, context-appropriate text, nothing else
- If the transcription is empty, return exactly: EMPTY
- Do not add words or content that are not in the transcription
- Do not change the core meaning of what was said
- Match the formality level to what seems intended by the speaker
"""
		return basePrompt + styleInstructions(for: styleIndex)
	}

	private static func appAwarePrompt(appContext: AppContext?, styleIndex: Int) -> String {
		let basePrompt = """
You are an intelligent dictation post-processor that adapts its formatting based on the application context and content type. You receive raw speech-to-text output and return clean, polished text formatted for the target application.

General rules:
- Analyze the input content type (email, chat message, grocery list, note, etc.) and apply the appropriate formatting, spacing, and structural style:
  * For emails: Structure with standard email formatting, including a greeting, body paragraphs separated by empty lines/double spaces, and a sign-off.
  * For normal messages/chat: Keep it conversational, using short paragraphs/lines with proper spacing/breaks, and using appropriate casual phrasing/emojis where fitting.
  * For grocery lists or other lists: Format as a structured list with bullet points (using '-' or '*') and clear line breaks.
  * For notes: Keep it simple, organized, and spaced nicely, using headings or bullets where appropriate.
- Remove filler words (um, uh, you know, like, er) unless they carry meaning
- Fix spelling, grammar, and punctuation errors
- Handle self-corrections: use the corrected version, remove the original mistake
- Preserve the speaker's core intent and meaning

Output rules:
- Return ONLY the cleaned, context-appropriate text, nothing else
- If the transcription is empty, return exactly: EMPTY
- Do not add words or content that are not in the transcription
- Do not change the core meaning of what was said
"""
		let category = appContext?.category ?? .other
		let categoryContext = category.systemPromptContext

		guard !categoryContext.isEmpty else {
			return basePrompt + "\n\nFormat the text appropriately based on its content, keeping it simple and clean." + styleInstructions(for: styleIndex)
		}

		var contextSection = "\n\nApplication context:\n- Application: \(appContext?.appName ?? "Unknown")\n- Category: \(category.displayName)"

		if let url = appContext?.url, let host = appContext?.browserURLHost {
			contextSection += "\n- URL: \(url)"
			contextSection += "\n- Domain: \(host)"

			let urlHint = urlHint(for: host)
			if !urlHint.isEmpty {
				contextSection += "\n\(urlHint)"
			}
		}

		let appendStyle = (category != .terminal && category != .codeEditor)
		let styleSection = appendStyle ? styleInstructions(for: styleIndex) : ""

		return basePrompt + "\n\nFormatting rules for \(category.displayName) context:\n" + categoryContext + contextSection + styleSection
	}

	private static func urlHint(for host: String) -> String {
		let lower = host.lowercased()
		if lower.contains("mail.google.com") || lower.contains("gmail.com") {
			return """
			- The user is in Gmail: strictly format as a professional email. Even if the transcription is a short instruction or brief note (e.g., "tell John I am on my way"), you MUST expand and structure it into a complete email format: greeting (e.g., "Hi John,"), body (e.g., "I wanted to let you know that I am on my way."), and sign-off (e.g., "Best regards,"). You are explicitly authorized to add standard structural email layouts.
			"""
		} else if lower.contains("outlook.") || lower.contains("mail.yahoo.com") {
			return """
			- The user is in an email client (Outlook/Yahoo): format as a professional email. If the dictation is a short message or instruction, expand and structure it with a greeting, spaced body paragraphs, and an appropriate closing sign-off.
			"""
		} else if lower.contains("slack.com") || lower.contains("discord.com") {
			return """
			- The user is in a messaging app (Slack/Discord): format as a concise, natural, conversational chat message. Keep paragraphs brief and do not use formal email greetings/closings.
			"""
		} else if lower.contains("notion.so") || lower.contains("notion.site") {
			return """
			- The user is in Notion: format as clean, structured markdown notes with bullet points or headers ("## ") where appropriate.
			"""
		} else if lower.contains("docs.google.com") {
			return """
			- The user is in Google Docs: format as document prose with proper paragraphs, grammar, and formal punctuation.
			"""
		} else if lower.contains("github.com") {
			return """
			- The user is on GitHub: format as markdown code comments, issue descriptions, pull requests, or commit messages depending on the dictated content.
			"""
		} else if lower.contains("jira.") || lower.contains("atlassian.net") {
			return """
			- The user is in Jira: format as structured bug reports or task descriptions with bullet points.
			"""
		}
		return ""
	}
}

/// User-configurable settings saved to disk.
public struct HexSettings: Codable, Equatable, Sendable {
	public static let defaultPasteLastTranscriptHotkey = HotKey(key: .v, modifiers: [.option, .shift])
	public static let baseSoundEffectsVolume: Double = HexCoreConstants.baseSoundEffectsVolume
	public static let defaultWordRemovals: [WordRemoval] = [
		.init(pattern: "uh+"),
		.init(pattern: "um+"),
		.init(pattern: "er+"),
		.init(pattern: "hm+")
	]

	public static var defaultPasteLastTranscriptHotkeyDescription: String {
		let modifiers = defaultPasteLastTranscriptHotkey.modifiers.sorted.map { $0.stringValue }.joined()
		let key = defaultPasteLastTranscriptHotkey.key?.toString ?? ""
		return modifiers + key
	}

	public var soundEffectsEnabled: Bool
	public var soundEffectsVolume: Double
	public var hotkey: HotKey
	public var openOnLogin: Bool
	public var showDockIcon: Bool
	public var selectedModel: String
	public var useClipboardPaste: Bool
	public var preventSystemSleep: Bool
	public var recordingAudioBehavior: RecordingAudioBehavior
	public var minimumKeyTime: Double
	public var copyToClipboard: Bool
	public var superFastModeEnabled: Bool
	public var useDoubleTapOnly: Bool
	public var doubleTapLockEnabled: Bool
	public var tripleTapAutonomousEnabled: Bool
	public var outputLanguage: String?
	public var selectedMicrophoneID: String?
	public var saveTranscriptionHistory: Bool
	public var maxHistoryEntries: Int?
	public var pasteLastTranscriptHotkey: HotKey?
	public var hasCompletedModelBootstrap: Bool
	public var hasCompletedStorageMigration: Bool
	public var wordRemovalsEnabled: Bool
	public var wordRemovals: [WordRemoval]
	public var wordRemappings: [WordRemapping]
	public var aiProvider: AIProvider
	public var groqAPIKey: String?
	public var googleAPIKey: String?
	public var googleModel: String
	public var aiPostProcessingMode: AIPostProcessingMode
	public var aiPostProcessingModel: String
	public var selectedStyleIndex: Int
	public var hasSelectedStyle: Bool
	public var autonomousModeEnabled: Bool
	public var ttsEnabled: Bool
	public var ttsVoice: String
	public var enabledToolIDs: [String]

	public static let defaultToolIDs: [String] = [
		"add_todo",
		"get_todos",
		"set_reminder",
		"get_reminders",
		"search_web",
		"open_app",
		"create_note",
		"set_alarm",
	]
	public var snippets: [SnippetSetting]

	private mutating func normalizeSettings() {
		if !doubleTapLockEnabled {
			useDoubleTapOnly = false
		}
		// Automatically append newly introduced default tools if they are missing from user settings
		for defaultID in HexSettings.defaultToolIDs {
			if !enabledToolIDs.contains(defaultID) {
				enabledToolIDs.append(defaultID)
			}
		}
	}

	public init(
		soundEffectsEnabled: Bool = true,
		soundEffectsVolume: Double = HexSettings.baseSoundEffectsVolume,
		hotkey: HotKey = .init(key: nil, modifiers: [.option]),
		openOnLogin: Bool = false,
		showDockIcon: Bool = true,
		selectedModel: String = ParakeetModel.multilingualV3.identifier,
		useClipboardPaste: Bool = true,
		preventSystemSleep: Bool = true,
		recordingAudioBehavior: RecordingAudioBehavior = .doNothing,
		minimumKeyTime: Double = HexCoreConstants.defaultMinimumKeyTime,
		copyToClipboard: Bool = false,
		superFastModeEnabled: Bool = false,
		useDoubleTapOnly: Bool = false,
		doubleTapLockEnabled: Bool = true,
		tripleTapAutonomousEnabled: Bool = false,
		outputLanguage: String? = nil,
		selectedMicrophoneID: String? = nil,
		saveTranscriptionHistory: Bool = true,
		maxHistoryEntries: Int? = nil,
		pasteLastTranscriptHotkey: HotKey? = HexSettings.defaultPasteLastTranscriptHotkey,
		hasCompletedModelBootstrap: Bool = false,
		hasCompletedStorageMigration: Bool = false,
		wordRemovalsEnabled: Bool = false,
		wordRemovals: [WordRemoval] = HexSettings.defaultWordRemovals,
		wordRemappings: [WordRemapping] = [],
		aiProvider: AIProvider = .groq,
		groqAPIKey: String? = nil,
		googleAPIKey: String? = nil,
		googleModel: String = "gemini-2.0-flash",
		aiPostProcessingMode: AIPostProcessingMode = .off,
		aiPostProcessingModel: String = "llama-3.3-70b-versatile",
		selectedStyleIndex: Int = 2,
		hasSelectedStyle: Bool = false,
		autonomousModeEnabled: Bool = false,
		ttsEnabled: Bool = true,
		ttsVoice: String = "en-US-JennyNeural",
		enabledToolIDs: [String] = HexSettings.defaultToolIDs,
		snippets: [SnippetSetting] = [
			.init(shortcut: "LinkedIn", content: "https://www.linkedin.com/in/john-doe-9b0139134/"),
			.init(shortcut: "intro email", content: "Hey, would love to find some time to chat later..."),
			.init(shortcut: "my calendly link", content: "calendly.com/you/invite-name")
		]
	) {
		self.soundEffectsEnabled = soundEffectsEnabled
		self.soundEffectsVolume = soundEffectsVolume
		self.hotkey = hotkey
		self.openOnLogin = openOnLogin
		self.showDockIcon = showDockIcon
		self.selectedModel = selectedModel
		self.useClipboardPaste = useClipboardPaste
		self.preventSystemSleep = preventSystemSleep
		self.recordingAudioBehavior = recordingAudioBehavior
		self.minimumKeyTime = minimumKeyTime
		self.copyToClipboard = copyToClipboard
		self.superFastModeEnabled = superFastModeEnabled
		self.useDoubleTapOnly = useDoubleTapOnly
		self.doubleTapLockEnabled = doubleTapLockEnabled
		self.tripleTapAutonomousEnabled = tripleTapAutonomousEnabled
		self.outputLanguage = outputLanguage
		self.selectedMicrophoneID = selectedMicrophoneID
		self.saveTranscriptionHistory = saveTranscriptionHistory
		self.maxHistoryEntries = maxHistoryEntries
		self.pasteLastTranscriptHotkey = pasteLastTranscriptHotkey
		self.hasCompletedModelBootstrap = hasCompletedModelBootstrap
		self.hasCompletedStorageMigration = hasCompletedStorageMigration
		self.wordRemovalsEnabled = wordRemovalsEnabled
		self.wordRemovals = wordRemovals
		self.wordRemappings = wordRemappings
		self.aiProvider = aiProvider
		self.groqAPIKey = groqAPIKey
		self.googleAPIKey = googleAPIKey
		self.googleModel = googleModel
		self.aiPostProcessingMode = aiPostProcessingMode
		self.aiPostProcessingModel = aiPostProcessingModel
		self.selectedStyleIndex = selectedStyleIndex
		self.hasSelectedStyle = hasSelectedStyle
		self.autonomousModeEnabled = autonomousModeEnabled
		self.ttsEnabled = ttsEnabled
		self.ttsVoice = ttsVoice
		self.enabledToolIDs = enabledToolIDs
		self.snippets = snippets
		normalizeSettings()
	}

	public init(from decoder: Decoder) throws {
		self.init()
		let container = try decoder.container(keyedBy: HexSettingKey.self)
		for field in HexSettingsSchema.fields {
			try field.decode(into: &self, from: container)
		}
		normalizeSettings()
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: HexSettingKey.self)
		for field in HexSettingsSchema.fields {
			try field.encode(self, into: &container)
		}
	}
}

// MARK: - Schema

private enum HexSettingKey: String, CodingKey, CaseIterable {
	case soundEffectsEnabled
	case soundEffectsVolume
	case hotkey
	case openOnLogin
	case showDockIcon
	case selectedModel
	case useClipboardPaste
	case preventSystemSleep
	case recordingAudioBehavior
	case pauseMediaOnRecord // Legacy
	case minimumKeyTime
	case copyToClipboard
	case superFastModeEnabled
	case useDoubleTapOnly
	case doubleTapLockEnabled
	case tripleTapAutonomousEnabled
	case outputLanguage
	case selectedMicrophoneID
	case saveTranscriptionHistory
	case maxHistoryEntries
	case pasteLastTranscriptHotkey
	case hasCompletedModelBootstrap
	case hasCompletedStorageMigration
	case wordRemovalsEnabled
	case wordRemovals
	case wordRemappings
	case aiProvider
	case groqAPIKey
	case googleAPIKey
	case googleModel
	case aiPostProcessingMode
	case aiPostProcessingModel
	case selectedStyleIndex
	case hasSelectedStyle
	case autonomousModeEnabled
	case ttsEnabled
	case ttsVoice
	case enabledToolIDs
	case snippets
}

private struct SettingsField<Value: Codable & Sendable> {
	let key: HexSettingKey
	let keyPath: WritableKeyPath<HexSettings, Value>
	let defaultValue: Value
	let decodeStrategy: (KeyedDecodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Value
	let encodeStrategy: (inout KeyedEncodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Void

	init(
		_ key: HexSettingKey,
		keyPath: WritableKeyPath<HexSettings, Value>,
		default defaultValue: Value,
		decode: ((KeyedDecodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Value)? = nil,
		encode: ((inout KeyedEncodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Void)? = nil
	) {
		self.key = key
		self.keyPath = keyPath
		self.defaultValue = defaultValue
		self.decodeStrategy = decode ?? { container, key, defaultValue in
			try container.decodeIfPresent(Value.self, forKey: key) ?? defaultValue
		}
		self.encodeStrategy = encode ?? { container, key, value in
			try container.encode(value, forKey: key)
		}
	}

	func eraseToAny() -> AnySettingsField {
		AnySettingsField(
			key: key,
			decode: { container, settings in
				let value = try decodeStrategy(container, key, defaultValue)
				settings[keyPath: keyPath] = value
			},
			encode: { settings, container in
				let value = settings[keyPath: keyPath]
				try encodeStrategy(&container, key, value)
			}
		)
	}
}

private struct AnySettingsField {
	let key: HexSettingKey
	let decode: (KeyedDecodingContainer<HexSettingKey>, inout HexSettings) throws -> Void
	let encode: (HexSettings, inout KeyedEncodingContainer<HexSettingKey>) throws -> Void

	func decode(into settings: inout HexSettings, from container: KeyedDecodingContainer<HexSettingKey>) throws {
		try decode(container, &settings)
	}

	func encode(_ settings: HexSettings, into container: inout KeyedEncodingContainer<HexSettingKey>) throws {
		try encode(settings, &container)
	}
}

private enum HexSettingsSchema {
	static let defaults = HexSettings()

	nonisolated(unsafe) static let fields: [AnySettingsField] = [
		SettingsField(.soundEffectsEnabled, keyPath: \.soundEffectsEnabled, default: defaults.soundEffectsEnabled).eraseToAny(),
		SettingsField(.soundEffectsVolume, keyPath: \.soundEffectsVolume, default: defaults.soundEffectsVolume).eraseToAny(),
		SettingsField(.hotkey, keyPath: \.hotkey, default: defaults.hotkey).eraseToAny(),
		SettingsField(.openOnLogin, keyPath: \.openOnLogin, default: defaults.openOnLogin).eraseToAny(),
		SettingsField(.showDockIcon, keyPath: \.showDockIcon, default: defaults.showDockIcon).eraseToAny(),
		SettingsField(.selectedModel, keyPath: \.selectedModel, default: defaults.selectedModel).eraseToAny(),
		SettingsField(.useClipboardPaste, keyPath: \.useClipboardPaste, default: defaults.useClipboardPaste).eraseToAny(),
		SettingsField(.preventSystemSleep, keyPath: \.preventSystemSleep, default: defaults.preventSystemSleep).eraseToAny(),
		SettingsField(
			.recordingAudioBehavior,
			keyPath: \.recordingAudioBehavior,
			default: defaults.recordingAudioBehavior,
			decode: { container, key, defaultValue in
				if let value = try container.decodeIfPresent(RecordingAudioBehavior.self, forKey: key) {
					return value
				}
				if let legacyPause = try container.decodeIfPresent(Bool.self, forKey: .pauseMediaOnRecord) {
					return legacyPause ? .pauseMedia : .doNothing
				}
				return defaultValue
			}
		).eraseToAny(),
		SettingsField(.minimumKeyTime, keyPath: \.minimumKeyTime, default: defaults.minimumKeyTime).eraseToAny(),
		SettingsField(.copyToClipboard, keyPath: \.copyToClipboard, default: defaults.copyToClipboard).eraseToAny(),
		SettingsField(.superFastModeEnabled, keyPath: \.superFastModeEnabled, default: defaults.superFastModeEnabled).eraseToAny(),
		SettingsField(.useDoubleTapOnly, keyPath: \.useDoubleTapOnly, default: defaults.useDoubleTapOnly).eraseToAny(),
		SettingsField(.doubleTapLockEnabled, keyPath: \.doubleTapLockEnabled, default: defaults.doubleTapLockEnabled).eraseToAny(),
		SettingsField(.tripleTapAutonomousEnabled, keyPath: \.tripleTapAutonomousEnabled, default: defaults.tripleTapAutonomousEnabled).eraseToAny(),
		SettingsField(
			.outputLanguage,
			keyPath: \.outputLanguage,
			default: defaults.outputLanguage,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(
			.selectedMicrophoneID,
			keyPath: \.selectedMicrophoneID,
			default: defaults.selectedMicrophoneID,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(.saveTranscriptionHistory, keyPath: \.saveTranscriptionHistory, default: defaults.saveTranscriptionHistory).eraseToAny(),
		SettingsField(
			.maxHistoryEntries,
			keyPath: \.maxHistoryEntries,
			default: defaults.maxHistoryEntries,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(
			.pasteLastTranscriptHotkey,
			keyPath: \.pasteLastTranscriptHotkey,
			default: defaults.pasteLastTranscriptHotkey,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(.hasCompletedModelBootstrap, keyPath: \.hasCompletedModelBootstrap, default: defaults.hasCompletedModelBootstrap).eraseToAny(),
		SettingsField(.hasCompletedStorageMigration, keyPath: \.hasCompletedStorageMigration, default: defaults.hasCompletedStorageMigration).eraseToAny(),
		SettingsField(.wordRemovalsEnabled, keyPath: \.wordRemovalsEnabled, default: defaults.wordRemovalsEnabled).eraseToAny(),
		SettingsField(
			.wordRemovals,
			keyPath: \.wordRemovals,
			default: defaults.wordRemovals
		).eraseToAny(),
		SettingsField(
			.wordRemappings,
			keyPath: \.wordRemappings,
			default: defaults.wordRemappings
		).eraseToAny(),
		SettingsField(.aiProvider, keyPath: \.aiProvider, default: defaults.aiProvider).eraseToAny(),
		SettingsField(
			.groqAPIKey,
			keyPath: \.groqAPIKey,
			default: defaults.groqAPIKey,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(
			.googleAPIKey,
			keyPath: \.googleAPIKey,
			default: defaults.googleAPIKey,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(.googleModel, keyPath: \.googleModel, default: defaults.googleModel).eraseToAny(),
		SettingsField(.aiPostProcessingMode, keyPath: \.aiPostProcessingMode, default: defaults.aiPostProcessingMode).eraseToAny(),
		SettingsField(.aiPostProcessingModel, keyPath: \.aiPostProcessingModel, default: defaults.aiPostProcessingModel).eraseToAny(),
		SettingsField(.selectedStyleIndex, keyPath: \.selectedStyleIndex, default: defaults.selectedStyleIndex).eraseToAny(),
		SettingsField(.hasSelectedStyle, keyPath: \.hasSelectedStyle, default: defaults.hasSelectedStyle).eraseToAny(),
		SettingsField(.autonomousModeEnabled, keyPath: \.autonomousModeEnabled, default: defaults.autonomousModeEnabled).eraseToAny(),
		SettingsField(.ttsEnabled, keyPath: \.ttsEnabled, default: defaults.ttsEnabled).eraseToAny(),
		SettingsField(.ttsVoice, keyPath: \.ttsVoice, default: defaults.ttsVoice).eraseToAny(),
		SettingsField(.enabledToolIDs, keyPath: \.enabledToolIDs, default: defaults.enabledToolIDs).eraseToAny(),
		SettingsField(.snippets, keyPath: \.snippets, default: defaults.snippets).eraseToAny()
	]
}
