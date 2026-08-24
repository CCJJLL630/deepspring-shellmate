import Cocoa
import Foundation

class KeyPressDelegate {
  private enum SMCommandHandlingResult: Equatable {
    case selectionAttempted
    case notASelection
  }

  private var eventMonitor: Any?
  private var debounceWorkItem: DispatchWorkItem?
  private var activeLinesByTerminal: [String: String] = [:]
  private var observedActiveTerminalID: String?

  private let activeTerminalID: () -> String?
  private let selectionHandler: SuggestionSelectionHandler

  init(
    commandIndex: SuggestionCommandLookingUp = SuggestionCommandIndex.shared,
    activeTerminalID: @escaping () -> String? = { AFKSessionService.shared.currentTerminalID },
    writeClipboard: @escaping SuggestionSelectionHandler.ClipboardWriter = setClipboardContent,
    paste: @escaping SuggestionSelectionHandler.PasteAction = pasteClipboardContent,
    didSelect: @escaping SuggestionSelectionHandler.SuccessAction = {
      if !OnboardingStateManager.shared.isStepCompleted(step: 2) {
        OnboardingStateManager.shared.markAsCompleted(step: 2)
      }
    }
  ) {
    self.activeTerminalID = activeTerminalID
    self.selectionHandler = SuggestionSelectionHandler(
      commandIndex: commandIndex,
      writeClipboard: writeClipboard,
      paste: paste,
      didSelect: didSelect)
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    print("KeyPressDelegate - Application did finish launching.")
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleTerminalActiveLineChanged(_:)),
      name: .terminalActiveLineChanged,
      object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleTerminalWindowIdDidChange(_:)),
      name: .terminalWindowIdDidChange,
      object: nil)
    startMonitoring()
  }

  deinit {
    print("KeyPressDelegate - Deinitialized")
    stopMonitoring()
    NotificationCenter.default.removeObserver(self)
  }

  func startMonitoring() {
    print("KeyPressDelegate - Start monitoring key presses.")
    eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.handleKeyPress(event: event)
    }
  }

  private func stopMonitoring() {
    if let eventMonitor = eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
      print("KeyPressDelegate - Stopped monitoring key presses.")
    }
  }

  private func handleKeyPress(event: NSEvent) {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
      frontmostApp.bundleIdentifier == "com.apple.Terminal"
    else {
      return
    }

    // Capture the active Terminal and its line together. A window switch during the debounce must
    // not change which terminal's command is resolved.
    let terminalID = observedActiveTerminalID ?? activeTerminalID()
    let activeLine = terminalID.flatMap { activeLinesByTerminal[$0] }

    if event.keyCode == 36 {
      print("KeyPressDelegate - Enter key detected.")
      debounceEnterKey(activeLine: activeLine, terminalID: terminalID)
    }

    // Handle AFK logic for any key press.
    if let terminalID = terminalID {
      AFKSessionService.shared.handleKeyPress(for: terminalID)
    }
  }

  private func debounceEnterKey(activeLine: String?, terminalID: String?) {
    debounceWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      self?.processEnterKey(activeLine: activeLine, terminalID: terminalID)
    }
    debounceWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
  }

  func isValidSMIndexCommand(line: String) -> Bool {
    return SMSelectionCommandParser.selectionIndex(in: line) != nil
  }

  func extractSMCommandIndex(line: String) -> String? {
    guard let selectionIndex = SMSelectionCommandParser.selectionIndex(in: line),
      let address = SuggestionAddress(selectionIndex: selectionIndex)
    else {
      return nil
    }
    return address.description
  }

  // Function to check for valid `sm` question
  func isValidSMQuestion(line: String) -> Bool {
    // Regular expression to match `sm` followed by a space and a quoted string
    let regex = try! NSRegularExpression(pattern: #"sm\s+["'](.+?)["']"#, options: [])
    let nsString = line as NSString
    let results = regex.matches(
      in: line, options: [], range: NSRange(location: 0, length: nsString.length))

    // Check if there's at least one match
    return !results.isEmpty
  }

  private func processEnterKey(activeLine: String?, terminalID: String?) {
    print("Enter key pressed in Terminal")

    guard let activeLine = activeLine else {
      print("No active line available for the active Terminal.")
      return
    }

    handleUpdateShellProfile(for: activeLine)

    print("Current active line: \(activeLine)")
    let result = handleSMCommand(for: activeLine, terminalID: terminalID)
    if result == .notASelection {
      handleOnboardingStep3()
    }
  }

  private func handleUpdateShellProfile(for line: String) {
    if UpdateShellProfileViewModel.shared.shouldShowUpdateShellProfileBanner()
      && doesLineContainFixingCommand(line)
    {
      UpdateShellProfileViewModel.shared.updateShouldShowUpdateShellProfile(value: false)
      OnboardingStateManager.shared.resetStep(step: 1)
      OnboardingStateManager.shared.resetStep(step: 2)
    }
  }

  private func doesLineContainFixingCommand(_ line: String) -> Bool {
    let sanitizedLine = sanitizeText(line)
    let sanitizedFixingCommand = sanitizeText(UpdateShellProfileViewModel.shared.fixingCommand)
    return sanitizedLine.contains(sanitizedFixingCommand)
  }

  private func handleOnboardingStep3() {
    if !OnboardingStateManager.shared.isStepCompleted(step: 3)
      && OnboardingStateManager.shared.isStepCompleted(step: 2)
    {
      OnboardingStateManager.shared.markAsCompleted(step: 3)
    }
  }

  private func handleSMCommand(for line: String, terminalID: String?) -> SMCommandHandlingResult {
    if let selectionIndex = SMSelectionCommandParser.selectionIndex(in: line) {
      print("Is valid 'sm' index command: true")
      MixpanelHelper.shared.trackEvent(name: "userInsertedSMCommandAtTerminal")

      let request = SuggestionSelectionRequest(
        selectionIndex: selectionIndex, terminalID: terminalID)
      if selectionHandler.select(request) {
        print("Selected command at index \(selectionIndex)")
      } else {
        print("No command found for index \(selectionIndex) in the active Terminal")
      }
      return .selectionAttempted
    }

    print("Is valid 'sm' index command: false")
    if SMSelectionCommandParser.isSelectionAttempt(line) {
      // A malformed or missing index is still a selection attempt. It must not advance onboarding.
      return .selectionAttempted
    }

    checkAndHandleOnboardingStep1(line: line)
    return .notASelection
  }

  private func checkAndHandleOnboardingStep1(line: String) {
    if !OnboardingStateManager.shared.isStepCompleted(step: 1)
      && (isValidSMQuestion(line: line) || line.lowercased().contains("sm"))
      && doesCurrentLineContainOnboardingCommand(line: line)
    {
      OnboardingStateManager.shared.markAsCompleted(step: 1)
    }
  }

  private func sanitizeText(_ text: String) -> String {
    let alphanumericText = text.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(
      separator: " ")
    let reducedSpacesText = alphanumericText.replacingOccurrences(
      of: "\\s+", with: " ", options: .regularExpression, range: nil)
    return reducedSpacesText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  func doesCurrentLineContainOnboardingCommand(line: String) -> Bool {
    let sanitizedLine = sanitizeText(line)
    let sanitizedCommand = sanitizeText(getOnboardingSmCommand())
    return sanitizedLine.contains(sanitizedCommand) || sanitizedLine.contains("cal")
  }

  @objc private func handleTerminalWindowIdDidChange(_ notification: Notification) {
    guard let windowID = notification.userInfo?["terminalWindowID"] as? CGWindowID else {
      return
    }
    observedActiveTerminalID = String(windowID)
  }

  @objc private func handleTerminalActiveLineChanged(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
      let activeLine = userInfo["activeLine"] as? String,
      let windowID = userInfo["terminalWindowID"] as? CGWindowID
    else {
      return
    }

    let terminalID = String(windowID)
    print("Received active line from Terminal \(terminalID): \(activeLine)")
    observedActiveTerminalID = terminalID
    activeLinesByTerminal[terminalID] = activeLine
  }
}
