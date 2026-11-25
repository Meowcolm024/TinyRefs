mod export;
mod import;
mod list;
mod reference;
mod structured;

use std::{mem, panic, ptr, slice, str};

use reference::Reference;
use structured::StructuredReference;

#[repr(i32)]
enum Status {
    Ok = 0,
    InvalidInput = 1,
    ParseError = 2,
    InternalError = 3,
    InvalidMetadata = 4,
}

#[repr(C)]
pub struct BridgeResult {
    data: *const u8,
    len: usize,
    status: i32,
}

impl BridgeResult {
    fn new(status: Status, bytes: Vec<u8>) -> Self {
        let len = bytes.len();
        let data = Box::into_raw(bytes.into_boxed_slice()).cast::<u8>();
        Self {
            data,
            len,
            status: status as i32,
        }
    }
}

/// Returns owned UTF-8 JSON or a diagnostic. Free it with tinyrefs_biblatex_free.
///
/// # Safety
/// For nonzero len, input must point to len initialized bytes in a single
/// allocation, readable and unchanged for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tinyrefs_biblatex_parse(input: *const u8, len: usize) -> BridgeResult {
    // SAFETY: The caller guarantees the buffer is readable for the call.
    unsafe {
        invoke(input, len, |source| {
            let entries = import::parse(source).map_err(|message| (Status::ParseError, message))?;
            let structured: Vec<_> = entries
                .iter()
                .map(|entry| StructuredReference::new(entry, &entry.fields))
                .collect();
            encode_json(&structured)
        })
    }
}

/// Returns enriched UTF-8 reference JSON or a diagnostic. Free it with tinyrefs_biblatex_free.
///
/// # Safety
/// For nonzero len, input must point to len initialized bytes in a single
/// allocation, readable and unchanged for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tinyrefs_biblatex_describe(input: *const u8, len: usize) -> BridgeResult {
    // SAFETY: The caller guarantees the buffer is readable for the call.
    unsafe {
        invoke(input, len, |source| {
            let entries: Vec<Reference> = serde_json::from_str(source)
                .map_err(|error| (Status::InvalidInput, error.to_string()))?;
            let structured = entries
                .iter()
                .map(|entry| {
                    let fields = export::validated_fields(entry).map_err(|message| {
                        (
                            Status::InvalidMetadata,
                            format!("Entry {:?}: {message}", entry.citation_key),
                        )
                    })?;
                    Ok(StructuredReference::new(entry, &fields))
                })
                .collect::<Result<Vec<_>, _>>()?;
            encode_json(&structured)
        })
    }
}

fn encode_json(value: &impl serde::Serialize) -> Result<Vec<u8>, (Status, String)> {
    serde_json::to_vec_pretty(value).map_err(|error| (Status::InternalError, error.to_string()))
}

/// Returns owned JSON list items or a diagnostic. Free it with tinyrefs_biblatex_free.
///
/// # Safety
/// For nonzero len, input must point to len initialized bytes in a single
/// allocation, readable and unchanged for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tinyrefs_biblatex_list_items(
    input: *const u8,
    len: usize,
) -> BridgeResult {
    // SAFETY: The caller guarantees the buffer is readable for the call.
    unsafe {
        invoke(input, len, |source| {
            let request: list::ListRequest = serde_json::from_str(source)
                .map_err(|error| (Status::InvalidInput, error.to_string()))?;
            let items = request
                .items()
                .map_err(|message| (Status::InvalidMetadata, message))?;
            encode_json(&items)
        })
    }
}

/// Returns owned UTF-8 BibLaTeX or a diagnostic. Free it with tinyrefs_biblatex_free.
///
/// # Safety
/// For nonzero len, input must point to len initialized bytes in a single
/// allocation, readable and unchanged for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tinyrefs_biblatex_serialize(input: *const u8, len: usize) -> BridgeResult {
    // SAFETY: The caller guarantees the buffer is readable for the call.
    unsafe {
        invoke(input, len, |source| {
            let entries: Vec<Reference> = serde_json::from_str(source)
                .map_err(|error| (Status::InvalidInput, error.to_string()))?;
            export::serialize(&entries)
                .map(String::into_bytes)
                .map_err(|message| (Status::InvalidMetadata, message))
        })
    }
}

unsafe fn invoke(
    input: *const u8,
    len: usize,
    operation: fn(&str) -> Result<Vec<u8>, (Status, String)>,
) -> BridgeResult {
    match panic::catch_unwind(|| {
        let bytes = match len {
            0 => &[],
            _ if input.is_null() || len > isize::MAX as usize => {
                return BridgeResult::new(Status::InvalidInput, b"Invalid input buffer.".to_vec());
            }
            // SAFETY: The caller supplies a readable buffer of this length.
            _ => unsafe { slice::from_raw_parts(input, len) },
        };

        let source = match str::from_utf8(bytes) {
            Ok(source) => source,
            Err(error) => {
                let message = format!("Invalid UTF-8 at byte {}.", error.valid_up_to());
                return BridgeResult::new(Status::InvalidInput, message.into_bytes());
            }
        };

        match operation(source) {
            Ok(bytes) => BridgeResult::new(Status::Ok, bytes),
            Err((status, message)) => BridgeResult::new(status, message.into_bytes()),
        }
    }) {
        Ok(result) => result,
        Err(payload) => {
            // A panic payload can itself panic when dropped.
            mem::forget(payload);
            BridgeResult::new(Status::InternalError, b"The Rust bridge panicked.".to_vec())
        }
    }
}

/// Frees the Rust-owned buffer and invalidates the result.
///
/// # Safety
/// The result must be an unchanged return value of a bridge operation and
/// must not have been freed before.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tinyrefs_biblatex_free(result: BridgeResult) {
    let bytes = ptr::slice_from_raw_parts_mut(result.data.cast_mut(), result.len);
    // SAFETY: The caller returns the original boxed slice pointer and length.
    drop(unsafe { Box::from_raw(bytes) });
}
