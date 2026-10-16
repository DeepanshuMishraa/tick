//! Ported from the Swift app's hotkey processor tests.

use tick_core::hotkey::{HotKey, Key, KeyEvent, ModifierKind, Modifiers};
use tick_core::hotkey_processor::{should_transcribe, HotKeyProcessor, ProcessorOutput, ProcessorState};

use ModifierKind::{Command as Cmd, Fn, Option as Opt, Shift};
use ProcessorOutput::{Cancel, Discard, StartRecording as Start, StopRecording as Stop};

#[derive(Clone, Copy)]
enum Expect {
    Any,
    Lock,
    Idle,
    Hold(f64),
}

struct Step {
    time: f64,
    key: Option<Key>,
    mods: &'static [ModifierKind],
    out: Option<ProcessorOutput>,
    matched: bool,
    state: Expect,
}

fn s(time: f64, key: Option<Key>, mods: &'static [ModifierKind], out: Option<ProcessorOutput>, matched: bool) -> Step {
    Step { time, key, mods, out, matched, state: Expect::Any }
}

fn st(
    time: f64,
    key: Option<Key>,
    mods: &'static [ModifierKind],
    out: Option<ProcessorOutput>,
    matched: bool,
    state: Expect,
) -> Step {
    Step { time, key, mods, out, matched, state }
}

fn run(hotkey: HotKey, steps: Vec<Step>) {
    run_with(hotkey, false, true, steps);
}

fn run_with(hotkey: HotKey, double_tap_only: bool, lock_enabled: bool, steps: Vec<Step>) {
    let mut processor = HotKeyProcessor::new(hotkey);
    processor.use_double_tap_only = double_tap_only;
    processor.double_tap_lock_enabled = lock_enabled;
    for step in steps {
        let event = KeyEvent::new(step.key, Modifiers::of(step.mods));
        let output = processor.process(&event, step.time);
        assert_eq!(output, step.out, "{}s: output", step.time);
        assert_eq!(processor.is_matched(), step.matched, "{}s: isMatched", step.time);
        match step.state {
            Expect::Any => {}
            Expect::Lock => assert_eq!(processor.state(), ProcessorState::DoubleTapLock, "{}s", step.time),
            Expect::Idle => assert_eq!(processor.state(), ProcessorState::Idle, "{}s", step.time),
            Expect::Hold(at) => {
                assert_eq!(processor.state(), ProcessorState::PressAndHold { started_at: at }, "{}s", step.time)
            }
        }
    }
}

fn key(k: Key, mods: &[ModifierKind]) -> HotKey {
    HotKey::new(Some(k), Modifiers::of(mods))
}

fn mods(mods: &[ModifierKind]) -> HotKey {
    HotKey::new(None, Modifiers::of(mods))
}

const A: Option<Key> = Some(Key::A);
const B: Option<Key> = Some(Key::B);
const C: Option<Key> = Some(Key::C);
const T: Option<Key> = Some(Key::T);
const U: Option<Key> = Some(Key::U);
const ESC: Option<Key> = Some(Key::Escape);

#[test]
fn press_and_hold_starts_standard() {
    run(key(Key::A, &[Cmd]), vec![s(0.0, A, &[Cmd], Some(Start), true)]);
}

#[test]
fn press_and_hold_starts_modifier_only() {
    run(mods(&[Opt]), vec![s(0.0, None, &[Opt], Some(Start), true)]);
}

#[test]
fn press_and_hold_stops_on_release_standard() {
    run(key(Key::A, &[Cmd]), vec![s(0.0, A, &[Cmd], Some(Start), true), s(0.2, None, &[Cmd], Some(Stop), false)]);
}

#[test]
fn press_and_hold_stops_on_release_modifier_only() {
    run(mods(&[Opt]), vec![s(0.0, None, &[Opt], Some(Start), true), s(0.2, None, &[], Some(Stop), false)]);
}

#[test]
fn press_and_hold_stops_on_release_multiple_modifiers() {
    run(
        mods(&[Opt, Cmd]),
        vec![
            s(0.0, None, &[Opt], None, false),
            s(0.1, None, &[Opt, Cmd], Some(Start), true),
            s(0.2, None, &[], Some(Stop), false),
        ],
    );
}

#[test]
fn releasing_modifier_before_key_still_stops() {
    run(
        key(Key::U, &[Opt]),
        vec![
            s(0.0, None, &[Opt], None, false),
            s(0.05, U, &[Opt], Some(Start), true),
            s(1.5, U, &[], None, true),
            s(1.55, None, &[], Some(Stop), false),
        ],
    );
}

