// swift-tools-version: 6.0
//
// TickNative is the narrow Apple-framework bridge used by the Rust app.
// It owns only what has no Rust equivalent: Core ML speech engines
// (WhisperKit, FluidAudio/Parakeet), MLX on-device LLM generation, the
// PermissionFlow drag-to-authorize panel, and Sparkle updates.
// Everything is exposed through a small C ABI (see Sources/TickNative/CAPI.swift).
import PackageDescription

let package = Package(
  name: "TickNative",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "TickNative", type: .dynamic, targets: ["TickNative"]),
  ],
  dependencies: [
    .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "0.15.0"),
    .package(url: "https://github.com/FluidInference/FluidAudio", revision: "47552dde26f79b880efff2f23ad4dab55aa914ca"),
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.3"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.3"),
    .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.1.9"),
    .package(url: "https://github.com/jaywcjlove/PermissionFlow.git", exact: "2.11.2"),
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.8.1"),
  ],
  targets: [
    .target(
      name: "TickNative",
      dependencies: [
        .product(name: "WhisperKit", package: "WhisperKit"),
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "PermissionFlow", package: "PermissionFlow"),
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      path: "Sources/TickNative"
    ),
  ],
  // Matches the language mode the engine code shipped with in the Swift app.
  swiftLanguageModes: [.v5]
)
