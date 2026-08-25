//
//  PermissionsViewModel.swift
//  ShellMate
//
//  Created by Daniel Delattre on 26/06/24.
//

import AppKit
import Combine
import Foundation

class PermissionsViewModel: ObservableObject {
  @Published var isAppTrusted = false

  private var timer: AnyCancellable?

  init() {
    checkAccessibilityPermissions()
    startTimer()
  }

  deinit {
    timer?.cancel()
  }

  func checkAccessibilityPermissions() {
    isAppTrusted = AccessibilityChecker.isAppTrusted()
  }

  private func startTimer() {
    timer = Timer.publish(every: 1.0, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in
        self?.checkAccessibilityPermissions()
      }
  }

  func initializeApp() {
    NotificationCenter.default.post(name: .startAppInitialization, object: nil)
  }

  func requestAccessibilityPermissions() {
    let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
  }
}

enum ApiKeyValidationState: String {
  case unverified
  case valid
  case invalid
}

/// UI adapter for the transactional credential editor. `apiKey` is an in-memory draft only; custom
/// credentials are persisted exclusively by `CredentialRuntime` after successful validation.
class LicenseViewModel: ObservableObject {
  static let shared = LicenseViewModel(
    runtime: ShellMateCredentialRuntime.shared,
    validator: ShellMateCredentialValidator(),
    refresher: ShellMateCredentialRefresher(),
    reporter: ShellMateCredentialEventReporter()
  )

  @Published var apiKeyErrorMessage: String?
  @Published var apiKey: String {
    didSet { handleDraftEdit() }
  }
  @Published var apiKeyValidationState: ApiKeyValidationState
  @Published private(set) var isAPIKeyRevealed = false
  @Published private(set) var hasCustomCredential: Bool

  private let runtime: CredentialRuntime
  private let validator: any CredentialValidating
  private let editor: CredentialEditor
  private var validationTask: Task<Void, Never>?
  private var startupValidationTask: Task<Void, Never>?
  private var viewGeneration: UInt64 = 0
  private var isApplyingDraft = false

  private init(
    runtime: CredentialRuntime,
    validator: any CredentialValidating,
    refresher: any CredentialRefreshHandling,
    reporter: any CredentialEventReporting
  ) {
    self.runtime = runtime
    self.validator = validator
    self.editor = CredentialEditor(
      runtime: runtime,
      validator: validator,
      refresher: refresher,
      reporter: reporter
    )
    let persistedCredential = runtime.activeCredential()
    self.apiKey = persistedCredential ?? ""
    self.hasCustomCredential = persistedCredential != nil
    self.apiKeyValidationState = persistedCredential == nil ? .unverified : .valid
  }

  deinit {
    validationTask?.cancel()
    startupValidationTask?.cancel()
  }

