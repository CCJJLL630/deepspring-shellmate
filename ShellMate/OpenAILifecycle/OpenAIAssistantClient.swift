import Foundation

public struct OpenAIPollingPolicy: Equatable, Sendable {
  public let interval: TimeInterval
  public let overallTimeout: TimeInterval

  public init(interval: TimeInterval = 0.5, overallTimeout: TimeInterval = 60) {
    precondition(interval > 0, "The polling interval must be positive")
    precondition(overallTimeout > 0, "The polling deadline must be positive")
    self.interval = interval
    self.overallTimeout = overallTimeout
  }
}

public struct OpenAIClientConfiguration: Equatable, @unchecked Sendable {
  public let baseURL: URL
  public let requestTimeout: TimeInterval
  public let maximumErrorBodyLength: Int
  public let polling: OpenAIPollingPolicy

  public init(
    baseURL: URL = URL(string: "https://api.openai.com")!,
    requestTimeout: TimeInterval = 30,
    maximumErrorBodyLength: Int = 4_096,
    polling: OpenAIPollingPolicy = OpenAIPollingPolicy()
  ) {
    precondition(requestTimeout > 0, "The request timeout must be positive")
    precondition(maximumErrorBodyLength > 0, "The HTTP error body limit must be positive")
    self.baseURL = baseURL
    self.requestTimeout = requestTimeout
    self.maximumErrorBodyLength = maximumErrorBodyLength
    self.polling = polling
  }
}

public struct OpenAIAssistantClient: Sendable {
  private let transport: any OpenAITransport
  private let clock: any OpenAIPollingClock
  public let configuration: OpenAIClientConfiguration

  public init(
    transport: any OpenAITransport = URLSessionOpenAITransport(),
    clock: any OpenAIPollingClock = SystemOpenAIPollingClock(),
    configuration: OpenAIClientConfiguration = OpenAIClientConfiguration()
  ) {
    self.transport = transport
    self.clock = clock
    self.configuration = configuration
  }

  public func createThread(headers: [String: String]) async throws -> String {
    let endpoint = OpenAIEndpoint.createThread
    let data = try await request(
      endpoint: endpoint,
      method: .post,
      headers: headers,
      body: Data("{}".utf8)
    )
    return try identifier(from: data, endpoint: endpoint)
  }

  public func getMostRecentRun(
    threadID: String,
    headers: [String: String]
  ) async throws -> OpenAIRunSnapshot? {
    let endpoint = OpenAIEndpoint.latestRun(threadID: threadID)
    let data = try await request(endpoint: endpoint, method: .get, headers: headers)
    let object = try jsonObject(from: data, endpoint: endpoint)

    guard let rawRuns = object["data"] as? [Any] else {
      throw protocolFailure(endpoint, "The response is missing a valid 'data' array")
    }
    guard let rawRun = rawRuns.first else { return nil }
    guard let run = rawRun as? [String: Any] else {
      throw protocolFailure(endpoint, "The latest run is not a JSON object")
    }
    return try runSnapshot(from: run, endpoint: endpoint, requiredRunID: nil)
  }

  public func createMessage(
    threadID: String,
    messageContent: String,
    headers: [String: String]
  ) async throws -> String {
    let endpoint = OpenAIEndpoint.createMessage(threadID: threadID)
    let body = try jsonData(
      ["role": "user", "content": messageContent],
      endpoint: endpoint
    )
    let data = try await request(
      endpoint: endpoint,
      method: .post,
      headers: headers,
      body: body
    )
    return try identifier(from: data, endpoint: endpoint)
  }

  public func createRun(
    threadID: String,
    assistantID: String,
    headers: [String: String]
  ) async throws -> String {
    let endpoint = OpenAIEndpoint.createRun(threadID: threadID)
    guard !assistantID.isEmpty else {
      throw protocolFailure(endpoint, "The assistant ID is empty")
    }

    let payload: [String: Any] = [
      "assistant_id": assistantID,
      "truncation_strategy": [
        "type": "last_messages",
        "last_messages": 5,
      ],
    ]
    let body = try jsonData(payload, endpoint: endpoint)
    let data = try await request(
      endpoint: endpoint,
      method: .post,
      headers: headers,
      body: body
    )
    return try identifier(from: data, endpoint: endpoint)
  }

