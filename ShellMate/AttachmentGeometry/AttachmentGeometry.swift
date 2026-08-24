import Foundation

/// The side of the Terminal requested by the user.
public enum AttachmentSide: String, Equatable, Sendable {
  case left
  case right
  case float

  fileprivate var opposite: AttachmentSide? {
    switch self {
    case .left:
      return .right
    case .right:
      return .left
    case .float:
      return nil
    }
  }
}

/// An immutable display snapshot used for attachment calculations.
///
/// `frame` and `visibleFrame` use Cocoa's bottom-left coordinate system. The identifier is used
/// only as the final deterministic display-selection tie breaker.
public struct AttachmentDisplay: Equatable {
  public let identifier: UInt32
  public let frame: CGRect
  public let visibleFrame: CGRect

  public init(identifier: UInt32, frame: CGRect, visibleFrame: CGRect) {
    self.identifier = identifier
    self.frame = frame
    self.visibleFrame = visibleFrame
  }
}

/// All geometry needed for a single placement decision.
public struct AttachmentPlacementRequest: Equatable {
  /// The Terminal frame reported by Accessibility, whose origin is in top-left coordinates.
  public let axTerminalFrame: CGRect
  /// The display whose top-left corner defines the Accessibility coordinate origin.
  public let coordinateReferenceDisplay: AttachmentDisplay
  public let displays: [AttachmentDisplay]
  public let requestedSide: AttachmentSide
  /// ShellMate keeps its current width while attached. Its height follows the Terminal.
  public let shellMateWidth: CGFloat

  public init(
    axTerminalFrame: CGRect,
    coordinateReferenceDisplay: AttachmentDisplay,
    displays: [AttachmentDisplay],
    requestedSide: AttachmentSide,
    shellMateWidth: CGFloat
  ) {
    self.axTerminalFrame = axTerminalFrame
    self.coordinateReferenceDisplay = coordinateReferenceDisplay
    self.displays = displays
    self.requestedSide = requestedSide
    self.shellMateWidth = shellMateWidth
  }
}

/// The complete result shared by final placement and the ghost preview.
public struct AttachmentPlacement: Equatable {
  public let terminalFrame: CGRect
  public let display: AttachmentDisplay
  public let requestedSide: AttachmentSide
  public let effectiveSide: AttachmentSide
  public let frame: CGRect

  public init(
    terminalFrame: CGRect,
    display: AttachmentDisplay,
    requestedSide: AttachmentSide,
    effectiveSide: AttachmentSide,
    frame: CGRect
  ) {
    self.terminalFrame = terminalFrame
    self.display = display
    self.requestedSide = requestedSide
    self.effectiveSide = effectiveSide
    self.frame = frame
  }
}

/// Pure, deterministic attachment geometry.
public struct AttachmentGeometryPlanner {
  public init() {}

  /// Converts a Terminal Accessibility frame to Cocoa coordinates using an explicit display.
  /// This deliberately has no dependency on `NSScreen.main` or the key window.
  public func convertAXFrame(
    _ axFrame: CGRect,
    coordinateReferenceDisplay: AttachmentDisplay
  ) -> CGRect? {
    guard Self.isUsable(rect: axFrame),
      Self.isUsable(display: coordinateReferenceDisplay)
    else {
      return nil
    }

    // AX coordinates have their origin at the reference display's top-left; Cocoa coordinates
    // have their origin at its bottom-left. Secondary-display offsets naturally follow from this
    // single global transform (including negative and vertically stacked display origins).
    let x = coordinateReferenceDisplay.frame.minX + axFrame.minX
    let y = coordinateReferenceDisplay.frame.maxY - axFrame.minY - axFrame.height
    let converted = CGRect(x: x, y: y, width: axFrame.width, height: axFrame.height)
    return Self.isUsable(rect: converted) ? converted : nil
  }

  /// The final-window entry point. It intentionally delegates to the same implementation as the
  /// ghost-preview entry point.
  public func finalPlacement(for request: AttachmentPlacementRequest) -> AttachmentPlacement? {
    return placement(for: request)
  }

  /// The ghost-preview entry point. Returning the same placement model prevents conversion,
  /// display-selection, and fallback rules from drifting from final placement.
  public func ghostPreview(for request: AttachmentPlacementRequest) -> AttachmentPlacement? {
    return placement(for: request)
  }

