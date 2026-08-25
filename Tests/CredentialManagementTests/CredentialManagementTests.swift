import Foundation
import XCTest
@testable import CredentialManagement

final class CredentialMigrationTests: XCTestCase {
  func testLegacyOnlyMigrationSanitizesVerifiesAndDeletesPreferenceExactlyOnce() {
    let store = RecordingCredentialStore()
    let preferences = RecordingLegacyPreferences(.string("  sk-legacy\n-key  "))

    let runtime = CredentialRuntime(store: store, legacyPreferences: preferences)

    XCTAssertEqual(runtime.migrationResult, .migratedLegacyCredential)
    XCTAssertEqual(runtime.activeCredential(), "sk-legacy-key")
    XCTAssertEqual(store.storedCredential, "sk-legacy-key")
    XCTAssertEqual(store.readCount, 2)
    XCTAssertEqual(store.writeCount, 1)
    XCTAssertEqual(preferences.removeCount, 1)
    XCTAssertEqual(preferences.value, .missing)
  }

  func testKeychainOnlyCredentialLoadsAfterRelaunchWithoutWriting() {
    let store = RecordingCredentialStore(storedCredential: "sk-keychain-only")
    let preferences = RecordingLegacyPreferences(.missing)

    let firstLaunch = CredentialRuntime(store: store, legacyPreferences: preferences)
    let secondLaunch = CredentialRuntime(store: store, legacyPreferences: preferences)

    XCTAssertEqual(firstLaunch.migrationResult, .loadedExistingCredential)
    XCTAssertEqual(secondLaunch.migrationResult, .loadedExistingCredential)
    XCTAssertEqual(secondLaunch.activeCredential(), "sk-keychain-only")
    XCTAssertEqual(store.writeCount, 0)
    XCTAssertEqual(preferences.removeCount, 0)
  }

  func testConflictingKeychainCredentialWinsAndPlaintextIsRemoved() {
    let store = RecordingCredentialStore(storedCredential: "sk-secure-existing")
    let preferences = RecordingLegacyPreferences(.string("sk-legacy-conflict"))

    let runtime = CredentialRuntime(store: store, legacyPreferences: preferences)

    XCTAssertEqual(runtime.activeCredential(), "sk-secure-existing")
    XCTAssertEqual(runtime.migrationResult, .loadedExistingCredential)
    XCTAssertEqual(store.writeCount, 0)
    XCTAssertEqual(preferences.value, .missing)
    XCTAssertEqual(preferences.removeCount, 1)
  }

  func testEmptyAndMalformedLegacyValuesAreRemovedWithoutKeychainWrites() {
    let emptyStore = RecordingCredentialStore()
    let emptyPreferences = RecordingLegacyPreferences(.string(" \n\t "))
    let emptyRuntime = CredentialRuntime(
      store: emptyStore, legacyPreferences: emptyPreferences
    )
    XCTAssertEqual(emptyRuntime.migrationResult, .removedEmptyLegacyCredential)
    XCTAssertNil(emptyRuntime.activeCredential())
    XCTAssertEqual(emptyStore.writeCount, 0)
    XCTAssertEqual(emptyPreferences.removeCount, 1)

    let malformedStore = RecordingCredentialStore()
    let malformedPreferences = RecordingLegacyPreferences(.malformed)
    let malformedRuntime = CredentialRuntime(
      store: malformedStore, legacyPreferences: malformedPreferences
    )
    XCTAssertEqual(malformedRuntime.migrationResult, .removedMalformedLegacyCredential)
    XCTAssertNil(malformedRuntime.activeCredential())
    XCTAssertEqual(malformedStore.writeCount, 0)
    XCTAssertEqual(malformedPreferences.removeCount, 1)
  }

  func testRepeatedMigrationIsIdempotent() {
    let store = RecordingCredentialStore()
    let preferences = RecordingLegacyPreferences(.string("sk-once"))

    let firstLaunch = CredentialRuntime(store: store, legacyPreferences: preferences)
    let secondLaunch = CredentialRuntime(store: store, legacyPreferences: preferences)

    XCTAssertEqual(firstLaunch.migrationResult, .migratedLegacyCredential)
    XCTAssertEqual(secondLaunch.migrationResult, .loadedExistingCredential)
    XCTAssertEqual(secondLaunch.activeCredential(), "sk-once")
    XCTAssertEqual(store.writeCount, 1)
    XCTAssertEqual(preferences.removeCount, 1)
  }

