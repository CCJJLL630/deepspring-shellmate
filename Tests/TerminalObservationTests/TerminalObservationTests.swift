import Foundation
import XCTest
@testable import TerminalObservation

private struct LegacyReferenceResult: Equatable {
  let payload: String
  let activeLine: String
  let meaningfulText: String
}

private func legacyReference(_ value: String) -> LegacyReferenceResult {
  let normalized = value.replacingOccurrences(
    of: "\n+", with: "\n", options: .regularExpression)
  let lines = normalized.split(separator: "\n")
  return LegacyReferenceResult(
    payload: lines.suffix(50).joined(separator: "\n"),
    activeLine: lines.last.map(String.init) ?? "",
    meaningfulText: normalized.replacingOccurrences(
      of: "\\W+", with: "", options: .regularExpression))
}

private struct LegacyOperationCounter {
  private(set) var snapshotUnits = 0
  private(set) var consumerReadUnits = 0
  private(set) var wholeBufferTransformationUnits = 0

  mutating func observe(_ snapshot: String) {
    let units = snapshot.utf16.count
    snapshotUnits += units

    // Active line: one full read, newline normalization, and line splitting.
    consumerReadUnits += units
    wholeBufferTransformationUnits += units * 2

    // Analysis: a second full read, newline normalization, meaningful-change canonicalization,
    // and line splitting.
    consumerReadUnits += units
    wholeBufferTransformationUnits += units * 3
  }
}

private final class SourceCounters {
  var suffixLoads = 0
  var fullValueReads = 0
  var requestedUTF16Units = 0
}

private final class StringTerminalSource: TerminalTextSource {
  let value: String
  let supportsRanges: Bool
  let counters: SourceCounters

  init(value: String, supportsRanges: Bool = true, counters: SourceCounters = .init()) {
    self.value = value
    self.supportsRanges = supportsRanges
    self.counters = counters
  }

  func readSuffix(maxUTF16Units: Int) throws -> TerminalSuffixReadResult {
    counters.suffixLoads += 1
    guard supportsRanges else { return .unsupported }

    let requested = min(maxUTF16Units, value.utf16.count)
    counters.requestedUTF16Units += requested
    return .value(
      TerminalSuffixRead(
        value: TerminalContextFormatter.boundedUTF16Suffix(
          of: value,
          maximumUnits: requested),
        requestedUTF16Units: requested))
  }

  func readFullValue() throws -> String {
    counters.fullValueReads += 1
    return value
  }
}

/// Models a range-capable backing store whose prefix need not be allocated or traversed.
private final class SparsePrefixTerminalSource: TerminalTextSource {
  let virtualPrefixUTF16Units: Int
  let storedTail: String
  let counters: SourceCounters

  init(virtualPrefixUTF16Units: Int, storedTail: String, counters: SourceCounters = .init()) {
    self.virtualPrefixUTF16Units = virtualPrefixUTF16Units
    self.storedTail = storedTail
    self.counters = counters
  }

  func readSuffix(maxUTF16Units: Int) throws -> TerminalSuffixReadResult {
    counters.suffixLoads += 1
    let totalUnits = virtualPrefixUTF16Units + storedTail.utf16.count
    let requested = min(maxUTF16Units, totalUnits)
    counters.requestedUTF16Units += requested

    // The fixtures keep at least one complete budget in the stored tail, so no prefix work occurs.
    let suffix = TerminalContextFormatter.boundedUTF16Suffix(
      of: storedTail,
      maximumUnits: requested)
    return .value(TerminalSuffixRead(value: suffix, requestedUTF16Units: requested))
  }

  func readFullValue() throws -> String {
    counters.fullValueReads += 1
    XCTFail("A range-capable sparse source must never be fully materialized")
    return ""
  }
}

