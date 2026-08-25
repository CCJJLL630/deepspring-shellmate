import SwiftUI

/// Shared secure presentation for onboarding and Settings. Each presentation starts hidden and only
/// reveals the in-memory draft after an explicit user action.
struct APIKeyEditorField: View {
  @ObservedObject var licenseViewModel: LicenseViewModel

  var body: some View {
    HStack(spacing: 8) {
      Group {
        if licenseViewModel.isAPIKeyRevealed {
          TextField("Enter OpenAI API Key", text: $licenseViewModel.apiKey)
        } else {
          SecureField("Enter OpenAI API Key", text: $licenseViewModel.apiKey)
        }
      }
      .textFieldStyle(RoundedBorderTextFieldStyle())

      Button(action: licenseViewModel.toggleAPIKeyVisibility) {
        Label(
          licenseViewModel.isAPIKeyRevealed ? "Hide" : "Reveal",
          systemImage: licenseViewModel.isAPIKeyRevealed ? "eye.slash" : "eye"
        )
        .labelStyle(.iconOnly)
      }
      .buttonStyle(BorderlessButtonStyle())
      .help(licenseViewModel.isAPIKeyRevealed ? "Hide API key" : "Reveal API key")
      .accessibilityLabel(licenseViewModel.isAPIKeyRevealed ? "Hide API key" : "Reveal API key")

      if licenseViewModel.hasCustomCredential {
        Button("Remove", action: licenseViewModel.removeCustomKey)
          .buttonStyle(BorderlessButtonStyle())
          .help("Remove the custom API key from Keychain")
      }
    }
    .onAppear {
      licenseViewModel.hideAPIKey()
    }
  }
}
