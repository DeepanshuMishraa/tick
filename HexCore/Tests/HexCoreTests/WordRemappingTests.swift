import Testing
@testable import HexCore
import Sauce

struct WordRemappingTests {
	@Test
	func detectsOneWordCorrection() {
		let correction = WordCorrectionDetector.detect(
			before: "Please open kurzor in the browser",
			after: "Please open cursor in the browser"
		)

		#expect(correction == WordCorrection(match: "kurzor", replacement: "cursor"))
	}

	@Test
	func detectsHelloCorrectionWithPunctuation() {
		let correction = WordCorrectionDetector.detect(
			before: "hello, how are you?",
			after: "helo, how are you?"
		)

		#expect(correction == WordCorrection(match: "hello", replacement: "helo"))
	}

	@Test
	func delayedBaselineMustContainInsertedText() {
		#expect(WordCorrectionDetector.containsInsertedText(
			"hello, how are you?",
			insertedText: "hello, how are you?"
		))
		#expect(!WordCorrectionDetector.containsInsertedText(
			"helo, how are you?",
			insertedText: "hello, how are you?"
		))
	}

	@Test
	func refusesToLearnWithoutACompleteBaseline() {
		let correction = WordCorrectionDetector.detectObservedCorrection(
			beforeInsertion: "Please say ",
			baseline: nil,
			snapshot: "zeros is changed to ones",
			insertedText: "hello, how are you?"
		)

		#expect(correction == nil)
	}

	@Test
	func detectsCorrectionAgainstCompleteBaseline() {
		let correction = WordCorrectionDetector.detectObservedCorrection(
			beforeInsertion: "Please say ",
			baseline: "Please say hello, how are you?",
			snapshot: "Please say helo, how are you?",
			insertedText: "hello, how are you?"
		)

		#expect(correction == WordCorrection(match: "hello", replacement: "helo"))
	}

	@Test
	func ignoresCorrectionOutsideInsertedPhrase() {
		let correction = WordCorrectionDetector.detectObservedCorrection(
			beforeInsertion: "Please say ",
			baseline: "Please say hello, how are you? Existing text",
			snapshot: "Please say hello, how are you? Changed text",
			insertedText: "hello, how are you?"
		)

		#expect(correction == nil)
	}

	@Test
	func ignoresStalePrePasteSnapshot() {
		let correction = WordCorrectionDetector.detectObservedCorrection(
			beforeInsertion: "Please say ",
			baseline: nil,
			snapshot: "Please say ",
			insertedText: "hello, how are you?"
		)

		#expect(correction == nil)
	}

	@Test
	func reconstructsKeyboardCorrectionWithoutAccessibilityText() {
		var tracker = WordCorrectionKeystrokeTracker(insertedText: "hello, how are you?")
		_ = tracker.apply(key: .leftArrow, text: nil, modifiers: [.command])
		_ = tracker.apply(key: .rightArrow, text: nil, modifiers: [])
		_ = tracker.apply(key: .rightArrow, text: nil, modifiers: [])
		_ = tracker.apply(key: .forwardDelete, text: nil, modifiers: [])

		#expect(tracker.currentText == "helo, how are you?")
		#expect(tracker.correction == WordCorrection(match: "hello", replacement: "helo"))
	}

	@Test
	func reconstructsSelectedWordReplacement() {
		var tracker = WordCorrectionKeystrokeTracker(insertedText: "hello world")
		_ = tracker.apply(key: .leftArrow, text: nil, modifiers: [.command])
		for _ in 0..<5 {
			_ = tracker.apply(key: .rightArrow, text: nil, modifiers: [.shift])
		}
		_ = tracker.apply(key: .h, text: "h", modifiers: [])
		_ = tracker.apply(key: .e, text: "e", modifiers: [])
		_ = tracker.apply(key: .l, text: "l", modifiers: [])
		_ = tracker.apply(key: .o, text: "o", modifiers: [])

		#expect(tracker.currentText == "helo world")
		#expect(tracker.correction == WordCorrection(match: "hello", replacement: "helo"))
	}

	@Test
	func ignoresMultipleWordCorrections() {
		let correction = WordCorrectionDetector.detect(
			before: "open kurzor now",
			after: "open cursor please"
		)

		#expect(correction == nil)
	}

	@Test
	func ignoresInsertionsAndDeletions() {
		#expect(WordCorrectionDetector.detect(before: "open kurzor", after: "open cursor now") == nil)
		#expect(WordCorrectionDetector.detect(before: "open kurzor now", after: "open cursor") == nil)
	}

	@Test
	func expandsSnippetBeforeInsertion() {
		let snippets = [SnippetSetting(shortcut: "Gmail", content: "person@example.com")]
		let result = SnippetApplier.apply("Send this to Gmail", snippets: snippets)

		#expect(result == "Send this to person@example.com")
	}

	@Test
	func basicRemapping() {
		let remappings = [
			WordRemapping(match: "comma", replacement: ",")
		]
		let result = WordRemappingApplier.apply("Hello comma world", remappings: remappings)
		#expect(result == "Hello , world")
	}

	@Test
	func newlineEscapeSequence() {
		let remappings = [
			WordRemapping(match: "new line", replacement: "\\n")
		]
		let result = WordRemappingApplier.apply("Hello new line world", remappings: remappings)
		#expect(result == "Hello \n world")
	}

	@Test
	func newParagraphEscapeSequence() {
		let remappings = [
			WordRemapping(match: "new paragraph", replacement: "\\n\\n")
		]
		let result = WordRemappingApplier.apply("Hello new paragraph world", remappings: remappings)
		#expect(result == "Hello \n\n world")
	}

	@Test
	func tabEscapeSequence() {
		let remappings = [
			WordRemapping(match: "tab", replacement: "\\t")
		]
		let result = WordRemappingApplier.apply("Hello tab world", remappings: remappings)
		#expect(result == "Hello \t world")
	}

	@Test
	func escapedBackslash() {
		let remappings = [
			WordRemapping(match: "backslash", replacement: "\\\\")
		]
		let result = WordRemappingApplier.apply("Hello backslash world", remappings: remappings)
		#expect(result == "Hello \\ world")
	}

	@Test
	func literalBackslashN() {
		let remappings = [
			WordRemapping(match: "code", replacement: "\\\\n")
		]
		let result = WordRemappingApplier.apply("Hello code world", remappings: remappings)
		#expect(result == "Hello \\n world")
	}

	@Test
	func caseInsensitive() {
		let remappings = [
			WordRemapping(match: "COMMA", replacement: ",")
		]
		let result = WordRemappingApplier.apply("Hello comma world", remappings: remappings)
		#expect(result == "Hello , world")
	}

	@Test
	func doesNotRemapInsideWords() {
		let remappings = [
			WordRemapping(match: "new", replacement: "\\n")
		]
		let result = WordRemappingApplier.apply("renewable energy", remappings: remappings)
		#expect(result == "renewable energy")
	}

	@Test
	func disabledRemappingIgnored() {
		let remappings = [
			WordRemapping(isEnabled: false, match: "comma", replacement: ",")
		]
		let result = WordRemappingApplier.apply("Hello comma world", remappings: remappings)
		#expect(result == "Hello comma world")
	}

	@Test
	func multipleRemappings() {
		let remappings = [
			WordRemapping(match: "comma", replacement: ","),
			WordRemapping(match: "period", replacement: "."),
			WordRemapping(match: "new line", replacement: "\\n")
		]
		let result = WordRemappingApplier.apply("Hello comma new line world period", remappings: remappings)
		#expect(result == "Hello , \n world .")
	}
}
