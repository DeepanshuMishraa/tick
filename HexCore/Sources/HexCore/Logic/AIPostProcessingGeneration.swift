import Foundation

/// Consumes a model's edit script and joins its producer before another segment
/// can use the model. A complete script must pass the normal output validator.
public enum AIPostProcessingGeneration {
    public static func validatedOutput<Events: AsyncSequence>(
        from events: Events,
        source: String,
        generationTask: Task<Void, Never>,
        text: (Events.Element) -> String?
    ) async throws -> String? {
        try await withTaskCancellationHandler {
            do {
                var script = ""
                var output: String?
                for try await event in events {
                    try Task.checkCancellation()
                    guard let chunk = text(event) else { continue }
                    script.append(chunk)
                    if let validated = AIPostProcessingEditScript.applying(script, to: source),
                       !validated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        output = validated
                        break
                    }
                }
                generationTask.cancel()
                await generationTask.value
                try Task.checkCancellation()
                return output
            } catch {
                generationTask.cancel()
                await generationTask.value
                throw error
            }
        } onCancel: {
            generationTask.cancel()
        }
    }
}
