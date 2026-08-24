import Foundation
import XCTest
@testable import SuggestionLookup

final class SuggestionLookupTests: XCTestCase {
  private struct ReferenceKey: Hashable {
    let terminalID: String
    let address: SuggestionAddress
  }

  private struct Event {
    let terminalID: String
    let stateID: UUID
    let command: String?
  }

  private struct ReferenceHistoryModel {
    private struct Batch {
      let stateID: UUID
      var commands: [String?]
    }

    private var histories: [String: [Batch]] = [:]

    mutating func append(_ event: Event) -> SuggestionAddress {
      var history = histories[event.terminalID] ?? []
      let batchOffset: Int
      if let existingOffset = history.firstIndex(where: { $0.stateID == event.stateID }) {
        batchOffset = existingOffset
        history[existingOffset].commands.append(event.command)
      } else {
        batchOffset = history.count
        history.append(Batch(stateID: event.stateID, commands: [event.command]))
      }
      histories[event.terminalID] = history
      return SuggestionAddress(
        batchIndex: batchOffset + 1,
        suggestionIndex: history[batchOffset].commands.count)
    }

    func command(for terminalID: String, at address: SuggestionAddress) -> String? {
      guard let history = histories[terminalID], address.batchIndex <= history.count else {
        return nil
      }
      let commands = history[address.batchIndex - 1].commands
      guard address.suggestionIndex <= commands.count else { return nil }
      return commands[address.suggestionIndex - 1]
    }

    var keysAndCommands: [ReferenceKey: String] {
      var result: [ReferenceKey: String] = [:]
      for (terminalID, history) in histories {
        for (batchOffset, batch) in history.enumerated() {
          for (suggestionOffset, command) in batch.commands.enumerated() {
            if let command = command {
              let address = SuggestionAddress(
                batchIndex: batchOffset + 1, suggestionIndex: suggestionOffset + 1)
              result[ReferenceKey(terminalID: terminalID, address: address)] = command
            }
          }
        }
      }
      return result
    }
  }

  private final class SelectionSideEffectSpy {
    var clipboardWrites: [String] = []
    var pasteCount = 0
    var successCount = 0

    func makeHandler(index: SuggestionCommandLookingUp) -> SuggestionSelectionHandler {
      return SuggestionSelectionHandler(
        commandIndex: index,
        writeClipboard: { [weak self] in self?.clipboardWrites.append($0) },
        paste: { [weak self] in self?.pasteCount += 1 },
        didSelect: { [weak self] in self?.successCount += 1 })
    }
  }

  private final class FormerHistoryExporterReference {
    private var commands: [String] = []
    private(set) var exportCount = 0
    private(set) var cumulativeEntryVisits = 0

    func appendAndExport(_ command: String) {
      commands.append(command)
      exportCount += 1
      for _ in commands {
        cumulativeEntryVisits += 1
      }
    }
  }

  func testMappingsMatchHistoryReferenceIncludingProTipOnlyBatches() {
    let terminalAStates = (1...4).map { uuid($0) }
    let terminalBStates = (101...103).map { uuid($0) }
    let events = [
      Event(terminalID: "terminal-A", stateID: terminalAStates[0], command: nil),
      Event(terminalID: "terminal-A", stateID: terminalAStates[1], command: "a-2.1"),
      Event(terminalID: "terminal-A", stateID: terminalAStates[1], command: "a-2.2"),
      Event(terminalID: "terminal-B", stateID: terminalBStates[0], command: "b-1.1"),
      Event(terminalID: "terminal-A", stateID: terminalAStates[2], command: nil),
      Event(terminalID: "terminal-B", stateID: terminalBStates[1], command: nil),
      Event(terminalID: "terminal-A", stateID: terminalAStates[1], command: "a-2.3"),
      Event(terminalID: "terminal-B", stateID: terminalBStates[2], command: "b-3.1"),
      Event(terminalID: "terminal-B", stateID: terminalBStates[2], command: "b-3.2"),
      Event(terminalID: "terminal-B", stateID: terminalBStates[2], command: "b-3.3"),
      Event(terminalID: "terminal-A", stateID: terminalAStates[3], command: "a-4.1"),
    ]

    var reference = ReferenceHistoryModel()
    let tracker = SuggestionAddressTracker()
    let index = SuggestionCommandIndex()

    for event in events {
      let referenceAddress = reference.append(event)
      let optimizedAddress = tracker.addressForNextEntry(
        terminalID: event.terminalID, stateID: event.stateID)
      XCTAssertEqual(optimizedAddress, referenceAddress)
      if let command = event.command {
        index.register(command: command, for: event.terminalID, at: optimizedAddress)
      }
    }

    for (key, command) in reference.keysAndCommands {
      XCTAssertEqual(reference.command(for: key.terminalID, at: key.address), command as String?)
      XCTAssertEqual(
        index.command(for: key.terminalID, at: key.address),
        reference.command(for: key.terminalID, at: key.address))
    }

    XCTAssertNil(
      index.command(
        for: "terminal-A", at: SuggestionAddress(batchIndex: 1, suggestionIndex: 1)))
    XCTAssertNil(
      index.command(
        for: "terminal-A", at: SuggestionAddress(batchIndex: 3, suggestionIndex: 1)))
    XCTAssertNil(
      index.command(
        for: "terminal-B", at: SuggestionAddress(batchIndex: 2, suggestionIndex: 1)))
    XCTAssertEqual(
      index.operationCounts.registrations,
      reference.keysAndCommands.count)
  }

