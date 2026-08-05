//! Ownership of the byte buffers libwgslender hands back.
//!
//! The C ABI frees with `wgslender_free_c(ptr, len)` — a *sized* free — so
//! ownership cannot be a bare pointer. Pointer and length travel together in
//! [`LibBuffer`] or the free is wrong.

use core::ptr::NonNull;
use core::slice;

use wgslender_sys::{WgslenderResult, wgslender_free_c};

use crate::error::Error;

/// Bytes owned by libwgslender, released on drop.
#[derive(Debug)]
pub(crate) struct LibBuffer {
    ptr: NonNull<u8>,
    len: u32,
}

impl LibBuffer {
    /// Take ownership of a buffer the library returned.
    ///
    /// Returns `None` for the null pointer the result structs use to report
    /// that they produced nothing.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `ptr` and `len` must be the pointer/length pair of one buffer from a
    ///   single wgslender result struct.
    /// * That buffer must not have been freed, nor adopted anywhere else: this
    ///   type frees it on drop, so a second owner would free it twice.
    pub(crate) unsafe fn adopt(ptr: *const u8, len: u32) -> Option<Self> {
        let ptr = NonNull::new(ptr.cast_mut())?;
        Some(Self { ptr, len })
    }

    /// The owned bytes.
    pub(crate) fn as_bytes(&self) -> &[u8] {
        // SAFETY: `adopt`'s contract is that (ptr, len) describe one live
        // wgslender buffer, and only `Drop` frees it, so the bytes are readable
        // for as long as this borrow lasts.
        unsafe { slice::from_raw_parts(self.ptr.as_ptr(), self.len as usize) }
    }

    /// Copy the bytes out as a `String`; the buffer is freed on return.
    ///
    /// # Errors
    ///
    /// [`Error::InvalidUtf8`] if the library produced bytes that are not UTF-8.
    pub(crate) fn into_string(self) -> Result<String, Error> {
        Ok(core::str::from_utf8(self.as_bytes())?.to_owned())
    }
}

impl Drop for LibBuffer {
    fn drop(&mut self) {
        // SAFETY: `adopt` took ownership of exactly this (ptr, len) pair, and no
        // other code frees it, so this is the one and only free of the buffer.
        unsafe { wgslender_free_c(self.ptr.as_ptr(), self.len) };
    }
}

/// Take the text out of a [`WgslenderResult`], releasing the library's buffer
/// either way.
///
/// # Errors
///
/// [`Error::Internal`] if the call produced no buffer or set its error flag;
/// [`Error::InvalidUtf8`] if the text is not UTF-8.
pub(crate) fn take_text(result: WgslenderResult) -> Result<String, Error> {
    // SAFETY: `code_ptr`/`code_len` are the pair the call just returned, and
    // this is the first and only adoption of them.
    let buffer = unsafe { LibBuffer::adopt(result.code_ptr, result.code_len) };
    let Some(buffer) = buffer else {
        return Err(Error::Internal);
    };
    if result.error {
        // Dropping `buffer` frees whatever the library did produce.
        return Err(Error::Internal);
    }
    buffer.into_string()
}
