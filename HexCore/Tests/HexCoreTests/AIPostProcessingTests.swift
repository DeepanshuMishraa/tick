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
		XCTAssertTrue(formal.contains("explicitly ordered sequence"))
		XCTAssertTrue(formal.contains("unordered list"))
	}

	func testAppAwarePromptKeepsApplicationContextAndStyle() {
		let context = AppContext(bundleID: "com.apple.Terminal", appName: "Terminal")
		let prompt = AIPostProcessingMode.appAware.systemPrompt(appContext: context, selectedStyleIndex: 1)

		XCTAssertTrue(prompt.contains("Terminal"))
		XCTAssertTrue(prompt.contains("raw shell command"))
		XCTAssertTrue(prompt.contains("SELECTED WRITING STYLE: CASUAL"))
	}

	func testValidatorRejectsUnsafeOrWrappedOutput() {
		XCTAssertNil(AIPostProcessingOutputValidator.validated(""))
		XCTAssertNil(AIPostProcessingOutputValidator.validated("EMPTY"))
		XCTAssertNil(AIPostProcessingOutputValidator.validated("<think>private reasoning</think>answer"))
		XCTAssertNil(AIPostProcessingOutputValidator.validated("Corrected text:\nhello"))
		XCTAssertNil(AIPostProcessingOutputValidator.validated("```bash\nls\n```"))
	}

	func testValidatorPreservesFormattedText() {
		let output = "1. First item\n2. Second item\n\nA new paragraph."
		XCTAssertEqual(AIPostProcessingOutputValidator.validated(output), output)
	}
}
