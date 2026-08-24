import Foundation
import XCTest
@testable import OpenAILifecycle

final class OpenAILifecycleTests: XCTestCase {
  private let headers = ["Authorization": "Bearer test"]
  private let threadID = "thread-test"
  private let runID = "run-test"

  func testQueuedInProgressCompletedPollsThreeTimesFetchesOnceAndCleansUp() async throws {
    let transport = ScriptedTransport(
      steps: processPrefix() + [
        .json(.runStatus(threadID: threadID, runID: runID), 200, ["status": "queued"]),
        .json(
          .runStatus(threadID: threadID, runID: runID), 200, ["status": "in_progress"]),
        .json(.runStatus(threadID: threadID, runID: runID), 200, ["status": "completed"]),
        .response(.fetchMessages(threadID: threadID), 200, messageResponse()),
      ])
    let clock = AdvancingClock()
    let generation = GenerationStateSpy()
    let context = makeContext(1)
    let client = makeClient(transport: transport, clock: clock)

    let outcome = try await client.processSuggestion(
      threadID: threadID,
      assistantID: "assistant-test",
      messageContent: "suggest",
      headers: headers,
      generationContext: context,
      generationState: generation
    )

    guard case .completed(let result) = outcome else {
      return XCTFail("Expected a completed suggestion")
    }
    XCTAssertEqual(result["notEnoughInformation"], .bool(false))
    XCTAssertEqual(
      transport.count(.runStatus(threadID: threadID, runID: runID)),
      3
    )
    XCTAssertEqual(transport.count(.fetchMessages(threadID: threadID)), 1)
    XCTAssertEqual(clock.sleepCount(), 2)
    XCTAssertEqual(generation.transitions(for: context), [true, false])
    XCTAssertFalse(generation.isActive(context))
    try transport.assertExhausted()
  }

  func testCancellingPollsAgainThenReturnsTypedCancelledFailureAndCleansUp() async throws {
    let lastError: [String: Any] = ["code": "run_cancelled", "message": "cancelled by user"]
    let transport = ScriptedTransport(
      steps: processPrefix() + [
        .json(.runStatus(threadID: threadID, runID: runID), 200, ["status": "cancelling"]),
        .json(
          .runStatus(threadID: threadID, runID: runID), 200,
          ["status": "cancelled", "last_error": lastError]),
      ])
    let generation = GenerationStateSpy()
    let context = makeContext(2)
    let client = makeClient(transport: transport, clock: AdvancingClock())

    do {
      _ = try await process(client, generation: generation, context: context)
      XCTFail("Expected cancelled run failure")
    } catch let error as OpenAILifecycleError {
      guard case .terminalRun(let failure) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(failure.runID, runID)
      XCTAssertEqual(failure.status, .cancelled)
      XCTAssertEqual(
        failure.details.lastError,
        .object([
          "code": .string("run_cancelled"),
          "message": .string("cancelled by user"),
        ]))
    }

    XCTAssertEqual(
      transport.count(.runStatus(threadID: threadID, runID: runID)),
      2
    )
    XCTAssertEqual(transport.count(.fetchMessages(threadID: threadID)), 0)
    XCTAssertEqual(generation.transitions(for: context), [true, false])
    try transport.assertExhausted()
  }

  func testEveryTerminalRunStatusIsTypedAndPreservesFailureDetails() async throws {
    let cases: [(String, OpenAIRunTerminalStatus)] = [
      ("failed", .failed),
      ("cancelled", .cancelled),
      ("expired", .expired),
      ("incomplete", .incomplete),
    ]

    for (offset, testCase) in cases.enumerated() {
      let body: [String: Any] = [
        "status": testCase.0,
        "last_error": ["code": "code-\(offset)", "message": "detail-\(offset)"],
        "incomplete_details": ["reason": "reason-\(offset)"],
      ]
      let transport = ScriptedTransport(
        steps: processPrefix() + [
          .json(.runStatus(threadID: threadID, runID: runID), 200, body)
        ])
      let generation = GenerationStateSpy()
      let context = makeContext(10 + offset)
      let client = makeClient(transport: transport, clock: AdvancingClock())

      do {
        _ = try await process(client, generation: generation, context: context)
        XCTFail("Expected \(testCase.0) to fail")
      } catch let error as OpenAILifecycleError {
        guard case .terminalRun(let failure) = error else {
          XCTFail("Unexpected error for \(testCase.0): \(error)")
          continue
        }
        XCTAssertEqual(failure.runID, runID)
        XCTAssertEqual(failure.status, testCase.1)
        XCTAssertEqual(
          failure.details.lastError,
          .object([
            "code": .string("code-\(offset)"),
            "message": .string("detail-\(offset)"),
          ]))
        XCTAssertEqual(
          failure.details.incompleteDetails,
          .object(["reason": .string("reason-\(offset)")]))
      }

      XCTAssertEqual(generation.transitions(for: context), [true, false])
      try transport.assertExhausted()
    }
  }

