import Foundation
import XCTest
@testable import AttachmentGeometry

final class AttachmentGeometryTests: XCTestCase {
  private let planner = AttachmentGeometryPlanner()

  private func display(
    _ identifier: UInt32,
    _ frame: CGRect,
    visibleFrame: CGRect? = nil
  ) -> AttachmentDisplay {
    return AttachmentDisplay(
      identifier: identifier,
      frame: frame,
      visibleFrame: visibleFrame ?? frame)
  }

  private func axFrame(for cocoaFrame: CGRect, reference: AttachmentDisplay) -> CGRect {
    return CGRect(
      x: cocoaFrame.minX - reference.frame.minX,
      y: reference.frame.maxY - cocoaFrame.maxY,
      width: cocoaFrame.width,
      height: cocoaFrame.height)
  }

  private func request(
    cocoaTerminalFrame: CGRect,
    reference: AttachmentDisplay,
    displays: [AttachmentDisplay],
    side: AttachmentSide,
    width: CGFloat
  ) -> AttachmentPlacementRequest {
    return AttachmentPlacementRequest(
      axTerminalFrame: axFrame(for: cocoaTerminalFrame, reference: reference),
      coordinateReferenceDisplay: reference,
      displays: displays,
      requestedSide: side,
      shellMateWidth: width)
  }

  @discardableResult
  private func assertFinalAndGhostAgree(
    _ request: AttachmentPlacementRequest,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> AttachmentPlacement {
    let final = planner.finalPlacement(for: request)
    let ghost = planner.ghostPreview(for: request)
    XCTAssertNotNil(final, file: file, line: line)
    XCTAssertEqual(final, ghost, file: file, line: line)
    let placement = try! XCTUnwrap(final, file: file, line: line)
    assertFiniteAndContained(placement, file: file, line: line)
    return placement
  }

  private func assertFiniteAndContained(
    _ placement: AttachmentPlacement,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let frame = placement.frame
    let visible = placement.display.visibleFrame
    XCTAssertTrue(frame.origin.x.isFinite, file: file, line: line)
    XCTAssertTrue(frame.origin.y.isFinite, file: file, line: line)
    XCTAssertTrue(frame.width.isFinite, file: file, line: line)
    XCTAssertTrue(frame.height.isFinite, file: file, line: line)
    XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
    XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
    XCTAssertGreaterThanOrEqual(frame.minX, visible.minX, file: file, line: line)
    XCTAssertGreaterThanOrEqual(frame.minY, visible.minY, file: file, line: line)
    XCTAssertLessThanOrEqual(frame.maxX, visible.maxX, file: file, line: line)
    XCTAssertLessThanOrEqual(frame.maxY, visible.maxY, file: file, line: line)
  }

  func testPrimaryNegativeAboveBelowAndMixedHeightLayouts() {
    let primary = display(
      10,
      CGRect(x: 0, y: 0, width: 1_440, height: 900),
      visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 875))
    let negativeX = display(
      20,
      CGRect(x: -1_280, y: 50, width: 1_280, height: 800),
      visibleFrame: CGRect(x: -1_280, y: 50, width: 1_280, height: 780))
    let above = display(
      30,
      CGRect(x: 0, y: 900, width: 1_200, height: 900),
      visibleFrame: CGRect(x: 0, y: 900, width: 1_200, height: 875))
    let below = display(
      40,
      CGRect(x: 100, y: -900, width: 1_600, height: 900),
      visibleFrame: CGRect(x: 100, y: -850, width: 1_600, height: 850))
    let mixedHeight = display(
      50,
      CGRect(x: 1_440, y: -200, width: 1_000, height: 1_200),
      visibleFrame: CGRect(x: 1_440, y: -150, width: 1_000, height: 1_100))
    let displays = [mixedHeight, below, primary, above, negativeX]

    let fixtures: [(AttachmentDisplay, CGRect)] = [
      (primary, CGRect(x: 500, y: 200, width: 500, height: 500)),
      (negativeX, CGRect(x: -900, y: 200, width: 500, height: 500)),
      (above, CGRect(x: 400, y: 1_100, width: 400, height: 500)),
      (below, CGRect(x: 500, y: -700, width: 500, height: 500)),
      (mixedHeight, CGRect(x: 1_700, y: 0, width: 400, height: 700)),
    ]

    for (target, terminalFrame) in fixtures {
      for side in [AttachmentSide.left, .right] {
        let placement = assertFinalAndGhostAgree(
          request(
            cocoaTerminalFrame: terminalFrame,
            reference: primary,
            displays: displays,
            side: side,
            width: 180))
        XCTAssertEqual(placement.display.identifier, target.identifier)
        XCTAssertEqual(placement.terminalFrame, terminalFrame)
        XCTAssertEqual(placement.effectiveSide, side)
        XCTAssertEqual(placement.frame.height, terminalFrame.height)
        let expectedX = side == .left ? terminalFrame.minX - 180 : terminalFrame.maxX
        XCTAssertEqual(placement.frame.minX, expectedX)
        XCTAssertEqual(placement.frame.minY, terminalFrame.minY)
      }
    }
  }

