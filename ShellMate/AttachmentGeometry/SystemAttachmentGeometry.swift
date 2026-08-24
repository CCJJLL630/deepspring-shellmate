#if canImport(AppKit)
import AppKit
import CoreGraphics

/// A stable snapshot of live display geometry. The AX reference is the Core Graphics main display,
/// not `NSScreen.main` (which can follow the key window).
struct SystemAttachmentGeometryContext {
  let displays: [AttachmentDisplay]
  let coordinateReferenceDisplay: AttachmentDisplay

  private let planner = AttachmentGeometryPlanner()

  static func current(
    screens: [NSScreen] = NSScreen.screens,
    coordinateReferenceDisplayID: CGDirectDisplayID = CGMainDisplayID()
  ) -> SystemAttachmentGeometryContext? {
    let displays = screens.compactMap { screen -> AttachmentDisplay? in
      guard
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? NSNumber
      else {
        return nil
      }
      return AttachmentDisplay(
        identifier: number.uint32Value,
        frame: screen.frame,
        visibleFrame: screen.visibleFrame)
    }

    // A partial snapshot is not trustworthy; fail closed rather than selecting from stale or
    // unidentified display geometry.
    guard displays.count == screens.count,
      let reference = displays.first(where: { $0.identifier == coordinateReferenceDisplayID })
    else {
      return nil
    }
    return SystemAttachmentGeometryContext(
      displays: displays,
      coordinateReferenceDisplay: reference)
  }

  func convertAXFrame(_ frame: CGRect) -> CGRect? {
    return planner.convertAXFrame(frame, coordinateReferenceDisplay: coordinateReferenceDisplay)
  }

  func finalPlacement(
    axTerminalFrame: CGRect,
    requestedSide: AttachmentSide,
    shellMateWidth: CGFloat
  ) -> AttachmentPlacement? {
    return planner.finalPlacement(
      for: request(
        axTerminalFrame: axTerminalFrame,
        requestedSide: requestedSide,
        shellMateWidth: shellMateWidth))
  }

  func ghostPreview(
    axTerminalFrame: CGRect,
    requestedSide: AttachmentSide,
    shellMateWidth: CGFloat
  ) -> AttachmentPlacement? {
    return planner.ghostPreview(
      for: request(
        axTerminalFrame: axTerminalFrame,
        requestedSide: requestedSide,
        shellMateWidth: shellMateWidth))
  }

  private func request(
    axTerminalFrame: CGRect,
    requestedSide: AttachmentSide,
    shellMateWidth: CGFloat
  ) -> AttachmentPlacementRequest {
    return AttachmentPlacementRequest(
      axTerminalFrame: axTerminalFrame,
      coordinateReferenceDisplay: coordinateReferenceDisplay,
      displays: displays,
      requestedSide: requestedSide,
      shellMateWidth: shellMateWidth)
  }
}
#endif
