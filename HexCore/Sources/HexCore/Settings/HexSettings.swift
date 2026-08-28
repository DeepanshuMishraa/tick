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
You are Tick's fast local dictation formatter. Return only the final text the speaker intended to type.

Rules:
- Remove spoken thinking fillers and hesitation words wherever they do not carry meaning: "um", "umm", "uh", "uhh", "hmm", "hm", "ah", "ahh", "er", "erm", "like" when used only as a filler, and "you know" when it is not meaningful. Never remove these words when they are part of a name, quoted text, code, or intended meaning. Then fix spelling, grammar, capitalization, punctuation, and obvious transcription errors.
- Resolve corrections before formatting. In "meet me at 3pm, no sorry 4pm", output "meet me at 4pm" only. Treat "no wait", "actually", and "I mean" the same way.
- Convert spoken "new line", "next line", "new paragraph", "comma", "period", "question mark", and "colon" to formatting.
- Treat "first thing is ...", "second thing is ...", "third thing is ...", and similar item markers as hard boundaries between ordered list items. Keep any introduction as prose, then put each item on its own line.
- A request for a "list" alone is an unordered list: one `- ` bullet per item. Use `1.`, `2.`, `3.` only for explicit numbering/order or ordinal cues such as "first" and "second". Number items consecutively in ordered lists, even if a spoken ordinal is wrong. For example, first/second/fourth becomes 1/2/3. Never turn ordinary prose into a list.
- Preserve meaning, language, personality, code, commands, URLs, email addresses, numbers, and identifiers. Do not invent content or use markdown fences.
- Use blank lines between paragraphs and return EMPTY for empty input.

Output only the final answer. No reasoning, labels, explanations, or correction summary.

Examples:
Input: meet me at 3pm, no sorry 4pm
Output: meet me at 4pm
Input: give me a list of three things: how to be nice, how to be fair, and how to be great
Output:
- how to be nice
- how to be fair
- how to be great
Input: give me a list of three things. First, how to be nice. Second, how to be fair. Fourth, how to be great.
Output:
1. How to be nice
2. How to be fair
3. How to be great
Input: The first thing is hello everyone. Second thing is hello, how are you? And third thing is how are you doing, mate.
Output:
1. Hello everyone.
2. Hello, how are you?
3. How are you doing, mate.
"""
		return basePrompt + styleInstructions(for: styleIndex)
	}

	private static func appAwarePrompt(appContext: AppContext?, styleIndex: Int) -> String {
		let basePrompt = """
You are Tick's fast local dictation formatter. Return only the final text intended for the target application.

Rules:
- Remove spoken thinking fillers and hesitation words such as "um", "umm", "uh", "uhh", "hmm", "hm", "ah", "ahh", "er", "erm", filler "like", and non-meaningful "you know". Preserve them when intentional or part of a name, quote, code, or identifier. Fix spelling, grammar, punctuation, capitalization, and obvious speech-recognition errors.
- Resolve corrections before formatting: "meet me at 3pm, no sorry 4pm" becomes "meet me at 4pm" only.
- Convert spoken line breaks, paragraphs, and punctuation into real formatting.
- Treat "first thing is", "second thing is", "third thing is", and similar markers as hard boundaries between ordered list items.
- A "list" alone uses one `- ` bullet per item. Explicit numbering/order or ordinal cues use consecutive `1.`, `2.`, `3.` numbering, even when the spoken ordinal is wrong.
- Preserve meaning, language, code, commands, URLs, email addresses, numbers, and identifiers. Never use fences or add content unless the email context below requires standard email structure.

Output only the final answer. No reasoning, labels, or explanations. Empty input becomes EMPTY.
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

/// Removes only high-confidence spoken correction cues before the local model
/// formats the transcription. This keeps common corrections reliable even when
/// the compact model spends its output budget on formatting.
public enum AIPostProcessingInputNormalizer {
	private static let correctionCues = [
		"no, sorry",
		"no sorry",
		"no, wait",
		"no wait",
		"i mean"
	]

