import ApplicationServices
import Foundation

enum AXTerminalTextSourceError: Error {
  case characterCount(AXError)
  case invalidCharacterCount
  case createRange
  case suffix(AXError)
  case invalidSuffix
  case fullValue(AXError)
  case invalidFullValue
}

/// Reads Terminal text by character range without first materializing the complete AX value.
final class AXTerminalTextSource: TerminalTextSource {
  private let element: AXUIElement

  init(element: AXUIElement) {
    self.element = element
  }

  func readSuffix(maxUTF16Units: Int) throws -> TerminalSuffixReadResult {
    var countValue: AnyObject?
    let countError = AXUIElementCopyAttributeValue(
      element,
      kAXNumberOfCharactersAttribute as CFString,
      &countValue)

    guard countError == .success else {
      if Self.isUnsupported(countError) { return .unsupported }
      throw AXTerminalTextSourceError.characterCount(countError)
    }
    guard let number = countValue as? NSNumber else {
      throw AXTerminalTextSourceError.invalidCharacterCount
    }

    let characterCount = max(0, number.intValue)
    let requestedUnits = min(max(0, maxUTF16Units), characterCount)
    guard requestedUnits > 0 else {
      return .value(TerminalSuffixRead(value: "", requestedUTF16Units: 0))
    }

    var range = CFRange(
      location: characterCount - requestedUnits,
      length: requestedUnits)
    guard let rangeValue = AXValueCreate(.cfRange, &range) else {
      throw AXTerminalTextSourceError.createRange
    }

    var suffixValue: AnyObject?
    let suffixError = AXUIElementCopyParameterizedAttributeValue(
      element,
      kAXStringForRangeParameterizedAttribute as CFString,
      rangeValue,
      &suffixValue)
    guard suffixError == .success else {
      if Self.isUnsupported(suffixError) { return .unsupported }
      throw AXTerminalTextSourceError.suffix(suffixError)
    }
    guard let suffix = suffixValue as? NSString else {
      throw AXTerminalTextSourceError.invalidSuffix
    }

    return .value(
      TerminalSuffixRead(
        value: Self.validUnicodeString(from: suffix),
        requestedUTF16Units: requestedUnits))
  }

  func readFullValue() throws -> String {
    var textValue: AnyObject?
    let textError = AXUIElementCopyAttributeValue(
      element,
      kAXValueAttribute as CFString,
      &textValue)
    guard textError == .success else {
      throw AXTerminalTextSourceError.fullValue(textError)
    }
    guard let text = textValue as? NSString else {
      throw AXTerminalTextSourceError.invalidFullValue
    }
    return Self.validUnicodeString(from: text)
  }

  private static func isUnsupported(_ error: AXError) -> Bool {
    switch error {
    case .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented:
      return true
    default:
      return false
    }
  }

  /// AX ranges are UTF-16 ranges and can begin between a high and low surrogate. Preserve all
  /// complete scalars without allowing NSString bridging to introduce a replacement character.
  private static func validUnicodeString(from value: NSString) -> String {
    var location = 0
    var length = value.length

    if length > 0, (0xDC00...0xDFFF).contains(value.character(at: 0)) {
      location += 1
      length -= 1
    }
    if length > 0,
      (0xD800...0xDBFF).contains(value.character(at: location + length - 1))
    {
      length -= 1
    }

    return value.substring(with: NSRange(location: location, length: length))
  }
}
