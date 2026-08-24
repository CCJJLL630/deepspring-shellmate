import Foundation

struct SuggestionSelectionRequest {
  let selectionIndex: String?
  let terminalID: String?
}

/// Resolves one captured selection request and owns all selection side effects.
final class SuggestionSelectionHandler {
  typealias ClipboardWriter = (String) -> Void
  typealias PasteAction = () -> Void
  typealias SuccessAction = () -> Void

  private let commandIndex: SuggestionCommandLookingUp
  private let writeClipboard: ClipboardWriter
  private let paste: PasteAction
  private let didSelect: SuccessAction

  init(
    commandIndex: SuggestionCommandLookingUp,
    writeClipboard: @escaping ClipboardWriter,
    paste: @escaping PasteAction,
    didSelect: @escaping SuccessAction = {}
  ) {
    self.commandIndex = commandIndex
    self.writeClipboard = writeClipboard
    self.paste = paste
    self.didSelect = didSelect
  }

  /// Returns true only when the request resolved and all success actions were issued.
  @discardableResult
  func select(_ request: SuggestionSelectionRequest) -> Bool {
    guard let terminalID = request.terminalID, !terminalID.isEmpty,
      let selectionIndex = request.selectionIndex,
      let address = SuggestionAddress(selectionIndex: selectionIndex),
      let command = commandIndex.command(for: terminalID, at: address)
    else {
      return false
    }

    writeClipboard(command)
    paste()
    didSelect()
    return true
  }
}

/// Parses the numeric argument from the command line captured when Enter was handled.
enum SMSelectionCommandParser {
  private static let selectionRegex = try! NSRegularExpression(
    pattern: #"^.*\bsm\s+(\d+(?:\.\d+)?)\s*$"#)
  private static let selectionAttemptRegex = try! NSRegularExpression(
    pattern: #"^.*\bsm(?:\s+(?![\"']).*)?\s*$"#)

  static func selectionIndex(in line: String) -> String? {
    let range = NSRange(location: 0, length: line.utf16.count)
    guard let match = selectionRegex.firstMatch(in: line, options: [], range: range),
      let indexRange = Range(match.range(at: 1), in: line)
    else {
      return nil
    }
    return String(line[indexRange])
  }

  static func isSelectionAttempt(_ line: String) -> Bool {
    let range = NSRange(location: 0, length: line.utf16.count)
    return selectionAttemptRegex.firstMatch(in: line, options: [], range: range) != nil
  }
}
