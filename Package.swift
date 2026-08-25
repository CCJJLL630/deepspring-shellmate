// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "ShellMateSuggestionLookup",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "SuggestionLookup", targets: ["SuggestionLookup"]),
    .library(name: "OpenAILifecycle", targets: ["OpenAILifecycle"]),
    .library(name: "AttachmentGeometry", targets: ["AttachmentGeometry"]),
    .library(name: "CredentialManagement", targets: ["CredentialManagement"]),
    .library(name: "TerminalObservation", targets: ["TerminalObservation"]),
  ],
  targets: [
    .target(
      name: "SuggestionLookup",
      path: "ShellMate/SuggestionLookup"
    ),
    .testTarget(
      name: "SuggestionLookupTests",
      dependencies: ["SuggestionLookup"],
      path: "Tests/SuggestionLookupTests"
    ),
    .target(
      name: "OpenAILifecycle",
      path: "ShellMate/OpenAILifecycle"
    ),
    .testTarget(
      name: "OpenAILifecycleTests",
      dependencies: ["OpenAILifecycle"],
      path: "Tests/OpenAILifecycleTests"
    ),
    .target(
      name: "AttachmentGeometry",
      path: "ShellMate/AttachmentGeometry"
    ),
    .testTarget(
      name: "AttachmentGeometryTests",
      dependencies: ["AttachmentGeometry"],
      path: "Tests/AttachmentGeometryTests"
    ),
    .target(
      name: "CredentialManagement",
      path: "ShellMate/CredentialManagement"
    ),
    .testTarget(
      name: "CredentialManagementTests",
      dependencies: ["CredentialManagement"],
      path: "Tests/CredentialManagementTests"
    ),
    .target(
      name: "TerminalObservation",
      path: "ShellMate/TerminalObservation"
    ),
    .testTarget(
      name: "TerminalObservationTests",
      dependencies: ["TerminalObservation"],
      path: "Tests/TerminalObservationTests"
    ),
  ]
)
