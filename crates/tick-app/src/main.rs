//! Tick: on-device voice dictation for macOS.

mod audio;
mod hotkeys;
mod intelligence;
mod native;
mod platform;
mod sound;
mod speech;
mod state;
mod storage;
mod ui;
mod walkthrough;

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
    // FluidAudio caches Parakeet under XDG_CACHE_HOME; keep it in Tick's folder.
    // SAFETY: set before any other thread starts.
    unsafe { std::env::set_var("XDG_CACHE_HOME", storage::cache()) };
    tracing::info!(target: "caches", "XDG_CACHE_HOME = {}", storage::cache().display());

    let app = gpui_kit::application().with_assets(ui::icons::Assets);
    app.on_reopen(ui::open_main_window);
    app.run(|cx| {
        gpui_kit::init(cx);
        let state = state::init(cx);
        ui::start(&state, cx);
    });
}
