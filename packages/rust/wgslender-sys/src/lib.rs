//! # wgslender-sys
//!
//! Raw FFI declarations for the wgslender WGSL minifier, validator, linter,
//! reflector and shader compiler.
//!
//! This crate is an implementation detail of the `wgslender` crate. It mirrors
//! `include/wgslender.h` one item at a time and adds no safety, ownership or
//! encoding discipline of its own — depend on `wgslender` instead.
//!
//! ## Quick start
//!
//! ```
//! let mut len: u32 = 0;
//! // SAFETY: `len` is a live, aligned, initialised `u32`; the callee only writes to it.
//! let ptr = unsafe { wgslender_sys::wgslender_version_c(&raw mut len) };
//! // SAFETY: the returned pointer addresses a static string of exactly `len` bytes.
//! let bytes = unsafe { core::slice::from_raw_parts(ptr, len as usize) };
//! assert!(core::str::from_utf8(bytes).is_ok());
//! ```
//!
//! ## The C ABI in one paragraph
//!
//! Every entry point is stateless: there is no initialisation or teardown, each
//! call allocates its own arena internally, and results are copied into buffers
//! owned by the caller. All entry points are documented thread-safe. Every
//! non-null buffer in a result struct must be released with the *sized* free
//! [`wgslender_free_c`], passing the matching length field from the same struct.
//! The single exception is [`wgslender_version_c`], which returns a pointer to
//! static storage that must never be freed.
//!
//! Source text is passed as a pointer/length pair of UTF-8 bytes and does not
//! need to be NUL-terminated.
//!
//! ## Why every function is `unsafe`
//!
//! Edition 2024 allows declaring a foreign function `safe` when it is proven to
//! have no preconditions. Every one of the 22 exports takes at least one raw
//! pointer — including [`wgslender_version_c`], which writes through an out
//! parameter — so none of them qualifies.
//!
//! ## Linking
//!
//! The build script compiles the static library from the wgslender repository
//! with `zig build lib` and links it. Set `WGSLENDER_LIB_DIR` to a directory
//! containing a prebuilt `libwgslender.a` to skip that and link it directly.
//!
//! ## Edition support
//!
//! Requires Edition 2024 or later. MSRV is rustc 1.85.

#![no_std]

// ── Option flags for `wgslender_minify_c` (frozen legacy fast path) ──
//
// These bitflags express only the six boolean minify knobs and cannot carry
// lists (`keepNames`), enums or per-rule options. New options are JSON-only:
// prefer `wgslender_minify_json_c`, a strict superset. No new bit will be added.

/// Collapse whitespace in the emitted WGSL.
pub const WGSLENDER_OPT_MINIFY_WHITESPACE: u32 = 1 << 0;
/// Rename identifiers that are not part of the shader's public surface.
pub const WGSLENDER_OPT_MINIFY_IDENTIFIERS: u32 = 1 << 1;
/// Apply syntax-level shortenings, such as `1.0` becoming `1.`.
pub const WGSLENDER_OPT_MINIFY_SYNTAX: u32 = 1 << 2;
/// Drop declarations unreachable from any entry point.
pub const WGSLENDER_OPT_TREE_SHAKING: u32 = 1 << 3;
/// Rename `@group`/`@binding` variables instead of aliasing them.
pub const WGSLENDER_OPT_MANGLE_EXTERNAL: u32 = 1 << 4;
/// Keep the type names of uniform structs intact.
pub const WGSLENDER_OPT_PRESERVE_UNIFORM_STRUCTS: u32 = 1 << 5;

/// All standard minification options enabled.
pub const WGSLENDER_OPT_DEFAULT: u32 = WGSLENDER_OPT_MINIFY_WHITESPACE
    | WGSLENDER_OPT_MINIFY_IDENTIFIERS
    | WGSLENDER_OPT_MINIFY_SYNTAX
    | WGSLENDER_OPT_TREE_SHAKING;

/// Treat warnings as errors during validation.
pub const WGSLENDER_OPT_STRICT: u32 = 1 << 0;

// ── Result types ─────────────────────────────────────────────────────

/// Result of the two minify entry points: plain minified WGSL text.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WgslenderResult {
    /// Minified WGSL text, null on error.
    pub code_ptr: *const u8,
    /// Length in bytes of the buffer at `code_ptr`.
    pub code_len: u32,
    /// Set when minification failed.
    pub error: bool,
}

/// Result of [`wgslender_validate_c`].
///
/// There is no error flag: a null `json_ptr` signals an internal failure.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WgslenderValidateResult {
    /// Set when the shader passed validation.
    pub valid: bool,
    /// JSON diagnostics envelope, null on allocation failure.
    pub json_ptr: *const u8,
    /// Length in bytes of the buffer at `json_ptr`.
    pub json_len: u32,
    /// Number of diagnostics with error severity.
    pub error_count: u32,
    /// Number of diagnostics with warning severity.
    pub warning_count: u32,
}

/// Result of every entry point whose payload is a single JSON document.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WgslenderJsonResult {
    /// JSON payload, null on error.
    pub json_ptr: *const u8,
    /// Length in bytes of the buffer at `json_ptr`.
    pub json_len: u32,
    /// Set when the call failed.
    pub error: bool,
}