  func testFailedLegacyWriteRetainsOriginalPreferenceAndDoesNotActivateCandidate() {
    let secret = "  sk-must-survive-write-failure  "
    let store = RecordingCredentialStore()
    store.writeError = SecretFailure(secret)
    let preferences = RecordingLegacyPreferences(.string(secret))

    let runtime = CredentialRuntime(store: store, legacyPreferences: preferences)

    XCTAssertEqual(runtime.migrationResult, .failed(.credentialStoreUnavailable))
    XCTAssertNil(runtime.activeCredential())
    XCTAssertNil(store.storedCredential)
    XCTAssertEqual(preferences.value, .string(secret))
    XCTAssertEqual(preferences.removeCount, 0)
  }

  func testLockedOrMalformedKeychainReadRetainsLegacyPreferenceWithoutCrashing() {
    let secret = "sk-retained-while-keychain-locked"
    let store = RecordingCredentialStore()
    store.readError = SecretFailure(secret)
    let preferences = RecordingLegacyPreferences(.string(secret))

    let runtime = CredentialRuntime(store: store, legacyPreferences: preferences)

    XCTAssertEqual(runtime.migrationResult, .failed(.credentialStoreUnavailable))
    XCTAssertNil(runtime.activeCredential())
    XCTAssertEqual(preferences.value, .string(secret))
    XCTAssertEqual(store.writeCount, 0)
    XCTAssertEqual(preferences.removeCount, 0)
  }

  func testFailedVerificationRetainsLegacyPreferenceAndRemovesUnverifiedItem() {
    let store = RecordingCredentialStore()
    store.readOverrideAfterWrite = "different-value"
    let preferences = RecordingLegacyPreferences(.string("sk-legacy"))

    let runtime = CredentialRuntime(store: store, legacyPreferences: preferences)

    XCTAssertEqual(runtime.migrationResult, .failed(.credentialVerificationFailed))
    XCTAssertNil(runtime.activeCredential())
    XCTAssertEqual(preferences.value, .string("sk-legacy"))
    XCTAssertEqual(store.writeCount, 1)
    XCTAssertEqual(store.deleteCount, 1)
  }
}

final class CredentialEditorTests: XCTestCase {
  func testSuccessfulReplacementValidatesAndPersistsExactSanitizedCandidateOnce() async {
    let store = RecordingCredentialStore(storedCredential: "sk-current")
    let preferences = RecordingLegacyPreferences(.missing)
    let runtime = CredentialRuntime(store: store, legacyPreferences: preferences)
    store.resetOperationCounts()
    let validator = RecordingValidator()
    let refresher = RecordingRefresher()
    let reporter = RecordingReporter()
    let editor = CredentialEditor(
      runtime: runtime, validator: validator, refresher: refresher, reporter: reporter
    )

    let request = editor.prepareReplacement(" \n sk-new\t-candidate \r")
    let result = await editor.validateAndReplace(request)

    XCTAssertEqual(result, .committed)
    let validatedCandidates = await validator.candidates
    XCTAssertEqual(validatedCandidates, ["sk-new-candidate"])
    XCTAssertEqual(store.storedCredential, "sk-new-candidate")
    XCTAssertEqual(runtime.activeCredential(), "sk-new-candidate")
    XCTAssertEqual(
      runtime.credentialForAuthorization(fallback: "free-tier"), "sk-new-candidate"
    )
    XCTAssertEqual(
      OpenAIAuthorization.headers(for: runtime.credentialForAuthorization(fallback: "free-tier"))[
        "Authorization"
      ],
      "Bearer sk-new-candidate"
    )
    XCTAssertEqual(store.writeCount, 1)
    XCTAssertEqual(store.readCount, 1)
    XCTAssertEqual(refresher.changes, [.replaced])
    XCTAssertEqual(reporter.events.filter { $0 == .replacementCommitted }.count, 1)
  }

  func testInvalidAndFailedValidationNeverReplaceActiveCredential() async {
    for secret in ["sk-invalid-draft", "sk-transport-failed-draft"] {
      let store = RecordingCredentialStore(storedCredential: "sk-still-active")
      let runtime = CredentialRuntime(
        store: store, legacyPreferences: RecordingLegacyPreferences(.missing)
      )
      store.resetOperationCounts()
      let validator = RecordingValidator(error: SecretFailure(secret))
      let refresher = RecordingRefresher()
      let editor = CredentialEditor(runtime: runtime, validator: validator, refresher: refresher)

      let result = await editor.validateAndReplace(editor.prepareReplacement(secret))

      XCTAssertEqual(result, .rejected(.validationRejected))
      XCTAssertEqual(runtime.activeCredential(), "sk-still-active")
      XCTAssertEqual(store.storedCredential, "sk-still-active")
      XCTAssertEqual(store.writeCount, 0)
      XCTAssertEqual(refresher.changes, [])
    }
  }