final class TerminalObservationTests: XCTestCase {
  func testBoundedFormatterMatchesLegacyReferenceFixtures() throws {
    let numberedLines = (1...75).map { "line \($0)" }.joined(separator: "\n")
    let fixtures = [
      "first command\nsecond command\nthird command",
      "\n\nalpha\n\n\n\nbeta\n\n",
      "@@@ !!!\n...,,,\n$%^&*()",
      "one\r\n\r\ntwo\r\nthree\r\n",
      String(repeating: "long-value-", count: 500),
      "👩🏽‍💻 café\n你好 😀\nnaïve résumé\nمرحبا بالعالم",
      numberedLines,
      "",
    ]
    let formatter = TerminalContextFormatter(
      configuration: .init(maximumLines: 50, contextBudgetUTF16Units: 65_536))

    for fixture in fixtures {
      let expected = legacyReference(fixture)
      let actual = formatter.snapshot(from: fixture)
      XCTAssertEqual(actual.context, expected.payload, "fixture: \(fixture.prefix(40))")
      XCTAssertEqual(actual.activeLine, expected.activeLine, "fixture: \(fixture.prefix(40))")
      XCTAssertLessThanOrEqual(actual.context.split(separator: "\n").count, 50)
    }
  }

  func testMeaningfulChangeAndBlankLineSuppressionRemainTerminalSpecific() throws {
    let session = TerminalObservationSession<String>(
      configuration: .init(maximumLines: 50, contextBudgetUTF16Units: 4_096))
    session.selectTerminal("A")

    let punctuationRevision = try XCTUnwrap(
      session.beginRevision(for: "A", source: StringTerminalSource(value: "\n@@@\n...\n")))
    XCTAssertEqual(try session.activeLine(for: punctuationRevision)?.activeLine, "...")
    XCTAssertNil(try session.analysis(for: punctuationRevision))

    let firstMeaningful = try XCTUnwrap(
      session.beginRevision(for: "A", source: StringTerminalSource(value: "build-a\n\nready")))
    XCTAssertEqual(try session.analysis(for: firstMeaningful)?.text, "build-a\nready")

    // The legacy \W+ canonicalization suppresses punctuation-only changes.
    let punctuationOnlyChange = try XCTUnwrap(
      session.beginRevision(for: "A", source: StringTerminalSource(value: "build a\nready")))
    XCTAssertNil(try session.analysis(for: punctuationOnlyChange))

    // An identical context in another Terminal is independently meaningful.
    session.selectTerminal("B")
    let otherTerminal = try XCTUnwrap(
      session.beginRevision(for: "B", source: StringTerminalSource(value: "build a\nready")))
    let observation = try XCTUnwrap(session.analysis(for: otherTerminal))
    XCTAssertEqual(observation.terminalID, "B")
    XCTAssertEqual(observation.text, "build a\nready")
  }

  func testOversizedSuffixPreservesValidUnicodeBoundaries() {
    let splitPair = "prefix😀tail"
    let fiveUnitFormatter = TerminalContextFormatter(
      configuration: .init(maximumLines: 50, contextBudgetUTF16Units: 5))
    let sixUnitFormatter = TerminalContextFormatter(
      configuration: .init(maximumLines: 50, contextBudgetUTF16Units: 6))

    let fiveUnitResult = fiveUnitFormatter.snapshot(from: splitPair)
    XCTAssertEqual(fiveUnitResult.context, "tail")
    XCTAssertFalse(fiveUnitResult.context.contains("�"))
    XCTAssertLessThanOrEqual(fiveUnitResult.utf16Count, 5)

    let sixUnitResult = sixUnitFormatter.snapshot(from: splitPair)
    XCTAssertEqual(sixUnitResult.context, "😀tail")
    XCTAssertLessThanOrEqual(sixUnitResult.utf16Count, 6)

    let longLine = String(repeating: "界", count: 10_000) + "😀done"
    let bounded = TerminalContextFormatter(
      configuration: .init(maximumLines: 50, contextBudgetUTF16Units: 4_096)
    ).snapshot(from: longLine)
    XCTAssertLessThanOrEqual(bounded.utf16Count, 4_096)
    XCTAssertTrue(bounded.context.hasSuffix("😀done"))
    XCTAssertFalse(bounded.context.contains("�"))
  }

