import Foundation

/// Thin wrapper around URLSession that turns non-2xx responses into errors.
public struct HTTPClient: Sendable {
    let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpAdditionalHeaders = ["User-Agent": AudibleClientInfo.userAgent]
            cfg.timeoutIntervalForRequest = 60
            self.session = URLSession(configuration: cfg)
        }
    }

    @discardableResult
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AudibleError.invalidResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AudibleError.http(http.statusCode, String(decoding: data.prefix(2000), as: UTF8.self))
        }
        return (data, http)
    }

    public func imageData(from url: URL) async -> Data? {
        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }
}

/// Streams a (large) file to disk and reports byte progress. Cancel via Task cancellation.
final class FileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64?) -> Void
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64?
    private var continuation: CheckedContinuation<Int64, Error>?
    private var task: URLSessionDataTask?
    private let lock = NSLock()
    private var buffer = Data()

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func download(
        _ request: URLRequest, to destination: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Int64 {
        let d = FileDownloader(destination: destination, progress: progress)
        return try await d.run(request)
    }

    private func run(_ request: URLRequest) async throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = destination.appendingPathExtension("part")
        fm.createFile(atPath: part.path, contents: nil)
        handle = try FileHandle(forWritingTo: part)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let size: Int64 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                continuation = cont
                let t = session.dataTask(with: request)
                task = t
                lock.unlock()
                if Task.isCancelled { t.cancel() } else { t.resume() }
            }
        } onCancel: {
            lock.lock()
            let t = task
            lock.unlock()
            t?.cancel()
        }

        try? fm.removeItem(at: destination)
        try fm.moveItem(at: part, to: destination)
        return size
    }

    private func finish(_ result: Result<Int64, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        flush()
        try? handle?.close()
        handle = nil
        if case .failure = result {
            try? FileManager.default.removeItem(at: destination.appendingPathExtension("part"))
        }
        cont?.resume(with: result)
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        try? handle?.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(.failure(AudibleError.http(http.statusCode, "")))
            return
        }
        expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        received += Int64(data.count)
        if buffer.count >= 1 << 20 { flush() }
        progress(received, expected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) } else { finish(.success(received)) }
    }
}