	public static func normalized(_ text: String) -> String {
		var value = text
		for _ in 0..<3 {
			guard let cue = earliestCue(in: value) else { break }
			let replacement = String(value[cue.range.upperBound...])
				.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:")))
			guard !replacement.isEmpty else { break }

			let prefix = String(value[..<cue.range.lowerBound])
			guard let correctedPrefix = replacingAbandonedPhrase(in: prefix) else { break }
			value = correctedPrefix + " " + replacement
		}
		value = normalizedSpokenOrderedList(value)
		return value
			.replacingOccurrences(of: #"[^\S\r\n]+"#, with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private static func earliestCue(in text: String) -> (range: Range<String.Index>, cue: String)? {
		correctionCues
			.compactMap { cue in
				guard let range = text.range(of: cue, options: .caseInsensitive) else { return nil }
				return (range, cue)
			}
			.min { $0.range.lowerBound < $1.range.lowerBound }
	}

	private static func replacingAbandonedPhrase(in prefix: String) -> String? {
		var phrase = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
		while let last = phrase.last, [",", ";", ":"].contains(last) {
			phrase.removeLast()
			phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
		}

		// If the abandoned phrase is a complete sentence, preserve earlier
		// sentences and discard only the sentence being corrected.
		if let last = phrase.last, [".", "!", "?"].contains(last) {
			phrase.removeLast()
			phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		if let boundary = phrase.lastIndex(where: { ".!?\n".contains($0) }) {
			let preserved = String(phrase[...boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
			if !preserved.isEmpty {
				return preserved
			}
		}

		var words = phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
		guard !words.isEmpty else { return nil }

		let anchors = Set(["at", "on", "to", "for", "from", "in", "with", "as"])
		if let anchorIndex = words.lastIndex(where: { anchors.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }) {
			words = Array(words.prefix(anchorIndex + 1))
		} else {
			words.removeLast()
		}
		return words.joined(separator: " ")
	}

	private static func normalizedSpokenOrderedList(_ text: String) -> String {
		let pattern = #"\b(?:the\s+)?(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\s+(?:thing|item|point|step)\s+(?:is|:)\s*"#
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
			return text
		}
		let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
		let matches = regex.matches(in: text, range: fullRange)
		guard matches.count >= 2 else { return text }

		let firstMatch = matches[0]
		guard let firstMarkerRange = Range(firstMatch.range, in: text) else { return text }
		var prefix = String(text[..<firstMarkerRange.lowerBound])
		prefix = prefix.replacingOccurrences(
			of: #"\bthe\s*$"#,
			with: "",
			options: [.caseInsensitive, .regularExpression]
		).trimmingCharacters(in: .whitespacesAndNewlines)

		var items: [String] = []
		for (index, match) in matches.enumerated() {
			guard let markerRange = Range(match.range, in: text) else { continue }
			let contentEnd = index + 1 < matches.count
				? Range(matches[index + 1].range, in: text)?.lowerBound ?? text.endIndex
				: text.endIndex
			var content = String(text[markerRange.upperBound..<contentEnd])
			content = content.trimmingCharacters(in: .whitespacesAndNewlines)
			content = content.replacingOccurrences(
				of: #"\s+(?:and|then)\s*$"#,
				with: "",
				options: [.caseInsensitive, .regularExpression]
			).trimmingCharacters(in: .whitespacesAndNewlines)
			if !content.isEmpty {
				items.append(content)
			}
		}
		guard items.count >= 2 else { return text }

		let numberedItems = items.enumerated().map { "\($0.offset + 1). \($0.element)" }
		if prefix.isEmpty {
			return numberedItems.joined(separator: "\n")
		}
		return prefix + "\n" + numberedItems.joined(separator: "\n")
	}
}

/// Defensive validation for local model output. A bad completion must never
/// replace a good raw transcription.
public enum AIPostProcessingOutputValidator {
	public static func validated(_ output: String, sourceText: String? = nil) -> String? {
		guard var value = removingModelArtifacts(from: output) else { return nil }
		value = removingKnownWrapperPrefix(from: value)
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

		guard let sourceText else { return value }
		// Apply the same high-confidence cleanup to a near-verbatim model
		// completion. This guarantees corrections and spoken item markers are
		// handled even when the small local model copies the input structure.
		return normalizedListFormatting(AIPostProcessingInputNormalizer.normalized(value), sourceText: sourceText)
	}

	private static func removingModelArtifacts(from output: String) -> String? {
		var value = output.trimmingCharacters(in: .whitespacesAndNewlines)
		let reasoningBlocks = [
			("<think>", "</think>"),
			("<reasoning>", "</reasoning>"),
			("<analysis>", "</analysis>")
		]

		for (opening, closing) in reasoningBlocks {
			while let start = value.range(of: opening, options: .caseInsensitive) {
				guard let end = value.range(
					of: closing,
					options: .caseInsensitive,
					range: start.upperBound..<value.endIndex
				) else {
					return nil
				}
				value.removeSubrange(start.lowerBound..<end.upperBound)
			}
		}

		for marker in ["<|im_start|>", "<|im_end|>", "<|endoftext|>"] {
			value = value.replacingOccurrences(of: marker, with: "", options: .caseInsensitive)
		}
		return value.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private static func removingKnownWrapperPrefix(from output: String) -> String {
		let prefixes = [
			"corrected transcription:", "corrected text:", "final answer:",
			"here is the corrected text:", "here's the corrected text:", "output:"
		]
		var value = output
		let lowercased = value.lowercased()
		if let prefix = prefixes.first(where: { lowercased.hasPrefix($0) }) {
			value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return value
	}

	private static func normalizedListFormatting(_ output: String, sourceText: String) -> String {
		let source = sourceText.lowercased()
		let hasListCue = source.contains("list")
		let hasOrderedCue = [
			"first", "second", "third", "fourth", "step", "numbered", "in order", "number one"
		].contains(where: source.contains)
		guard hasListCue || hasOrderedCue else { return output }

		var lines = output.components(separatedBy: .newlines)
		var numberedLineCount = 0
		for line in lines where numberedContent(in: line) != nil {
			numberedLineCount += 1
		}
		guard numberedLineCount >= 2 else { return output }

		var itemNumber = 0
		for index in lines.indices {
			guard let content = numberedContent(in: lines[index]) else { continue }
			itemNumber += 1
			if hasOrderedCue {
				lines[index] = "\(itemNumber). \(content)"
			} else {
				lines[index] = "- \(content)"
			}
		}
		return lines.joined(separator: "\n")
	}

	private static func numberedContent(in line: String) -> String? {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		var end = trimmed.startIndex
		while end < trimmed.endIndex, trimmed[end].isNumber {
			end = trimmed.index(after: end)
		}
		guard end > trimmed.startIndex, end < trimmed.endIndex,
			trimmed[end] == "." || trimmed[end] == ")"
		else { return nil }

		let contentStart = trimmed.index(after: end)
		let content = String(trimmed[contentStart...]).trimmingCharacters(in: .whitespaces)
		return content.isEmpty ? nil : content
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