  func testRequiresActionFailsImmediatelyWithDetails() async throws {
    let requiredAction: [String: Any] = [
      "type": "submit_tool_outputs",
      "submit_tool_outputs": ["tool_calls": []],
    ]
    let transport = ScriptedTransport(
      steps: processPrefix() + [
        .json(
          .runStatus(threadID: threadID, runID: runID), 200,
          ["status": "requires_action", "required_action": requiredAction])
      ])
    let generation = GenerationStateSpy()
    let context = makeContext(20)
    let client = makeClient(transport: transport, clock: AdvancingClock())

    do {
      _ = try await process(client, generation: generation, context: context)
      XCTFail("Expected requires_action to fail")
    } catch let error as OpenAILifecycleError {
      guard case .requiresAction(let failure) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(failure.runID, runID)
      XCTAssertEqual(
        failure.requiredAction,
        .object([
          "type": .string("submit_tool_outputs"),
          "submit_tool_outputs": .object(["tool_calls": .array([])]),
        ]))
    }

    XCTAssertEqual(
      transport.count(.runStatus(threadID: threadID, runID: runID)),
      1
    )
    XCTAssertEqual(transport.count(.fetchMessages(threadID: threadID)), 0)
    XCTAssertEqual(generation.transitions(for: context), [true, false])
    try transport.assertExhausted()
  }

  func testUnknownMissingAndMalformedStatusesAreProtocolFailures() async throws {
    let statusBodies: [[String: Any]] = [
      [:],
      ["status": NSNull()],
      ["status": 42],
      ["status": ""],
      ["status": "future_status"],
    ]

    for (offset, statusBody) in statusBodies.enumerated() {
      let endpoint = OpenAIEndpoint.runStatus(threadID: threadID, runID: runID)
      let transport = ScriptedTransport(
        steps: processPrefix() + [.json(endpoint, 200, statusBody)])
      let generation = GenerationStateSpy()
      let context = makeContext(30 + offset)
      let client = makeClient(transport: transport, clock: AdvancingClock())

      do {
        _ = try await process(client, generation: generation, context: context)
        XCTFail("Expected malformed status to fail")
      } catch let error as OpenAILifecycleError {
        guard case .protocolFailure(let failure) = error else {
          XCTFail("Unexpected error: \(error)")
          continue
        }
        XCTAssertEqual(failure.endpoint, endpoint)
        XCTAssertTrue(failure.description.contains("status"))
      }

      XCTAssertEqual(transport.count(endpoint), 1)
      XCTAssertEqual(generation.transitions(for: context), [true, false])
      try transport.assertExhausted()
    }
  }

  func testExistingRequiresActionFailsBeforeGenerationStarts() async throws {
    let endpoint = OpenAIEndpoint.latestRun(threadID: threadID)
    let transport = ScriptedTransport(
      steps: [
        .json(
          endpoint, 200,
          [
            "data": [
              [
                "id": "existing-run",
                "status": "requires_action",
                "required_action": ["type": "submit_tool_outputs"],
              ]
            ]
          ])
      ])
    let generation = GenerationStateSpy()
    let context = makeContext(40)
    let client = makeClient(transport: transport, clock: AdvancingClock())

    do {
      _ = try await process(client, generation: generation, context: context)
      XCTFail("Expected existing requires_action run to fail")
    } catch let error as OpenAILifecycleError {
      guard case .requiresAction(let failure) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(failure.runID, "existing-run")
      XCTAssertEqual(
        failure.requiredAction,
        .object(["type": .string("submit_tool_outputs")]))
    }

    XCTAssertEqual(generation.transitions(for: context), [])
    XCTAssertEqual(transport.requestCount(), 1)
    try transport.assertExhausted()
  }

