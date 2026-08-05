//! Proves the raw declarations in this crate resolve against the real static
//! library, and that a minimal round trip through the C ABI works.
//!
//! Both tests are skipped under miri: they call into a static library compiled
//! from Zig, which miri cannot interpret (see `UNSAFE_AND_FFI.md § Miri`).

use wgslender_sys::{
    WGSLENDER_OPT_DEFAULT, wgslender_free_c, wgslender_minify_c, wgslender_version_c,
};

/// Byte length of `text` as the `u32` the C ABI expects.
fn len32(text: &str) -> u32 {
    match u32::try_from(text.len()) {
        Ok(len) => len,
        Err(err) => panic!("fixture length does not fit in a u32: {err}"),
    }
}

#[test]
#[cfg(not(miri))]
fn version_is_a_three_part_semver() {
    let mut len: u32 = 0;
    // SAFETY: `len` is a live, aligned, initialised `u32` and the callee only writes
    // the version length through it.
    let ptr = unsafe { wgslender_version_c(&raw mut len) };
    // SAFETY: `wgslender_version_c` returns a pointer to a static string of exactly
    // `len` bytes. Specifically: the buffer has static storage duration, so it stays
    // valid for reads for the rest of the program and must not be freed.
    let bytes = unsafe { core::slice::from_raw_parts(ptr, len as usize) };

    let version = match core::str::from_utf8(bytes) {
        Ok(version) => version,
        Err(err) => panic!("version string is not UTF-8: {err}"),
    };
    let parts: Vec<&str> = version.split('.').collect();
    assert_eq!(
        parts.len(),
        3,
        "expected a three-part semver, got {version:?}"
    );
    for part in parts {
        assert!(
            !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()),
            "non-numeric component in version {version:?}"
        );
    }
}

#[test]
#[cfg(not(miri))]
fn minify_with_default_flags_shrinks_an_entry_point() {
    const SOURCE: &str =
        "@compute @workgroup_size(1)\nfn main() {\n    let unused_value = 1.0;\n}\n";

    // SAFETY: `SOURCE` is valid for reads of `len32(SOURCE)` bytes for the whole
    // program (it is a `'static` string), which is the only precondition.
    let result =
        unsafe { wgslender_minify_c(SOURCE.as_ptr(), len32(SOURCE), WGSLENDER_OPT_DEFAULT) };

    assert!(!result.error, "minification reported an error");
    assert!(!result.code_ptr.is_null(), "success must return a buffer");
    assert!(
        result.code_len > 0,
        "success must return a non-empty buffer"
    );

    // SAFETY: on success the callee returns a buffer of exactly `code_len` readable
    // bytes; it is not freed until the `wgslender_free_c` call below.
    let code = unsafe { core::slice::from_raw_parts(result.code_ptr, result.code_len as usize) };
    let minified = match core::str::from_utf8(code) {
        Ok(minified) => minified.to_owned(),
        Err(err) => panic!("minified output is not UTF-8: {err}"),
    };

    // SAFETY: `code_ptr`/`code_len` come straight from the result struct, as the C
    // header requires, and nothing has freed them yet. `minified` owns a copy, so no
    // borrow of the buffer outlives this call.
    unsafe { wgslender_free_c(result.code_ptr.cast_mut(), result.code_len) };

    assert!(
        minified.len() < SOURCE.len(),
        "expected minified output to be shorter than {} bytes, got {minified:?}",
        SOURCE.len()
    );
    assert!(
        minified.contains("fn main"),
        "entry point name must survive minification, got {minified:?}"
    );
}