  public func pollRunStatus(
    threadID: String,
    runID: String,
    headers: [String: String]
  ) async throws {
    let endpoint = OpenAIEndpoint.runStatus(threadID: threadID, runID: runID)
    let deadline = clock.now() + configuration.polling.overallTimeout
    var lastObservedStatus: OpenAIRunStatus?

    while true {
      try Task.checkCancellation()
      try checkDeadline(deadline, runID: runID, lastObservedStatus: lastObservedStatus)

      let remaining = max(0.001, deadline - clock.now())
      let data: Data
      do {
        data = try await request(
          endpoint: endpoint,
          method: .get,
          headers: headers,
          timeoutOverride: min(configuration.requestTimeout, remaining)
        )
      } catch {
        if error is CancellationError || Task.isCancelled {
          throw CancellationError()
        }
        if clock.now() >= deadline {
          throw OpenAILifecycleError.pollingTimedOut(
            OpenAIPollingTimeoutFailure(
              runID: runID, lastObservedStatus: lastObservedStatus))
        }
        throw error
      }

      let object = try jsonObject(from: data, endpoint: endpoint)
      let status = try runStatus(from: object, endpoint: endpoint)
      lastObservedStatus = status
      try checkDeadline(deadline, runID: runID, lastObservedStatus: lastObservedStatus)

      switch status {
      case .completed:
        return

      case .failed, .cancelled, .expired, .incomplete:
        let terminalStatus: OpenAIRunTerminalStatus
        switch status {
        case .failed: terminalStatus = .failed
        case .cancelled: terminalStatus = .cancelled
        case .expired: terminalStatus = .expired
        case .incomplete: terminalStatus = .incomplete
        default: preconditionFailure("Only terminal failures reach this branch")
        }
        throw OpenAILifecycleError.terminalRun(
          OpenAITerminalRunFailure(
            runID: runID,
            status: terminalStatus,
            details: OpenAIRunFailureDetails(
              lastError: jsonValue(object["last_error"]),
              incompleteDetails: jsonValue(object["incomplete_details"])
            )
          ))

      case .requiresAction:
        throw OpenAILifecycleError.requiresAction(
          OpenAIRequiresActionFailure(
            runID: runID,
            requiredAction: jsonValue(object["required_action"])
          ))

      case .queued, .inProgress, .cancelling:
        let delay = min(configuration.polling.interval, deadline - clock.now())
        guard delay > 0 else {
          throw OpenAILifecycleError.pollingTimedOut(
            OpenAIPollingTimeoutFailure(
              runID: runID, lastObservedStatus: lastObservedStatus))
        }
        do {
          try await clock.sleep(for: delay)
          try Task.checkCancellation()
        } catch {
          if error is CancellationError || Task.isCancelled {
            throw CancellationError()
          }
          throw error
        }
      }
    }
  }

  public func fetchMessageResult(
    threadID: String,
    headers: [String: String]
  ) async throws -> [String: OpenAIJSONValue] {
    let endpoint = OpenAIEndpoint.fetchMessages(threadID: threadID)
    let data = try await request(endpoint: endpoint, method: .get, headers: headers)
    let object = try jsonObject(from: data, endpoint: endpoint)

    guard let messages = object["data"] as? [Any],
      let firstMessage = messages.first as? [String: Any],
      let contents = firstMessage["content"] as? [Any],
      let firstContent = contents.first as? [String: Any],
      let text = firstContent["text"] as? [String: Any],
      let value = text["value"] as? String
    else {
      throw protocolFailure(endpoint, "The response does not contain assistant message text")
    }

    let trimmedValue = value.replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let valueData = trimmedValue.data(using: .utf8) else {
      throw decodingFailure(endpoint, "The assistant message text is not valid UTF-8")
    }
    let valueObject = try jsonObject(from: valueData, endpoint: endpoint)

    var converted: [String: OpenAIJSONValue] = [:]
    converted.reserveCapacity(valueObject.count)
    for (key, rawValue) in valueObject {
      guard let value = OpenAIJSONValue(foundationValue: rawValue) else {
        throw protocolFailure(endpoint, "The assistant message contains an unsupported JSON value")
      }
      converted[key] = value
    }
    return converted
  }