#[test]
fn cancels_on_other_key_press_standard() {
    run(key(Key::A, &[Cmd]), vec![s(0.0, A, &[Cmd], Some(Start), true), s(0.5, B, &[Cmd], Some(Stop), false)]);
}

#[test]
fn ignores_extra_modifier_after_threshold_modifier_only() {
    run(mods(&[Opt]), vec![s(0.0, None, &[Opt], Some(Start), true), s(0.5, None, &[Opt, Cmd], None, true)]);
}

#[test]
fn does_not_cancel_after_threshold_standard() {
    run(key(Key::A, &[Cmd]), vec![s(0.0, A, &[Cmd], Some(Start), true), s(1.5, B, &[Cmd], None, true)]);
}

#[test]
fn does_not_cancel_after_threshold_modifier_only() {
    run(mods(&[Opt]), vec![s(0.0, None, &[Opt], Some(Start), true), s(1.5, None, &[Opt, Cmd], None, true)]);
}

#[test]
fn does_not_trigger_on_backslide_standard() {
    run(
        key(Key::A, &[Cmd]),
        vec![
            s(0.0, A, &[Cmd, Shift], None, false),
            s(0.1, A, &[Cmd], None, false),
            s(0.2, None, &[], None, false),
            s(0.3, A, &[Cmd], Some(Start), true),
        ],
    );
}

#[test]
fn double_tap_lock_standard() {
    run(
        key(Key::A, &[Cmd]),
        vec![
            s(0.0, A, &[Cmd], Some(Start), true),
            s(0.1, None, &[Cmd], Some(Stop), false),
            s(0.1, None, &[], None, false),
            s(0.15, None, &[Cmd], None, false),
            s(0.2, A, &[Cmd], Some(Start), true),
            st(0.3, None, &[Cmd], None, true, Expect::Lock),
        ],
    );
}

#[test]
fn double_tap_lock_modifier_only() {
    run(
        mods(&[Opt]),
        vec![
            s(0.0, None, &[Opt], Some(Start), true),
            s(0.1, None, &[], Some(Stop), false),
            s(0.2, None, &[Opt], Some(Start), true),
            st(0.3, None, &[], None, true, Expect::Lock),
        ],
    );
}

#[test]
fn double_tap_lock_multiple_modifiers() {
    run(
        mods(&[Opt, Cmd]),
        vec![
            s(0.0, None, &[Opt], None, false),
            s(0.05, None, &[Opt, Cmd], Some(Start), true),
            s(0.1, None, &[Opt], Some(Stop), false),
            s(0.2, None, &[Opt, Cmd], Some(Start), true),
            st(0.3, None, &[Opt], None, true, Expect::Lock),
        ],
    );
}

#[test]
fn slow_double_tap_ignored_standard() {
    run(
        key(Key::A, &[Cmd]),
        vec![
            s(0.0, A, &[Cmd], Some(Start), true),
            s(0.1, None, &[Cmd], Some(Stop), false),
            s(0.4, A, &[Cmd], Some(Start), true),
        ],
    );
}

#[test]
fn slow_double_tap_ignored_modifier_only() {
    run(
        mods(&[Opt]),
        vec![
            s(0.0, None, &[Opt], Some(Start), true),
            s(0.1, None, &[], Some(Stop), false),
            s(0.4, None, &[Opt], Some(Start), true),
        ],
    );
}

#[test]
fn lock_stops_on_next_tap_standard() {
    run(
        key(Key::A, &[Cmd]),
        vec![
            s(0.0, A, &[Cmd], Some(Start), true),
            s(0.1, None, &[Cmd], Some(Stop), false),
            s(0.2, A, &[Cmd], Some(Start), true),
            st(0.3, None, &[Cmd], None, true, Expect::Lock),
            s(1.0, A, &[Cmd], Some(Stop), false),
        ],
    );
}

#[test]
fn lock_stops_on_next_tap_modifier_only() {
    run(
        mods(&[Opt]),
        vec![
            s(0.0, None, &[Opt], Some(Start), true),
            s(0.1, None, &[], Some(Stop), false),
            s(0.2, None, &[Opt], Some(Start), true),
            st(0.3, None, &[], None, true, Expect::Lock),
            s(1.0, None, &[Opt], Some(Stop), false),
        ],
    );
}

#[test]
fn lock_disabled_stays_press_and_hold() {
    run_with(
        key(Key::A, &[Cmd]),
        false,
        false,
        vec![
            s(0.0, A, &[Cmd], Some(Start), true),
            s(0.1, None, &[Cmd], Some(Stop), false),
            s(0.1, None, &[], None, false),
            s(0.15, None, &[Cmd], None, false),
            s(0.2, A, &[Cmd], Some(Start), true),
            st(0.3, None, &[Cmd], Some(Stop), false, Expect::Idle),
        ],
    );
}

