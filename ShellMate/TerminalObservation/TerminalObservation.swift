import Foundation

/// The result of asking a Terminal value source for only its newest UTF-16 units.
public enum TerminalSuffixReadResult: Equatable {
  case value(TerminalSuffixRead)
  case unsupported
}

public struct TerminalSuffixRead: Equatable {
  public let value: String
  /// The actual number of UTF-16 units requested from the backing store.
  public let requestedUTF16Units: Int

  public init(value: String, requestedUTF16Units: Int) {
    self.value = value
    self.requestedUTF16Units = requestedUTF16Units
  }
}

/// Supplies one revision of a Terminal text value. Implementations should not obtain the complete
/// value while servicing `readSuffix`.
public protocol TerminalTextSource: AnyObject {
  func readSuffix(maxUTF16Units: Int) throws -> TerminalSuffixReadResult
  func readFullValue() throws -> String
}

public struct TerminalObservationConfiguration: Equatable {
  public let maximumLines: Int
  public let contextBudgetUTF16Units: Int

  public init(maximumLines: Int = 50, contextBudgetUTF16Units: Int = 32 * 1_024) {
    // Terminal observations are deliberately capped at the existing 50-line payload. Keeping a
    // configurable lower limit is useful for focused consumers and tests, but no caller may expand
    // the observation beyond that product contract.
    self.maximumLines = min(50, max(1, maximumLines))
    self.contextBudgetUTF16Units = max(1, contextBudgetUTF16Units)
  }
}

/// The only text retained for a revision. It has already been newline-normalized and reduced to
/// the configured number of newest logical lines and UTF-16 context budget.
public struct TerminalObservationSnapshot: Equatable {
  public let context: String

  public var activeLine: String {
    context.split(separator: "\n").last.map(String.init) ?? ""
  }

  public var utf16Count: Int { context.utf16.count }

  public init(context: String) {
    self.context = context
  }
}

/// Pure formatting shared by the AX integration and deterministic tests.
public struct TerminalContextFormatter {
  public let configuration: TerminalObservationConfiguration

  public init(configuration: TerminalObservationConfiguration = .init()) {
    self.configuration = configuration
  }

  public func snapshot(from value: String) -> TerminalObservationSnapshot {
    let boundedValue = Self.boundedUTF16Suffix(
      of: value,
      maximumUnits: configuration.contextBudgetUTF16Units)
    let normalizedValue = boundedValue.replacingOccurrences(
      of: "\n+", with: "\n", options: .regularExpression)
    let lines = normalizedValue.split(separator: "\n")
    let context = lines.suffix(configuration.maximumLines).joined(separator: "\n")
    return TerminalObservationSnapshot(context: context)
  }

  /// Returns a valid Unicode suffix no larger than `maximumUnits`. If the boundary would bisect a
  /// surrogate pair, the incomplete scalar is omitted rather than replaced by U+FFFD.
  public static func boundedUTF16Suffix(of value: String, maximumUnits: Int) -> String {
    guard maximumUnits > 0 else { return "" }

    let utf16 = value.utf16
    guard utf16.count > maximumUnits else { return value }

    var units = Array(utf16.suffix(maximumUnits))
    if let first = units.first, (0xDC00...0xDFFF).contains(first) {
      units.removeFirst()
    }
    if let last = units.last, (0xD800...0xDBFF).contains(last) {
      units.removeLast()
    }
    return String(decoding: units, as: UTF16.self)
  }
}

public struct TerminalObservationRevision<TerminalID: Hashable>: Hashable {
  public let terminalID: TerminalID
  fileprivate let sequence: UInt64

  fileprivate init(terminalID: TerminalID, sequence: UInt64) {
    self.terminalID = terminalID
    self.sequence = sequence
  }
}

public struct TerminalActiveLineObservation<TerminalID: Hashable>: Equatable {
  public let revision: TerminalObservationRevision<TerminalID>
  public let terminalID: TerminalID
  public let activeLine: String
}

public struct TerminalAnalysisObservation<TerminalID: Hashable>: Equatable {
  public let revision: TerminalObservationRevision<TerminalID>
  public let terminalID: TerminalID
  public let text: String
}

public struct TerminalObservationMetrics: Equatable {
  public fileprivate(set) var suffixLoads = 0
  public fileprivate(set) var fullValueReads = 0
  public fileprivate(set) var cacheHits = 0
  public fileprivate(set) var requestedUTF16Units = 0
  public fileprivate(set) var maximumRetainedContextUTF16Units = 0

  public init() {}
}

/// Owns the currently selected Terminal revision and its one bounded snapshot. This type is
/// intentionally synchronous: TerminalContentManager drives it from the main queue so checking a
/// revision and posting the resulting notification form one ordered operation.
public final class TerminalObservationSession<TerminalID: Hashable> {
  public let configuration: TerminalObservationConfiguration
  public private(set) var selectedTerminalID: TerminalID?
  public private(set) var metrics = TerminalObservationMetrics()

