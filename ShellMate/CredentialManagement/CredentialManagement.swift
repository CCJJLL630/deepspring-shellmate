import Foundation

public enum CredentialSanitizer {
  /// OpenAI credentials never contain whitespace. Removing all whitespace also handles copied keys
  /// that contain line wrapping, rather than validating a value different from the one displayed.
  public static func sanitize(_ candidate: String) -> String {
    candidate.filter { !$0.isWhitespace }
  }
}

public enum LegacyCredentialValue: Equatable, Sendable {
  case missing
  case string(String)
  case malformed
}

public protocol CredentialStore: Sendable {
  func readCredential() throws -> String?
  func writeCredential(_ credential: String) throws
  func deleteCredential() throws
}

public protocol LegacyCredentialPreferences: Sendable {
  func readLegacyCredential() throws -> LegacyCredentialValue
  func removeLegacyCredential() throws
}

public enum CredentialFailure: Error, Equatable, Sendable {
  case emptyCandidate
  case validationRejected
  case credentialStoreUnavailable
  case credentialVerificationFailed
  case credentialRemovalFailed
  case legacyPreferenceUnavailable
  case legacyPreferenceCleanupFailed

  public var userMessage: String {
    switch self {
    case .emptyCandidate:
      return "Enter an API key before validating it."
    case .validationRejected:
      return "The API key could not be validated. Your current key is unchanged."
    case .credentialStoreUnavailable, .credentialVerificationFailed:
      return "The API key could not be saved securely. Your current key is unchanged."
    case .credentialRemovalFailed:
      return "The API key could not be removed from Keychain. Your current key is unchanged."
    case .legacyPreferenceUnavailable, .legacyPreferenceCleanupFailed:
      return "The previous API key preference could not be migrated securely."
    }
  }
}

extension CredentialFailure: LocalizedError {
  public var errorDescription: String? { userMessage }
}

public enum CredentialMigrationResult: Equatable, Sendable {
  case noCredential
  case loadedExistingCredential
  case migratedLegacyCredential
  case removedEmptyLegacyCredential
  case removedMalformedLegacyCredential
  case failed(CredentialFailure)
}

/// Owns the active credential and is the only object allowed to commit Keychain changes.
///
/// The in-memory value is changed only after a write has been read back exactly. Callers asking for
/// authorization while a replacement is in progress continue to receive the previous credential.
public final class CredentialRuntime: @unchecked Sendable {
  private let store: any CredentialStore
  private let legacyPreferences: any LegacyCredentialPreferences
  private let operationLock = NSLock()
  private let stateLock = NSLock()
  private var activeCredentialStorage: String?

  public let migrationResult: CredentialMigrationResult

  public init(
    store: any CredentialStore,
    legacyPreferences: any LegacyCredentialPreferences
  ) {
    self.store = store
    self.legacyPreferences = legacyPreferences

    let bootstrap = Self.bootstrap(store: store, legacyPreferences: legacyPreferences)
    self.activeCredentialStorage = bootstrap.credential
    self.migrationResult = bootstrap.result
  }

  public func activeCredential() -> String? {
    stateLock.withLock { activeCredentialStorage }
  }

  public func credentialForAuthorization(fallback: String) -> String {
    activeCredential() ?? fallback
  }

  /// Commits an already validated value. The value is sanitized again defensively so persistence,
  /// the active session, and authorization all use exactly the same bytes.
  public func replaceCredential(with candidate: String) throws {
    let sanitized = CredentialSanitizer.sanitize(candidate)
    guard !sanitized.isEmpty else { throw CredentialFailure.emptyCandidate }

    try operationLock.withLock {
      let previous = activeCredential()
      do {
        try store.writeCredential(sanitized)
      } catch {
        throw CredentialFailure.credentialStoreUnavailable
      }

      do {
        guard try store.readCredential() == sanitized else {
          rollback(to: previous)
          throw CredentialFailure.credentialVerificationFailed
        }
      } catch let failure as CredentialFailure {
        throw failure
      } catch {
        rollback(to: previous)
        throw CredentialFailure.credentialStoreUnavailable
      }

      stateLock.withLock {
        activeCredentialStorage = sanitized
      }
    }
  }