#[test]
fn double_tap_only_ignored_when_lock_disabled() {
    run_with(
        key(Key::A, &[Cmd]),
        true,
        false,
        vec![s(0.0, A, &[Cmd], Some(Start), true), s(0.2, None, &[Cmd], Some(Stop), false)],
    );
}

#[test]
fn key_press_discards_and_stays_dirty() {
    run(
        mods(&[Opt]),
        vec![
            s(0.0, None, &[Opt], Some(Start), true),
            s(0.1, C, &[Opt], Some(Discard), false),
            s(0.2, None, &[Opt], None, false),
        ],
    );
}

#[test]
fn fn_triggers_after_fn_plus_key_then_full_release() {
    run(
        mods(&[Fn]),
        vec![
            s(0.0, C, &[Fn], None, false),
            s(0.05, None, &[], None, false),
            s(0.2, None, &[Fn], Some(Start), true),
            s(0.4, None, &[], Some(Stop), false),
        ],
    );
}

#[test]
fn fn_does_not_trigger_while_still_held_after_key_release() {
    run(
        mods(&[Fn]),
        vec![
            s(0.0, C, &[Fn], None, false),
            s(0.05, None, &[Fn], None, false),
            s(0.1, None, &[], None, false),
            s(0.25, None, &[Fn], Some(Start), true),
            s(0.6, None, &[], Some(Stop), false),
        ],
    );
}

#[test]
fn stays_matched_after_two_seconds() {
    run(
        mods(&[Opt]),
        vec![
            s(0.0, None, &[Opt], Some(Start), true),
            s(2.0, None, &[Opt, Cmd], None, true),
            s(2.1, None, &[Opt], None, true),
            s(2.2, None, &[], Some(Stop), false),
        ],
    );
}

#[test]
fn only_locks_after_second_release() {
    run(
        mods(&[Opt]),
        vec![
            s(0.0, None, &[Opt], Some(Start), true),
            s(0.1, None, &[], Some(Stop), false),
            st(0.2, None, &[Opt], Some(Start), true, Expect::Hold(0.2)),
            st(0.3, None, &[], None, true, Expect::Lock),
        ],
    );
}

#[test]
fn second_tap_held_too_long_becomes_hold() {
    run(
        mods(&[Opt]),
        vec![
            s(0.0, None, &[Opt], Some(Start), true),
            s(0.1, None, &[], Some(Stop), false),
            s(0.2, None, &[Opt], Some(Start), true),
            s(2.2, None, &[Opt], None, true),
            s(2.3, None, &[], Some(Stop), false),
        ],
    );
}

#[test]
fn escape_cancels_from_hold() {
    run(key(Key::A, &[Cmd]), vec![s(0.0, A, &[Cmd], Some(Start), true), s(0.5, ESC, &[], Some(Cancel), false)]);
}

#[test]
fn escape_cancels_from_lock() {
    run(
        mods(&[Opt]),
        vec![
            s(0.0, None, &[Opt], Some(Start), true),
            s(0.1, None, &[], Some(Stop), false),
            s(0.2, None, &[Opt], Some(Start), true),
            s(0.3, None, &[], None, true),
            s(1.0, ESC, &[], Some(Cancel), false),
        ],
    );
}

#[test]
fn escape_while_holding_does_not_restart() {
    run(
        key(Key::A, &[Cmd]),
        vec![
            s(0.0, A, &[Cmd], Some(Start), true),
            s(0.5, ESC, &[Cmd], Some(Cancel), false),
            s(0.6, A, &[Cmd], None, false),
            s(0.7, None, &[], None, false),
            s(0.8, A, &[Cmd], Some(Start), true),
        ],
    );
}

#[test]
fn modifier_only_does_not_trigger_with_other_keys() {
    run(
        mods(&[Cmd, Opt]),
        vec![
            s(0.0, T, &[Cmd, Opt], None, false),
            s(0.1, None, &[Cmd, Opt], None, false),
            s(0.2, None, &[], None, false),
            s(0.3, None, &[Cmd, Opt], Some(Start), true),
            s(0.4, None, &[], Some(Stop), false),
        ],
    );
}

#[test]
fn multiple_modifiers_partial_release() {
    run(mods(&[Opt, Cmd]), vec![s(0.0, None, &[Opt, Cmd], Some(Start), true), s(0.5, None, &[Opt], Some(Stop), false)]);
}