  func testLegacyProgressiveSnapshotOperationCounts() {
    var counter = LegacyOperationCounter()
    let line = String(repeating: "x", count: 80)
    var snapshot = ""

    for index in 1...1_000 {
      if index > 1 { snapshot.append("\n") }
      snapshot.append(line)
      counter.observe(snapshot)
    }

    XCTAssertEqual(counter.snapshotUnits, 40_539_500)
    XCTAssertEqual(counter.consumerReadUnits, 81_079_000)
    XCTAssertEqual(counter.wholeBufferTransformationUnits, 202_697_500)
  }

  func testOptimizedProgressiveSnapshotsHaveExactBoundedWork() throws {
    let configuration = TerminalObservationConfiguration(
      maximumLines: 50,
      contextBudgetUTF16Units: 4_096)
    let session = TerminalObservationSession<String>(configuration: configuration)
    let sourceCounters = SourceCounters()
    session.selectTerminal("terminal")

    let line = String(repeating: "x", count: 80)
    var snapshot = ""
    for index in 1...1_000 {
      if index > 1 { snapshot.append("\n") }
      snapshot.append(line)

      let source = StringTerminalSource(value: snapshot, counters: sourceCounters)
      let revision = try XCTUnwrap(session.beginRevision(for: "terminal", source: source))
      _ = try session.activeLine(for: revision)
      _ = try session.analysis(for: revision)
    }

    XCTAssertEqual(session.metrics.suffixLoads, 1_000)
    XCTAssertEqual(session.metrics.fullValueReads, 0)
    XCTAssertEqual(session.metrics.cacheHits, 1_000)
    XCTAssertEqual(session.metrics.requestedUTF16Units, 3_994_425)
    XCTAssertLessThanOrEqual(session.metrics.requestedUTF16Units, 3_994_425)
    XCTAssertLessThanOrEqual(session.metrics.maximumRetainedContextUTF16Units, 4_096)

    XCTAssertEqual(sourceCounters.suffixLoads, 1_000)
    XCTAssertEqual(sourceCounters.fullValueReads, 0)
    XCTAssertEqual(sourceCounters.requestedUTF16Units, 3_994_425)
  }

  func testIdenticalTailsPerformIdenticalWorkRegardlessOfVirtualPrefixLength() throws {
    let budget = 4_096
    let tail = (1...80).map { "tail-\($0)-" + String(repeating: "z", count: 72) }
      .joined(separator: "\n")
    XCTAssertGreaterThanOrEqual(tail.utf16.count, budget)

    func observe(prefixUnits: Int) throws -> (
      active: TerminalActiveLineObservation<String>?,
      analysis: TerminalAnalysisObservation<String>?,
      metrics: TerminalObservationMetrics,
      counters: SourceCounters
    ) {
      let counters = SourceCounters()
      let source = SparsePrefixTerminalSource(
        virtualPrefixUTF16Units: prefixUnits,
        storedTail: tail,
        counters: counters)
      let session = TerminalObservationSession<String>(
        configuration: .init(maximumLines: 50, contextBudgetUTF16Units: budget))
      session.selectTerminal("terminal")
      let revision = try XCTUnwrap(session.beginRevision(for: "terminal", source: source))
      let active = try session.activeLine(for: revision)
      let analysis = try session.analysis(for: revision)
      return (active, analysis, session.metrics, counters)
    }

    let shortPrefix = try observe(prefixUnits: 7)
    let enormousPrefix = try observe(prefixUnits: 100_000_000)

    XCTAssertEqual(shortPrefix.active?.activeLine, enormousPrefix.active?.activeLine)
    XCTAssertEqual(shortPrefix.analysis?.text, enormousPrefix.analysis?.text)
    XCTAssertEqual(shortPrefix.metrics, enormousPrefix.metrics)
    XCTAssertEqual(shortPrefix.counters.suffixLoads, enormousPrefix.counters.suffixLoads)
    XCTAssertEqual(
      shortPrefix.counters.requestedUTF16Units,
      enormousPrefix.counters.requestedUTF16Units)
    XCTAssertEqual(shortPrefix.counters.requestedUTF16Units, budget)
    XCTAssertEqual(shortPrefix.counters.fullValueReads, 0)
    XCTAssertEqual(enormousPrefix.counters.fullValueReads, 0)
  }