  func testEachPermanentlyTransientStatusReachesDeterministicOverallDeadline() async throws {
    for (offset, status) in ["queued", "in_progress", "cancelling"].enumerated() {
      let statusEndpoint = OpenAIEndpoint.runStatus(threadID: threadID, runID: runID)
      let transport = ScriptedTransport(
        steps: processPrefix(),
        fallback: .json(statusEndpoint, 200, ["status": status])
      )
      let clock = AdvancingClock()
      let generation = GenerationStateSpy()
      let context = makeContext(50 + offset)
      let client = makeClient(
        transport: transport,
        clock: clock,
        polling: OpenAIPollingPolicy(interval: 0.25, overallTimeout: 1)
      )

      do {
        _ = try await process(client, generation: generation, context: context)
        XCTFail("Expected \(status) to time out")
      } catch let error as OpenAILifecycleError {
        guard case .pollingTimedOut(let failure) = error else {
          XCTFail("Unexpected error: \(error)")
          continue
        }
        XCTAssertEqual(failure.runID, runID)
        XCTAssertEqual(failure.lastObservedStatus?.rawValue, status)
      }

      XCTAssertEqual(clock.currentTime(), 1)
      XCTAssertEqual(clock.sleepCount(), 4)
      XCTAssertEqual(transport.count(statusEndpoint), 4)
      XCTAssertEqual(transport.count(.fetchMessages(threadID: threadID)), 0)
      XCTAssertEqual(generation.transitions(for: context), [true, false])
    }
  }

  func testCancellationDuringInflightPollingRequestStopsAllLaterRequests() async throws {
    let gate = SuspensionGate()
    let statusEndpoint = OpenAIEndpoint.runStatus(threadID: threadID, runID: runID)
    let transport = ScriptedTransport(
      steps: processPrefix() + [
        .suspendedResponse(
          statusEndpoint,
          gate,
          OpenAIHTTPResponse(statusCode: 200, data: jsonData(["status": "completed"])))
      ])
    let generation = GenerationStateSpy()
    let context = makeContext(60)
    let client = makeClient(transport: transport, clock: AdvancingClock())

    let task = Task {
      try await self.process(client, generation: generation, context: context)
    }
    await gate.waitUntilStarted()
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }

    XCTAssertEqual(transport.count(statusEndpoint), 1)
    XCTAssertEqual(transport.count(.fetchMessages(threadID: threadID)), 0)
    XCTAssertEqual(generation.transitions(for: context), [true, false])
    try transport.assertExhausted()
  }

  func testCancellationDuringPollingDelayStopsAllLaterRequests() async throws {
    let sleepGate = SuspensionGate()
    let clock = BlockingClock(gate: sleepGate)
    let statusEndpoint = OpenAIEndpoint.runStatus(threadID: threadID, runID: runID)
    let transport = ScriptedTransport(
      steps: processPrefix() + [
        .json(statusEndpoint, 200, ["status": "queued"]),
        .json(statusEndpoint, 200, ["status": "completed"]),
      ])
    let generation = GenerationStateSpy()
    let context = makeContext(61)
    let client = makeClient(transport: transport, clock: clock)

    let task = Task {
      try await self.process(client, generation: generation, context: context)
    }
    await sleepGate.waitUntilStarted()
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }

    XCTAssertEqual(transport.count(statusEndpoint), 1)
    XCTAssertEqual(transport.count(.fetchMessages(threadID: threadID)), 0)
    XCTAssertEqual(generation.transitions(for: context), [true, false])
    XCTAssertEqual(transport.remainingStepCount(), 1)
  }

  func testHTTPFailuresAtEveryLifecycleStagePreserveEndpointStatusAndBody() async throws {
    for statusCode in [401, 429, 500] {
      for (stageOffset, stage) in LifecycleStage.allCases.enumerated() {
        let body = "stage=\(stage.rawValue);status=\(statusCode)"
        let (transport, expectedEndpoint) = transportFailing(
          at: stage,
          statusCode: statusCode,
          body: Data(body.utf8)
        )
        let generation = GenerationStateSpy()
        let context = makeContext(100 + statusCode + stageOffset)
        let client = makeClient(transport: transport, clock: AdvancingClock())

        do {
          if stage == .threadCreation {
            _ = try await client.createThread(headers: headers)
          } else {
            _ = try await process(client, generation: generation, context: context)
          }
          XCTFail("Expected HTTP failure at \(stage)")
        } catch let error as OpenAILifecycleError {
          guard case .http(let failure) = error else {
            XCTFail("Unexpected error at \(stage): \(error)")
            continue
          }
          XCTAssertEqual(failure.endpoint, expectedEndpoint)
          XCTAssertEqual(failure.statusCode, statusCode)
          XCTAssertEqual(failure.responseBody, body)
          XCTAssertFalse(failure.bodyWasTruncated)
        }

        let expectedTransitions = stage.isPostStart ? [true, false] : []
        XCTAssertEqual(generation.transitions(for: context), expectedTransitions)
        XCTAssertEqual(transport.count(expectedEndpoint), 1)
        try transport.assertExhausted()
      }
    }
  }

  func testHTTPErrorBodyIsBoundedAndReportsTruncation() async throws {
    let endpoint = OpenAIEndpoint.createThread
    let transport = ScriptedTransport(
      steps: [.response(endpoint, 500, Data(String(repeating: "x", count: 1_000).utf8))])
    let client = makeClient(
      transport: transport,
      clock: AdvancingClock(),
      maximumErrorBodyLength: 32
    )

    do {
      _ = try await client.createThread(headers: headers)
      XCTFail("Expected HTTP failure")
    } catch let error as OpenAILifecycleError {
      guard case .http(let failure) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(failure.endpoint, endpoint)
      XCTAssertEqual(failure.statusCode, 500)
      XCTAssertEqual(failure.responseBody, String(repeating: "x", count: 32))
      XCTAssertTrue(failure.bodyWasTruncated)
    }
  }

  func testActiveRunLookupHTTPFailureIsNotTreatedAsNoActiveRun() async throws {
    let endpoint = OpenAIEndpoint.latestRun(threadID: threadID)
    let transport = ScriptedTransport(
      steps: [.response(endpoint, 429, Data("retry later".utf8))])
    let generation = GenerationStateSpy()
    let context = makeContext(70)
    let client = makeClient(transport: transport, clock: AdvancingClock())

    do {
      _ = try await process(client, generation: generation, context: context)
      XCTFail("Expected latest-run HTTP failure")
    } catch let error as OpenAILifecycleError {
      guard case .http(let failure) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(failure.endpoint, endpoint)
      XCTAssertEqual(failure.statusCode, 429)
    }

    XCTAssertEqual(transport.requestCount(), 1)
    XCTAssertEqual(transport.count(.createMessage(threadID: threadID)), 0)
    XCTAssertEqual(generation.transitions(for: context), [])
  }

  func testTransportDecodingAndProtocolFailuresRemainDistinct() async throws {
    let endpoint = OpenAIEndpoint.createThread

    let transportError = ScriptedTransport(
      steps: [.transportError(endpoint, "connection reset")])
    do {
      _ = try await makeClient(transport: transportError, clock: AdvancingClock())
        .createThread(headers: headers)
      XCTFail("Expected transport failure")
    } catch let error as OpenAILifecycleError {
      guard case .transport(let failure) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(failure.endpoint, endpoint)
      XCTAssertEqual(failure.description, "connection reset")
    }

    let malformedJSON = ScriptedTransport(
      steps: [.response(endpoint, 200, Data("{".utf8))])
    do {
      _ = try await makeClient(transport: malformedJSON, clock: AdvancingClock())
        .createThread(headers: headers)
      XCTFail("Expected decoding failure")
    } catch let error as OpenAILifecycleError {
      guard case .decoding(let failure) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(failure.endpoint, endpoint)
    }

    let invalidShape = ScriptedTransport(steps: [.json(endpoint, 200, ["not_id": "value"])])
    do {
      _ = try await makeClient(transport: invalidShape, clock: AdvancingClock())
        .createThread(headers: headers)
      XCTFail("Expected protocol failure")
    } catch let error as OpenAILifecycleError {
      guard case .protocolFailure(let failure) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(failure.endpoint, endpoint)
      XCTAssertTrue(failure.description.contains("id"))
    }
  }

  func testMalformedSuccessfulJSONAtEveryLifecycleStageIsTypedDecodingFailure() async throws {
    for (offset, stage) in LifecycleStage.allCases.enumerated() {
      let (transport, expectedEndpoint) = transportFailing(
        at: stage,
        statusCode: 200,
        body: Data("{".utf8)
      )
      let generation = GenerationStateSpy()
      let context = makeContext(200 + offset)
      let client = makeClient(transport: transport, clock: AdvancingClock())

      do {
        if stage == .threadCreation {
          _ = try await client.createThread(headers: headers)
        } else {
          _ = try await process(client, generation: generation, context: context)
        }
        XCTFail("Expected decoding failure at \(stage)")
      } catch let error as OpenAILifecycleError {
        guard case .decoding(let failure) = error else {
          XCTFail("Unexpected error at \(stage): \(error)")
          continue
        }
        XCTAssertEqual(failure.endpoint, expectedEndpoint)
      }

      XCTAssertEqual(
        generation.transitions(for: context),
        stage.isPostStart ? [true, false] : []
      )
      try transport.assertExhausted()
    }
  }

  func testOneTerminalsFailureCannotClearAnotherTerminalsGenerationState() async throws {
    let sharedGeneration = GenerationStateSpy()
    let contextA = makeContext(300, terminalID: "terminal-A")
    let contextB = makeContext(301, terminalID: "terminal-B")

    let bGate = SuspensionGate()
    let bStatusEndpoint = OpenAIEndpoint.runStatus(threadID: "thread-B", runID: "run-B")
    let bTransport = ScriptedTransport(
      steps: processPrefix(threadID: "thread-B", runID: "run-B") + [
        .suspendedResponse(
          bStatusEndpoint,
          bGate,
          OpenAIHTTPResponse(statusCode: 200, data: jsonData(["status": "completed"]))
        ),
        .response(.fetchMessages(threadID: "thread-B"), 200, messageResponse()),
      ])
    let bClient = makeClient(transport: bTransport, clock: AdvancingClock())
    let bTask = Task {
      try await bClient.processSuggestion(
        threadID: "thread-B",
        assistantID: "assistant-test",
        messageContent: "B",
        headers: self.headers,
        generationContext: contextB,
        generationState: sharedGeneration
      )
    }
    await bGate.waitUntilStarted()
    XCTAssertTrue(sharedGeneration.isActive(contextB))

    let aStatusEndpoint = OpenAIEndpoint.runStatus(threadID: "thread-A", runID: "run-A")
    let aTransport = ScriptedTransport(
      steps: processPrefix(threadID: "thread-A", runID: "run-A") + [
        .json(aStatusEndpoint, 200, ["status": "failed"])
      ])
    let aClient = makeClient(transport: aTransport, clock: AdvancingClock())
    do {
      _ = try await aClient.processSuggestion(
        threadID: "thread-A",
        assistantID: "assistant-test",
        messageContent: "A",
        headers: headers,
        generationContext: contextA,
        generationState: sharedGeneration
      )
      XCTFail("Expected terminal A to fail")
    } catch let error as OpenAILifecycleError {
      guard case .terminalRun = error else {
        return XCTFail("Unexpected terminal A error: \(error)")
      }
    }

    XCTAssertEqual(sharedGeneration.transitions(for: contextA), [true, false])
    XCTAssertFalse(sharedGeneration.isActive(contextA))
    XCTAssertEqual(sharedGeneration.transitions(for: contextB), [true])
    XCTAssertTrue(sharedGeneration.isActive(contextB))

    bGate.release()
    guard case .completed = try await bTask.value else {
      return XCTFail("Expected terminal B to complete")
    }
    XCTAssertEqual(sharedGeneration.transitions(for: contextB), [true, false])
    XCTAssertFalse(sharedGeneration.isActive(contextB))
  }

  // MARK: - Helpers

  private func process(
    _ client: OpenAIAssistantClient,
    generation: GenerationStateSpy,
    context: OpenAIGenerationContext
  ) async throws -> OpenAISuggestionOutcome {
    try await client.processSuggestion(
      threadID: threadID,
      assistantID: "assistant-test",
      messageContent: "suggest",
      headers: headers,
      generationContext: context,
      generationState: generation
    )
  }

  private func makeClient(
    transport: any OpenAITransport,
    clock: any OpenAIPollingClock,
    polling: OpenAIPollingPolicy = OpenAIPollingPolicy(interval: 0.5, overallTimeout: 10),
    maximumErrorBodyLength: Int = 4_096
  ) -> OpenAIAssistantClient {
    OpenAIAssistantClient(
      transport: transport,
      clock: clock,
      configuration: OpenAIClientConfiguration(
        requestTimeout: 5,
        maximumErrorBodyLength: maximumErrorBodyLength,
        polling: polling
      )
    )
  }

  private func processPrefix(
    threadID: String? = nil,
    runID: String? = nil
  ) -> [ScriptedTransport.Step] {
    let threadID = threadID ?? self.threadID
    let runID = runID ?? self.runID
    return [
      .json(.latestRun(threadID: threadID), 200, ["data": []]),
      .json(.createMessage(threadID: threadID), 200, ["id": "message-test"]),
      .json(.createRun(threadID: threadID), 200, ["id": runID]),
    ]
  }

  private func messageResponse() -> Data {
    Self.messageResponse()
  }

  private static func messageResponse() -> Data {
    let value = String(
      data: jsonData([
        "suggestions": [],
        "notEnoughInformation": false,
      ]),
      encoding: .utf8
    )!
    return jsonData([
      "data": [
        ["content": [["text": ["value": value]]]]
      ]
    ])
  }

  private func makeContext(
    _ seed: Int,
    terminalID: String = "terminal-test"
  ) -> OpenAIGenerationContext {
    let suffix = String(format: "%012x", seed)
    return OpenAIGenerationContext(
      terminalID: terminalID,
      stateID: UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    )
  }

  private func transportFailing(
    at stage: LifecycleStage,
    statusCode: Int,
    body: Data
  ) -> (ScriptedTransport, OpenAIEndpoint) {
    let failureStep: (OpenAIEndpoint) -> ScriptedTransport.Step = {
      .response($0, statusCode, body)
    }

    switch stage {
    case .threadCreation:
      let endpoint = OpenAIEndpoint.createThread
      return (ScriptedTransport(steps: [failureStep(endpoint)]), endpoint)
    case .latestRun:
      let endpoint = OpenAIEndpoint.latestRun(threadID: threadID)
      return (ScriptedTransport(steps: [failureStep(endpoint)]), endpoint)
    case .messageCreation:
      let endpoint = OpenAIEndpoint.createMessage(threadID: threadID)
      return (
        ScriptedTransport(steps: Array(processPrefix().prefix(1)) + [failureStep(endpoint)]),
        endpoint
      )
    case .runCreation:
      let endpoint = OpenAIEndpoint.createRun(threadID: threadID)
      return (
        ScriptedTransport(steps: Array(processPrefix().prefix(2)) + [failureStep(endpoint)]),
        endpoint
      )
    case .polling:
      let endpoint = OpenAIEndpoint.runStatus(threadID: threadID, runID: runID)
      return (ScriptedTransport(steps: processPrefix() + [failureStep(endpoint)]), endpoint)
    case .messageFetching:
      let endpoint = OpenAIEndpoint.fetchMessages(threadID: threadID)
      return (
        ScriptedTransport(
          steps: processPrefix() + [
            .json(
              .runStatus(threadID: threadID, runID: runID), 200,
              ["status": "completed"]),
            failureStep(endpoint),
          ]),
        endpoint
      )
    }
  }

  private enum LifecycleStage: String, CaseIterable {
    case threadCreation
    case latestRun
    case messageCreation
    case runCreation
    case polling
    case messageFetching

    var isPostStart: Bool {
      switch self {
      case .messageCreation, .runCreation, .polling, .messageFetching:
        return true
      case .threadCreation, .latestRun:
        return false
      }
    }
  }
}

