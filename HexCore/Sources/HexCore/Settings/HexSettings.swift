import Foundation

public enum RecordingAudioBehavior: String, Codable, CaseIterable, Equatable, Sendable {
	case mute
	case doNothing
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

	public static func styleName(for styleIndex: Int) -> String {
		switch styleIndex {
		case 0: return "Formal"
		case 1: return "Casual"
		default: return "Very Casual"
		}
	}

	private static func styleInstructions(for styleIndex: Int) -> String {
		switch styleIndex {
		case 0: // Formal
			return """

SELECTED WRITING STYLE: FORMAL
- Use standard capitalization, grammar, and punctuation.
- Use a polished, professional tone without changing the speaker's meaning.
- End complete prose sentences with appropriate punctuation.
- For an unordered list, use one bullet per line. For an explicitly ordered list, use `1.`, `2.`, `3.`.
"""
		case 1: // Casual
			return """

SELECTED WRITING STYLE: CASUAL
- Keep sentence-initial capitalization and proper nouns capitalized.
- Use a relaxed, natural, friendly tone.
- Do not force a final period on a short chat/message unless it improves clarity.
- Preserve intentional emphasis and contractions; do not add slang or emoji.
"""
		case 2: // Very Casual
			fallthrough
		default:
			return """

SELECTED WRITING STYLE: VERY CASUAL
- Use lowercase for prose, including sentence starts, while preserving required spelling of code, commands, URLs, email addresses, and identifiers.
- Keep punctuation light and the tone very informal.
- Do not add slang, emoji, or content that was not spoken.
"""
		}
	}

	private static func genericPrompt(styleIndex: Int) -> String {
		let basePrompt = """
You are Tick's fast, local dictation formatter. You receive imperfect speech-to-text and return the exact text the user intended to type.

Your job:
- Infer whether the input is prose, a message, an email, a note, a list, a command, code, or a short fragment.
- Remove speech fillers such as "um", "uh", "you know", and meaningless "like".
- Fix spelling, grammar, capitalization, punctuation, and obvious transcription homophones.
- Resolve self-corrections: in "Tuesday, sorry, Wednesday", output only "Wednesday". Recognize "I mean", "no wait", "actually", and "sorry" as correction cues.
- Preserve the speaker's words, intent, language, and personality. Do not invent facts or expand content.

Formatting rules:
- Convert spoken formatting cues into formatting: "new line"/"next line" means a line break, "new paragraph" means a blank line, and spoken "comma", "period", "question mark", or "colon" means the corresponding punctuation.
- Detect list intent. Use one item per line. Use `1.`, `2.`, `3.` for an explicitly ordered sequence ("first", "second", "step one"), and `- ` for an unordered list ("bullet points", "items", or a series of things). Never turn ordinary prose into a list.
- Use blank lines between distinct paragraphs. Keep headings only when the speaker clearly dictates a heading or the destination context calls for one.
- Keep code, shell commands, URLs, email addresses, numbers, and identifiers syntactically valid. Never wrap code or commands in fences.
- Output in the same language as the transcription unless the transcription explicitly asks for translation.

Output rules:
- Return ONLY the final text, with no explanation, preamble, labels, or markdown fences.
- If the transcription is empty, return exactly: EMPTY.
- Never output reasoning, analysis, or a correction summary.
- When style conflicts with code/command syntax or required email/URL casing, preserve the syntax.
"""
		return basePrompt + styleInstructions(for: styleIndex)
	}