  private func placement(for request: AttachmentPlacementRequest) -> AttachmentPlacement? {
    guard request.requestedSide != .float else { return nil }
    guard request.shellMateWidth.isFinite, request.shellMateWidth > 0 else { return nil }
    guard Self.areUsable(displays: request.displays) else { return nil }
    guard
      let referenceDisplay = request.displays.first(where: {
        $0.identifier == request.coordinateReferenceDisplay.identifier
      }),
      referenceDisplay.frame == request.coordinateReferenceDisplay.frame
    else {
      return nil
    }

    guard
      let terminalFrame = convertAXFrame(
        request.axTerminalFrame,
        coordinateReferenceDisplay: request.coordinateReferenceDisplay),
      let selectedDisplay = Self.selectDisplay(for: terminalFrame, from: request.displays)
    else {
      return nil
    }

    let visibleFrame = selectedDisplay.visibleFrame
    let width = min(request.shellMateWidth, visibleFrame.width)
    // Attached ShellMate windows follow Terminal height whenever it fits, then shrink only as
    // much as required to remain entirely in the selected display's visible frame.
    let height = min(terminalFrame.height, visibleFrame.height)
    guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }

    guard
      let leftFrame = Self.unclampedFrame(
        side: .left,
        terminalFrame: terminalFrame,
        width: width,
        height: height),
      let rightFrame = Self.unclampedFrame(
        side: .right,
        terminalFrame: terminalFrame,
        width: width,
        height: height)
    else {
      return nil
    }

    let requestedFrame = request.requestedSide == .left ? leftFrame : rightFrame
    let oppositeFrame = request.requestedSide == .left ? rightFrame : leftFrame
    let effectiveSide: AttachmentSide

    if Self.contains(visibleFrame, requestedFrame) {
      effectiveSide = request.requestedSide
    } else if Self.contains(visibleFrame, oppositeFrame) {
      guard let opposite = request.requestedSide.opposite else { return nil }
      effectiveSide = opposite
    } else {
      guard
        let leftClearance = Self.finiteDifference(terminalFrame.minX, visibleFrame.minX),
        let rightClearance = Self.finiteDifference(visibleFrame.maxX, terminalFrame.maxX)
      else {
        return nil
      }

      if leftClearance > rightClearance {
        effectiveSide = .left
      } else if rightClearance > leftClearance {
        effectiveSide = .right
      } else {
        // A clearance tie preserves intent without mutating the saved preference.
        effectiveSide = request.requestedSide
      }
    }

    let effectiveFrame = effectiveSide == .left ? leftFrame : rightFrame
    guard let clampedFrame = Self.clamp(effectiveFrame, to: visibleFrame) else { return nil }