private final class ScriptedTransport: OpenAITransport, @unchecked Sendable {
  enum Step {
    case response(OpenAIEndpoint, Int, Data)
    case transportError(OpenAIEndpoint, String)
    case suspendedResponse(OpenAIEndpoint, SuspensionGate, OpenAIHTTPResponse)

    static func json(
      _ endpoint: OpenAIEndpoint,
      _ statusCode: Int,
      _ object: Any
    ) -> Step {
      .response(endpoint, statusCode, jsonData(object))
    }

    var endpoint: OpenAIEndpoint {
      switch self {
      case .response(let endpoint, _, _),
        .transportError(let endpoint, _),
        .suspendedResponse(let endpoint, _, _):
        return endpoint
      }
    }
  }

  private let lock = NSLock()
  private var steps: [Step]
  private let fallback: Step?
  private var requests: [OpenAIEndpoint] = []

  init(steps: [Step], fallback: Step? = nil) {
    self.steps = steps
    self.fallback = fallback
  }

  func send(_ request: OpenAIHTTPRequest) async throws -> OpenAIHTTPResponse {
    let step: Step
    lock.lock()
    requests.append(request.endpoint)
    if !steps.isEmpty {
      step = steps.removeFirst()
    } else if let fallback {
      step = fallback
    } else {
      lock.unlock()
      throw PlannedTransportFailure("Unexpected request to \(request.endpoint.path)")
    }
    lock.unlock()

    guard step.endpoint == request.endpoint else {
      throw PlannedTransportFailure(
        "Expected \(step.endpoint.path), received \(request.endpoint.path)")
    }

    switch step {
    case .response(_, let statusCode, let data):
      return OpenAIHTTPResponse(statusCode: statusCode, data: data)
    case .transportError(_, let message):
      throw PlannedTransportFailure(message)
    case .suspendedResponse(_, let gate, let response):
      try await gate.wait()
      return response
    }
  }