  func testStorageFailureLeavesActiveCredentialAndRefreshUnchanged() async {
    let store = RecordingCredentialStore(storedCredential: "sk-active")
    let runtime = CredentialRuntime(
      store: store, legacyPreferences: RecordingLegacyPreferences(.missing)
    )
    store.resetOperationCounts()
    store.writeError = SecretFailure("sk-failed-write")
    let refresher = RecordingRefresher()
    let editor = CredentialEditor(
      runtime: runtime, validator: RecordingValidator(), refresher: refresher
    )

    let result = await editor.validateAndReplace(
      editor.prepareReplacement("sk-failed-write")
    )

    XCTAssertEqual(result, .rejected(.credentialStoreUnavailable))
    XCTAssertEqual(runtime.activeCredential(), "sk-active")
    XCTAssertEqual(store.storedCredential, "sk-active")
    XCTAssertEqual(store.writeCount, 1)
    XCTAssertEqual(store.readCount, 0)
    XCTAssertTrue(refresher.changes.isEmpty)
  }

  func testOutOfOrderValidationsOnlyAllowNewestCandidateToCommit() async throws {
    let store = RecordingCredentialStore(storedCredential: "sk-original")
    let runtime = CredentialRuntime(
      store: store, legacyPreferences: RecordingLegacyPreferences(.missing)
    )
    store.resetOperationCounts()
    let validator = ControlledValidator()
    let refresher = RecordingRefresher()
    let editor = CredentialEditor(runtime: runtime, validator: validator, refresher: refresher)

    let firstRequest = editor.prepareReplacement("sk-first")
    let firstTask = Task { await editor.validateAndReplace(firstRequest) }
    try await validator.waitForCandidates(1)

    let secondRequest = editor.prepareReplacement("sk-second")
    let secondTask = Task { await editor.validateAndReplace(secondRequest) }
    try await validator.waitForCandidates(2)

    await validator.complete(candidate: "sk-second", result: .success(()))
    let secondResult = await secondTask.value
    XCTAssertEqual(secondResult, .committed)
    await validator.complete(candidate: "sk-first", result: .success(()))
    let firstResult = await firstTask.value
    XCTAssertEqual(firstResult, .superseded)

    XCTAssertEqual(runtime.activeCredential(), "sk-second")
    XCTAssertEqual(store.storedCredential, "sk-second")
    XCTAssertEqual(store.writeCount, 1)
    XCTAssertEqual(store.readCount, 1)
    XCTAssertEqual(refresher.changes, [.replaced])
  }

  func testNewEditSupersedesLateFailureWithoutChangingStateOrPersistence() async throws {
    let store = RecordingCredentialStore(storedCredential: "sk-active")
    let runtime = CredentialRuntime(
      store: store, legacyPreferences: RecordingLegacyPreferences(.missing)
    )
    store.resetOperationCounts()
    let validator = ControlledValidator()
    let editor = CredentialEditor(runtime: runtime, validator: validator)

    let first = editor.prepareReplacement("sk-old-draft")
    let task = Task { await editor.validateAndReplace(first) }
    try await validator.waitForCandidates(1)
    _ = editor.prepareReplacement("sk-new-unvalidated-draft")
    await validator.complete(
      candidate: "sk-old-draft", result: .failure(SecretFailure("sk-old-draft"))
    )

    let result = await task.value
    XCTAssertEqual(result, .superseded)
    XCTAssertEqual(runtime.activeCredential(), "sk-active")
    XCTAssertEqual(store.writeCount, 0)
  }

  func testRemovalDuringValidationPreventsStaleCompletionFromRestoringKey() async throws {
    let store = RecordingCredentialStore(storedCredential: "sk-active")
    let runtime = CredentialRuntime(
      store: store, legacyPreferences: RecordingLegacyPreferences(.missing)
    )
    store.resetOperationCounts()
    let validator = ControlledValidator()
    let refresher = RecordingRefresher()
    let editor = CredentialEditor(runtime: runtime, validator: validator, refresher: refresher)

    let request = editor.prepareReplacement("sk-late")
    let validationTask = Task { await editor.validateAndReplace(request) }
    try await validator.waitForCandidates(1)

    XCTAssertEqual(editor.removeCredential(), .removed)
    await validator.complete(candidate: "sk-late", result: .success(()))
    let validationResult = await validationTask.value
    XCTAssertEqual(validationResult, .superseded)

    XCTAssertNil(runtime.activeCredential())
    XCTAssertNil(store.storedCredential)
    XCTAssertEqual(store.deleteCount, 1)
    XCTAssertEqual(store.writeCount, 0)
    XCTAssertEqual(refresher.changes, [.removed])
    XCTAssertEqual(runtime.credentialForAuthorization(fallback: "free-tier-key"), "free-tier-key")
  }

