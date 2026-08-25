import Foundation

public protocol CredentialValidating: Sendable {
  func validate(candidate: String) async throws
}

public enum CredentialChange: Equatable, Sendable {
  case replaced
  case removed
}

public protocol CredentialRefreshHandling: Sendable {
  func refreshCredentialConfiguration(after change: CredentialChange)
}

public enum CredentialEvent: Equatable, Sendable {
  case validationStarted
  case validationSucceeded
  case validationRejected
  case persistenceFailed
  case replacementCommitted
  case removalSucceeded
  case removalFailed
  case supersededResultIgnored
}

public protocol CredentialEventReporting: Sendable {
  func reportCredentialEvent(_ event: CredentialEvent)
}

public struct NoOpCredentialRefresher: CredentialRefreshHandling {
  public init() {}
  public func refreshCredentialConfiguration(after change: CredentialChange) {}
}

public struct NoOpCredentialEventReporter: CredentialEventReporting {
  public init() {}
  public func reportCredentialEvent(_ event: CredentialEvent) {}
}

public enum CredentialValidationStatus: Equatable, Sendable {
  case unverified
  case validating
  case valid
  case invalid
}

public struct CredentialEditorSnapshot: Equatable, Sendable {
  public let validationStatus: CredentialValidationStatus
  public let failure: CredentialFailure?
  public let hasActiveCredential: Bool
  public let isRevealed: Bool
}

public enum CredentialEditResult: Equatable, Sendable {
  case committed
  case rejected(CredentialFailure)
  case superseded
}

public enum CredentialRemovalResult: Equatable, Sendable {
  case removed
  case rejected(CredentialFailure)
}

/// An opaque request deliberately has no printable candidate representation. It is prepared
/// synchronously when an edit occurs, so an earlier asynchronous validation is superseded at the
/// instant the user edits again, not merely when a later debounce fires.
public final class CredentialReplacementRequest: @unchecked Sendable, CustomStringConvertible {
  fileprivate let revision: UInt64
  fileprivate let candidate: String

  public var isEmpty: Bool { candidate.isEmpty }
  public var description: String { "<credential replacement request>" }

  fileprivate init(revision: UInt64, candidate: String) {
    self.revision = revision
    self.candidate = candidate
  }
}

/// Coordinates candidate validation and persistence as one linearizable transaction.
///
/// The lock is never held across validation. It is held for the short commit/refresh section so a
/// removal or newer edit cannot race between the stale-result check and persistence.
public final class CredentialEditor: @unchecked Sendable {
  private let runtime: CredentialRuntime
  private let validator: any CredentialValidating
  private let refresher: any CredentialRefreshHandling
  private let reporter: any CredentialEventReporting
  private let lock = NSLock()

  private var revision: UInt64 = 0
  private var validationStatus: CredentialValidationStatus
  private var failure: CredentialFailure?
  private var presentation = CredentialPresentation()

  public init(
    runtime: CredentialRuntime,
    validator: any CredentialValidating,
    refresher: any CredentialRefreshHandling = NoOpCredentialRefresher(),
    reporter: any CredentialEventReporting = NoOpCredentialEventReporter()
  ) {
    self.runtime = runtime
    self.validator = validator
    self.refresher = refresher
    self.reporter = reporter
    self.validationStatus = runtime.activeCredential() == nil ? .unverified : .valid
  }

  @discardableResult
  public func prepareReplacement(_ candidate: String) -> CredentialReplacementRequest {
    let sanitized = CredentialSanitizer.sanitize(candidate)
    return lock.withLock {
      revision &+= 1
      failure = sanitized.isEmpty ? .emptyCandidate : nil
      validationStatus = sanitized.isEmpty ? .invalid : .validating
      return CredentialReplacementRequest(revision: revision, candidate: sanitized)
    }
  }

  public func validateAndReplace(_ request: CredentialReplacementRequest) async
    -> CredentialEditResult
  {
    guard !request.candidate.isEmpty else {
      return finishRejectedRequest(request, failure: .emptyCandidate, event: .validationRejected)
    }

    reporter.reportCredentialEvent(.validationStarted)
    do {
      try await validator.validate(candidate: request.candidate)
    } catch {
      // Never propagate or report an underlying validation error: providers and test doubles may
      // include the submitted secret in their descriptions.
      return finishRejectedRequest(request, failure: .validationRejected, event: .validationRejected)
    }

    return lock.withLock {
      guard request.revision == revision else {
        reporter.reportCredentialEvent(.supersededResultIgnored)
        return .superseded
      }

      do {
        try runtime.replaceCredential(with: request.candidate)
      } catch let credentialFailure as CredentialFailure {
        validationStatus = .invalid
        failure = credentialFailure
        reporter.reportCredentialEvent(.persistenceFailed)
        return .rejected(credentialFailure)
      } catch {
        validationStatus = .invalid
        failure = .credentialStoreUnavailable
        reporter.reportCredentialEvent(.persistenceFailed)
        return .rejected(.credentialStoreUnavailable)
      }

      validationStatus = .valid
      failure = nil
      reporter.reportCredentialEvent(.validationSucceeded)
      reporter.reportCredentialEvent(.replacementCommitted)
      refresher.refreshCredentialConfiguration(after: .replaced)
      return .committed
    }
  }

  public func removeCredential() -> CredentialRemovalResult {
    lock.withLock {
      revision &+= 1
      do {
        try runtime.removeCredential()
      } catch let credentialFailure as CredentialFailure {
        validationStatus = runtime.activeCredential() == nil ? .unverified : .invalid
        failure = credentialFailure
        reporter.reportCredentialEvent(.removalFailed)
        return .rejected(credentialFailure)
      } catch {
        validationStatus = runtime.activeCredential() == nil ? .unverified : .invalid
        failure = .credentialRemovalFailed
        reporter.reportCredentialEvent(.removalFailed)
        return .rejected(.credentialRemovalFailed)
      }

      validationStatus = .unverified
      failure = nil
      presentation.hide()
      reporter.reportCredentialEvent(.removalSucceeded)
      refresher.refreshCredentialConfiguration(after: .removed)
      return .removed
    }
  }

  public func toggleCredentialVisibility() -> Bool {
    lock.withLock {
      presentation.toggle()
      return presentation.isRevealed
    }
  }

  public func hideCredential() {
    lock.withLock {
      presentation.hide()
    }
  }

  public func snapshot() -> CredentialEditorSnapshot {
    lock.withLock {
      CredentialEditorSnapshot(
        validationStatus: validationStatus,
        failure: failure,
        hasActiveCredential: runtime.activeCredential() != nil,
        isRevealed: presentation.isRevealed
      )
    }
  }

  private func finishRejectedRequest(
    _ request: CredentialReplacementRequest,
    failure requestFailure: CredentialFailure,
    event: CredentialEvent
  ) -> CredentialEditResult {
    lock.withLock {
      guard request.revision == revision else {
        reporter.reportCredentialEvent(.supersededResultIgnored)
        return .superseded
      }
      validationStatus = .invalid
      failure = requestFailure
      reporter.reportCredentialEvent(event)
      return .rejected(requestFailure)
    }
  }
}

private extension NSLock {
  func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
    lock()
    defer { unlock() }
    return try body()
  }
}
