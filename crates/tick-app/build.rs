//! Builds the TickNative Swift bridge with xcodebuild (SwiftPM alone cannot
//! compile MLX's Metal shaders) and links its framework.

use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"));
    let root = manifest_dir.join("../..").canonicalize().expect("workspace root exists");
    let package = root.join("native/TickNative");
    let derived = root.join("target/native");
    let products = derived.join("Build/Products/Release");

    println!("cargo:rerun-if-changed={}", package.join("Package.swift").display());
    println!("cargo:rerun-if-changed={}", package.join("Sources").display());
    println!("cargo:rerun-if-env-changed=TICK_SKIP_NATIVE_BUILD");

    if std::env::var_os("TICK_SKIP_NATIVE_BUILD").is_none() {
        let status = Command::new("xcodebuild")
            .current_dir(&package)
            .args([
                "-scheme",
                "TickNative",
                "-configuration",
                "Release",
                "-destination",
                "platform=macOS,arch=arm64",
                "-derivedDataPath",
            ])
            .arg(&derived)
            .args(["-skipPackagePluginValidation", "-skipMacroValidation", "-quiet", "build"])
            .status()
            .expect("xcodebuild must be installed (Xcode 16+)");
        assert!(status.success(), "TickNative failed to build; run xcodebuild in native/TickNative for details");
    }

    let frameworks = products.join("PackageFrameworks");
    assert!(
        frameworks.join("TickNative.framework").exists(),
        "missing {}; unset TICK_SKIP_NATIVE_BUILD to build it",
        frameworks.display()
    );
    println!("cargo:rustc-link-search=framework={}", frameworks.display());
    println!("cargo:rustc-link-lib=framework=TickNative");
    // Bundled app layout first, then the build products for `cargo run`.
    println!("cargo:rustc-link-arg=-Wl,-rpath,@executable_path/../Frameworks");
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", frameworks.display());
    if let Some(toolchain) = swift_runtime_dir() {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", toolchain.display());
    }
    println!("cargo:rustc-env=TICK_NATIVE_PRODUCTS={}", products.display());
}

/// Directory holding back-deployment Swift dylibs such as
/// `libswiftCompatibilitySpan.dylib`, needed by `cargo run` builds.
fn swift_runtime_dir() -> Option<PathBuf> {
    let output = Command::new("xcrun").args(["--find", "swift"]).output().ok()?;
    let swift = PathBuf::from(String::from_utf8(output.stdout).ok()?.trim());
    let dir = swift.parent()?.parent()?.join("lib/swift/macosx");
    dir.join("libswiftCompatibilitySpan.dylib").exists().then_some(dir).or_else(|| find_span(&swift))
}

fn find_span(swift: &Path) -> Option<PathBuf> {
    let base = swift.parent()?.parent()?.join("lib");
    std::fs::read_dir(&base).ok()?.flatten().map(|e| e.path().join("macosx")).find(|d| d.join("libswiftCompatibilitySpan.dylib").exists())
}