  /// Retains the launch-time permission workflow while validating one immutable credential value.
  /// It never commits or rewrites the active credential.
  func scheduleApiKeyCheck(
    after delay: TimeInterval,
    maxRetries: Int = 1,
    completion: @escaping (Bool) -> Void
  ) {
    startupValidationTask?.cancel()
    let generation = viewGeneration
    let candidate = runtime.credentialForAuthorization(fallback: getHardcodedOpenAIAPIKey())
    let validatesCustomCredential = runtime.activeCredential() != nil

    startupValidationTask = Task { [weak self, validator] in
      guard let viewModel = self else { return }
      do {
        if delay > 0 {
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        var attemptsRemaining = max(1, maxRetries)
        while true {
          do {
            try await validator.validate(candidate: candidate)
            try Task.checkCancellation()
            await MainActor.run {
              guard generation == viewModel.viewGeneration else { return }
              viewModel.apiKeyErrorMessage = nil
              viewModel.apiKeyValidationState = validatesCustomCredential ? .valid : .unverified
              viewModel.postAPIKeyValidation(validatesCustomCredential ? true : nil)
              completion(true)
            }
            return
          } catch is CancellationError {
            return
          } catch {
            attemptsRemaining -= 1
            guard attemptsRemaining > 0 else { throw CredentialFailure.validationRejected }
            try await Task.sleep(nanoseconds: 10 * 1_000_000_000)
          }
        }
      } catch is CancellationError {
        return
      } catch {
        await MainActor.run {
          guard generation == viewModel.viewGeneration else { return }
          viewModel.apiKeyValidationState = .invalid
          viewModel.apiKeyErrorMessage = CredentialFailure.validationRejected.userMessage
          viewModel.postAPIKeyValidation(false)
          completion(false)
        }
      }
    }
  }

  /// Explicit validation API used by callers that need to test a supplied candidate. It cannot
  /// silently fall back to another global credential.
  func checkApiKey(_ key: String) async -> Result<Void, Error> {
    let candidate = CredentialSanitizer.sanitize(key)
    guard !candidate.isEmpty else { return .failure(CredentialFailure.emptyCandidate) }
    do {
      try await validator.validate(candidate: candidate)
      return .success(())
    } catch {
      return .failure(CredentialFailure.validationRejected)
    }
  }

  func removeCustomKey() {
    validationTask?.cancel()
    startupValidationTask?.cancel()
    viewGeneration &+= 1

    switch editor.removeCredential() {
    case .removed:
      applyDraft("")
      hasCustomCredential = false
      apiKeyValidationState = .unverified
      apiKeyErrorMessage = nil
      isAPIKeyRevealed = false
    case .rejected(let failure):
      hasCustomCredential = runtime.activeCredential() != nil
      apiKeyValidationState = .invalid
      apiKeyErrorMessage = failure.userMessage
    }
  }

  func toggleAPIKeyVisibility() {
    isAPIKeyRevealed = editor.toggleCredentialVisibility()
  }

  func hideAPIKey() {
    editor.hideCredential()
    isAPIKeyRevealed = false
  }

  private func handleDraftEdit() {
    guard !isApplyingDraft else { return }

    let sanitized = CredentialSanitizer.sanitize(apiKey)
    if sanitized != apiKey {
      applyDraft(sanitized)
    }

    let request = editor.prepareReplacement(sanitized)
    validationTask?.cancel()
    startupValidationTask?.cancel()
    viewGeneration &+= 1
    let generation = viewGeneration
    apiKeyErrorMessage = nil

    guard !request.isEmpty else {
      // Clearing the field is only an edit. Deletion requires the explicit Remove action.
      apiKeyValidationState = hasCustomCredential ? .valid : .unverified
      return
    }

    apiKeyValidationState = .unverified
    validationTask = Task { [weak self, editor] in
      guard let viewModel = self else { return }
      do {
        try await Task.sleep(nanoseconds: 250_000_000)
      } catch {
        return
      }

      let result = await editor.validateAndReplace(request)
      await MainActor.run {
        guard generation == viewModel.viewGeneration else { return }
        switch result {
        case .committed:
          viewModel.applyDraft(sanitized)
          viewModel.hasCustomCredential = true
          viewModel.apiKeyValidationState = .valid
          viewModel.apiKeyErrorMessage = nil
        case .rejected(let failure):
          viewModel.hasCustomCredential = viewModel.runtime.activeCredential() != nil
          viewModel.apiKeyValidationState = .invalid
          viewModel.apiKeyErrorMessage = failure.userMessage
        case .superseded:
          break
        }
      }
    }
  }

  private func applyDraft(_ draft: String) {
    isApplyingDraft = true
    apiKey = draft
    isApplyingDraft = false
  }

  private func postAPIKeyValidation(_ isValid: Bool?) {
    var userInfo: [AnyHashable: Any] = [:]
    if let isValid {
      userInfo["isValid"] = isValid
    }
    NotificationCenter.default.post(
      name: .userValidatedOwnOpenAIAPIKey,
      object: nil,
      userInfo: userInfo
    )
  }
}