  /// Processes a suggestion on an existing thread. An existing active run is skipped before the
  /// generation state is enabled. Once enabled, the exact terminal/state pair is disabled once on
  /// every return and throw path, including parent-task cancellation.
  public func processSuggestion(
    threadID: String,
    assistantID: String,
    messageContent: String,
    headers: [String: String],
    generationContext: OpenAIGenerationContext,
    generationState: any OpenAIGenerationStateManaging
  ) async throws -> OpenAISuggestionOutcome {
    try Task.checkCancellation()

    if let recentRun = try await getMostRecentRun(threadID: threadID, headers: headers) {
      switch recentRun.status {
      case .queued, .inProgress, .cancelling:
        return .skippedActiveRun(runID: recentRun.runID, status: recentRun.status)
      case .requiresAction:
        throw OpenAILifecycleError.requiresAction(
          OpenAIRequiresActionFailure(
            runID: recentRun.runID,
            requiredAction: recentRun.requiredAction
          ))
      case .completed, .failed, .cancelled, .expired, .incomplete:
        break
      }
    }

    try Task.checkCancellation()
    await generationState.setGenerating(generationContext, to: true)

    do {
      try Task.checkCancellation()
      _ = try await createMessage(
        threadID: threadID,
        messageContent: messageContent,
        headers: headers
      )
      let runID = try await createRun(
        threadID: threadID,
        assistantID: assistantID,
        headers: headers
      )
      try await pollRunStatus(threadID: threadID, runID: runID, headers: headers)
      let result = try await fetchMessageResult(threadID: threadID, headers: headers)
      try Task.checkCancellation()
      await generationState.setGenerating(generationContext, to: false)
      return .completed(result)
    } catch {
      await generationState.setGenerating(generationContext, to: false)
      if error is CancellationError || Task.isCancelled {
        throw CancellationError()
      }
      throw error
    }
  }

  private func request(
    endpoint: OpenAIEndpoint,
    method: OpenAIHTTPMethod,
    headers: [String: String],
    body: Data? = nil,
    timeoutOverride: TimeInterval? = nil
  ) async throws -> Data {
    try Task.checkCancellation()

    let request = OpenAIHTTPRequest(
      endpoint: endpoint,
      url: url(for: endpoint),
      method: method,
      headers: headers,
      body: body,
      timeoutInterval: timeoutOverride ?? configuration.requestTimeout
    )

    let response: OpenAIHTTPResponse
    do {
      response = try await transport.send(request)
    } catch {
      if error is CancellationError || Task.isCancelled {
        throw CancellationError()
      }
      if let rawError = error as? OpenAIRawTransportError,
        rawError == .nonHTTPResponse
      {
        throw protocolFailure(endpoint, "The transport returned a non-HTTP response")
      }
      if let lifecycleError = error as? OpenAILifecycleError {
        throw lifecycleError
      }
      throw OpenAILifecycleError.transport(
        OpenAITransportFailure(
          endpoint: endpoint,
          description: error.localizedDescription
        ))
    }

    try Task.checkCancellation()
    guard (200...299).contains(response.statusCode) else {
      let candidate = Data(response.data.prefix(configuration.maximumErrorBodyLength))
      let decoded = String(decoding: candidate, as: UTF8.self)
      let boundedBody = String(decoded.prefix(configuration.maximumErrorBodyLength))
      throw OpenAILifecycleError.http(
        OpenAIHTTPFailure(
          endpoint: endpoint,
          statusCode: response.statusCode,
          responseBody: boundedBody,
          bodyWasTruncated: response.data.count > candidate.count
            || decoded.count > boundedBody.count
        ))
    }
    return response.data
  }