    return AttachmentPlacement(
      terminalFrame: terminalFrame,
      display: selectedDisplay,
      requestedSide: request.requestedSide,
      effectiveSide: effectiveSide,
      frame: clampedFrame)
  }

  private static func selectDisplay(
    for terminalFrame: CGRect,
    from displays: [AttachmentDisplay]
  ) -> AttachmentDisplay? {
    var intersecting: [(display: AttachmentDisplay, area: CGFloat)] = []
    intersecting.reserveCapacity(displays.count)

    for display in displays {
      guard let area = intersectionArea(terminalFrame, display.frame) else { return nil }
      if area > 0 {
        intersecting.append((display, area))
      }
    }

    if !intersecting.isEmpty {
      return intersecting.min { lhs, rhs in
        if lhs.area != rhs.area {
          // `min` uses this inverted comparison to put the greatest area first.
          return lhs.area > rhs.area
        }
        return displayPrecedes(lhs.display, rhs.display)
      }?.display
    }

    var nearest: (display: AttachmentDisplay, distance: CGFloat)?
    for display in displays {
      guard let distance = distanceBetween(terminalFrame, display.frame) else { return nil }
      guard let current = nearest else {
        nearest = (display, distance)
        continue
      }

      if distance < current.distance
        || (distance == current.distance && displayPrecedes(display, current.display))
      {
        nearest = (display, distance)
      }
    }
    return nearest?.display
  }

  /// Canonical geometric ordering followed by stable display identity makes ties independent of
  /// `NSScreen.screens` enumeration order.
  private static func displayPrecedes(_ lhs: AttachmentDisplay, _ rhs: AttachmentDisplay) -> Bool {
    let lhsValues = [
      lhs.frame.minX, lhs.frame.minY, lhs.frame.width, lhs.frame.height,
      lhs.visibleFrame.minX, lhs.visibleFrame.minY, lhs.visibleFrame.width,
      lhs.visibleFrame.height,
    ]
    let rhsValues = [
      rhs.frame.minX, rhs.frame.minY, rhs.frame.width, rhs.frame.height,
      rhs.visibleFrame.minX, rhs.visibleFrame.minY, rhs.visibleFrame.width,
      rhs.visibleFrame.height,
    ]

    for (lhsValue, rhsValue) in zip(lhsValues, rhsValues) where lhsValue != rhsValue {
      return lhsValue < rhsValue
    }
    return lhs.identifier < rhs.identifier
  }

  private static func unclampedFrame(
    side: AttachmentSide,
    terminalFrame: CGRect,
    width: CGFloat,
    height: CGFloat
  ) -> CGRect? {
    let x: CGFloat
    switch side {
    case .left:
      guard let value = finiteDifference(terminalFrame.minX, width) else { return nil }
      x = value
    case .right:
      x = terminalFrame.maxX
    case .float:
      return nil
    }

    let result = CGRect(x: x, y: terminalFrame.minY, width: width, height: height)
    return isUsable(rect: result) ? result : nil
  }

  private static func clamp(_ frame: CGRect, to bounds: CGRect) -> CGRect? {
    guard isUsable(rect: frame), isUsable(rect: bounds), frame.width <= bounds.width,
      frame.height <= bounds.height
    else {
      return nil
    }

    let maximumX = bounds.maxX - frame.width
    let maximumY = bounds.maxY - frame.height
    let x = min(max(frame.minX, bounds.minX), maximumX)
    let y = min(max(frame.minY, bounds.minY), maximumY)
    let result = CGRect(x: x, y: y, width: frame.width, height: frame.height)
    guard isUsable(rect: result), contains(bounds, result) else { return nil }
    return result
  }

  private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat? {
    let width = max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
    let height = max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    let area = width * height
    return area.isFinite ? area : nil
  }

  private static func distanceBetween(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat? {
    let horizontal = max(0, max(rhs.minX - lhs.maxX, lhs.minX - rhs.maxX))
    let vertical = max(0, max(rhs.minY - lhs.maxY, lhs.minY - rhs.maxY))
    guard horizontal.isFinite, vertical.isFinite else { return nil }

    let largest = max(horizontal, vertical)
    guard largest > 0 else { return 0 }
    let smallest = min(horizontal, vertical)
    let ratio = smallest / largest
    let distance = largest * (1 + ratio * ratio).squareRoot()
    return distance.isFinite ? distance : nil
  }

  private static func finiteDifference(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat? {
    let result = lhs - rhs
    return result.isFinite ? result : nil
  }

  private static func areUsable(displays: [AttachmentDisplay]) -> Bool {
    guard !displays.isEmpty else { return false }
    var identifiers = Set<UInt32>()
    for display in displays {
      guard isUsable(display: display), identifiers.insert(display.identifier).inserted else {
        return false
      }
    }
    return true
  }

  private static func isUsable(display: AttachmentDisplay) -> Bool {
    return isUsable(rect: display.frame)
      && isUsable(rect: display.visibleFrame)
      && contains(display.frame, display.visibleFrame)
  }

  private static func isUsable(rect: CGRect) -> Bool {
    return rect.origin.x.isFinite
      && rect.origin.y.isFinite
      && rect.size.width.isFinite
      && rect.size.height.isFinite
      && rect.size.width > 0
      && rect.size.height > 0
      && rect.minX.isFinite
      && rect.minY.isFinite
      && rect.maxX.isFinite
      && rect.maxY.isFinite
      && rect.maxX > rect.minX
      && rect.maxY > rect.minY
  }

  private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
    return outer.minX <= inner.minX
      && outer.minY <= inner.minY
      && outer.maxX >= inner.maxX
      && outer.maxY >= inner.maxY
  }
}