  private let formatter: TerminalContextFormatter
  private var nextSequence: UInt64 = 0
  private var currentRevision: TerminalObservationRevision<TerminalID>?
  private var pendingSource: TerminalTextSource?
  private var loadWasAttempted = false
  private var cachedSnapshot: TerminalObservationSnapshot?
  private var cachedLoadError: Error?
  private var previousActiveLines: [TerminalID: String] = [:]
  private var previousMeaningfulContexts: [TerminalID: String] = [:]

  public init(configuration: TerminalObservationConfiguration = .init()) {
    self.configuration = configuration
    self.formatter = TerminalContextFormatter(configuration: configuration)
  }

  /// Invalidates every pending revision, even when the same Terminal identifier is selected again.
  public func selectTerminal(_ terminalID: TerminalID?) {
    selectedTerminalID = terminalID
    invalidateCurrentRevision()
  }

  /// Binds the source to its Terminal and revision so it cannot later be consumed as another
  /// Terminal's value. A source for a Terminal other than the selected one is rejected.
  @discardableResult
  public func beginRevision(
    for terminalID: TerminalID,
    source: TerminalTextSource
  ) -> TerminalObservationRevision<TerminalID>? {
    guard selectedTerminalID == terminalID else { return nil }

    nextSequence &+= 1
    let revision = TerminalObservationRevision(terminalID: terminalID, sequence: nextSequence)
    currentRevision = revision
    pendingSource = source
    loadWasAttempted = false
    cachedSnapshot = nil
    cachedLoadError = nil
    return revision
  }

  public func isCurrent(_ revision: TerminalObservationRevision<TerminalID>) -> Bool {
    selectedTerminalID == revision.terminalID && currentRevision == revision
  }

  /// Produces at most one active-line change for a revision. Duplicate suppression is scoped to the
  /// Terminal rather than shared between windows.
  public func activeLine(
    for revision: TerminalObservationRevision<TerminalID>
  ) throws -> TerminalActiveLineObservation<TerminalID>? {
    guard let snapshot = try snapshot(for: revision), isCurrent(revision) else { return nil }
    let activeLine = snapshot.activeLine
    guard previousActiveLines[revision.terminalID] != activeLine else { return nil }

    previousActiveLines[revision.terminalID] = activeLine
    return TerminalActiveLineObservation(
      revision: revision,
      terminalID: revision.terminalID,
      activeLine: activeLine)
  }

  /// Produces an analysis request only for non-empty, meaningfully changed bounded context.
  public func analysis(
    for revision: TerminalObservationRevision<TerminalID>
  ) throws -> TerminalAnalysisObservation<TerminalID>? {
    guard let snapshot = try snapshot(for: revision), isCurrent(revision) else { return nil }
    let meaningfulContext = snapshot.context.replacingOccurrences(
      of: "\\W+", with: "", options: .regularExpression)
    guard !meaningfulContext.isEmpty else { return nil }
    guard previousMeaningfulContexts[revision.terminalID] != meaningfulContext else { return nil }

    previousMeaningfulContexts[revision.terminalID] = meaningfulContext
    return TerminalAnalysisObservation(
      revision: revision,
      terminalID: revision.terminalID,
      text: snapshot.context)
  }

  private func snapshot(
    for revision: TerminalObservationRevision<TerminalID>
  ) throws -> TerminalObservationSnapshot? {
    guard isCurrent(revision) else { return nil }

    if loadWasAttempted {
      metrics.cacheHits += 1
      if let cachedLoadError { throw cachedLoadError }
      return cachedSnapshot
    }

    loadWasAttempted = true
    guard let source = pendingSource else { return nil }
    pendingSource = nil

    do {
      metrics.suffixLoads += 1
      let value: String
      switch try source.readSuffix(
        maxUTF16Units: configuration.contextBudgetUTF16Units)
      {
      case .value(let read):
        let requestedUnits = min(
          configuration.contextBudgetUTF16Units,
          max(0, read.requestedUTF16Units))
        metrics.requestedUTF16Units += requestedUnits
        value = read.value
      case .unsupported:
        metrics.fullValueReads += 1
        value = try source.readFullValue()
      }

      guard isCurrent(revision) else { return nil }
      let snapshot = formatter.snapshot(from: value)
      cachedSnapshot = snapshot
      metrics.maximumRetainedContextUTF16Units = max(
        metrics.maximumRetainedContextUTF16Units,
        snapshot.utf16Count)
      return snapshot
    } catch {
      cachedLoadError = error
      throw error
    }
  }

  private func invalidateCurrentRevision() {
    currentRevision = nil
    pendingSource = nil
    loadWasAttempted = false
    cachedSnapshot = nil
    cachedLoadError = nil
  }
}
