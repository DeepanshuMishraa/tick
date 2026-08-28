import XCTest
@testable import HexCore

final class AIPostProcessingTests: XCTestCase {
	func testDisabledModeHasNoPrompt() {
		XCTAssertTrue(AIPostProcessingMode.off.systemPrompt().isEmpty)
	}

	func testPromptsIncludeSelectedStyleAndListFormatting() {
		let formal = AIPostProcessingMode.on.systemPrompt(selectedStyleIndex: 0)
		let casual = AIPostProcessingMode.on.systemPrompt(selectedStyleIndex: 1)
		let veryCasual = AIPostProcessingMode.on.systemPrompt(selectedStyleIndex: 2)

		XCTAssertTrue(formal.contains("SELECTED WRITING STYLE: FORMAL"))
		XCTAssertTrue(casual.contains("SELECTED WRITING STYLE: CASUAL"))
		XCTAssertTrue(veryCasual.contains("SELECTED WRITING STYLE: VERY CASUAL"))
		XCTAssertTrue(formal.contains("Number items consecutively"))
		XCTAssertTrue(formal.contains("unordered list"))
	}

	func testSmartPromptKeepsApplicationContextAndStyle() {
		let context = AppContext(bundleID: "com.apple.Terminal", appName: "Terminal")
		let prompt = AIPostProcessingMode.on.systemPrompt(appContext: context, selectedStyleIndex: 1)

		XCTAssertTrue(prompt.contains("Terminal"))
		XCTAssertTrue(prompt.contains("raw shell command"))
		XCTAssertTrue(prompt.contains("SELECTED WRITING STYLE: CASUAL"))
	}

	func testPromptForcesTransformationInsteadOfAnAssistantReply() {
		let prompt = AIPostProcessingMode.on.systemPrompt()

		XCTAssertTrue(prompt.contains("text-transformation task, not a question-answering task"))
		XCTAssertTrue(prompt.contains("Never answer, solve, explain, or comment"))
		XCTAssertTrue(prompt.contains("Email / Letter Intent"))
		XCTAssertTrue(prompt.contains("Do not invent recipients"))
	}

	func testValidatorRemovesModelArtifactsAndKnownWrappers() {
		XCTAssertNil(AIPostProcessingOutputValidator.validated(""))
		XCTAssertNil(AIPostProcessingOutputValidator.validated("EMPTY"))
		XCTAssertEqual(
			AIPostProcessingOutputValidator.validated("<think>private reasoning</think>answer"),
			"answer"
		)
		XCTAssertEqual(AIPostProcessingOutputValidator.validated("Corrected text:\nhello"), "hello")
		XCTAssertNil(AIPostProcessingOutputValidator.validated("<think>unfinished reasoning"))
		XCTAssertNil(AIPostProcessingOutputValidator.validated("```bash\nls\n```"))
	}

	func testValidatorRejectsConversationalAnswer() {
		XCTAssertNil(
			AIPostProcessingOutputValidator.validated(
				"Sure, the answer is 42.",
				sourceText: "what is the answer to life"
			)
		)
	}

	func testValidatorPreservesFormattedText() {
		let output = "1. First item\n2. Second item\n\nA new paragraph."
		XCTAssertEqual(AIPostProcessingOutputValidator.validated(output), output)
	}

	func testInputNormalizerKeepsOnlySelfCorrectionReplacement() {
		XCTAssertEqual(
			AIPostProcessingInputNormalizer.normalized("meet me at 3pm, no sorry 4pm"),
			"meet me at 4pm"
		)
	}

	func testInputNormalizerFormatsSpokenOrderedItems() {
		let input = "The first thing is hello everyone. Second thing is hello, how are you? And third thing is how are you doing, mate."

		XCTAssertEqual(
			AIPostProcessingInputNormalizer.normalized(input),
			"1. hello everyone.\n2. hello, how are you?\n3. how are you doing, mate."
		)
	}

	func testInputNormalizerKeepsIntroductionBeforeSpokenItems() {
		let input = "hello, George. I'm telling you some things that you should take care of. The first thing is hello everyone. Second thing is hello, how are you? And third thing is how are you doing, mate."

		XCTAssertEqual(
			AIPostProcessingInputNormalizer.normalized(input),
			"hello, George. I'm telling you some things that you should take care of.\n1. hello everyone.\n2. hello, how are you?\n3. how are you doing, mate."
		)
	}

	func testInputNormalizerReplacesCorrectedSentence() {
		let input = "hello, how are you? I will meet you at four PM. No sorry, I will meet you at three PM."

		XCTAssertEqual(
			AIPostProcessingInputNormalizer.normalized(input),
			"hello, how are you? I will meet you at three PM."
		)
	}

	func testValidatorRenumbersExplicitOrderedLists() {
		let source = "give me a list of three things: first nice, second fair, fourth great"
		let output = "1. Nice\n2. Fair\n4. Great"

		XCTAssertEqual(
			AIPostProcessingOutputValidator.validated(output, sourceText: source),
			"1. Nice\n2. Fair\n3. Great"
		)
	}

	func testValidatorRecognizesOrdinalItemsWithoutTheWordList() {
		let source = "The first thing is hello everyone. Second thing is hello, how are you? Third thing is how are you doing, mate."
		let output = "1. hello everyone.\n2. hello, how are you?\n3. how are you doing, mate."

		XCTAssertEqual(
			AIPostProcessingOutputValidator.validated(output, sourceText: source),
			output
		)
	}

	func testValidatorRepairsNearVerbatimSpokenItems() {
		let source = "The first thing is hello everyone. Second thing is hello, how are you? Third thing is how are you doing, mate."

		XCTAssertEqual(
			AIPostProcessingOutputValidator.validated(source, sourceText: source),
			"1. hello everyone.\n2. hello, how are you?\n3. how are you doing, mate."
		)
	}

	func testValidatorUsesBulletsForUnorderedLists() {
		let source = "give me a list of three things: nice, fair, and great"
		let output = "1. Nice\n2. Fair\n3. Great"

		XCTAssertEqual(
			AIPostProcessingOutputValidator.validated(output, sourceText: source),
			"- Nice\n- Fair\n- Great"
		)
	}
}