  private func url(for endpoint: OpenAIEndpoint) -> URL {
    var url = configuration.baseURL

    func append(_ components: String...) {
      for component in components {
        url.appendPathComponent(component)
      }
    }

    switch endpoint {
    case .createThread:
      append("v1", "threads")
    case .latestRun(let threadID):
      append("v1", "threads", threadID, "runs")
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
      components.queryItems = [
        URLQueryItem(name: "limit", value: "1"),
        URLQueryItem(name: "order", value: "desc"),
      ]
      url = components.url!
    case .createMessage(let threadID), .fetchMessages(let threadID):
      append("v1", "threads", threadID, "messages")
    case .createRun(let threadID):
      append("v1", "threads", threadID, "runs")
    case .runStatus(let threadID, let runID):
      append("v1", "threads", threadID, "runs", runID)
    }
    return url
  }

  private func jsonData(_ object: Any, endpoint: OpenAIEndpoint) throws -> Data {
    do {
      return try JSONSerialization.data(withJSONObject: object)
    } catch {
      throw protocolFailure(endpoint, "Unable to encode the request: \(error.localizedDescription)")
    }
  }

  private func jsonObject(
    from data: Data,
    endpoint: OpenAIEndpoint
  ) throws -> [String: Any] {
    let rawObject: Any
    do {
      rawObject = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw decodingFailure(endpoint, error.localizedDescription)
    }
    guard let object = rawObject as? [String: Any] else {
      throw protocolFailure(endpoint, "The response root is not a JSON object")
    }
    return object
  }

  private func identifier(from data: Data, endpoint: OpenAIEndpoint) throws -> String {
    let object = try jsonObject(from: data, endpoint: endpoint)
    guard let identifier = object["id"] as? String, !identifier.isEmpty else {
      throw protocolFailure(endpoint, "The response is missing a valid 'id'")
    }
    return identifier
  }

  private func runSnapshot(
    from object: [String: Any],
    endpoint: OpenAIEndpoint,
    requiredRunID: String?
  ) throws -> OpenAIRunSnapshot {
    let runID: String
    if let requiredRunID {
      runID = requiredRunID
    } else {
      guard let identifier = object["id"] as? String, !identifier.isEmpty else {
        throw protocolFailure(endpoint, "The run is missing a valid 'id'")
      }
      runID = identifier
    }

    return OpenAIRunSnapshot(
      runID: runID,
      status: try runStatus(from: object, endpoint: endpoint),
      lastError: jsonValue(object["last_error"]),
      incompleteDetails: jsonValue(object["incomplete_details"]),
      requiredAction: jsonValue(object["required_action"])
    )
  }

  private func runStatus(
    from object: [String: Any],
    endpoint: OpenAIEndpoint
  ) throws -> OpenAIRunStatus {
    guard let rawStatus = object["status"] as? String, !rawStatus.isEmpty else {
      throw protocolFailure(endpoint, "The run has a missing or malformed 'status'")
    }
    guard let status = OpenAIRunStatus(rawValue: rawStatus) else {
      throw protocolFailure(endpoint, "The run has an unknown status '\(rawStatus)'")
    }
    return status
  }

  private func jsonValue(_ value: Any?) -> OpenAIJSONValue? {
    guard let value else { return nil }
    return OpenAIJSONValue(foundationValue: value)
  }

  private func checkDeadline(
    _ deadline: TimeInterval,
    runID: String,
    lastObservedStatus: OpenAIRunStatus?
  ) throws {
    guard clock.now() < deadline else {
      throw OpenAILifecycleError.pollingTimedOut(
        OpenAIPollingTimeoutFailure(
          runID: runID,
          lastObservedStatus: lastObservedStatus
        ))
    }
  }

  private func decodingFailure(
    _ endpoint: OpenAIEndpoint,
    _ description: String
  ) -> OpenAILifecycleError {
    .decoding(OpenAIDecodingFailure(endpoint: endpoint, description: description))
  }

  private func protocolFailure(
    _ endpoint: OpenAIEndpoint,
    _ description: String
  ) -> OpenAILifecycleError {
    .protocolFailure(OpenAIProtocolFailure(endpoint: endpoint, description: description))
  }
}
