//! CoreAudio device queries: enumeration, names, default input selection,
//! input mute repair, and hardware change listeners.

#![allow(non_upper_case_globals)]

use std::ffi::c_void;

use core_foundation::base::TCFType;
use core_foundation::string::{CFString, CFStringRef};

pub type DeviceId = u32;

#[repr(C)]
#[derive(Clone, Copy)]
struct PropertyAddress {
    selector: u32,
    scope: u32,
    element: u32,
}

type ListenerProc = extern "C" fn(object: u32, count: u32, addresses: *const PropertyAddress, data: *mut c_void) -> i32;

#[link(name = "CoreAudio", kind = "framework")]
unsafe extern "C" {
    fn AudioObjectGetPropertyDataSize(object: u32, address: *const PropertyAddress, qualifier_size: u32, qualifier: *const c_void, size: *mut u32) -> i32;
    fn AudioObjectGetPropertyData(object: u32, address: *const PropertyAddress, qualifier_size: u32, qualifier: *const c_void, size: *mut u32, data: *mut c_void) -> i32;
    fn AudioObjectSetPropertyData(object: u32, address: *const PropertyAddress, qualifier_size: u32, qualifier: *const c_void, size: u32, data: *const c_void) -> i32;
    fn AudioObjectAddPropertyListener(object: u32, address: *const PropertyAddress, listener: ListenerProc, data: *mut c_void) -> i32;
}

const fn fourcc(code: &[u8; 4]) -> u32 {
    u32::from_be_bytes(*code)
}

const SYSTEM_OBJECT: u32 = 1;
const SCOPE_GLOBAL: u32 = fourcc(b"glob");
const SCOPE_INPUT: u32 = fourcc(b"inpt");
const SCOPE_OUTPUT: u32 = fourcc(b"outp");
const DEVICES: u32 = fourcc(b"dev#");
const DEFAULT_INPUT: u32 = fourcc(b"dIn ");
const DEFAULT_OUTPUT: u32 = fourcc(b"dOut");
const DEVICE_UID: u32 = fourcc(b"uid ");
const DEVICE_NAME: u32 = fourcc(b"lnam");
const STREAM_CONFIGURATION: u32 = fourcc(b"slay");
const TRANSPORT_TYPE: u32 = fourcc(b"tran");
const MUTE: u32 = fourcc(b"mute");
const TRANSPORT_BUILT_IN: u32 = fourcc(b"bltn");
const TRANSPORT_BLUETOOTH: u32 = fourcc(b"blue");
const TRANSPORT_BLUETOOTH_LE: u32 = fourcc(b"blea");

fn address(selector: u32, scope: u32) -> PropertyAddress {
    PropertyAddress { selector, scope, element: 0 }
}

fn get_u32(object: u32, selector: u32, scope: u32) -> Option<u32> {
    let mut value = 0u32;
    let mut size = std::mem::size_of::<u32>() as u32;
    // SAFETY: `value`/`size` describe a writable u32.
    let status = unsafe {
        AudioObjectGetPropertyData(object, &address(selector, scope), 0, std::ptr::null(), &mut size, (&mut value as *mut u32).cast())
    };
    (status == 0).then_some(value)
}

fn get_string(object: u32, selector: u32) -> Option<String> {
    let mut value: CFStringRef = std::ptr::null();
    let mut size = std::mem::size_of::<CFStringRef>() as u32;
    // SAFETY: CoreAudio returns a +1 CFString on success.
    let status = unsafe {
        AudioObjectGetPropertyData(object, &address(selector, SCOPE_GLOBAL), 0, std::ptr::null(), &mut size, (&mut value as *mut CFStringRef).cast())
    };
    // SAFETY: wraps the +1 reference so it is released.
    (status == 0 && !value.is_null()).then(|| unsafe { CFString::wrap_under_create_rule(value) }.to_string())
}

