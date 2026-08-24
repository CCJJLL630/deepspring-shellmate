import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum OpenAIHTTPMethod: String, Equatable, Sendable {
  case get = "GET"
  case post = "POST"
}

public struct OpenAIHTTPRequest: @unchecked Sendable {
  public let endpoint: OpenAIEndpoint
  public let url: URL
  public let method: OpenAIHTTPMethod
  public let headers: [String: String]
  public let body: Data?
  public let timeoutInterval: TimeInterval

  public init(
    endpoint: OpenAIEndpoint,
    url: URL,
    method: OpenAIHTTPMethod,
    headers: [String: String],
    body: Data?,
    timeoutInterval: TimeInterval
  ) {
    self.endpoint = endpoint
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
    self.timeoutInterval = timeoutInterval
  }
}

public struct OpenAIHTTPResponse: Equatable, Sendable {
  public let statusCode: Int
  public let data: Data

  public init(statusCode: Int, data: Data) {
    self.statusCode = statusCode
    self.data = data
  }
}

public enum OpenAIRawTransportError: Error, Equatable, Sendable {
  case nonHTTPResponse
}

public protocol OpenAITransport: Sendable {
  func send(_ request: OpenAIHTTPRequest) async throws -> OpenAIHTTPResponse
}

public final class URLSessionOpenAITransport: OpenAITransport, @unchecked Sendable {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func send(_ request: OpenAIHTTPRequest) async throws -> OpenAIHTTPResponse {
    try Task.checkCancellation()

    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method.rawValue
    urlRequest.allHTTPHeaderFields = request.headers
    urlRequest.httpBody = request.body
    urlRequest.timeoutInterval = request.timeoutInterval

    let taskBox = URLSessionTaskBox()
    let (data, response): (Data, URLResponse) = try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          let task = session.dataTask(with: urlRequest) { data, response, error in
            if let error {
              continuation.resume(throwing: error)
            } else if let data, let response {
              continuation.resume(returning: (data, response))
            } else {
              continuation.resume(throwing: OpenAIRawTransportError.nonHTTPResponse)
            }
          }
          taskBox.install(task)
          task.resume()
        }
      },
      onCancel: { taskBox.cancel() }
    )
    try Task.checkCancellation()

    guard let response = response as? HTTPURLResponse else {
      throw OpenAIRawTransportError.nonHTTPResponse
    }
    return OpenAIHTTPResponse(statusCode: response.statusCode, data: data)
  }
}

public protocol OpenAIPollingClock: Sendable {
  func now() -> TimeInterval
  func sleep(for interval: TimeInterval) async throws
}

public struct SystemOpenAIPollingClock: OpenAIPollingClock {
  public init() {}

  public func now() -> TimeInterval {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
  }

  public func sleep(for interval: TimeInterval) async throws {
    guard interval > 0 else {
      try Task.checkCancellation()
      return
    }
    let nanoseconds = UInt64(min(interval * 1_000_000_000, Double(UInt64.max)))
    try await Task.sleep(nanoseconds: nanoseconds)
  }
}

private final class URLSessionTaskBox: @unchecked Sendable {
  private let lock = NSLock()
  private var task: URLSessionTask?
  private var isCancelled = false

  func install(_ task: URLSessionTask) {
    lock.lock()
    self.task = task
    let shouldCancel = isCancelled
    lock.unlock()
    if shouldCancel { task.cancel() }
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let task = task
    lock.unlock()
    task?.cancel()
  }
}
