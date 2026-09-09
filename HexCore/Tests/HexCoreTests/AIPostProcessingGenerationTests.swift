import XCTest
@testable import HexCore

final class AIPostProcessingGenerationTests: XCTestCase, @unchecked Sendable {
    func testValidScriptReturnsBeforeProducerFinishesAndJoinsCancellation() async throws {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let cancelled = expectation(description: "Model producer cancelled")
        let producer = Task {
            continuation.yield(#"{"edits":[]}"#)
            do {
                try await Task.sleep(for: .seconds(2))
                XCTFail("Generated unnecessary tokens after valid script")
            } catch { cancelled.fulfill() }
            continuation.finish()
        }
        let result = try await AIPostProcessingGeneration.validatedOutput(
            from: stream, source: "Keep every word.", generationTask: producer, text: { $0 }
        )
        XCTAssertEqual(result, "Keep every word.")
        await fulfillment(of: [cancelled], timeout: 0.1)
    }

    func testSplitUnicodeAndEscapedStringsAreValidatedOnlyWhenComplete() async throws {
        let script = #"{"edits":[{"old":"café","new":"café \"Central\""}]}"#
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let producer = Task {
            for character in script { continuation.yield(String(character)) }
            continuation.finish()
        }
        let result = try await AIPostProcessingGeneration.validatedOutput(
            from: stream, source: "Meet at the café today.", generationTask: producer, text: { $0 }
        )
        XCTAssertEqual(result, "Meet at the café \"Central\" today.")
    }

    func testInvalidBalancedScriptAndTruncatedScriptAreRejected() async throws {
        for script in [#"{"edits":[{"old":"unknown","new":"replacement"}]}"#, #"{"edits":["#] {
            let (stream, continuation) = AsyncStream<String>.makeStream()
            let producer = Task {
                continuation.yield(script)
                continuation.finish()
            }
            let result = try await AIPostProcessingGeneration.validatedOutput(
                from: stream, source: "Keep every word.", generationTask: producer, text: { $0 }
            )
            XCTAssertNil(result)
        }
    }

    func testCancellationStopsProducerWithoutReturningText() async {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let started = expectation(description: "Producer started")
        let stopped = expectation(description: "Producer stopped")
        let producer = Task {
            started.fulfill()
            do { try await Task.sleep(for: .seconds(10)) } catch { stopped.fulfill() }
            continuation.finish()
        }
        let consumer = Task {
            do {
                _ = try await AIPostProcessingGeneration.validatedOutput(
                    from: stream, source: "Keep every word.", generationTask: producer, text: { $0 }
                )
                XCTFail("Cancelled generation returned output")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await fulfillment(of: [started], timeout: 0.5)
        consumer.cancel()
        await consumer.value
        await fulfillment(of: [stopped], timeout: 0.5)
    }
}
