import Foundation

struct SuggestionAddress: Hashable, CustomStringConvertible {
  let batchIndex: Int
  let suggestionIndex: Int

  init(batchIndex: Int, suggestionIndex: Int) {
    precondition(batchIndex > 0 && suggestionIndex > 0, "Suggestion indices must be positive")
    self.batchIndex = batchIndex
    self.suggestionIndex = suggestionIndex
  }

  init?(selectionIndex: String) {
    let components = selectionIndex.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 1 || components.count == 2,
      let batchIndex = Self.positiveInteger(components[0])
    else {
      return nil
    }

    let suggestionIndex: Int
    if components.count == 1 {
      suggestionIndex = 1
    } else {
      guard String(batchIndex) == components[0],
        let parsedSuggestionIndex = Self.positiveInteger(components[1]),
        String(parsedSuggestionIndex) == components[1]
      else {
        return nil
      }
      suggestionIndex = parsedSuggestionIndex
    }

    self.init(batchIndex: batchIndex, suggestionIndex: suggestionIndex)
  }

  var description: String {
    return "\(batchIndex).\(suggestionIndex)"
  }

  private static func positiveInteger(_ value: Substring) -> Int? {
    guard !value.isEmpty,
      value.utf8.allSatisfy({ byte in byte >= 48 && byte <= 57 }),
      let result = Int(value), result > 0
    else {
      return nil
    }
    return result
  }
}

protocol SuggestionCommandLookingUp: AnyObject {
  func command(for terminalID: String, at address: SuggestionAddress) -> String?
}

protocol SuggestionCommandRegistering: AnyObject {
  func register(command: String, for terminalID: String, at address: SuggestionAddress)
}

/// A process-local index of selectable suggestions.
///
/// Nothing is persisted, so a new application launch always starts with an empty index. The
/// terminal ID is part of the dictionary key to prevent one Terminal window from selecting a
/// command generated for another one.
final class SuggestionCommandIndex: SuggestionCommandLookingUp, SuggestionCommandRegistering {
  struct OperationCounts: Equatable {
    let registrations: Int
    let lookups: Int
    let historyExports: Int
  }

  static let shared = SuggestionCommandIndex()

  private struct Key: Hashable {
    let terminalID: String
    let address: SuggestionAddress
  }

  private let lock = NSLock()
  private var commands: [Key: String] = [:]
  private var registrationCount = 0
  private var lookupCount = 0

  init() {}

  func register(command: String, for terminalID: String, at address: SuggestionAddress) {
    guard !terminalID.isEmpty, !command.isEmpty else { return }

    withLock {
      commands[Key(terminalID: terminalID, address: address)] = command
      registrationCount += 1
    }
  }

  func command(for terminalID: String, at address: SuggestionAddress) -> String? {
    return withLock {
      lookupCount += 1
      return commands[Key(terminalID: terminalID, address: address)]
    }
  }

  var operationCounts: OperationCounts {
    return withLock {
      OperationCounts(
        registrations: registrationCount,
        lookups: lookupCount,
        historyExports: 0
      )
    }
  }

  private func withLock<T>(_ operation: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return operation()
  }
}

/// Tracks where an entry will appear in the UI without retaining or walking suggestion history.
/// Pro-tip entries use the same operation and therefore reserve their visible batch positions.
final class SuggestionAddressTracker {
  private struct BatchKey: Hashable {
    let terminalID: String
    let stateID: UUID
  }

  private struct BatchPosition {
    let batchIndex: Int
    var suggestionCount: Int
  }

  private var batchCountsByTerminal: [String: Int] = [:]
  private var positionsByBatch: [BatchKey: BatchPosition] = [:]

  func addressForNextEntry(terminalID: String, stateID: UUID) -> SuggestionAddress {
    let key = BatchKey(terminalID: terminalID, stateID: stateID)

    if var position = positionsByBatch[key] {
      position.suggestionCount += 1
      positionsByBatch[key] = position
      return SuggestionAddress(
        batchIndex: position.batchIndex, suggestionIndex: position.suggestionCount)
    }

    let batchIndex = (batchCountsByTerminal[terminalID] ?? 0) + 1
    batchCountsByTerminal[terminalID] = batchIndex
    positionsByBatch[key] = BatchPosition(batchIndex: batchIndex, suggestionCount: 1)
    return SuggestionAddress(batchIndex: batchIndex, suggestionIndex: 1)
  }
}