  func testExplicitAXReferenceDoesNotFollowMainScreenOrEnumerationOrder() throws {
    let reference = display(100, CGRect(x: 0, y: 0, width: 1_440, height: 900))
    let possibleMainScreen = display(
      200,
      CGRect(x: -1_600, y: 250, width: 1_600, height: 1_200),
      visibleFrame: CGRect(x: -1_600, y: 250, width: 1_600, height: 1_175))
    let cocoaTerminal = CGRect(x: -1_200, y: 600, width: 600, height: 500)
    let axTerminal = axFrame(for: cocoaTerminal, reference: reference)

    XCTAssertEqual(
      planner.convertAXFrame(axTerminal, coordinateReferenceDisplay: reference),
      cocoaTerminal)

    let firstRequest = AttachmentPlacementRequest(
      axTerminalFrame: axTerminal,
      coordinateReferenceDisplay: reference,
      displays: [reference, possibleMainScreen],
      requestedSide: .left,
      shellMateWidth: 160)
    let changedMainOrderRequest = AttachmentPlacementRequest(
      axTerminalFrame: axTerminal,
      coordinateReferenceDisplay: reference,
      displays: [possibleMainScreen, reference],
      requestedSide: .left,
      shellMateWidth: 160)

    let first = try XCTUnwrap(planner.finalPlacement(for: firstRequest))
    let afterMainChange = try XCTUnwrap(planner.finalPlacement(for: changedMainOrderRequest))
    XCTAssertEqual(first, afterMainChange)
    XCTAssertEqual(first.terminalFrame, cocoaTerminal)
    XCTAssertEqual(first.display.identifier, possibleMainScreen.identifier)
  }

  func testRequestedSidesFallBackOnlyWhenOppositeSideFits() {
    let screen = display(1, CGRect(x: 0, y: 0, width: 1_000, height: 800))

    let rightWouldOverflow = assertFinalAndGhostAgree(
      request(
        cocoaTerminalFrame: CGRect(x: 700, y: 200, width: 250, height: 300),
        reference: screen,
        displays: [screen],
        side: .right,
        width: 200))
    XCTAssertEqual(rightWouldOverflow.requestedSide, .right)
    XCTAssertEqual(rightWouldOverflow.effectiveSide, .left)
    XCTAssertEqual(rightWouldOverflow.frame.minX, 500)

    let leftWouldOverflow = assertFinalAndGhostAgree(
      request(
        cocoaTerminalFrame: CGRect(x: 50, y: 200, width: 250, height: 300),
        reference: screen,
        displays: [screen],
        side: .left,
        width: 200))
    XCTAssertEqual(leftWouldOverflow.requestedSide, .left)
    XCTAssertEqual(leftWouldOverflow.effectiveSide, .right)
    XCTAssertEqual(leftWouldOverflow.frame.minX, 300)
  }