  func testUnsupportedRangeUsesOneFullReadForBothConsumers() throws {
    let counters = SourceCounters()
    let source = StringTerminalSource(
      value: String(repeating: "old scrollback\n", count: 10_000) + "current prompt",
      supportsRanges: false,
      counters: counters)
    let session = TerminalObservationSession<String>(
      configuration: .init(maximumLines: 50, contextBudgetUTF16Units: 4_096))
    session.selectTerminal("terminal")
    let revision = try XCTUnwrap(session.beginRevision(for: "terminal", source: source))

    XCTAssertEqual(try session.activeLine(for: revision)?.activeLine, "current prompt")
    XCTAssertNotNil(try session.analysis(for: revision))

    XCTAssertEqual(counters.suffixLoads, 1)
    XCTAssertEqual(counters.fullValueReads, 1)
    XCTAssertEqual(session.metrics.suffixLoads, 1)
    XCTAssertEqual(session.metrics.fullValueReads, 1)
    XCTAssertEqual(session.metrics.cacheHits, 1)
    XCTAssertLessThanOrEqual(session.metrics.maximumRetainedContextUTF16Units, 4_096)
  }

  func testStaleSupersededSwitchedAndCrossTerminalRevisionsDoNotEmit() throws {
    let session = TerminalObservationSession<String>(
      configuration: .init(maximumLines: 50, contextBudgetUTF16Units: 4_096))
    session.selectTerminal("A")

    let staleCounters = SourceCounters()
    let stale = try XCTUnwrap(
      session.beginRevision(
        for: "A", source: StringTerminalSource(value: "stale A", counters: staleCounters)))
    let current = try XCTUnwrap(
      session.beginRevision(for: "A", source: StringTerminalSource(value: "current A")))

    XCTAssertNil(try session.activeLine(for: stale))
    XCTAssertNil(try session.analysis(for: stale))
    XCTAssertEqual(staleCounters.suffixLoads, 0)
    XCTAssertEqual(staleCounters.fullValueReads, 0)

    let currentActive = try XCTUnwrap(session.activeLine(for: current))
    XCTAssertEqual(currentActive.terminalID, "A")
    XCTAssertEqual(currentActive.activeLine, "current A")

    // A switch invalidates even an already loaded revision before its analysis debounce fires.
    session.selectTerminal("B")
    XCTAssertNil(try session.analysis(for: current))

    let rejectedCounters = SourceCounters()
    XCTAssertNil(
      session.beginRevision(
        for: "A",
        source: StringTerminalSource(value: "wrong terminal", counters: rejectedCounters)))
    XCTAssertEqual(rejectedCounters.suffixLoads, 0)

    let terminalB = try XCTUnwrap(
      session.beginRevision(for: "B", source: StringTerminalSource(value: "current B")))
    let bActive = try XCTUnwrap(session.activeLine(for: terminalB))
    let bAnalysis = try XCTUnwrap(session.analysis(for: terminalB))
    XCTAssertEqual(bActive.terminalID, "B")
    XCTAssertEqual(bAnalysis.terminalID, "B")
    XCTAssertEqual(bAnalysis.text, "current B")
  }

  func testDeduplicationIsScopedToTerminalAndSurvivesSwitches() throws {
    let session = TerminalObservationSession<String>()

    session.selectTerminal("A")
    let firstA = try XCTUnwrap(
      session.beginRevision(for: "A", source: StringTerminalSource(value: "same prompt")))
    XCTAssertNotNil(try session.activeLine(for: firstA))
    XCTAssertNotNil(try session.analysis(for: firstA))

    session.selectTerminal("B")
    let firstB = try XCTUnwrap(
      session.beginRevision(for: "B", source: StringTerminalSource(value: "same prompt")))
    XCTAssertEqual(try session.activeLine(for: firstB)?.terminalID, "B")
    XCTAssertEqual(try session.analysis(for: firstB)?.terminalID, "B")

    session.selectTerminal("A")
    let repeatedA = try XCTUnwrap(
      session.beginRevision(for: "A", source: StringTerminalSource(value: "same prompt")))
    XCTAssertNil(try session.activeLine(for: repeatedA))
    XCTAssertNil(try session.analysis(for: repeatedA))
  }
}
