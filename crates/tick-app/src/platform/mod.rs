//! macOS integration: event taps, Accessibility, permissions, power,
//! workspace services. Everything AppKit-specific lives below this module.

pub mod keyboard;
pub mod paste;
pub mod permissions;
pub mod screen;
mod sys;
pub mod system;
pub mod windows;
pub mod workspace;