  /// Deleting an item that is not present is a successful, idempotent operation.
  public func removeCredential() throws {
    try operationLock.withLock {
      let previous = activeCredential()
      do {
        try store.deleteCredential()
      } catch {
        throw CredentialFailure.credentialRemovalFailed
      }

      do {
        guard try store.readCredential() == nil else {
          throw CredentialFailure.credentialRemovalFailed
        }
      } catch {
        // If deletion succeeded but verification was unavailable, restore the last known credential
        // when possible rather than silently changing the persisted credential.
        if let previous { try? store.writeCredential(previous) }
        throw CredentialFailure.credentialRemovalFailed
      }

      stateLock.withLock {
        activeCredentialStorage = nil
      }
    }
  }

  private func rollback(to previous: String?) {
    if let previous {
      try? store.writeCredential(previous)
    } else {
      try? store.deleteCredential()
    }
  }

  private static func bootstrap(
    store: any CredentialStore,
    legacyPreferences: any LegacyCredentialPreferences
  ) -> (credential: String?, result: CredentialMigrationResult) {
    let existing: String?
    do {
      existing = try store.readCredential()
    } catch {
      // A locked or denied Keychain must not cause the plaintext fallback to be discarded.
      return (nil, .failed(.credentialStoreUnavailable))
    }

    if let existing {
      let sanitized = CredentialSanitizer.sanitize(existing)
      if !sanitized.isEmpty {
        do {
          let legacy = try legacyPreferences.readLegacyCredential()
          if legacy != .missing {
            try legacyPreferences.removeLegacyCredential()
          }
          return (sanitized, .loadedExistingCredential)
        } catch {
          return (sanitized, .failed(.legacyPreferenceCleanupFailed))
        }
      }
    }

    let legacy: LegacyCredentialValue
    do {
      legacy = try legacyPreferences.readLegacyCredential()
    } catch {
      return (nil, .failed(.legacyPreferenceUnavailable))
    }

    switch legacy {
    case .missing:
      return (nil, .noCredential)

    case .malformed:
      do {
        try legacyPreferences.removeLegacyCredential()
        return (nil, .removedMalformedLegacyCredential)
      } catch {
        return (nil, .failed(.legacyPreferenceCleanupFailed))
      }

    case .string(let legacyCredential):
      let sanitized = CredentialSanitizer.sanitize(legacyCredential)
      guard !sanitized.isEmpty else {
        do {
          try legacyPreferences.removeLegacyCredential()
          return (nil, .removedEmptyLegacyCredential)
        } catch {
          return (nil, .failed(.legacyPreferenceCleanupFailed))
        }
      }

      do {
        try store.writeCredential(sanitized)
      } catch {
        // In particular, retain the valid legacy preference when Keychain storage is denied.
        return (nil, .failed(.credentialStoreUnavailable))
      }

      do {
        guard try store.readCredential() == sanitized else {
          try? store.deleteCredential()
          return (nil, .failed(.credentialVerificationFailed))
        }
      } catch {
        try? store.deleteCredential()
        return (nil, .failed(.credentialStoreUnavailable))
      }

      do {
        try legacyPreferences.removeLegacyCredential()
        return (sanitized, .migratedLegacyCredential)
      } catch {
        // The secure credential is usable, but report that plaintext cleanup still needs attention.
        return (sanitized, .failed(.legacyPreferenceCleanupFailed))
      }
    }
  }
}

public enum OpenAIAuthorization {
  public static func headers(for credential: String) -> [String: String] {
    [
      "Content-Type": "application/json",
      "Authorization": "Bearer \(credential)",
      "OpenAI-Beta": "assistants=v2",
    ]
  }
}

public struct CredentialPresentation: Equatable, Sendable {
  public private(set) var isRevealed: Bool

  public init(isRevealed: Bool = false) {
    self.isRevealed = isRevealed
  }

  public mutating func toggle() {
    isRevealed.toggle()
  }

  public mutating func hide() {
    isRevealed = false
  }

  public func presentedValue(for credential: String) -> String {
    isRevealed ? credential : String(repeating: "•", count: 12)
  }
}

private extension NSLock {
  func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
    lock()
    defer { unlock() }
    return try body()
  }
}
