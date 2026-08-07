//! The `workspace/executeCommand` ids this server answers, in one place.
//!
//! **Why they are namespaced.** A language client is entitled to turn every
//! id in `executeCommandProvider.commands` into a command of its own:
//! vscode-languageclient's ExecuteCommandFeature registers a real VS Code
//! command for each one. So a server id that collides with an id the editor
//! extension registers itself makes the second registration throw
//! `command 'x' already exists`. That is not hypothetical — it aborted the
//! extension's `activate` at `npm/wgslender-vscode/src/commands/lsp.ts:33`
//! on `wgslender.toggleMinifyMode`, and every command declared after that
//! line silently never registered.
//!
//! `wgslender.*` is the editor's namespace. The server stays in
//! `wgslender.server.*` and leaves it alone.
//!
//! This file imports nothing on purpose: `Handler`, the two transports and
//! the code-lens builder all need these strings, and a leaf keeps that from
//! becoming an import cycle.

/// Command ids, one constant per command. Spell these rather than the
/// literal anywhere a command is advertised, dispatched, or attached to a
/// code lens.
pub const id = struct {
    pub const set_minify_mode = "wgslender.server.setMinifyMode";
    pub const toggle_minify_mode = "wgslender.server.toggleMinifyMode";
    pub const recompute_minify_insights = "wgslender.server.recomputeMinifyInsights";
    pub const show_minified_output = "wgslender.server.showMinifiedOutput";
    pub const reflect = "wgslender.server.reflect";
};

/// Advertised by both transports: the three `Handler.executeCommand`
/// dispatches, plus `showMinifiedOutput`, which each transport routes to its
/// own method because it returns data.
pub const shared = [_][]const u8{
    id.set_minify_mode,
    id.toggle_minify_mode,
    id.recompute_minify_insights,
    id.show_minified_output,
};

/// The native transport answers one more: `reflect` as a command
/// (`lsp/native/workspace_commands.zig`). The WASM transport exposes the
/// same operation as the `wgslender/reflect` *request* instead, so it must
/// not claim the command — advertising what a transport cannot run is how
/// the two lists drifted apart in the first place.
pub const native = shared ++ [_][]const u8{id.reflect};

/// The ids as a JSON array body — `"a","b"` — for hand-built capability
/// JSON. Comptime, so the WASM capabilities string stays a single literal.
pub fn jsonList(comptime ids: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (ids, 0..) |command, i| {
            out = out ++ (if (i == 0) "\"" else ",\"") ++ command ++ "\"";
        }
        return out;
    }
}