  func testNeitherSideFitsUsesGreaterClearanceAndRequestedSideOnTies() {
    let screen = display(1, CGRect(x: 0, y: 0, width: 1_000, height: 800))

    let greaterLeftClearance = assertFinalAndGhostAgree(
      request(
        cocoaTerminalFrame: CGRect(x: 350, y: 200, width: 400, height: 300),
        reference: screen,
        displays: [screen],
        side: .right,
        width: 400))
    XCTAssertEqual(greaterLeftClearance.requestedSide, .right)
    XCTAssertEqual(greaterLeftClearance.effectiveSide, .left)
    XCTAssertEqual(greaterLeftClearance.frame.minX, 0)

    let tiedTerminal = CGRect(x: 300, y: 200, width: 400, height: 300)
    let requestedLeft = assertFinalAndGhostAgree(
      request(
        cocoaTerminalFrame: tiedTerminal,
        reference: screen,
        displays: [screen],
        side: .left,
        width: 400))
    let requestedRight = assertFinalAndGhostAgree(
      request(
        cocoaTerminalFrame: tiedTerminal,
        reference: screen,
        displays: [screen],
        side: .right,
        width: 400))
    XCTAssertEqual(requestedLeft.effectiveSide, .left)
    XCTAssertEqual(requestedRight.effectiveSide, .right)
    // Fallback is part of the placement only; user intent remains unchanged.
    XCTAssertEqual(requestedLeft.requestedSide, .left)
    XCTAssertEqual(requestedRight.requestedSide, .right)
  }

  func testVisibleFrameInsetsPartialTerminalAndOversizedDimensionsAreClamped() {
    let screen = display(
      1,
      CGRect(x: 0, y: 0, width: 1_200, height: 1_000),
      visibleFrame: CGRect(x: 80, y: 60, width: 1_040, height: 900))

    let insetPlacement = assertFinalAndGhostAgree(
      request(
        cocoaTerminalFrame: CGRect(x: 850, y: 930, width: 250, height: 100),
        reference: screen,
        displays: [screen],
        side: .right,
        width: 200))
    XCTAssertEqual(insetPlacement.display.visibleFrame.minX, 80)
    XCTAssertEqual(insetPlacement.frame.maxY, 960)
    XCTAssertEqual(insetPlacement.frame.height, 100)
    XCTAssertEqual(insetPlacement.effectiveSide, .left)

    let partiallyOffScreen = assertFinalAndGhostAgree(
      request(
        cocoaTerminalFrame: CGRect(x: -100, y: -100, width: 400, height: 300),
        reference: screen,
        displays: [screen],
        side: .left,
        width: 240))
    XCTAssertEqual(partiallyOffScreen.frame.minY, screen.visibleFrame.minY)
    XCTAssertEqual(partiallyOffScreen.effectiveSide, .right)

    let oversized = assertFinalAndGhostAgree(
      request(
        cocoaTerminalFrame: CGRect(x: 300, y: -250, width: 500, height: 1_500),
        reference: screen,
        displays: [screen],
        side: .right,
        width: 5_000))
    XCTAssertEqual(oversized.frame, screen.visibleFrame)

    let heightMatching = assertFinalAndGhostAgree(
      request(
        cocoaTerminalFrame: CGRect(x: 350, y: 200, width: 400, height: 525),
        reference: screen,
        displays: [screen],
        side: .right,
        width: 150))
    XCTAssertEqual(heightMatching.frame.height, 525)
    XCTAssertEqual(heightMatching.frame.minY, 200)
  }

  func testLargestIntersectionSelectsDisplayForSpanningTerminal() {
    let left = display(1, CGRect(x: 0, y: 0, width: 1_000, height: 800))
    let right = display(
      2,
      CGRect(x: 1_000, y: -100, width: 1_200, height: 1_000),
      visibleFrame: CGRect(x: 1_000, y: -50, width: 1_200, height: 950))
    let terminal = CGRect(x: 850, y: 100, width: 600, height: 500)

    for order in [[left, right], [right, left]] {
      let placement = assertFinalAndGhostAgree(
        request(
          cocoaTerminalFrame: terminal,
          reference: left,
          displays: order,
          side: .right,
          width: 180))
      XCTAssertEqual(placement.display.identifier, right.identifier)
    }
  }

