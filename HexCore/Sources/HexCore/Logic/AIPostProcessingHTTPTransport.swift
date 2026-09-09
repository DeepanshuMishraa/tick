import Foundation

/// Bounds the entire online formatter request, including a connection that
/// receives bytes but never completes. The local formatter remains the fallback.
public enum AIPostProcessingHTTPTransport {
    public static func data(
        for request: URLRequest,
        session: URLSession = .shared,
        deadline: TimeInterval = 1
    ) async throws -> (Data, URLResponse) {
        let operation = RequestOperation()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(request: request, session: session, deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            operation.finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return response
    }
}

/// URLSession and the deadline can complete concurrently. Only the first result
/// resumes the caller; cancellation does not wait for the transport's callback.
private final class RequestOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var task: URLSessionDataTask?
    private var timeout: DispatchWorkItem?

    func start(
        request: URLRequest,
        session: URLSession,
        deadline: TimeInterval,
        continuation: CheckedContinuation<(Data, URLResponse), Error>
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                self?.finish(.failure(error))
            } else if let data, let response {
                self?.finish(.success((data, response)))
            } else {
                self?.finish(.failure(URLError(.badServerResponse)))
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(URLError(.timedOut)))
        }
        self.task = task
        self.timeout = timeout
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, deadline), execute: timeout)
        task.resume()
        lock.unlock()
    }

    func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        let task = self.task
        let timeout = self.timeout
        self.continuation = nil
        self.task = nil
        self.timeout = nil
        lock.unlock()

        timeout?.cancel()
        task?.cancel()
        continuation?.resume(with: result)
    }
}