#[test]
fn multiple_modifiers_extra_ignored_after_threshold() {
    run(
        mods(&[Opt, Cmd]),
        vec![s(0.0, None, &[Opt, Cmd], Some(Start), true), s(0.5, None, &[Opt, Cmd, Shift], None, true)],
    );
}

#[test]
fn key_modifier_changing_modifiers_cancels_within_1s() {
    run(key(Key::A, &[Cmd]), vec![s(0.0, A, &[Cmd], Some(Start), true), s(0.5, A, &[Cmd, Shift], Some(Stop), false)]);
}

#[test]
fn dirty_state_blocks_until_full_release() {
    run(
        mods(&[Opt]),
        vec![
            s(0.0, None, &[Opt], Some(Start), true),
            s(0.1, None, &[Opt, Cmd], Some(Discard), false),
            s(0.2, None, &[Opt], None, false),
            s(0.3, C, &[Opt], None, false),
            s(0.4, None, &[], None, false),
            s(0.5, None, &[Opt], Some(Start), true),
        ],
    );
}

#[test]
fn multiple_modifiers_no_backslide() {
    run(
        mods(&[Opt, Cmd]),
        vec![
            s(0.0, None, &[Opt, Cmd, Shift], None, false),
            s(0.1, None, &[Opt, Cmd], None, false),
            s(0.2, None, &[], None, false),
            s(0.3, None, &[Opt, Cmd], Some(Start), true),
        ],
    );
}

// Recording decision

#[test]
fn modifier_only_short_press_is_discarded() {
    assert!(!should_transcribe(&mods(&[Cmd]), 0.2, 0.1));
}

#[test]
fn printable_key_short_press_proceeds() {
    assert!(should_transcribe(&key(Key::Quote, &[Cmd]), 0.2, 0.1));
}

#[test]
fn long_modifier_only_press_proceeds() {
    assert!(should_transcribe(&mods(&[Opt]), 0.2, 0.3));
}

#[test]
fn missing_start_time_defaults_to_short() {
    assert!(!should_transcribe(&mods(&[Opt]), 0.2, 0.0));
}

#[test]
fn modifier_only_enforces_minimum() {
    assert!(!should_transcribe(&mods(&[Opt]), 0.1, 0.25));
    assert!(should_transcribe(&mods(&[Opt]), 0.1, 0.35));
    assert!(!should_transcribe(&mods(&[Opt]), 0.5, 0.4));
    assert!(should_transcribe(&key(Key::A, &[Cmd]), 0.1, 0.15));
}

// Mouse clicks

fn processor(hotkey: HotKey, minimum: f64) -> HotKeyProcessor {
    let mut processor = HotKeyProcessor::new(hotkey);
    processor.minimum_key_time = minimum;
    processor
}

#[test]
fn mouse_click_discards_quick_modifier_only_recording() {
    let mut p = processor(mods(&[Opt]), 0.15);
    assert_eq!(p.process(&KeyEvent::new(None, Modifiers::of(&[Opt])), 0.0), Some(Start));
    assert_eq!(p.process_mouse_click(0.1), Some(Discard));
}

#[test]
fn mouse_click_ignored_after_threshold() {
    let mut p = processor(mods(&[Opt]), 0.15);
    assert_eq!(p.process(&KeyEvent::new(None, Modifiers::of(&[Opt])), 0.0), Some(Start));
    assert_eq!(p.process_mouse_click(0.35), None);
}

#[test]
fn mouse_click_ignored_in_lock() {
    let mut p = processor(mods(&[Opt]), 0.15);
    let down = KeyEvent::new(None, Modifiers::of(&[Opt]));
    let up = KeyEvent::new(None, Modifiers::empty());
    // The Swift original used 0.2 → 0.5, which only locked because of Date
    // rounding at the exact 0.3 s boundary; keep the second tap inside it.
    p.process(&down, 0.0);
    p.process(&up, 0.2);
    p.process(&down, 0.3);
    p.process(&up, 0.4);
    assert_eq!(p.state(), ProcessorState::DoubleTapLock);
    assert_eq!(p.process_mouse_click(0.6), None);
}

#[test]
fn mouse_click_ignores_key_hotkeys() {
    let mut p = processor(key(Key::A, &[Cmd]), 0.15);
    assert_eq!(p.process(&KeyEvent::new(A, Modifiers::of(&[Cmd])), 0.0), Some(Start));
    assert_eq!(p.process_mouse_click(0.1), None);
}

#[test]
fn mouse_click_respects_higher_user_preference() {
    let mut p = processor(mods(&[Opt]), 0.5);
    assert_eq!(p.process(&KeyEvent::new(None, Modifiers::of(&[Opt])), 0.0), Some(Start));
    assert_eq!(p.process_mouse_click(0.4), Some(Discard));
}