  func testNearestDisplayAndAllDisplaySelectionTiesAreStable() {
    let right = display(20, CGRect(x: 0, y: 0, width: 1_000, height: 1_000))
    let left = display(30, CGRect(x: -1_000, y: 0, width: 1_000, height: 1_000))

    let intersectingTie = CGRect(x: -100, y: 200, width: 200, height: 300)
    let nearestTie = CGRect(x: -100, y: 1_200, width: 200, height: 100)
    let nearestRight = CGRect(x: 1_500, y: 300, width: 100, height: 100)

    for displays in [[right, left], [left, right]] {
      let tiedIntersection = assertFinalAndGhostAgree(
        request(
          cocoaTerminalFrame: intersectingTie,
          reference: right,
          displays: displays,
          side: .left,
          width: 120))
      let tiedNearest = assertFinalAndGhostAgree(
        request(
          cocoaTerminalFrame: nearestTie,
          reference: right,
          displays: displays,
          side: .left,
          width: 120))
      let nearest = assertFinalAndGhostAgree(
        request(
          cocoaTerminalFrame: nearestRight,
          reference: right,
          displays: displays,
          side: .right,
          width: 120))

      // Geometric ordering is the stable tie breaker; it is independent of array order and ID.
      XCTAssertEqual(tiedIntersection.display.identifier, left.identifier)
      XCTAssertEqual(tiedNearest.display.identifier, left.identifier)
      XCTAssertEqual(nearest.display.identifier, right.identifier)
    }
  }

  func testFixedSeedMatrixIsFiniteContainedAndEnumerationIndependent() {
    var random = FixedSeedRandom(seed: 0x5EED_CAFE_BABE)

    for _ in 0..<300 {
      let primaryWidth = random.value(in: 900...1_800)
      let primaryHeight = random.value(in: 700...1_200)
      let primary = randomDisplay(
        identifier: 1,
        frame: CGRect(x: 0, y: 0, width: primaryWidth, height: primaryHeight),
        random: &random)

      let leftWidth = random.value(in: 700...1_600)
      let leftHeight = random.value(in: 600...1_300)
      let left = randomDisplay(
        identifier: 2,
        frame: CGRect(
          x: -leftWidth,
          y: random.value(in: -300...300),
          width: leftWidth,
          height: leftHeight),
        random: &random)

      let rightWidth = random.value(in: 700...1_700)
      let rightHeight = random.value(in: 600...1_300)
      let right = randomDisplay(
        identifier: 3,
        frame: CGRect(
          x: primaryWidth,
          y: random.value(in: -300...300),
          width: rightWidth,
          height: rightHeight),
        random: &random)

      let verticalWidth = random.value(in: 700...1_700)
      let verticalHeight = random.value(in: 600...1_200)
      let verticalAbove = random.boolean()
      let vertical = randomDisplay(
        identifier: 4,
        frame: CGRect(
          x: random.value(in: -400...400),
          y: verticalAbove ? primaryHeight : -verticalHeight,
          width: verticalWidth,
          height: verticalHeight),
        random: &random)

      let displays = [primary, left, right, vertical]
      let terminal = CGRect(
        x: random.value(in: Int(-leftWidth - 500)...Int(primaryWidth + rightWidth + 500)),
        y: random.value(in: Int(-verticalHeight - 500)...Int(primaryHeight + verticalHeight + 500)),
        width: random.value(in: 80...2_400),
        height: random.value(in: 80...1_800))
      let shellMateWidth = random.value(in: 80...2_500)

      let permutations = [
        displays,
        Array(displays.reversed()),
        [displays[2], displays[0], displays[3], displays[1]],
      ]

      for side in [AttachmentSide.left, .right] {
        let baselineRequest = request(
          cocoaTerminalFrame: terminal,
          reference: primary,
          displays: permutations[0],
          side: side,
          width: shellMateWidth)
        let baseline = assertFinalAndGhostAgree(baselineRequest)

        for permutation in permutations.dropFirst() {
          let permuted = assertFinalAndGhostAgree(
            request(
              cocoaTerminalFrame: terminal,
              reference: primary,
              displays: permutation,
              side: side,
              width: shellMateWidth))
          XCTAssertEqual(permuted, baseline)
        }
      }
    }
  }