  func testRemovalAndAbsentRemovalAreIdempotentWithExactSideEffects() {
    let store = RecordingCredentialStore(storedCredential: "sk-active")
    let runtime = CredentialRuntime(
      store: store, legacyPreferences: RecordingLegacyPreferences(.missing)
    )
    store.resetOperationCounts()
    let refresher = RecordingRefresher()
    let editor = CredentialEditor(
      runtime: runtime, validator: RecordingValidator(), refresher: refresher
    )

    XCTAssertEqual(editor.removeCredential(), .removed)
    XCTAssertEqual(editor.removeCredential(), .removed)

    XCTAssertNil(runtime.activeCredential())
    XCTAssertEqual(store.deleteCount, 2)
    XCTAssertEqual(store.readCount, 2)
    XCTAssertEqual(refresher.changes, [.removed, .removed])
  }

  func testDeletionFailureLeavesCredentialActiveAndDoesNotRefresh() {
    let store = RecordingCredentialStore(storedCredential: "sk-active")
    let runtime = CredentialRuntime(
      store: store, legacyPreferences: RecordingLegacyPreferences(.missing)
    )
    store.resetOperationCounts()
    store.deleteError = SecretFailure("sk-active")
    let refresher = RecordingRefresher()
    let editor = CredentialEditor(
      runtime: runtime, validator: RecordingValidator(), refresher: refresher
    )

    XCTAssertEqual(editor.removeCredential(), .rejected(.credentialRemovalFailed))
    XCTAssertEqual(runtime.activeCredential(), "sk-active")
    XCTAssertEqual(store.storedCredential, "sk-active")
    XCTAssertEqual(store.deleteCount, 1)
    XCTAssertTrue(refresher.changes.isEmpty)
  }

  func testMaskedAndRevealedPresentationRequiresExplicitToggle() {
    let secret = "sk-presentation-secret"
    var presentation = CredentialPresentation()

    XCTAssertFalse(presentation.isRevealed)
    XCTAssertFalse(presentation.presentedValue(for: secret).contains(secret))
    XCTAssertFalse(presentation.presentedValue(for: secret).contains("presentation"))

    presentation.toggle()
    XCTAssertTrue(presentation.isRevealed)
    XCTAssertEqual(presentation.presentedValue(for: secret), secret)

    presentation.hide()
    XCTAssertFalse(presentation.isRevealed)
    XCTAssertFalse(presentation.presentedValue(for: secret).contains(secret))
  }

  func testSecretBearingFailuresAreNotDisclosedByErrorsRequestsEventsOrPreferences() async {
    let secret = "sk-known-secret-MUST-NOT-LEAK"
    let store = RecordingCredentialStore(storedCredential: "sk-existing")
    let preferences = RecordingLegacyPreferences(.missing)
    let runtime = CredentialRuntime(store: store, legacyPreferences: preferences)
    store.resetOperationCounts()
    let reporter = RecordingReporter()
    let request = CredentialEditor(
      runtime: runtime,
      validator: RecordingValidator(error: SecretFailure(secret)),
      reporter: reporter
    ).prepareReplacement(" \n\(secret)\t")
    let editor = CredentialEditor(
      runtime: runtime,
      validator: RecordingValidator(error: SecretFailure(secret)),
      reporter: reporter
    )
    let editorRequest = editor.prepareReplacement(" \n\(secret)\t")

    let result = await editor.validateAndReplace(editorRequest)
    let disclosedText = [
      String(describing: result),
      String(describing: CredentialFailure.validationRejected),
      CredentialFailure.validationRejected.localizedDescription,
      request.description,
      reporter.events.map(String.init(describing:)).joined(separator: " "),
      String(describing: preferences.value),
    ].joined(separator: " | ")

    XCTAssertEqual(result, .rejected(.validationRejected))
    XCTAssertFalse(disclosedText.contains(secret), disclosedText)
    XCTAssertEqual(store.writeCount, 0)
    XCTAssertEqual(preferences.value, .missing)
  }
}

