//
//  GPTAssistantManager.swift
//  ShellMate
//
//  Created by Daniel Delattre on 02/06/24.
//

import Foundation
import Sentry

class GPTAssistantManager {
  static let shared = GPTAssistantManager()

  var apiKey: String
  var assistantId: String
  var headers: [String: String]

  private let lifecycleClient: OpenAIAssistantClient

  init(
    transport: any OpenAITransport = URLSessionOpenAITransport(),
    clock: any OpenAIPollingClock = SystemOpenAIPollingClock(),
    configuration: OpenAIClientConfiguration = OpenAIClientConfiguration()
  ) {
    self.apiKey = retrieveOpenaiAPIKey()
    self.assistantId = ""
    self.headers = OpenAIAuthorization.headers(for: apiKey)
    self.lifecycleClient = OpenAIAssistantClient(
      transport: transport,
      clock: clock,
      configuration: configuration
    )
  }

  func setupAssistant() async -> Bool {
    self.apiKey = retrieveOpenaiAPIKey()
    self.headers = OpenAIAuthorization.headers(for: apiKey)

    let assistantCreator = GPTAssistantCreator(apiKey: apiKey)
    let assistantBaseName = "ShellMateSuggestCommands"
    let assistantCurrentVersion: String
    do {
      assistantCurrentVersion = try getAppVersionAndBuild()
    } catch {
      print("Error retrieving app version and build: \(error)")
      SentrySDK.capture(error: error)
      return false
    }
    let assistantInstructions = GPTAssistantInstructions.getInstructions()

    do {
      let assistantId = try await assistantCreator.getOrUpdateAssistant(
        assistantBaseName: assistantBaseName,
        assistantCurrentVersion: assistantCurrentVersion,
        assistantInstructions: assistantInstructions
      )
      print("Assistant ID: \(assistantId)")
      self.assistantId = assistantId
      return true
    } catch {
      // Do not persist or log provider errors: an upstream failure can echo submitted data.
      let safeError = NSError(
        domain: "GPTAssistantSetup", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Assistant setup failed"]
      )
      SentrySDK.capture(error: safeError)
      return false
    }
  }

  func createThread() async throws -> String {
    try await lifecycleClient.createThread(headers: headers)
  }

  func createMessage(threadId: String, messageContent: String) async throws -> String {
    try await lifecycleClient.createMessage(
      threadID: threadId,
      messageContent: messageContent,
      headers: headers
    )
  }

  func startRun(threadId: String) async throws -> String {
    try await lifecycleClient.createRun(
      threadID: threadId,
      assistantID: assistantId,
      headers: headers
    )
  }

  func pollRunStatusAsync(threadId: String, runId: String) async throws {
    try await lifecycleClient.pollRunStatus(
      threadID: threadId,
      runID: runId,
      headers: headers
    )
  }

  func fetchMessageResult(threadId: String) async throws -> [String: Any] {
    let result = try await lifecycleClient.fetchMessageResult(threadID: threadId, headers: headers)
    return result.mapValues(\.foundationValue)
  }

  func getMostRecentRun(threadId: String) async throws -> [String: Any]? {
    guard
      let run = try await lifecycleClient.getMostRecentRun(threadID: threadId, headers: headers)
    else {
      return nil
    }

    var result: [String: Any] = [
      "id": run.runID,
      "status": run.status.rawValue,
    ]
    if let lastError = run.lastError {
      result["last_error"] = lastError.foundationValue
    }
    if let incompleteDetails = run.incompleteDetails {
      result["incomplete_details"] = incompleteDetails.foundationValue
    }
    if let requiredAction = run.requiredAction {
      result["required_action"] = requiredAction.foundationValue
    }
    return result
  }

  func processMessageInThread(
    terminalID: String,
    messageContent: String,
    terminalStateID: UUID
  ) async throws -> [String: Any] {
    let threadId = try await GPTAssistantThreadIDManager.shared.getOrCreateThreadId(for: terminalID)
    guard !threadId.isEmpty else {
      throw OpenAILifecycleError.protocolFailure(
        OpenAIProtocolFailure(
          endpoint: .latestRun(threadID: threadId),
          description: "The thread ID is empty"
        ))
    }

    let outcome = try await lifecycleClient.processSuggestion(
      threadID: threadId,
      assistantID: assistantId,
      messageContent: messageContent,
      headers: headers,
      generationContext: OpenAIGenerationContext(
        terminalID: terminalID,
        stateID: terminalStateID
      ),
      generationState: SuggestionGenerationMonitor.shared
    )

    switch outcome {
    case .completed(let response):
      return response.mapValues(\.foundationValue)
    case .skippedActiveRun(let runID, let status):
      print(
        "There is already an active run \(runID) for thread \(threadId) with status "
          + "\(status.rawValue). Not proceeding with a new request."
      )
      MixpanelHelper.shared.trackEvent(
        name: "skippedNewRunDueToActiveRun",
        properties: ["status": status.rawValue, "threadId": threadId]
      )
      return [:]
    }
  }
}
