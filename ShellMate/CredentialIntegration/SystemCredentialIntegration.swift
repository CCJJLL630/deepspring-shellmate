import Foundation

/// The application-wide runtime is initialized on first credential access. Its initializer performs
/// the one-way UserDefaults migration before any GPT client asks for authorization.
enum ShellMateCredentialRuntime {
  static let shared: CredentialRuntime = {
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "ai.deepspring.ShellMate"
    let store = MacOSKeychainCredentialStore(
      service: "\(bundleIdentifier).openai-api-key",
      account: "custom-openai-api-key"
    )
    let legacy = UserDefaultsLegacyCredentialPreferences()
    return CredentialRuntime(store: store, legacyPreferences: legacy)
  }()
}

struct ShellMateCredentialValidator: CredentialValidating {
  func validate(candidate: String) async throws {
    let assistantVersion = try getAppVersionAndBuild()
    let creator = GPTAssistantCreator(apiKey: candidate)
    _ = try await creator.getOrUpdateAssistant(
      assistantBaseName: "ShellMateSuggestCommands",
      assistantCurrentVersion: assistantVersion,
      assistantInstructions: GPTAssistantInstructions.getInstructions()
    )
  }
}

struct ShellMateCredentialRefresher: CredentialRefreshHandling {
  func refreshCredentialConfiguration(after change: CredentialChange) {
    DispatchQueue.main.async {
      var userInfo: [AnyHashable: Any] = ["credentialChanged": true]
      if change == .replaced {
        userInfo["isValid"] = true
      }
      NotificationCenter.default.post(
        name: .userValidatedOwnOpenAIAPIKey,
        object: nil,
        userInfo: userInfo
      )
    }
  }
}

struct ShellMateCredentialEventReporter: CredentialEventReporting {
  func reportCredentialEvent(_ event: CredentialEvent) {
    switch event {
    case .validationSucceeded:
      MixpanelHelper.shared.trackEvent(name: "openAIAPIKeyValidationSuccess")
    case .validationRejected:
      MixpanelHelper.shared.trackEvent(name: "openAIAPIKeyValidationFailure")
    case .replacementCommitted:
      MixpanelHelper.shared.trackEvent(name: "userValidatedOwnOpenAIAPIKey")
    default:
      break
    }
  }
}