  func testFloatingMissingAndInvalidGeometryReturnNoPlacement() {
    let valid = display(1, CGRect(x: 0, y: 0, width: 1_000, height: 800))
    let validAXFrame = CGRect(x: 100, y: 100, width: 400, height: 300)

    XCTAssertNil(
      planner.finalPlacement(
        for: AttachmentPlacementRequest(
          axTerminalFrame: validAXFrame,
          coordinateReferenceDisplay: valid,
          displays: [valid],
          requestedSide: .float,
          shellMateWidth: 200)))
    XCTAssertNil(
      planner.ghostPreview(
        for: AttachmentPlacementRequest(
          axTerminalFrame: validAXFrame,
          coordinateReferenceDisplay: valid,
          displays: [valid],
          requestedSide: .float,
          shellMateWidth: 200)))

    let invalidVisibleFrame = display(
      2,
      CGRect(x: 0, y: 0, width: 1_000, height: 800),
      visibleFrame: CGRect(x: -1, y: 0, width: 1_001, height: 800))
    let missingReference = display(99, CGRect(x: 2_000, y: 0, width: 1_000, height: 800))
    let nonFiniteDisplay = display(
      3,
      CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 800))
    let invalidFrames = [
      CGRect(x: CGFloat.nan, y: 100, width: 400, height: 300),
      CGRect(x: 100, y: CGFloat.infinity, width: 400, height: 300),
      CGRect(x: 100, y: 100, width: 0, height: 300),
      CGRect(x: 100, y: 100, width: 400, height: -1),
      CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: 400, height: 300),
    ]

    let invalidRequests = [
      AttachmentPlacementRequest(
        axTerminalFrame: validAXFrame,
        coordinateReferenceDisplay: valid,
        displays: [],
        requestedSide: .right,
        shellMateWidth: 200),
      AttachmentPlacementRequest(
        axTerminalFrame: validAXFrame,
        coordinateReferenceDisplay: missingReference,
        displays: [valid],
        requestedSide: .right,
        shellMateWidth: 200),
      AttachmentPlacementRequest(
        axTerminalFrame: validAXFrame,
        coordinateReferenceDisplay: valid,
        displays: [valid, valid],
        requestedSide: .right,
        shellMateWidth: 200),
      AttachmentPlacementRequest(
        axTerminalFrame: validAXFrame,
        coordinateReferenceDisplay: invalidVisibleFrame,
        displays: [invalidVisibleFrame],
        requestedSide: .right,
        shellMateWidth: 200),
      AttachmentPlacementRequest(
        axTerminalFrame: validAXFrame,
        coordinateReferenceDisplay: nonFiniteDisplay,
        displays: [nonFiniteDisplay],
        requestedSide: .right,
        shellMateWidth: 200),
      AttachmentPlacementRequest(
        axTerminalFrame: validAXFrame,
        coordinateReferenceDisplay: valid,
        displays: [valid],
        requestedSide: .right,
        shellMateWidth: .nan),
      AttachmentPlacementRequest(
        axTerminalFrame: validAXFrame,
        coordinateReferenceDisplay: valid,
        displays: [valid],
        requestedSide: .right,
        shellMateWidth: 0),
    ] + invalidFrames.map {
      AttachmentPlacementRequest(
        axTerminalFrame: $0,
        coordinateReferenceDisplay: valid,
        displays: [valid],
        requestedSide: .right,
        shellMateWidth: 200)
    }

    for invalidRequest in invalidRequests {
      XCTAssertNil(planner.finalPlacement(for: invalidRequest))
      XCTAssertNil(planner.ghostPreview(for: invalidRequest))
    }
  }

  private func randomDisplay(
    identifier: UInt32,
    frame: CGRect,
    random: inout FixedSeedRandom
  ) -> AttachmentDisplay {
    let leftInset = random.value(in: 0...40)
    let rightInset = random.value(in: 0...40)
    let bottomInset = random.value(in: 0...50)
    let topInset = random.value(in: 0...35)
    return display(
      identifier,
      frame,
      visibleFrame: CGRect(
        x: frame.minX + leftInset,
        y: frame.minY + bottomInset,
        width: frame.width - leftInset - rightInset,
        height: frame.height - bottomInset - topInset))
  }
}

private struct FixedSeedRandom {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func value(in range: ClosedRange<Int>) -> CGFloat {
    precondition(range.lowerBound <= range.upperBound)
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    let count = UInt64(range.upperBound - range.lowerBound + 1)
    return CGFloat(range.lowerBound + Int(state % count))
  }

  mutating func boolean() -> Bool {
    return value(in: 0...1) == 1
  }
}
