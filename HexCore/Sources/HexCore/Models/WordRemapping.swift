import Foundation
import Sauce

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

	/// Returns true when a snapshot contains the text Hex inserted. This is
	/// used by the live correction monitor while waiting for delayed
	/// Accessibility updates; an already-edited value must never be adopted as
	/// the post-paste baseline.
	public static func containsInsertedText(_ snapshot: String, insertedText: String) -> Bool {
		let insertedWords = words(in: insertedText)
		guard !insertedWords.isEmpty else { return false }
		let snapshotWords = words(in: snapshot)
		guard snapshotWords.count >= insertedWords.count else { return false }

		return snapshotWords.indices.contains { index in
			guard index + insertedWords.count <= snapshotWords.count else { return false }
			return zip(snapshotWords[index...], insertedWords).allSatisfy {
				$0.caseInsensitiveCompare($1) == .orderedSame
			}
		}
	}

	/// Compares two complete Accessibility values. A missing baseline is not
	/// enough evidence to learn a dictionary entry: comparing an arbitrary
	/// focused/selected fragment against the inserted phrase creates false
	/// remappings from unrelated text.
	public static func detectObservedCorrection(
		beforeInsertion: String?,
		baseline: String?,
		snapshot: String,
		insertedText: String
	) -> WordCorrection? {
		guard snapshot != beforeInsertion else { return nil }
		guard let baseline, containsInsertedText(baseline, insertedText: insertedText) else { return nil }
		guard let correction = detect(before: baseline, after: snapshot) else { return nil }

		// The changed token must be inside the exact phrase Hex inserted. A
		// change elsewhere in a long document is ordinary typing, not a
		// correction of this transcription.
		let baselineWords = words(in: baseline)
		let snapshotWords = words(in: snapshot)
		let insertedWords = words(in: insertedText)
		let changedIndices = baselineWords.indices.filter {
			baselineWords[$0].caseInsensitiveCompare(snapshotWords[$0]) != .orderedSame
		}
		guard changedIndices.count == 1, let changedIndex = changedIndices.first else { return nil }

		let isInsideInsertedPhrase = baselineWords.indices.contains { start in
			guard start + insertedWords.count <= baselineWords.count,
				  changedIndex >= start,
				  changedIndex < start + insertedWords.count else { return false }
			return zip(baselineWords[start..<(start + insertedWords.count)], insertedWords)
				.allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
		}
		return isInsideInsertedPhrase ? correction : nil
	}

	private static func words(in text: String) -> [String] {
		text.split { character in
			!character.isLetter && !character.isNumber && character != "'"
		}.map(String.init)
	}
}

/// Reconstructs a correction made immediately after Hex inserts text when the
/// target editor does not expose its value through Accessibility. The tracker
/// is intentionally short-lived and only models edits within the inserted
/// phrase; it does not persist or log general keyboard input.
public struct WordCorrectionKeystrokeTracker: Equatable, Sendable {
	public let originalText: String
	public private(set) var currentText: String

	private var characters: [Character]
	private var caret: Int
	private var selectionAnchor: Int?

	public init(insertedText: String) {
		originalText = insertedText
		currentText = insertedText
		characters = Array(insertedText)
		caret = characters.count
		selectionAnchor = nil
	}

	public var correction: WordCorrection? {
		WordCorrectionDetector.detect(before: originalText, after: currentText)
	}

	/// Applies one key-down event. Returns true only when the reconstructed text
	/// changed and the correction settle timer should be restarted.
	public mutating func apply(key: Key?, text: String?, modifiers: Modifiers) -> Bool {
		guard let key else { return false }
		let hasCommand = modifiers.contains(kind: .command)
		let hasControl = modifiers.contains(kind: .control)
		let hasOption = modifiers.contains(kind: .option)
		let hasShift = modifiers.contains(kind: .shift)

		switch key {
		case .leftArrow:
			moveCaret(to: hasCommand ? 0 : (hasOption ? previousWordBoundary() : caret - 1), selecting: hasShift)
			return false
		case .rightArrow:
			moveCaret(to: hasCommand ? characters.count : (hasOption ? nextWordBoundary() : caret + 1), selecting: hasShift)
			return false
		case .home:
			moveCaret(to: 0, selecting: hasShift)
			return false
		case .end:
			moveCaret(to: characters.count, selecting: hasShift)
			return false
		case .delete:
			if removeSelection() { return finishMutation() }
			let start = max(0, hasCommand ? 0 : (hasOption ? previousWordBoundary() : caret - 1))
			guard start < caret else { return false }
			characters.removeSubrange(start..<caret)
			caret = start
			return finishMutation()
		case .forwardDelete:
			if removeSelection() { return finishMutation() }
			let end = min(characters.count, hasCommand ? characters.count : (hasOption ? nextWordBoundary() : caret + 1))
			guard caret < end else { return false }
			characters.removeSubrange(caret..<end)
			return finishMutation()
		default:
			guard !hasCommand, !hasControl, let text, !text.isEmpty else { return false }
			_ = removeSelection()
			let inserted = Array(text)
			characters.insert(contentsOf: inserted, at: caret)
			caret += inserted.count
			return finishMutation()
		}
	}

	private mutating func moveCaret(to proposed: Int, selecting: Bool) {
		if selecting {
			if selectionAnchor == nil { selectionAnchor = caret }
		} else {
			selectionAnchor = nil
		}
		caret = min(max(proposed, 0), characters.count)
	}

	private mutating func removeSelection() -> Bool {
		guard let anchor = selectionAnchor, anchor != caret else {
			selectionAnchor = nil
			return false
		}
		let lower = min(anchor, caret)
		let upper = max(anchor, caret)
		characters.removeSubrange(lower..<upper)
		caret = lower
		selectionAnchor = nil
		return true
	}

	private func previousWordBoundary() -> Int {
		var index = caret
		while index > 0, characters[index - 1].isWhitespace { index -= 1 }
		while index > 0, !characters[index - 1].isWhitespace { index -= 1 }
		return index
	}

	private func nextWordBoundary() -> Int {
		var index = caret
		while index < characters.count, !characters[index].isWhitespace { index += 1 }
		while index < characters.count, characters[index].isWhitespace { index += 1 }
		return index
	}

	private mutating func finishMutation() -> Bool {
		selectionAnchor = nil
		currentText = String(characters)
		return true
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