/// Result of [`wgslender_lint_c`].
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WgslenderLintResult {
    /// Number of diagnostics with error severity.
    pub error_count: u32,
    /// Number of diagnostics with warning severity.
    pub warning_count: u32,
    /// JSON lint report, null on allocation failure.
    pub json_ptr: *const u8,
    /// Length in bytes of the buffer at `json_ptr`.
    pub json_len: u32,
}

/// Result of [`wgslender_lint_fix_c`].
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WgslenderLintFixResult {
    /// Number of diagnostics with error severity that remain after fixing.
    pub error_count: u32,
    /// Number of diagnostics with warning severity that remain after fixing.
    pub warning_count: u32,
    /// Rewritten source, null on allocation failure.
    pub fixed_ptr: *const u8,
    /// Length in bytes of the buffer at `fixed_ptr`.
    pub fixed_len: u32,
    /// JSON lint report for the diagnostics that remain, null on allocation failure.
    pub json_ptr: *const u8,
    /// Length in bytes of the buffer at `json_ptr`.
    pub json_len: u32,
}

/// Result of [`wgslender_compile_c`].
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WgslenderCompileResult {
    /// Generated WASM module, null when `wasm_len` is zero.
    pub wasm_ptr: *const u8,
    /// Length in bytes of the buffer at `wasm_ptr`.
    pub wasm_len: u32,
    /// Size in bytes of the minified WGSL the module expands to.
    pub original_size: u32,
    /// JSON array of error objects.
    pub errors_json_ptr: *const u8,
    /// Length in bytes of the buffer at `errors_json_ptr`.
    pub errors_json_len: u32,
}

/// Result of [`wgslender_minify_and_reflect_c`].
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WgslenderMinifyAndReflectResult {
    /// `{"minify":{...},"reflect":{...}}` envelope, null on error.
    pub json_ptr: *const u8,
    /// Length in bytes of the buffer at `json_ptr`.
    pub json_len: u32,
    /// Set when the call failed.
    pub error: bool,
}

// ── Functions ────────────────────────────────────────────────────────