  func count(_ endpoint: OpenAIEndpoint) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return requests.filter { $0 == endpoint }.count
  }

  func requestCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return requests.count
  }

  func remainingStepCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return steps.count
  }

  func assertExhausted() throws {
    lock.lock()
    defer { lock.unlock() }
    guard steps.isEmpty else {
      throw PlannedTransportFailure("\(steps.count) scripted requests were not made")
    }
  }
}

private struct PlannedTransportFailure: LocalizedError, Sendable {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}

private final class GenerationStateSpy: OpenAIGenerationStateManaging, @unchecked Sendable {
  private let lock = NSLock()
  private var events: [OpenAIGenerationContext: [Bool]] = [:]
  private var active: Set<OpenAIGenerationContext> = []

  func setGenerating(_ context: OpenAIGenerationContext, to isGenerating: Bool) async {
    lock.lock()
    events[context, default: []].append(isGenerating)
    if isGenerating {
      active.insert(context)
    } else {
      active.remove(context)
    }
    lock.unlock()
  }

  func transitions(for context: OpenAIGenerationContext) -> [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return events[context] ?? []
  }

  func isActive(_ context: OpenAIGenerationContext) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return active.contains(context)
  }
}

private final class AdvancingClock: OpenAIPollingClock, @unchecked Sendable {
  private let lock = NSLock()
  private var time: TimeInterval = 0
  private var sleeps = 0

