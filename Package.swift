// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "ShellMateSuggestionLookup",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "SuggestionLookup", targets: ["SuggestionLookup"]),
    .library(name: "OpenAILifecycle", targets: ["OpenAILifecycle"]),
    .library(name: "AttachmentGeometry", targets: ["AttachmentGeometry"]),
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
  ]
)
