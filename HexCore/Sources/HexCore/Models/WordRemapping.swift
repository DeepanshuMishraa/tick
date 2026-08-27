import Foundation

public struct WordRemapping: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var isEnabled: Bool
	public var match: String
	public var replacement: String

	public init(
		id: UUID = UUID(),
		isEnabled: Bool = true,
		match: String,
		replacement: String
	) {
		self.id = id
		self.isEnabled = isEnabled
		self.match = match
		self.replacement = replacement
	}
}

/// A single, intentional replacement made to text Hex just inserted.
///
/// This is deliberately conservative: dictionary learning only happens when
/// the user changes exactly one word and leaves the rest of the field intact.
public struct WordCorrection: Equatable, Sendable {
	public var match: String
	public var replacement: String

	public init(match: String, replacement: String) {
		self.match = match
		self.replacement = replacement
	}
}

public enum WordCorrectionDetector {
	/// Finds one word replacement between two snapshots of the same text field.
	/// Insertions, deletions, multi-word edits, and punctuation-only edits are
	/// ignored so an accidental edit cannot pollute the dictionary.
	public static func detect(before: String, after: String) -> WordCorrection? {
		let beforeWords = words(in: before)
		let afterWords = words(in: after)
		guard beforeWords.count == afterWords.count, !beforeWords.isEmpty else { return nil }

		let changedIndices = beforeWords.indices.filter {
			beforeWords[$0].caseInsensitiveCompare(afterWords[$0]) != .orderedSame
		}
		guard changedIndices.count == 1, let index = changedIndices.first else { return nil }

		let match = beforeWords[index]
		let replacement = afterWords[index]
		guard match.count > 1, replacement.count > 1 else { return nil }
		return WordCorrection(match: match, replacement: replacement)
	}

	private static func words(in text: String) -> [String] {
		text.split { character in
			!character.isLetter && !character.isNumber && character != "'"
		}.map(String.init)
	}
}

public enum WordRemappingApplier {
	public static func apply(_ text: String, remappings: [WordRemapping]) -> String {
		guard !remappings.isEmpty else { return text }
		var output = text
		for remapping in remappings where remapping.isEnabled {
			let trimmed = remapping.match.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }
			let escaped = NSRegularExpression.escapedPattern(for: trimmed)
			let pattern = "(?<!\\w)\(escaped)(?!\\w)"
			let replacement = processEscapeSequences(remapping.replacement)
			// Escape backslashes for regex replacement (backslash is special in replacement strings)
			let escapedReplacement = replacement.replacingOccurrences(of: "\\", with: "\\\\")
			output = output.replacingOccurrences(
				of: pattern,
				with: escapedReplacement,
				options: [.regularExpression, .caseInsensitive]
			)
		}
		return output
	}

	/// Processes escape sequences in a string: `\n` → newline, `\t` → tab, `\\` → backslash
	private static func processEscapeSequences(_ string: String) -> String {
		let placeholder = "\u{0000}"
		return string
			.replacingOccurrences(of: "\\\\", with: placeholder)
			.replacingOccurrences(of: "\\n", with: "\n")
			.replacingOccurrences(of: "\\t", with: "\t")
			.replacingOccurrences(of: "\\r", with: "\r")
			.replacingOccurrences(of: placeholder, with: "\\")
	}
}
