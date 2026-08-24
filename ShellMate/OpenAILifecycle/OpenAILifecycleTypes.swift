import Foundation

public enum OpenAIEndpoint: Equatable, Hashable, Sendable {
  case createThread
  case latestRun(threadID: String)
  case createMessage(threadID: String)
  case createRun(threadID: String)
  case runStatus(threadID: String, runID: String)
  case fetchMessages(threadID: String)

  public var path: String {
    switch self {
    case .createThread:
      return "/v1/threads"
    case .latestRun(let threadID):
      return "/v1/threads/\(threadID)/runs?limit=1&order=desc"
    case .createMessage(let threadID):
      return "/v1/threads/\(threadID)/messages"
    case .createRun(let threadID):
      return "/v1/threads/\(threadID)/runs"
    case .runStatus(let threadID, let runID):
      return "/v1/threads/\(threadID)/runs/\(runID)"
    case .fetchMessages(let threadID):
      return "/v1/threads/\(threadID)/messages"
    }
  }
}

extension OpenAIEndpoint: CustomStringConvertible {
  public var description: String { path }
}

public enum OpenAIJSONValue: Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: OpenAIJSONValue])
  case array([OpenAIJSONValue])
  case null

  init?(foundationValue value: Any) {
    switch value {
    case let value as String:
      self = .string(value)
    case let value as NSNumber:
      // JSONSerialization represents booleans as NSNumbers whose Objective-C type is `c`.
      if String(cString: value.objCType) == "c" {
        self = .bool(value.boolValue)
      } else {
        self = .number(value.doubleValue)
      }
    case let value as [String: Any]:
      var converted: [String: OpenAIJSONValue] = [:]
      for (key, nestedValue) in value {
        guard let nestedValue = OpenAIJSONValue(foundationValue: nestedValue) else { return nil }
        converted[key] = nestedValue
      }
      self = .object(converted)
    case let value as [Any]:
      var converted: [OpenAIJSONValue] = []
      converted.reserveCapacity(value.count)
      for nestedValue in value {
        guard let nestedValue = OpenAIJSONValue(foundationValue: nestedValue) else { return nil }
        converted.append(nestedValue)
      }
      self = .array(converted)
    case _ as NSNull:
      self = .null
    default:
      return nil
    }
  }

  public var foundationValue: Any {
    switch self {
    case .string(let value):
      return value
    case .number(let value):
      return value
    case .bool(let value):
      return value
    case .object(let value):
      return value.mapValues(\.foundationValue)
    case .array(let value):
      return value.map(\.foundationValue)
    case .null:
      return NSNull()
    }
  }
}

public enum OpenAIRunStatus: String, Equatable, Sendable {
  case queued
  case inProgress = "in_progress"
  case cancelling
  case completed
  case failed
  case cancelled
  case expired
  case incomplete
  case requiresAction = "requires_action"

  public var isTransient: Bool {
    switch self {
    case .queued, .inProgress, .cancelling:
      return true
    default:
      return false
    }
  }
}

public enum OpenAIRunTerminalStatus: String, Equatable, Sendable {
  case failed
  case cancelled
  case expired
  case incomplete
}

public struct OpenAIRunFailureDetails: Equatable, Sendable {
  public let lastError: OpenAIJSONValue?
  public let incompleteDetails: OpenAIJSONValue?

  public init(lastError: OpenAIJSONValue?, incompleteDetails: OpenAIJSONValue?) {
    self.lastError = lastError
    self.incompleteDetails = incompleteDetails
  }
}

public struct OpenAITerminalRunFailure: Equatable, Sendable {
  public let runID: String
  public let status: OpenAIRunTerminalStatus
  public let details: OpenAIRunFailureDetails

  public init(runID: String, status: OpenAIRunTerminalStatus, details: OpenAIRunFailureDetails) {
    self.runID = runID
    self.status = status
    self.details = details
  }
}

public struct OpenAIRequiresActionFailure: Equatable, Sendable {
  public let runID: String
  public let requiredAction: OpenAIJSONValue?

  public init(runID: String, requiredAction: OpenAIJSONValue?) {
    self.runID = runID
    self.requiredAction = requiredAction
  }
}

public struct OpenAIPollingTimeoutFailure: Equatable, Sendable {
  public let runID: String
  public let lastObservedStatus: OpenAIRunStatus?