  func testIntegerDecimalMalformedMissingUnknownAndStaleSelections() {
    let index = SuggestionCommandIndex()
    index.register(
      command: "a-first", for: "terminal-A",
      at: SuggestionAddress(batchIndex: 2, suggestionIndex: 1))
    index.register(
      command: "a-third", for: "terminal-A",
      at: SuggestionAddress(batchIndex: 2, suggestionIndex: 3))
    index.register(
      command: "b-third", for: "terminal-B",
      at: SuggestionAddress(batchIndex: 2, suggestionIndex: 3))

    let spy = SelectionSideEffectSpy()
    let handler = spy.makeHandler(index: index)

    XCTAssertTrue(
      handler.select(SuggestionSelectionRequest(selectionIndex: "2", terminalID: "terminal-A")))
    XCTAssertEqual(spy.clipboardWrites, ["a-first"])
    XCTAssertEqual(spy.pasteCount, 1)
    XCTAssertEqual(spy.successCount, 1)

    XCTAssertTrue(
      handler.select(
        SuggestionSelectionRequest(selectionIndex: "2.3", terminalID: "terminal-A")))
    XCTAssertTrue(
      handler.select(
        SuggestionSelectionRequest(selectionIndex: "2.3", terminalID: "terminal-B")))
    XCTAssertEqual(spy.clipboardWrites, ["a-first", "a-third", "b-third"])
    XCTAssertEqual(spy.pasteCount, 3)
    XCTAssertEqual(spy.successCount, 3)

    let lookupsAfterSuccess = index.operationCounts.lookups
    let malformedIndices: [String?] = [
      nil, "", " 2", "2 ", ".2", "2.", "2.3.1", "-2", "0", "2.0", "02.3", "2.03",
      "2.30", "two",
    ]
    for malformedIndex in malformedIndices {
      XCTAssertFalse(
        handler.select(
          SuggestionSelectionRequest(
            selectionIndex: malformedIndex, terminalID: "terminal-A")))
    }
    XCTAssertEqual(index.operationCounts.lookups, lookupsAfterSuccess)

    XCTAssertFalse(
      handler.select(SuggestionSelectionRequest(selectionIndex: "99", terminalID: "terminal-A")))
    XCTAssertFalse(
      handler.select(
        SuggestionSelectionRequest(selectionIndex: "2.3", terminalID: "unknown-terminal")))
    XCTAssertFalse(
      handler.select(SuggestionSelectionRequest(selectionIndex: "2.3", terminalID: nil)))
    XCTAssertFalse(
      handler.select(SuggestionSelectionRequest(selectionIndex: "2.3", terminalID: "")))

    XCTAssertEqual(index.operationCounts.lookups, lookupsAfterSuccess + 2)
    XCTAssertEqual(spy.clipboardWrites, ["a-first", "a-third", "b-third"])
    XCTAssertEqual(spy.pasteCount, 3)
    XCTAssertEqual(spy.successCount, 3)

    // A fresh process creates a fresh index. The mapping from the former launch is stale.
    let nextLaunchIndex = SuggestionCommandIndex()
    let nextLaunchSpy = SelectionSideEffectSpy()
    let nextLaunchHandler = nextLaunchSpy.makeHandler(index: nextLaunchIndex)
    XCTAssertFalse(
      nextLaunchHandler.select(
        SuggestionSelectionRequest(selectionIndex: "2.3", terminalID: "terminal-A")))
    XCTAssertEqual(nextLaunchIndex.operationCounts.lookups, 1)
    XCTAssertEqual(nextLaunchSpy.clipboardWrites.count, 0)
    XCTAssertEqual(nextLaunchSpy.pasteCount, 0)
    XCTAssertEqual(nextLaunchSpy.successCount, 0)
  }