#if canImport(Security) && os(macOS)
  final class MacOSKeychainCredentialStoreIntegrationTests: XCTestCase {
    func testIsolatedGenericPasswordRoundTripReplacementAndIdempotentCleanup() throws {
      let service = "ai.deepspring.ShellMate.tests.\(UUID().uuidString)"
      let account = "isolated-openai-credential"
      let store = MacOSKeychainCredentialStore(service: service, account: account)

      try? store.deleteCredential()
      defer { try? store.deleteCredential() }

      XCTAssertNil(try store.readCredential())
      try store.writeCredential("sk-integration-first")
      XCTAssertEqual(try store.readCredential(), "sk-integration-first")
      try store.writeCredential("sk-integration-replacement")
      XCTAssertEqual(try store.readCredential(), "sk-integration-replacement")
      try store.deleteCredential()
      XCTAssertNil(try store.readCredential())
      XCTAssertNoThrow(try store.deleteCredential())
    }
  }
#endif

private struct SecretFailure: Error, CustomStringConvertible, LocalizedError, @unchecked Sendable {
  let secret: String

  init(_ secret: String) {
    self.secret = secret
  }

  var description: String { "Failure echoed secret: \(secret)" }
  var errorDescription: String? { description }
}

private final class RecordingCredentialStore: CredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: String?
  private var reads = 0
  private var writes = 0
  private var deletes = 0
  private var writesSinceReset = 0

  var readError: Error?
  var writeError: Error?
  var deleteError: Error?
  var readOverrideAfterWrite: String?

  init(storedCredential: String? = nil) {
    self.storage = storedCredential
  }

  var storedCredential: String? { lock.withLock { storage } }
  var readCount: Int { lock.withLock { reads } }
  var writeCount: Int { lock.withLock { writes } }
  var deleteCount: Int { lock.withLock { deletes } }

  func readCredential() throws -> String? {
    try lock.withLock {
      reads += 1
      if let readError { throw readError }
      if writesSinceReset > 0, let readOverrideAfterWrite { return readOverrideAfterWrite }
      return storage
    }
  }

  func writeCredential(_ credential: String) throws {
    try lock.withLock {
      writes += 1
      writesSinceReset += 1
      if let writeError { throw writeError }
      storage = credential
    }
  }

  func deleteCredential() throws {
    try lock.withLock {
      deletes += 1
      if let deleteError { throw deleteError }
      storage = nil
    }
  }

  func resetOperationCounts() {
    lock.withLock {
      reads = 0
      writes = 0
      deletes = 0
      writesSinceReset = 0
    }
  }
}

private final class RecordingLegacyPreferences: LegacyCredentialPreferences, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: LegacyCredentialValue
  private var removals = 0

  init(_ value: LegacyCredentialValue) {
    self.storage = value
  }

  var value: LegacyCredentialValue { lock.withLock { storage } }
  var removeCount: Int { lock.withLock { removals } }

  func readLegacyCredential() throws -> LegacyCredentialValue {
    lock.withLock { storage }
  }

  func removeLegacyCredential() throws {
    lock.withLock {
      removals += 1
      storage = .missing
    }
  }
}

private actor RecordingValidator: CredentialValidating {
  private(set) var candidates: [String] = []
  private let error: Error?

  init(error: Error? = nil) {
    self.error = error
  }

  func validate(candidate: String) async throws {
    candidates.append(candidate)
    if let error { throw error }
  }
}

private actor ControlledValidator: CredentialValidating {
  private var candidates: [String] = []
  private var continuations: [String: CheckedContinuation<Void, Error>] = [:]

  func validate(candidate: String) async throws {
    candidates.append(candidate)
    try await withCheckedThrowingContinuation { continuation in
      continuations[candidate] = continuation
    }
  }

  func waitForCandidates(_ expectedCount: Int) async throws {
    for _ in 0..<10_000 {
      if candidates.count >= expectedCount { return }
      await Task.yield()
    }
    throw WaitFailure.timedOut
  }

  func complete(candidate: String, result: Result<Void, Error>) {
    guard let continuation = continuations.removeValue(forKey: candidate) else { return }
    continuation.resume(with: result)
  }
}

private enum WaitFailure: Error {
  case timedOut
}

private final class RecordingRefresher: CredentialRefreshHandling, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CredentialChange] = []

  var changes: [CredentialChange] { lock.withLock { storage } }

  func refreshCredentialConfiguration(after change: CredentialChange) {
    lock.withLock { storage.append(change) }
  }
}

private final class RecordingReporter: CredentialEventReporting, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CredentialEvent] = []

  var events: [CredentialEvent] { lock.withLock { storage } }

  func reportCredentialEvent(_ event: CredentialEvent) {
    lock.withLock { storage.append(event) }
  }
}

private extension NSLock {
  func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
    lock()
    defer { unlock() }
    return try body()
  }
}