	private static func appAwarePrompt(appContext: AppContext?, styleIndex: Int) -> String {
		let basePrompt = """
You are Tick's fast, local dictation formatter. You receive imperfect speech-to-text and return only the final text intended for the target application.

General rules:
- Remove filler words (um, uh, you know, like, er) when they do not carry meaning.
- Fix spelling, grammar, punctuation, and obvious speech-recognition errors.
- Resolve self-corrections by keeping the corrected phrase only.
- Translate spoken formatting cues into line breaks, paragraphs, punctuation, and lists.
- For list intent, put each item on its own line: number ordered items and use bullets for unordered items.
- Preserve language, meaning, code syntax, identifiers, URLs, and email addresses.

Output rules:
- Return ONLY the final text. Do not include explanations, labels, reasoning, or markdown fences.
- If the transcription is empty, return exactly: EMPTY.
- Do not add content that was not spoken, except the standard email structure explicitly required by email context below.
"""
		let category = appContext?.category ?? .other
		let categoryContext = category.systemPromptContext

		guard !categoryContext.isEmpty else {
			return basePrompt + "\n\nNo specific application is known. Choose the simplest formatting supported by the content." + styleInstructions(for: styleIndex)
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

		return basePrompt + "\n\nFormatting rules for \(category.displayName) context:\n" + categoryContext + contextSection + styleInstructions(for: styleIndex)
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

/// The single model used for optional on-device post-processing.
public enum OnDeviceAIModel {
	public static let identifier = "Qwen/Qwen3-1.7B-MLX-4bit"
	public static let displayName = "Qwen3 1.7B"
	public static let approximateSize = "~914 MB"
	public static let remoteBaseURL = URL(string: "https://pub-54623ce7fca847f9aec8c62f976b6c09.r2.dev/tick/models")!
	public static let files: [(name: String, size: Int64)] = [
		("config.json", 988),
		("merges.txt", 1_671_853),
		("model.safetensors.index.json", 49_731),
		("tokenizer.json", 11_422_654),
		("tokenizer_config.json", 8_311),
		("vocab.json", 2_776_833),
		("model.safetensors", 914_316_100)
	]
}

/// Defensive validation for local model output. A bad completion must never
/// replace a good raw transcription.
public enum AIPostProcessingOutputValidator {
	public static func validated(_ output: String) -> String? {
		let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !value.isEmpty, value.caseInsensitiveCompare("EMPTY") != .orderedSame else {
			return nil
		}

		let invalidMarkers = [
			"<think>", "</think>", "<reasoning>", "</reasoning>",
			"<analysis>", "</analysis>", "<|im_start|>", "<|im_end|>",
			"<|endoftext|>", "```"
		]
		guard !invalidMarkers.contains(where: { value.range(of: $0, options: .caseInsensitive) != nil }) else {
			return nil
		}

		let firstLine = value.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
		let wrapperPrefixes = [
			"corrected transcription:", "corrected text:", "final answer:",
			"here is the corrected text:", "here's the corrected text:", "output:"
		]
		guard !wrapperPrefixes.contains(where: { firstLine.hasPrefix($0) }) else {
			return nil
		}

		return value
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
	public var aiPostProcessingMode: AIPostProcessingMode
	public var selectedStyleIndex: Int
	public var hasSelectedStyle: Bool
	public var snippets: [SnippetSetting]

	private mutating func normalizeDoubleTapSettings() {
		if !doubleTapLockEnabled {
			useDoubleTapOnly = false
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
		aiPostProcessingMode: AIPostProcessingMode = .off,
		selectedStyleIndex: Int = 2,
		hasSelectedStyle: Bool = false,
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
		self.aiPostProcessingMode = aiPostProcessingMode
		self.selectedStyleIndex = selectedStyleIndex
		self.hasSelectedStyle = hasSelectedStyle
		self.snippets = snippets
		normalizeDoubleTapSettings()
	}

	public init(from decoder: Decoder) throws {
		self.init()
		let container = try decoder.container(keyedBy: HexSettingKey.self)
		// Legacy Groq fields are intentionally not part of HexSettingKey. They
		// are ignored while decoding and disappear on the next save, so an
		// existing user keeps their mode/style without retaining cloud settings.
		for field in HexSettingsSchema.fields {
			try field.decode(into: &self, from: container)
		}
		normalizeDoubleTapSettings()
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
	case aiPostProcessingMode
	case selectedStyleIndex
	case hasSelectedStyle
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
				if let rawValue = try container.decodeIfPresent(String.self, forKey: key) {
					switch rawValue {
					case RecordingAudioBehavior.mute.rawValue:
						return .mute
					case RecordingAudioBehavior.doNothing.rawValue:
						return .doNothing
					default:
						// Includes the removed "pauseMedia" value.
						return .doNothing
					}
				}
				if (try container.decodeIfPresent(Bool.self, forKey: .pauseMediaOnRecord)) != nil {
					return .doNothing
				}
				return defaultValue
			}
		).eraseToAny(),
		SettingsField(.minimumKeyTime, keyPath: \.minimumKeyTime, default: defaults.minimumKeyTime).eraseToAny(),
		SettingsField(.copyToClipboard, keyPath: \.copyToClipboard, default: defaults.copyToClipboard).eraseToAny(),
		SettingsField(.superFastModeEnabled, keyPath: \.superFastModeEnabled, default: defaults.superFastModeEnabled).eraseToAny(),
		SettingsField(.useDoubleTapOnly, keyPath: \.useDoubleTapOnly, default: defaults.useDoubleTapOnly).eraseToAny(),
		SettingsField(.doubleTapLockEnabled, keyPath: \.doubleTapLockEnabled, default: defaults.doubleTapLockEnabled).eraseToAny(),
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
		SettingsField(.aiPostProcessingMode, keyPath: \.aiPostProcessingMode, default: defaults.aiPostProcessingMode).eraseToAny(),
		SettingsField(.selectedStyleIndex, keyPath: \.selectedStyleIndex, default: defaults.selectedStyleIndex).eraseToAny(),
		SettingsField(.hasSelectedStyle, keyPath: \.hasSelectedStyle, default: defaults.hasSelectedStyle).eraseToAny(),
		SettingsField(.snippets, keyPath: \.snippets, default: defaults.snippets).eraseToAny()
	]
}