pub fn all_devices() -> Vec<DeviceId> {
    let address = address(DEVICES, SCOPE_GLOBAL);
    let mut size = 0u32;
    // SAFETY: size query on the system object.
    if unsafe { AudioObjectGetPropertyDataSize(SYSTEM_OBJECT, &address, 0, std::ptr::null(), &mut size) } != 0 {
        return Vec::new();
    }
    let mut ids = vec![0u32; size as usize / std::mem::size_of::<u32>()];
    // SAFETY: `ids` has room for `size` bytes.
    let status = unsafe { AudioObjectGetPropertyData(SYSTEM_OBJECT, &address, 0, std::ptr::null(), &mut size, ids.as_mut_ptr().cast()) };
    if status != 0 {
        return Vec::new();
    }
    ids.truncate(size as usize / std::mem::size_of::<u32>());
    ids
}

pub fn uid(device: DeviceId) -> Option<String> {
    get_string(device, DEVICE_UID)
}

pub fn name(device: DeviceId) -> Option<String> {
    get_string(device, DEVICE_NAME)
}

fn has_streams(device: DeviceId, scope: u32) -> bool {
    let address = address(STREAM_CONFIGURATION, scope);
    let mut size = 0u32;
    // SAFETY: size query.
    if unsafe { AudioObjectGetPropertyDataSize(device, &address, 0, std::ptr::null(), &mut size) } != 0 || size < 4 {
        return false;
    }
    // AudioBufferList: u32 count, then {u32 channels, u32 bytes, ptr data} per buffer.
    let mut buffer = vec![0u64; (size as usize).div_ceil(8)];
    // SAFETY: `buffer` holds at least `size` bytes, 8-byte aligned.
    if unsafe { AudioObjectGetPropertyData(device, &address, 0, std::ptr::null(), &mut size, buffer.as_mut_ptr().cast()) } != 0 {
        return false;
    }
    // SAFETY: reading the AudioBufferList layout written above.
    unsafe {
        let base = buffer.as_ptr().cast::<u8>();
        let count = *(base.cast::<u32>());
        const BUFFER_SIZE: usize = 16; // channels, byte size, data pointer
        (0..count as usize).any(|index| {
            let entry = base.add(8 + index * BUFFER_SIZE);
            entry.add(4) as usize <= base as usize + size as usize && *(entry.cast::<u32>()) > 0
        })
    }
}

pub fn has_input(device: DeviceId) -> bool {
    has_streams(device, SCOPE_INPUT)
}

pub fn has_output(device: DeviceId) -> bool {
    has_streams(device, SCOPE_OUTPUT)
}

fn transport(device: DeviceId) -> Option<u32> {
    get_u32(device, TRANSPORT_TYPE, SCOPE_GLOBAL)
}

pub fn default_input() -> Option<DeviceId> {
    get_u32(SYSTEM_OBJECT, DEFAULT_INPUT, SCOPE_GLOBAL).filter(|id| *id != 0)
}

/// Makes `device` the system default input, verifying it took effect
/// (retried once). A silent failure here used to mean recording a dead mic.
pub fn set_default_input(device: DeviceId) -> bool {
    let set = || {
        // SAFETY: writes one u32 device id.
        unsafe {
            AudioObjectSetPropertyData(
                SYSTEM_OBJECT,
                &address(DEFAULT_INPUT, SCOPE_GLOBAL),
                0,
                std::ptr::null(),
                std::mem::size_of::<u32>() as u32,
                (&device as *const u32).cast(),
            )
        }
    };
    if set() != 0 {
        tracing::error!(target: "recording", "default input change to {device} was rejected");
        return false;
    }
    if default_input() != Some(device) && (set() != 0 || default_input() != Some(device)) {
        tracing::error!(target: "recording", "default input stayed on {:?} after switching to {device}", default_input());
        return false;
    }
    true
}

/// The Mac's built-in microphone.
pub fn built_in_input() -> Option<DeviceId> {
    let devices = all_devices();
    devices
        .iter()
        .copied()
        .find(|device| has_input(*device) && get_u32(*device, TRANSPORT_TYPE, SCOPE_INPUT) == Some(TRANSPORT_BUILT_IN))
        .or_else(|| {
            devices.iter().copied().find(|device| {
                has_input(*device)
                    && name(*device).is_some_and(|n| {
                        let lower = n.to_lowercase();
                        lower.contains("built-in") || lower.contains("macbook") || lower.contains("internal")
                    })
            })
        })
}

