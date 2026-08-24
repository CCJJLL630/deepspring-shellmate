//
//  SuggestionGenerationMonitor.swift
//  ShellMate
//
//  Created by daniel on 11/09/24.
//

import Combine
import Foundation

/// Tracks generation independently for each Terminal window and terminal-state pair.
///
/// Lifecycle code awaits `setGenerating`, so enabling and cleanup are ordered and each cleanup can
/// only remove the state that the same request inserted.
final class SuggestionGenerationMonitor: ObservableObject, OpenAIGenerationStateManaging,
  @unchecked Sendable
{
  static let shared = SuggestionGenerationMonitor()

  @Published private(set) var isGeneratingSuggestion: [String: [UUID: Bool]] = [:]

  private init() {}

  func setGenerating(_ context: OpenAIGenerationContext, to isGenerating: Bool) async {
    await MainActor.run {
      self.applyGenerationState(
        for: context.terminalID,
        stateID: context.stateID,
        isGenerating: isGenerating
      )
    }
  }

  func isCurrentlyGeneratingSuggestion(for terminalID: String) -> Bool {
    isGeneratingSuggestion[terminalID]?.values.contains(true) ?? false
  }

  func resetAll() {
    DispatchQueue.main.async {
      self.isGeneratingSuggestion.removeAll()
    }
  }

  private func applyGenerationState(
    for terminalID: String,
    stateID: UUID,
    isGenerating: Bool
  ) {
    if isGenerating {
      isGeneratingSuggestion[terminalID, default: [:]][stateID] = true
    } else {
      isGeneratingSuggestion[terminalID]?.removeValue(forKey: stateID)
      if isGeneratingSuggestion[terminalID]?.isEmpty == true {
        isGeneratingSuggestion.removeValue(forKey: terminalID)
      }
    }
  }
}
