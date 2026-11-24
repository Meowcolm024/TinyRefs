mod import;

use std::{mem, panic, ptr, slice, str};

#[repr(i32)]
enum Status {
    Ok = 0,
    InvalidInput = 1,
    ParseError = 2,
    InternalError = 3,
}

#[repr(C)]
pub struct ParseResult {
    data: *const u8,
    len: usize,
    status: i32,
}

impl ParseResult {
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
pub unsafe extern "C" fn tinyrefs_biblatex_parse(input: *const u8, len: usize) -> ParseResult {
    match panic::catch_unwind(|| {
        let bytes = match len {
            0 => &[],
            _ if input.is_null() || len > isize::MAX as usize => {
                return ParseResult::new(Status::InvalidInput, b"Invalid input buffer.".to_vec());
            }
            // SAFETY: The caller supplies a readable buffer of this length.
            _ => unsafe { slice::from_raw_parts(input, len) },
        };

        let source = match str::from_utf8(bytes) {
            Ok(source) => source,
            Err(error) => {
                let message = format!("Invalid UTF-8 at byte {}.", error.valid_up_to());
                return ParseResult::new(Status::InvalidInput, message.into_bytes());
            }
        };

        let entries = match import::parse(source) {
            Ok(entries) => entries,
            Err(message) => return ParseResult::new(Status::ParseError, message.into_bytes()),
        };

        match serde_json::to_vec_pretty(&entries) {
            Ok(json) => ParseResult::new(Status::Ok, json),
            Err(error) => ParseResult::new(Status::InternalError, error.to_string().into_bytes()),
        }
    }) {
        Ok(result) => result,
        Err(payload) => {
            // A panic payload can itself panic when dropped.
            mem::forget(payload);
            ParseResult::new(Status::InternalError, b"The Rust parser panicked.".to_vec())
        }
    }
}

/// Frees the Rust-owned buffer and invalidates the result.
///
/// # Safety
/// The result must be an unchanged return value of tinyrefs_biblatex_parse
/// and must not have been freed before.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tinyrefs_biblatex_free(result: ParseResult) {
    let bytes = ptr::slice_from_raw_parts_mut(result.data.cast_mut(), result.len);
    // SAFETY: The caller returns the original boxed slice pointer and length.
    drop(unsafe { Box::from_raw(bytes) });
}