/// Unmutes an input that is muted at the device level (silent recordings).
pub fn ensure_unmuted(device: DeviceId) {
    if get_u32(device, MUTE, SCOPE_INPUT) == Some(1) {
        let zero = 0u32;
        // SAFETY: writes one u32.
        let status = unsafe {
            AudioObjectSetPropertyData(device, &address(MUTE, SCOPE_INPUT), 0, std::ptr::null(), 4, (&zero as *const u32).cast())
        };
        if status == 0 {
            tracing::warn!(target: "recording", "input device {device} was muted at the device level; unmuted it");
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputDevice {
    /// Stable UID (numeric ids change across replugs).
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DeviceSnapshot {
    pub devices: Vec<InputDevice>,
    /// Headsets whose mic profile macOS is not currently exposing.
    pub unavailable_bluetooth: Vec<InputDevice>,
    pub default_name: Option<String>,
}

pub fn snapshot() -> DeviceSnapshot {
    let mut snapshot = DeviceSnapshot::default();
    for device in all_devices() {
        let id = uid(device).unwrap_or_else(|| device.to_string());
        if has_input(device) {
            if let Some(name) = name(device) {
                snapshot.devices.push(InputDevice { id, name });
            }
        } else if has_output(device)
            && matches!(transport(device), Some(TRANSPORT_BLUETOOTH | TRANSPORT_BLUETOOTH_LE))
        {
            if let Some(name) = name(device) {
                snapshot.unavailable_bluetooth.push(InputDevice { id, name });
            }
        }
    }
    snapshot.default_name = built_in_input().or_else(default_input).and_then(name);
    snapshot
}

/// Resolves the configured microphone: UID first, numeric id as a fallback,
/// then the built-in mic. Tick defaults to the built-in mic rather than
/// whatever external device another app selected.
pub fn resolve_preferred(selected: Option<&str>) -> Option<DeviceId> {
    let fallback = || built_in_input().or_else(default_input);
    let Some(selected) = selected else { return fallback() };
    let devices = all_devices();
    devices
        .iter()
        .copied()
        .find(|device| has_input(*device) && uid(*device).as_deref() == Some(selected))
        .or_else(|| devices.iter().copied().find(|device| has_input(*device) && device.to_string() == selected))
        .or_else(|| {
            tracing::info!(target: "recording", "selected microphone {selected} is unavailable; using the built-in microphone");
            fallback()
        })
}

pub fn describe(device: Option<DeviceId>) -> String {
    match device {
        Some(device) => format!("{} [{device}]", name(device).unwrap_or_else(|| "unknown".into())),
        None => "none".into(),
    }
}

/// Hardware change kinds observed through CoreAudio.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HardwareChange {
    DefaultInput,
    DefaultOutput,
    Devices,
}

type Listener = Box<dyn Fn(HardwareChange) + Send + Sync>;

static LISTENER: std::sync::OnceLock<Listener> = std::sync::OnceLock::new();

extern "C" fn on_property(_object: u32, count: u32, addresses: *const PropertyAddress, _data: *mut c_void) -> i32 {
    let Some(listener) = LISTENER.get() else { return 0 };
    for index in 0..count as usize {
        // SAFETY: CoreAudio passes `count` valid addresses.
        let selector = unsafe { (*addresses.add(index)).selector };
        listener(match selector {
            DEFAULT_INPUT => HardwareChange::DefaultInput,
            DEFAULT_OUTPUT => HardwareChange::DefaultOutput,
            _ => HardwareChange::Devices,
        });
    }
    0
}

/// Installs the process-wide hardware listener. Later calls are ignored.
pub fn observe(listener: impl Fn(HardwareChange) + Send + Sync + 'static) {
    if LISTENER.set(Box::new(listener)).is_err() {
        return;
    }
    for selector in [DEFAULT_INPUT, DEFAULT_OUTPUT, DEVICES] {
        // SAFETY: the listener proc is a static function reading LISTENER.
        let status = unsafe {
            AudioObjectAddPropertyListener(SYSTEM_OBJECT, &address(selector, SCOPE_GLOBAL), on_property, std::ptr::null_mut())
        };
        if status != 0 {
            tracing::error!(target: "recording", "failed to observe audio hardware selector {selector:#x}: {status}");
        }
    }
}