unsafe extern "C" {
    /// Minify WGSL source using bitflag options.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * The returned `code_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `code_len`.
    pub unsafe fn wgslender_minify_c(
        source_ptr: *const u8,
        source_len: u32,
        flags: u32,
    ) -> WgslenderResult;

    /// Minify WGSL source with JSON options (the `wgslender.json` keys).
    ///
    /// Malformed option JSON degrades silently to the defaults.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `opts_ptr` must be valid for reads of `opts_len` bytes.
    /// * The returned `code_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `code_len`.
    pub unsafe fn wgslender_minify_json_c(
        source_ptr: *const u8,
        source_len: u32,
        opts_ptr: *const u8,
        opts_len: u32,
    ) -> WgslenderResult;

    /// Validate WGSL source, returning validity and JSON diagnostics.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_validate_c(
        source_ptr: *const u8,
        source_len: u32,
        flags: u32,
    ) -> WgslenderValidateResult;

    /// Reflect WGSL source, returning bindings, structs and entry points.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_reflect_c(
        source_ptr: *const u8,
        source_len: u32,
    ) -> WgslenderJsonResult;

    /// Find all references to the symbol under `offset`, a UTF-8 byte offset.
    ///
    /// `include_declaration` is 0 or 1.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_find_references_c(
        source_ptr: *const u8,
        source_len: u32,
        offset: u32,
        include_declaration: u32,
    ) -> WgslenderJsonResult;

    /// Compute the edits that rename the symbol at `offset` to `new_name`.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `new_name_ptr` must be valid for reads of `new_name_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_rename_c(
        source_ptr: *const u8,
        source_len: u32,
        offset: u32,
        new_name_ptr: *const u8,
        new_name_len: u32,
    ) -> WgslenderJsonResult;

    /// Rename the symbol at `offset` and return the rewritten source.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `new_name_ptr` must be valid for reads of `new_name_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_rename_apply_c(
        source_ptr: *const u8,
        source_len: u32,
        offset: u32,
        new_name_ptr: *const u8,
        new_name_len: u32,
    ) -> WgslenderJsonResult;

    /// Resolve a byte offset to a reparse-stable identifier for the symbol
    /// under the cursor.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_stable_id_at_offset_c(
        source_ptr: *const u8,
        source_len: u32,
        offset: u32,
    ) -> WgslenderJsonResult;

    /// Resolve a stable ID to its declaration byte range in the current source.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `id_ptr` must be valid for reads of `id_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_locate_stable_id_c(
        source_ptr: *const u8,
        source_len: u32,
        id_ptr: *const u8,
        id_len: u32,
    ) -> WgslenderJsonResult;

    /// Rename the symbol identified by a stable ID.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `id_ptr` must be valid for reads of `id_len` bytes.
    /// * `new_name_ptr` must be valid for reads of `new_name_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_rename_by_id_c(
        source_ptr: *const u8,
        source_len: u32,
        id_ptr: *const u8,
        id_len: u32,
        new_name_ptr: *const u8,
        new_name_len: u32,
    ) -> WgslenderJsonResult;

    /// Resolve a stable ID to its full declaration byte range.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `id_ptr` must be valid for reads of `id_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_locate_declaration_c(
        source_ptr: *const u8,
        source_len: u32,
        id_ptr: *const u8,
        id_len: u32,
    ) -> WgslenderJsonResult;

    /// Resolve a stable ID to its type-annotation byte range.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `id_ptr` must be valid for reads of `id_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_locate_type_c(
        source_ptr: *const u8,
        source_len: u32,
        id_ptr: *const u8,
        id_len: u32,
    ) -> WgslenderJsonResult;

    /// Compute the edit that deletes the declaration for a stable ID.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `id_ptr` must be valid for reads of `id_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_remove_declaration_by_id_c(
        source_ptr: *const u8,
        source_len: u32,
        id_ptr: *const u8,
        id_len: u32,
    ) -> WgslenderJsonResult;

    /// Delete the declaration for a stable ID and return the rewritten source.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `id_ptr` must be valid for reads of `id_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_remove_declaration_apply_by_id_c(
        source_ptr: *const u8,
        source_len: u32,
        id_ptr: *const u8,
        id_len: u32,
    ) -> WgslenderJsonResult;

    /// Compute the edit that replaces the type annotation for a stable ID.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `id_ptr` must be valid for reads of `id_len` bytes.
    /// * `new_type_ptr` must be valid for reads of `new_type_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_change_type_by_id_c(
        source_ptr: *const u8,
        source_len: u32,
        id_ptr: *const u8,
        id_len: u32,
        new_type_ptr: *const u8,
        new_type_len: u32,
    ) -> WgslenderJsonResult;

    /// Replace the type annotation for a stable ID and return the rewritten source.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `id_ptr` must be valid for reads of `id_len` bytes.
    /// * `new_type_ptr` must be valid for reads of `new_type_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_change_type_apply_by_id_c(
        source_ptr: *const u8,
        source_len: u32,
        id_ptr: *const u8,
        id_len: u32,
        new_type_ptr: *const u8,
        new_type_len: u32,
    ) -> WgslenderJsonResult;

    /// Minify and reflect in one call, returning a combined JSON envelope.
    ///
    /// This is the only C entry point that exposes the minify envelope, with the
    /// original and minified sizes and any minifier errors.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `opts_ptr` must be valid for reads of `opts_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_minify_and_reflect_c(
        source_ptr: *const u8,
        source_len: u32,
        opts_ptr: *const u8,
        opts_len: u32,
    ) -> WgslenderMinifyAndReflectResult;

    /// Lint WGSL source with a JSON config of shareable packs and rule severities.
    ///
    /// An empty config buffer enables no rules.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `config_ptr` must be valid for reads of `config_len` bytes.
    /// * The returned `json_ptr`, when non-null, must be freed exactly once with
    ///   [`wgslender_free_c`] and the matching `json_len`.
    pub unsafe fn wgslender_lint_c(
        source_ptr: *const u8,
        source_len: u32,
        config_ptr: *const u8,
        config_len: u32,
    ) -> WgslenderLintResult;

    /// Lint WGSL source and apply the available autofixes in one call.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `config_ptr` must be valid for reads of `config_len` bytes.
    /// * The returned `fixed_ptr` and `json_ptr`, when non-null, must each be
    ///   freed exactly once with [`wgslender_free_c`] and their matching lengths.
    pub unsafe fn wgslender_lint_fix_c(
        source_ptr: *const u8,
        source_len: u32,
        config_ptr: *const u8,
        config_len: u32,
    ) -> WgslenderLintFixResult;

    /// Compile WGSL source to a binary `.wasm` shader that regenerates the
    /// minified text at runtime.
    ///
    /// `opts_ptr` accepts the same JSON keys as [`wgslender_minify_json_c`].
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `source_ptr` must be valid for reads of `source_len` bytes.
    /// * `opts_ptr` must be valid for reads of `opts_len` bytes.
    /// * The returned `wasm_ptr` and `errors_json_ptr`, when non-null, must each
    ///   be freed exactly once with [`wgslender_free_c`] and their matching lengths.
    pub unsafe fn wgslender_compile_c(
        source_ptr: *const u8,
        source_len: u32,
        opts_ptr: *const u8,
        opts_len: u32,
    ) -> WgslenderCompileResult;

    /// Free a buffer returned by any of the entry points above.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `ptr` and `len` must both come from the same result struct field pair,
    ///   unchanged.
    /// * The buffer must not have been freed already, and must not be read after
    ///   this call.
    pub unsafe fn wgslender_free_c(ptr: *mut u8, len: u32);

    /// Return the library version string, whose length is written to `len`.
    ///
    /// The returned pointer addresses static storage and must never be freed.
    ///
    /// # Safety
    ///
    /// Behavior is undefined if any of the following conditions are violated:
    ///
    /// * `len` must be valid for writes of a `u32`.
    pub unsafe fn wgslender_version_c(len: *mut u32) -> *const u8;
}