  func testParserAcceptsIntegerAndExactDecimalOnly() {
    XCTAssertEqual(SMSelectionCommandParser.selectionIndex(in: "sm 2"), "2")
    XCTAssertEqual(SMSelectionCommandParser.selectionIndex(in: "prompt $ sm 2.3  "), "2.3")

    let malformedLines = [
      "sm", "sm ", "sm .3", "sm 2.", "sm 2.3.4", "sm -2", "sm two", "sm 2 trailing",
      #"sm 2 "extra""#,
    ]
    for line in malformedLines {
      XCTAssertNil(SMSelectionCommandParser.selectionIndex(in: line), line)
      XCTAssertTrue(SMSelectionCommandParser.isSelectionAttempt(line), line)
    }

    XCTAssertFalse(SMSelectionCommandParser.isSelectionAttempt(#"sm "explain this""#))
    XCTAssertFalse(SMSelectionCommandParser.isSelectionAttempt("echo normal-command"))
  }

  func testThousandsOfInterleavedSwitchesRegistrationsAndLookupsStayIsolated() {
    let terminalCount = 47
    let iterationCount = 5_000
    let address = SuggestionAddress(batchIndex: 1, suggestionIndex: 1)
    let index = SuggestionCommandIndex()
    var expectedByTerminal: [String: String] = [:]

    for terminalOffset in 0..<terminalCount {
      let terminalID = "terminal-\(terminalOffset)"
      let command = "seed-\(terminalOffset)"
      expectedByTerminal[terminalID] = command
      index.register(command: command, for: terminalID, at: address)
    }

    let spy = SelectionSideEffectSpy()
    let handler = spy.makeHandler(index: index)
    var activeTerminalID = "terminal-0"

    for iteration in 0..<iterationCount {
      let registrationOffset = (iteration * 17 + 3) % terminalCount
      let registrationTerminal = "terminal-\(registrationOffset)"
      let registeredCommand = "command-\(iteration)-for-\(registrationTerminal)"
      index.register(command: registeredCommand, for: registrationTerminal, at: address)
      expectedByTerminal[registrationTerminal] = registeredCommand

      let selectedOffset = (registrationOffset + 19) % terminalCount
      activeTerminalID = "terminal-\(selectedOffset)"

      // This request is the snapshot taken when Enter is handled.
      let request = SuggestionSelectionRequest(
        selectionIndex: "1", terminalID: activeTerminalID)

      // A switch during the key debounce must not retarget the captured request.
      activeTerminalID = "terminal-\((selectedOffset + 11) % terminalCount)"
      XCTAssertTrue(handler.select(request))
      XCTAssertEqual(spy.clipboardWrites.last, expectedByTerminal[request.terminalID!])
    }

    XCTAssertEqual(index.operationCounts.registrations, terminalCount + iterationCount)
    XCTAssertEqual(index.operationCounts.lookups, iterationCount)
    XCTAssertEqual(spy.clipboardWrites.count, iterationCount)
    XCTAssertEqual(spy.pasteCount, iterationCount)
    XCTAssertEqual(spy.successCount, iterationCount)
    XCTAssertFalse(activeTerminalID.isEmpty)
  }

  func testProgressiveRegistrationsAvoidFormerQuadraticExports() {
    let registrationCount = 1_000
    let index = SuggestionCommandIndex()
    let formerExporter = FormerHistoryExporterReference()

    for offset in 1...registrationCount {
      index.register(
        command: "command-\(offset)",
        for: "terminal-A",
        at: SuggestionAddress(batchIndex: offset, suggestionIndex: 1))
      formerExporter.appendAndExport("command-\(offset)")
    }

    XCTAssertEqual(
      index.operationCounts,
      SuggestionCommandIndex.OperationCounts(
        registrations: registrationCount, lookups: 0, historyExports: 0))
    XCTAssertEqual(formerExporter.exportCount, 1_000)
    XCTAssertEqual(formerExporter.cumulativeEntryVisits, 500_500)
  }

  private func uuid(_ value: Int) -> UUID {
    return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
  }
}