  public init(runID: String, lastObservedStatus: OpenAIRunStatus?) {
    self.runID = runID
    self.lastObservedStatus = lastObservedStatus
  }
}

public struct OpenAIHTTPFailure: Equatable, Sendable {
  public let endpoint: OpenAIEndpoint
  public let statusCode: Int
  public let responseBody: String
  public let bodyWasTruncated: Bool

  public init(
    endpoint: OpenAIEndpoint,
    statusCode: Int,
    responseBody: String,
    bodyWasTruncated: Bool
  ) {
    self.endpoint = endpoint
    self.statusCode = statusCode
    self.responseBody = responseBody
    self.bodyWasTruncated = bodyWasTruncated
  }
}

public struct OpenAITransportFailure: Equatable, Sendable {
  public let endpoint: OpenAIEndpoint
  public let description: String

  public init(endpoint: OpenAIEndpoint, description: String) {
    self.endpoint = endpoint
    self.description = description
  }
}

public struct OpenAIDecodingFailure: Equatable, Sendable {
  public let endpoint: OpenAIEndpoint
  public let description: String

  public init(endpoint: OpenAIEndpoint, description: String) {
    self.endpoint = endpoint
    self.description = description
  }
}

public struct OpenAIProtocolFailure: Equatable, Sendable {
  public let endpoint: OpenAIEndpoint
  public let description: String

  public init(endpoint: OpenAIEndpoint, description: String) {
    self.endpoint = endpoint
    self.description = description
  }
}

public enum OpenAILifecycleError: Error, Equatable, Sendable {
  case http(OpenAIHTTPFailure)
  case transport(OpenAITransportFailure)
  case decoding(OpenAIDecodingFailure)
  case protocolFailure(OpenAIProtocolFailure)
  case terminalRun(OpenAITerminalRunFailure)
  case requiresAction(OpenAIRequiresActionFailure)
  case pollingTimedOut(OpenAIPollingTimeoutFailure)
}

extension OpenAILifecycleError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .http(let failure):
      return "OpenAI HTTP \(failure.statusCode) at \(failure.endpoint.path): \(failure.responseBody)"
    case .transport(let failure):
      return "OpenAI transport failure at \(failure.endpoint.path): \(failure.description)"
    case .decoding(let failure):
      return "OpenAI decoding failure at \(failure.endpoint.path): \(failure.description)"
    case .protocolFailure(let failure):
      return "OpenAI protocol failure at \(failure.endpoint.path): \(failure.description)"
    case .terminalRun(let failure):
      return "OpenAI run \(failure.runID) ended with status \(failure.status.rawValue)"
    case .requiresAction(let failure):
      return "OpenAI run \(failure.runID) requires unsupported action"
    case .pollingTimedOut(let failure):
      let status = failure.lastObservedStatus?.rawValue ?? "none"
      return "OpenAI run \(failure.runID) timed out; last status: \(status)"
    }
  }
}

public struct OpenAIRunSnapshot: Equatable, Sendable {
  public let runID: String
  public let status: OpenAIRunStatus
  public let lastError: OpenAIJSONValue?
  public let incompleteDetails: OpenAIJSONValue?
  public let requiredAction: OpenAIJSONValue?

  public init(
    runID: String,
    status: OpenAIRunStatus,
    lastError: OpenAIJSONValue? = nil,
    incompleteDetails: OpenAIJSONValue? = nil,
    requiredAction: OpenAIJSONValue? = nil
  ) {
    self.runID = runID
    self.status = status
    self.lastError = lastError
    self.incompleteDetails = incompleteDetails
    self.requiredAction = requiredAction
  }
}

public struct OpenAIGenerationContext: Equatable, Hashable, Sendable {
  public let terminalID: String
  public let stateID: UUID

  public init(terminalID: String, stateID: UUID) {
    self.terminalID = terminalID
    self.stateID = stateID
  }
}

public protocol OpenAIGenerationStateManaging: Sendable {
  func setGenerating(_ context: OpenAIGenerationContext, to isGenerating: Bool) async
}

public enum OpenAISuggestionOutcome: Equatable, Sendable {
  case completed([String: OpenAIJSONValue])
  case skippedActiveRun(runID: String, status: OpenAIRunStatus)
}