  func now() -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return time
  }

  func sleep(for interval: TimeInterval) async throws {
    try Task.checkCancellation()
    lock.lock()
    time += interval
    sleeps += 1
    lock.unlock()
    try Task.checkCancellation()
  }

  func currentTime() -> TimeInterval { now() }

  func sleepCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return sleeps
  }
}

private final class BlockingClock: OpenAIPollingClock, @unchecked Sendable {
  private let gate: SuspensionGate

  init(gate: SuspensionGate) {
    self.gate = gate
  }

  func now() -> TimeInterval { 0 }

  func sleep(for interval: TimeInterval) async throws {
    try await gate.wait()
  }
}

private final class SuspensionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var started = false
  private var finished = false
  private var cancelled = false

  func wait() async throws {
    try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          lock.lock()
          started = true
          let waiters = startWaiters
          startWaiters.removeAll()

          let shouldCancel = cancelled
          let shouldFinish = finished
          if !shouldCancel && !shouldFinish {
            self.continuation = continuation
          }
          lock.unlock()

          waiters.forEach { $0.resume() }
          if shouldCancel {
            continuation.resume(throwing: CancellationError())
          } else if shouldFinish {
            continuation.resume()
          }
        }
      },
      onCancel: { [weak self] in self?.cancel() }
    )
  }

  func waitUntilStarted() async {
    await withCheckedContinuation { waiter in
      lock.lock()
      if started {
        lock.unlock()
        waiter.resume()
      } else {
        startWaiters.append(waiter)
        lock.unlock()
      }
    }
  }

  func release() {
    let continuation: CheckedContinuation<Void, Error>?
    lock.lock()
    guard !finished && !cancelled else {
      lock.unlock()
      return
    }
    finished = true
    continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume()
  }

  private func cancel() {
    let continuation: CheckedContinuation<Void, Error>?
    lock.lock()
    guard !finished && !cancelled else {
      lock.unlock()
      return
    }
    cancelled = true
    continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(throwing: CancellationError())
  }
}

private func jsonData(_ object: Any) -> Data {
  try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
