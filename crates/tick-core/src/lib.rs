//! Tick's platform-independent core. Nothing here touches AppKit, audio, or
//! the network; the app crate wires these pure functions to the system.

pub mod ai;
pub mod app_context;
pub mod constants;
pub mod history;
pub mod hotkey;
pub mod hotkey_processor;
pub mod id;
pub mod models;
pub mod settings;
pub mod stats;
pub mod text;
pub mod walkthrough;
