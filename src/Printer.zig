//! WGSL code printer.
//!
//! Walks the AST and emits WGSL text. Supports minified and pretty output.
//! The needs_space flag prevents token merging (e.g., > and = → >=).

const std = @import("std");
const Ast = @import("Ast.zig");
const Dce = @import("Dce.zig");
const SourceMap = @import("SourceMap.zig");

const Printer = @This();

pub const Options = struct {
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    minify_syntax: bool = false,
    tree_shaking: bool = false,
    renamer: ?*const Renamer = null,
    source_map_gen: ?*SourceMap.Generator = null,
};

pub const Renamer = struct {
    ptr: *const anyopaque,
    nameForSymbolFn: *const fn (*const anyopaque, Ast.SymbolIndex) []const u8,

    pub fn nameForSymbol(self: *const Renamer, ref: Ast.SymbolIndex) []const u8 {
        return self.nameForSymbolFn(self.ptr, ref);
    }
};

options: Options,
symbols: []const Ast.Symbol,
allocator: std.mem.Allocator,
buf: std.ArrayListUnmanaged(u8) = .empty,
indent: u32 = 0,
needs_space: bool = false,
output_line: u32 = 0,
output_col: u32 = 0,

/// Creates a printer with the given options and symbol table.
pub fn init(allocator: std.mem.Allocator, options: Options, symbols: []const Ast.Symbol) Printer {
    return .{
        .options = options,
        .symbols = symbols,
        .allocator = allocator,
    };
}

/// Frees the output buffer.
pub fn deinit(self: *Printer) void {
    self.buf.deinit(self.allocator);
}

/// Prints the entire module and returns the generated WGSL text.
pub fn print(self: *Printer, module: *const Ast.Module) ![]const u8 {
    self.buf.clearRetainingCapacity();
    try self.printModule(module);
    return self.buf.items;
}

// =========================================================================
// Output helpers
// =========================================================================

fn emit(self: *Printer, s: []const u8) !void {
    try self.buf.appendSlice(self.allocator, s);
    self.updatePosition(s);
    self.needs_space = false;
}

fn emitByte(self: *Printer, c: u8) !void {
    try self.buf.append(self.allocator, c);
    if (c == '\n') {
        self.output_line += 1;
        self.output_col = 0;
    } else {
        self.output_col += 1;
    }
    self.needs_space = false;
}

fn emitSpace(self: *Printer) !void {
    if (!self.options.minify_whitespace) {
        try self.buf.append(self.allocator, ' ');
        self.output_col += 1;
    } else if (self.needs_space) {
        try self.buf.append(self.allocator, ' ');
        self.output_col += 1;
    }
    self.needs_space = false;
}

fn emitNewline(self: *Printer) !void {
    if (!self.options.minify_whitespace) {
        try self.buf.append(self.allocator, '\n');
        self.output_line += 1;
        self.output_col = 0;
        var i: u32 = 0;
        while (i < self.indent) : (i += 1) {
            try self.buf.appendSlice(self.allocator, "    ");
            self.output_col += 4;
        }
    }
    self.needs_space = false;
}

fn emitSemicolon(self: *Printer) !void {
    try self.emit(";");
    try self.emitNewline();
}

fn emitName(self: *Printer, ref: Ast.SymbolIndex) !void {
    if (!ref.isValid()) return;
    const idx = ref.index();
    if (idx >= self.symbols.len) return;
    const sym = &self.symbols[idx];

    // Record source map mapping before printing
    if (self.options.source_map_gen) |gen| {
        var original_name: []const u8 = "";
        if (self.options.minify_identifiers) {
            if (self.options.renamer) |ren| {
                const renamed = ren.nameForSymbol(ref);
                if (!std.mem.eql(u8, renamed, sym.original_name)) {
                    original_name = sym.original_name;
                }
            }
        }
        try gen.addMapping(self.output_line, self.output_col, sym.loc, original_name);
    }

    if (self.options.minify_identifiers) {
        if (self.options.renamer) |ren| {
            try self.emit(ren.nameForSymbol(ref));
            return;
        }
    }
    try self.emit(sym.original_name);
}

fn updatePosition(self: *Printer, s: []const u8) void {
    for (s) |c| {
        if (c == '\n') {
            self.output_line += 1;
            self.output_col = 0;
        } else {
            self.output_col += 1;
        }
    }
}

// =========================================================================
// Module
// =========================================================================

fn printModule(self: *Printer, m: *const Ast.Module) !void {
    for (m.directives.items) |dir| {
        try self.printDirective(dir);
    }
    if (m.directives.items.len > 0 and m.declarations.items.len > 0) {
        try self.emitNewline();
    }

    // Filter live declarations
    for (m.declarations.items) |decl| {
        if (!self.options.tree_shaking or Dce.isDeclarationLive(decl, self.symbols)) {
            try self.printDecl(decl);
        }
    }
}

fn printDirective(self: *Printer, d: Ast.Directive) !void {
    switch (d) {
        .enable => |dir| {
            try self.emit("enable ");
            for (dir.features.items, 0..) |feat, i| {
                if (i > 0) {
                    try self.emit(",");
                    try self.emitSpace();
                }
                try self.emit(feat);
            }
            try self.emitSemicolon();
        },
        .requires => |dir| {
            try self.emit("requires ");
            for (dir.features.items, 0..) |feat, i| {
                if (i > 0) {
                    try self.emit(",");
                    try self.emitSpace();
                }
                try self.emit(feat);
            }
            try self.emitSemicolon();
        },
        .diagnostic => |dir| {
            try self.emit("diagnostic(");
            try self.emit(dir.severity);
            try self.emit(",");
            try self.emitSpace();
            try self.emit(dir.rule);
            try self.emit(")");
            try self.emitSemicolon();
        },
    }
}

// =========================================================================
// Declarations
// =========================================================================

/// Prints a single top-level declaration.
pub fn printDecl(self: *Printer, d: Ast.Decl) !void {
    switch (d) {
        .@"const" => |decl| {
            try self.emit("const ");
            try self.emitName(decl.name);
            if (decl.typ) |t| {
                try self.emit(":");
                try self.emitSpace();
                try self.printType(t);
            }
            try self.emitSpace();
            try self.emit("=");
            try self.emitSpace();
            if (decl.initializer) |init_expr| try self.printExpr(init_expr);
            try self.emitSemicolon();
        },
        .override => |decl| {
            try self.printAttributes(decl.attributes.items);
            try self.emit("override ");
            try self.emitName(decl.name);
            if (decl.typ) |t| {
                try self.emit(":");
                try self.emitSpace();
                try self.printType(t);
            }
            if (decl.initializer) |init_expr| {
                try self.emitSpace();
                try self.emit("=");
                try self.emitSpace();
                try self.printExpr(init_expr);
            }
            try self.emitSemicolon();
        },
        .@"var" => |decl| {
            try self.printAttributes(decl.attributes.items);
            try self.emit("var");
            if (decl.address_space != .none) {
                try self.emit("<");
                try self.emit(decl.address_space.string());
                if (decl.access_mode != .none) {
                    try self.emit(",");
                    try self.emitSpace();
                    try self.emit(decl.access_mode.string());
                }
                try self.emit(">");
            }
            try self.emit(" ");
            try self.emitName(decl.name);
            if (decl.typ) |t| {
                try self.emit(":");
                try self.emitSpace();
                try self.printType(t);
            }
            if (decl.initializer) |init_expr| {
                try self.emitSpace();
                try self.emit("=");
                try self.emitSpace();
                try self.printExpr(init_expr);
            }
            try self.emitSemicolon();
        },
        .let => |decl| {
            try self.emit("let ");
            try self.emitName(decl.name);
            if (decl.typ) |t| {
                try self.emit(":");
                try self.emitSpace();
                try self.printType(t);
            }
            try self.emitSpace();
            try self.emit("=");
            try self.emitSpace();
            if (decl.initializer) |init_expr| try self.printExpr(init_expr);
            try self.emitSemicolon();
        },
        .function => |decl| {
            try self.printAttributes(decl.attributes.items);
            try self.emit("fn ");
            try self.emitName(decl.name);
            try self.emit("(");
            for (decl.parameters.items, 0..) |param, i| {
                if (i > 0) {
                    try self.emit(",");
                    try self.emitSpace();
                }
                try self.printAttributes(param.attributes.items);
                try self.emitName(param.name);
                try self.emit(":");
                try self.emitSpace();
                try self.printType(param.typ);
            }
            try self.emit(")");
            if (decl.return_type) |rt| {
                try self.emitSpace();
                try self.emit("->");
                try self.emitSpace();
                try self.printAttributes(decl.return_attr.items);
                try self.printType(rt);
            }
            try self.emitSpace();
            if (decl.body) |body| try self.printCompoundStmt(body);
            try self.emitNewline();
        },
        .@"struct" => |decl| {
            try self.emit("struct ");
            try self.emitName(decl.name);
            try self.emitSpace();
            try self.emit("{");
            self.indent += 1;
            for (decl.members.items, 0..) |member, i| {
                try self.emitNewline();
                try self.printAttributes(member.attributes.items);
                try self.emitName(member.name);
                try self.emit(":");
                try self.emitSpace();
                try self.printType(member.typ);
                if (i < decl.members.items.len - 1) try self.emit(",");
            }
            std.debug.assert(self.indent > 0);
            self.indent -= 1;
            try self.emitNewline();
            try self.emit("}");
            try self.emitNewline();
        },
        .alias => |decl| {
            try self.emit("alias ");
            try self.emitName(decl.name);
            try self.emitSpace();
            try self.emit("=");
            try self.emitSpace();
            try self.printType(decl.typ);
            try self.emitSemicolon();
        },
        .const_assert => |decl| {
            try self.emit("const_assert ");
            try self.printExpr(decl.expr);
            try self.emitSemicolon();
        },
    }
}

fn printAttributes(self: *Printer, attrs: []const Ast.Attribute) !void {
    for (attrs) |attr| {
        try self.emit("@");
        try self.emit(attr.name);
        if (attr.args.items.len > 0) {
            try self.emit("(");
            for (attr.args.items, 0..) |arg, i| {
                if (i > 0) {
                    try self.emit(",");
                    try self.emitSpace();
                }
                try self.printExpr(arg);
            }
            try self.emit(")");
        }
        self.needs_space = true;
        try self.emitSpace();
    }
}

// =========================================================================
// Types
// =========================================================================

/// Iteratively prints a type, following single-child chains with a close-stack.
fn printType(self: *Printer, t: Ast.Type) error{OutOfMemory}!void {
    // 16 levels handles worst-case WGSL type nesting (e.g., ptr<storage, array<vec4<f32>>, read>).
    var close_stack: [16]struct { suffix: []const u8, needs_space: bool, access: ?[]const u8 } = undefined;
    var close_top: usize = 0;
    var current = t;

    for (0..32) |_| {
        switch (current) {
            .ident => |typ| {
                if (typ.ref.isValid()) {
                    try self.emitName(typ.ref);
                } else {
                    try self.emit(typ.name);
                }
                break;
            },
            .vec => |typ| {
                if (typ.shorthand.len > 0) {
                    try self.emit(typ.shorthand);
                    break;
                }
                try self.emit("vec");
                try self.emitByte('0' + typ.size);
                try self.emit("<");
                if (close_top < close_stack.len) {
                    close_stack[close_top] = .{ .suffix = ">", .needs_space = true, .access = null };
                    close_top += 1;
                }
                current = typ.elem_type orelse break;
            },
            .mat => |typ| {
                if (typ.shorthand.len > 0) {
                    try self.emit(typ.shorthand);
                    break;
                }
                try self.emit("mat");
                try self.emitByte('0' + typ.cols);
                try self.emit("x");
                try self.emitByte('0' + typ.rows);
                try self.emit("<");
                if (close_top < close_stack.len) {
                    close_stack[close_top] = .{ .suffix = ">", .needs_space = true, .access = null };
                    close_top += 1;
                }
                current = typ.elem_type orelse break;
            },
            .array => |typ| {
                try self.emit("array<");
                if (typ.elem_type) |et| {
                    // Handle array size after element type
                    try self.printType(et); // bounded: types max 3-4 deep
                }
                if (typ.size) |s| {
                    try self.emit(",");
                    try self.emitSpace();
                    try self.printExpr(s);
                }
                try self.emit(">");
                self.needs_space = true;
                break;
            },
            .ptr => |typ| {
                try self.emit("ptr<");
                try self.emit(typ.address_space.string());
                try self.emit(",");
                try self.emitSpace();
                if (close_top < close_stack.len) {
                    close_stack[close_top] = .{ .suffix = ">", .needs_space = true, .access = if (typ.access_mode != .none) typ.access_mode.string() else null };
                    close_top += 1;
                }
                current = typ.elem_type;
            },
            .atomic => |typ| {
                try self.emit("atomic<");
                if (close_top < close_stack.len) {
                    close_stack[close_top] = .{ .suffix = ">", .needs_space = true, .access = null };
                    close_top += 1;
                }
                current = typ.elem_type;
            },
            .sampler => |typ| {
                if (typ.comparison) {
                    try self.emit("sampler_comparison");
                } else {
                    try self.emit("sampler");
                }
                break;
            },
            .texture => |typ| {
                try self.printTextureType(typ);
                break;
            },
        }
    } else unreachable;
    // Emit closing suffixes in reverse
    while (close_top > 0) {
        close_top -= 1;
        const entry = close_stack[close_top];
        if (entry.access) |acc| {
            try self.emit(",");
            try self.emitSpace();
            try self.emit(acc);
        }
        try self.emit(entry.suffix);
        if (entry.needs_space) self.needs_space = true;
    }
}

fn printTextureType(self: *Printer, t: *const Ast.TextureType) !void {
    const prefix: []const u8 = switch (t.kind) {
        .sampled => "texture_",
        .multisampled => "texture_multisampled_",
        .storage => "texture_storage_",
        .depth => "texture_depth_",
        .depth_multisampled => "texture_depth_multisampled_",
        .external => {
            try self.emit("texture_external");
            return;
        },
    };
    try self.emit(prefix);
    try self.emit(switch (t.dimension) {
        .@"1d" => "1d",
        .@"2d" => "2d",
        .@"2d_array" => "2d_array",
        .@"3d" => "3d",
        .cube => "cube",
        .cube_array => "cube_array",
    });

    if (t.sampled_type) |st| {
        try self.emit("<");
        try self.printType(st);
        try self.emit(">");
        self.needs_space = true;
    } else if (t.texel_format.len > 0) {
        try self.emit("<");
        try self.emit(t.texel_format);
        try self.emit(",");
        try self.emitSpace();
        try self.emit(t.access_mode.string());
        try self.emit(">");
        self.needs_space = true;
    }
}

// =========================================================================
// Numeric Literal Optimization
// =========================================================================

/// Shorten numeric literals without changing their value.
///
/// Transformations applied (float only):
///   "0.5"       → ".5"       (strip leading zero before decimal)
///   "1.0"       → "1."       (strip trailing zero after decimal)
///   "1.50"      → "1.5"      (strip trailing zeros)
///   "1000000.0" → "1e6"      (scientific notation when shorter)
///   "1500.0"    → "1500."    (only use sci when it saves bytes)
///
/// Hex, suffixed (f/h/i/u), and scientific literals are returned as-is.
fn optimizeNumericLiteral(
    value: []const u8,
    buf: *[64]u8,
) []const u8 {
    if (value.len == 0 or value.len > 60) return value;

    // Skip hex literals (0x...) — no decimal optimization applies.
    if (value.len >= 2 and value[0] == '0' and
        (value[1] == 'x' or value[1] == 'X'))
    {
        return value;
    }

    // Skip literals that already have an exponent.
    for (value) |c| {
        if (c == 'e' or c == 'E') return value;
    }

    // Detect and strip type suffix (f, h, i, u).
    const suffix = classifySuffix(value);
    const body = value[0 .. value.len - suffix.len];

    // Only optimize floats (must contain '.').
    const dot_pos = std.mem.indexOfScalar(u8, body, '.') orelse
        return value;

    // Split into integer and fractional parts.
    const int_part = body[0..dot_pos];
    const frac_part = body[dot_pos + 1 ..];

    // Try scientific notation: only use if result is shorter.
    if (trySciNotation(int_part, frac_part, suffix, buf)) |sci| {
        if (sci.len < value.len) return sci;
    }

    // Strip trailing zeros from fractional part: "1.50" → "1.5"
    var frac_end = frac_part.len;
    while (frac_end > 0 and frac_part[frac_end - 1] == '0') {
        frac_end -= 1;
    }

    // Guard: if integer part is empty and all fractional digits are zero,
    // bail out to avoid producing a bare "." (invalid WGSL).
    // e.g. ".00" → would become "." without this check.
    // Note: "0.00" → "0." is fine (has integer part).
    if (frac_end == 0 and int_part.len == 0) {
        return value;
    }

    // Strip leading zero: "0.5" → ".5" (but not "0." → ".")
    const skip_leading = int_part.len == 1 and
        int_part[0] == '0' and frac_end > 0;

    const int_out = if (skip_leading) "" else int_part;
    const frac_out = frac_part[0..frac_end];

    // Check if optimized form is actually shorter.
    const opt_len = int_out.len + 1 + frac_out.len + suffix.len;
    if (opt_len >= value.len) return value;

    // Build result: int_out + "." + frac_out + suffix
    var pos: usize = 0;
    @memcpy(buf[pos..][0..int_out.len], int_out);
    pos += int_out.len;
    buf[pos] = '.';
    pos += 1;
    @memcpy(buf[pos..][0..frac_out.len], frac_out);
    pos += frac_out.len;
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    return buf[0..pos];
}

/// Classify trailing type suffix (f, h, i, u) or empty.
fn classifySuffix(value: []const u8) []const u8 {
    if (value.len == 0) return "";
    const last = value[value.len - 1];
    if (last == 'f' or last == 'h' or last == 'i' or last == 'u') {
        return value[value.len - 1 ..];
    }
    return "";
}

/// Try to express int_part.frac_part as scientific notation.
/// Returns null if no valid scientific form exists.
fn trySciNotation(
    int_part: []const u8,
    frac_part: []const u8,
    suffix: []const u8,
    buf: *[64]u8,
) ?[]const u8 {
    // Count trailing zeros in the combined significand.
    // E.g., "1000" + "000" = significand "1000000", exponent = 6.
    //
    // Only handle cases where frac is all zeros (or empty).
    for (frac_part) |c| {
        if (c != '0') return null;
    }

    // Count trailing zeros in integer part.
    if (int_part.len == 0) return null;
    var sig_end = int_part.len;
    while (sig_end > 1 and int_part[sig_end - 1] == '0') {
        sig_end -= 1;
    }
    // Exponent = trailing zeros in integer part only.
    // Frac zeros don't add magnitude (100.00 = 1e2, not 1e4).
    const trailing = int_part.len - sig_end;
    if (trailing == 0) return null;

    // Build: significand + "e" + exponent + suffix
    const sig = int_part[0..sig_end];
    var pos: usize = 0;
    @memcpy(buf[pos..][0..sig.len], sig);
    pos += sig.len;
    buf[pos] = 'e';
    pos += 1;
    const exp_s = std.fmt.bufPrint(
        buf[pos..],
        "{d}",
        .{trailing},
    ) catch return null;
    pos += exp_s.len;
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    return buf[0..pos];
}

// =========================================================================
// Expressions
// =========================================================================

/// Iteratively prints an expression tree using a reverse-push work item stack.
/// Items are pushed in reverse execution order so LIFO processing yields
/// correct left-to-right output.
fn printExpr(self: *Printer, e: Ast.Expr) !void {
    const PrintWork = union(enum) {
        expr: Ast.Expr,
        literal: []const u8,
        space,
        print_type: Ast.Type,
    };

    var stack: std.ArrayListUnmanaged(PrintWork) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, .{ .expr = e });

    // Bounded worklist avoids unbounded recursion. 65536 handles any
    // realistic expression tree (each node pushes at most a few items).
    for (0..65536) |_| {
        const work = stack.pop() orelse break;
        switch (work) {
            .literal => |s| try self.emit(s),
            .space => try self.emitSpace(),
            .print_type => |t| try self.printType(t),
            .expr => |ex| switch (ex) {
                .ident => |expr| {
                    if (expr.ref.isValid()) {
                        try self.emitName(expr.ref);
                    } else {
                        try self.emit(expr.name);
                    }
                },
                .literal => |expr| {
                    if (self.options.minify_syntax and
                        (expr.kind == .float_literal or
                            expr.kind == .int_literal))
                    {
                        var buf: [64]u8 = undefined;
                        const opt = optimizeNumericLiteral(
                            expr.value,
                            &buf,
                        );
                        try self.emit(opt);
                    } else {
                        try self.emit(expr.value);
                    }
                },
                .binary => |expr| {
                    // Execution order: left, space, op, space, right
                    try stack.append(self.allocator, .{ .expr = expr.right });
                    try stack.append(self.allocator, .space);
                    try stack.append(self.allocator, .{ .literal = expr.op.string() });
                    try stack.append(self.allocator, .space);
                    try stack.append(self.allocator, .{ .expr = expr.left });
                },
                .unary => |expr| {
                    // Execution order: op, operand
                    try stack.append(self.allocator, .{ .expr = expr.operand });
                    try stack.append(self.allocator, .{ .literal = expr.op.string() });
                },
                .call => |expr| {
                    // Execution order: func/type "(" arg0 "," arg1 ... ")"
                    try stack.append(self.allocator, .{ .literal = ")" });
                    var i = expr.args.items.len;
                    while (i > 0) {
                        i -= 1;
                        try stack.append(self.allocator, .{ .expr = expr.args.items[i] });
                        if (i > 0) {
                            try stack.append(self.allocator, .space);
                            try stack.append(self.allocator, .{ .literal = "," });
                        }
                    }
                    try stack.append(self.allocator, .{ .literal = "(" });
                    if (expr.template_type) |tt| {
                        try stack.append(self.allocator, .{ .print_type = tt });
                    } else if (expr.func) |f| {
                        try stack.append(self.allocator, .{ .expr = f });
                    }
                },
                .index => |expr| {
                    // Execution order: base "[" idx "]"
                    try stack.append(self.allocator, .{ .literal = "]" });
                    try stack.append(self.allocator, .{ .expr = expr.idx });
                    try stack.append(self.allocator, .{ .literal = "[" });
                    try stack.append(self.allocator, .{ .expr = expr.base });
                },
                .member => |expr| {
                    // Execution order: base "." member_name
                    try stack.append(self.allocator, .{ .literal = expr.member_name });
                    try stack.append(self.allocator, .{ .literal = "." });
                    try stack.append(self.allocator, .{ .expr = expr.base });
                },
                .paren => |expr| {
                    // Execution order: "(" expr ")"
                    try stack.append(self.allocator, .{ .literal = ")" });
                    try stack.append(self.allocator, .{ .expr = expr.expr });
                    try stack.append(self.allocator, .{ .literal = "(" });
                },
            },
        }
    } else unreachable;
}

// =========================================================================
// Statements
// =========================================================================

fn printCompoundStmt(self: *Printer, stmt: *const Ast.CompoundStmt) !void {
    try self.emit("{");
    self.indent += 1;
    for (stmt.stmts.items) |s| {
        try self.emitNewline();
        try self.printStmt(s);
    }
    std.debug.assert(self.indent > 0);
    self.indent -= 1;
    try self.emitNewline();
    try self.emit("}");
}

/// Work item for the iterative statement printer.
const StmtWork = union(enum) {
    stmt: Ast.Stmt,
    compound: *const Ast.CompoundStmt,
    literal: []const u8,
    space,
    newline,
    indent_inc,
    indent_dec,
    else_chain: Ast.Stmt,
    switch_case: *const Ast.SwitchCase,
    for_stmt: *const Ast.ForStmt,
    continuing: *const Ast.CompoundStmt,
};

/// Iteratively prints a statement tree. Expression printing (printExpr)
/// and else-if chains are already iterative.
fn printStmt(self: *Printer, root: Ast.Stmt) error{OutOfMemory}!void {
    var stack: std.ArrayListUnmanaged(StmtWork) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, .{ .stmt = root });

    // Bounded worklist — same rationale as printExpr.
    for (0..65536) |_| {
        const work = stack.pop() orelse break;
        switch (work) {
            .literal => |s| try self.emit(s),
            .space => try self.emitSpace(),
            .newline => try self.emitNewline(),
            .indent_inc => {
                self.indent += 1;
            },
            .indent_dec => {
                std.debug.assert(self.indent > 0);
                self.indent -= 1;
            },
            .compound => |body| {
                // Execution order: "{" indent++ (newline stmt)* indent-- newline "}"
                // Push in reverse:
                try stack.append(self.allocator, .{ .literal = "}" });
                try stack.append(self.allocator, .newline);
                try stack.append(self.allocator, .indent_dec);
                var i = body.stmts.items.len;
                while (i > 0) {
                    i -= 1;
                    try stack.append(self.allocator, .{ .stmt = body.stmts.items[i] });
                    try stack.append(self.allocator, .newline);
                }
                try stack.append(self.allocator, .indent_inc);
                try stack.append(self.allocator, .{ .literal = "{" });
            },
            .else_chain => |ec| {
                const s = ec;
                if (s == .@"if") {
                    const if_stmt = s.@"if";
                    try self.emit(" else if ");
                    try self.printExpr(if_stmt.condition);
                    try self.emitSpace();
                    if (if_stmt.else_branch) |eb| try stack.append(self.allocator, .{ .else_chain = eb });
                    try stack.append(self.allocator, .{ .compound = if_stmt.body });
                } else {
                    try self.emit(" else");
                    try self.emitSpace();
                    try stack.append(self.allocator, .{ .stmt = s });
                }
            },
            .switch_case => |c| {
                try self.emitNewline();
                if (c.selectors.items.len == 0) {
                    try self.emit("default");
                } else {
                    try self.emit("case ");
                    for (c.selectors.items, 0..) |sel, i| {
                        if (i > 0) {
                            try self.emit(",");
                            try self.emitSpace();
                        }
                        try self.printExpr(sel);
                    }
                }
                try self.emit(":");
                try self.emitSpace();
                try stack.append(self.allocator, .{ .compound = c.body });
            },
            .for_stmt => |stmt| {
                try self.emit("for");
                try self.emitSpace();
                try self.emit("(");
                if (stmt.init_stmt) |is| try self.printForInit(is);
                try self.emit(";");
                try self.emitSpace();
                if (stmt.condition) |c| try self.printExpr(c);
                try self.emit(";");
                try self.emitSpace();
                if (stmt.update) |u| try self.printForUpdate(u);
                try self.emit(")");
                try self.emitSpace();
                try stack.append(self.allocator, .{ .compound = stmt.body });
            },
            .continuing => |c| {
                try self.emit(" continuing");
                try self.emitSpace();
                try stack.append(self.allocator, .{ .compound = c });
            },
            .stmt => |s| switch (s) {
                .compound => |stmt| try stack.append(self.allocator, .{ .compound = stmt }),
                .@"return" => |stmt| {
                    try self.emit("return");
                    if (stmt.value) |v| {
                        try self.emit(" ");
                        try self.printExpr(v);
                    }
                    try self.emit(";");
                },
                .@"if" => |stmt| {
                    try self.emit("if ");
                    try self.printExpr(stmt.condition);
                    try self.emitSpace();
                    if (stmt.else_branch) |eb| try stack.append(self.allocator, .{ .else_chain = eb });
                    try stack.append(self.allocator, .{ .compound = stmt.body });
                },
                .@"switch" => |stmt| {
                    try self.emit("switch ");
                    try self.printExpr(stmt.expr);
                    try self.emitSpace();
                    // Execution order: "{" indent++ (newline case)* indent-- newline "}"
                    try stack.append(self.allocator, .{ .literal = "}" });
                    try stack.append(self.allocator, .newline);
                    try stack.append(self.allocator, .indent_dec);
                    var i = stmt.cases.items.len;
                    while (i > 0) {
                        i -= 1;
                        try stack.append(self.allocator, .{ .switch_case = &stmt.cases.items[i] });
                    }
                    try stack.append(self.allocator, .indent_inc);
                    try stack.append(self.allocator, .{ .literal = "{" });
                },
                .@"for" => |stmt| try stack.append(self.allocator, .{ .for_stmt = stmt }),
                .@"while" => |stmt| {
                    try self.emit("while ");
                    try self.printExpr(stmt.condition);
                    try self.emitSpace();
                    try stack.append(self.allocator, .{ .compound = stmt.body });
                },
                .loop => |stmt| {
                    try self.emit("loop");
                    try self.emitSpace();
                    if (stmt.continuing) |c| try stack.append(self.allocator, .{ .continuing = c });
                    try stack.append(self.allocator, .{ .compound = stmt.body });
                },
                .@"break" => try self.emit("break;"),
                .break_if => |stmt| {
                    try self.emit("break if ");
                    try self.printExpr(stmt.condition);
                    try self.emit(";");
                },
                .@"continue" => try self.emit("continue;"),
                .discard => try self.emit("discard;"),
                .assign => |stmt| {
                    try self.printExpr(stmt.left);
                    try self.emitSpace();
                    try self.emit(stmt.op.string());
                    try self.emitSpace();
                    try self.printExpr(stmt.right);
                    try self.emit(";");
                },
                .incr_decr => |stmt| {
                    try self.printExpr(stmt.expr);
                    if (stmt.increment) try self.emit("++") else try self.emit("--");
                    try self.emit(";");
                },
                .call => |stmt| {
                    try self.printExpr(.{ .call = stmt.call });
                    try self.emit(";");
                },
                .decl => |stmt| try self.printDeclStmt(stmt.decl),
            },
        }
    } else unreachable;
}

fn printForInit(self: *Printer, s: Ast.Stmt) !void {
    switch (s) {
        .decl => |ds| {
            switch (ds.decl) {
                .@"var" => |decl| {
                    try self.emit("var ");
                    try self.emitName(decl.name);
                    if (decl.typ) |t| {
                        try self.emit(":");
                        try self.emitSpace();
                        try self.printType(t);
                    }
                    if (decl.initializer) |init_expr| {
                        try self.emitSpace();
                        try self.emit("=");
                        try self.emitSpace();
                        try self.printExpr(init_expr);
                    }
                },
                .let => |decl| {
                    try self.emit("let ");
                    try self.emitName(decl.name);
                    if (decl.typ) |t| {
                        try self.emit(":");
                        try self.emitSpace();
                        try self.printType(t);
                    }
                    try self.emitSpace();
                    try self.emit("=");
                    try self.emitSpace();
                    if (decl.initializer) |init_expr| try self.printExpr(init_expr);
                },
                else => {},
            }
        },
        .assign => |stmt| {
            try self.printExpr(stmt.left);
            try self.emitSpace();
            try self.emit(stmt.op.string());
            try self.emitSpace();
            try self.printExpr(stmt.right);
        },
        else => {},
    }
}

fn printForUpdate(self: *Printer, s: Ast.Stmt) !void {
    switch (s) {
        .incr_decr => |stmt| {
            try self.printExpr(stmt.expr);
            if (stmt.increment) try self.emit("++") else try self.emit("--");
        },
        .assign => |stmt| {
            try self.printExpr(stmt.left);
            try self.emitSpace();
            try self.emit(stmt.op.string());
            try self.emitSpace();
            try self.printExpr(stmt.right);
        },
        .call => |stmt| try self.printExpr(.{ .call = stmt.call }),
        else => {},
    }
}

fn printDeclStmt(self: *Printer, d: Ast.Decl) !void {
    switch (d) {
        .@"const" => |decl| {
            try self.emit("const ");
            try self.emitName(decl.name);
            if (decl.typ) |t| {
                try self.emit(":");
                try self.emitSpace();
                try self.printType(t);
            }
            try self.emitSpace();
            try self.emit("=");
            try self.emitSpace();
            if (decl.initializer) |init_expr| try self.printExpr(init_expr);
            try self.emit(";");
        },
        .let => |decl| {
            try self.emit("let ");
            try self.emitName(decl.name);
            if (decl.typ) |t| {
                try self.emit(":");
                try self.emitSpace();
                try self.printType(t);
            }
            try self.emitSpace();
            try self.emit("=");
            try self.emitSpace();
            if (decl.initializer) |init_expr| try self.printExpr(init_expr);
            try self.emit(";");
        },
        .@"var" => |decl| {
            try self.printAttributes(decl.attributes.items);
            try self.emit("var");
            if (decl.address_space != .none) {
                try self.emit("<");
                try self.emit(decl.address_space.string());
                if (decl.access_mode != .none) {
                    try self.emit(",");
                    try self.emitSpace();
                    try self.emit(decl.access_mode.string());
                }
                try self.emit(">");
            }
            try self.emit(" ");
            try self.emitName(decl.name);
            if (decl.typ) |t| {
                try self.emit(":");
                try self.emitSpace();
                try self.printType(t);
            }
            if (decl.initializer) |init_expr| {
                try self.emitSpace();
                try self.emit("=");
                try self.emitSpace();
                try self.printExpr(init_expr);
            }
            try self.emit(";");
        },
        else => try self.printDecl(d),
    }
}

// =========================================================================
// Tests
// =========================================================================

const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");

fn expectPrinted(input: [:0]const u8, expected: []const u8) !void {
    var tokens = try Lexer.tokenize(std.testing.allocator, input);
    defer tokens.deinit(std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, input, tokens);
    const module = try parser.parse();

    var printer = Printer.init(alloc, .{}, module.symbols.items);
    defer printer.deinit();
    const actual = try printer.print(module);
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectPrintedMinify(input: [:0]const u8, expected: []const u8) !void {
    var tokens = try Lexer.tokenize(std.testing.allocator, input);
    defer tokens.deinit(std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, input, tokens);
    const module = try parser.parse();

    var printer = Printer.init(alloc, .{ .minify_whitespace = true }, module.symbols.items);
    defer printer.deinit();
    const actual = try printer.print(module);
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectPrintedMangle(input: [:0]const u8, expected: []const u8) !void {
    var tokens = try Lexer.tokenize(std.testing.allocator, input);
    defer tokens.deinit(std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, input, tokens);
    const module = try parser.parse();

    var printer = Printer.init(alloc, .{ .minify_syntax = true }, module.symbols.items);
    defer printer.deinit();
    const actual = try printer.print(module);
    try std.testing.expectEqualStrings(expected, actual);
}

// -------------------------------------------------------------------------
// Whitespace minification
// -------------------------------------------------------------------------

test "printer: minify whitespace basic" {
    try expectPrintedMinify("const x = 1;", "const x=1;");
    try expectPrintedMinify("const x = 1 + 2;", "const x=1+2;");
    try expectPrintedMinify("const x = a * b;", "const x=a*b;");
}

test "printer: minify whitespace function" {
    try expectPrintedMinify("fn foo() { return; }", "fn foo(){return;}");
    try expectPrintedMinify("fn foo() -> i32 { return 1; }", "fn foo()->i32{return 1;}");
}

test "printer: minify whitespace struct" {
    try expectPrintedMinify("struct Foo { x: i32, y: f32, }", "struct Foo{x:i32,y:f32}");
}

test "printer: minify whitespace attributes" {
    try expectPrintedMinify(
        "@group(0) @binding(1) var<uniform> u: U;",
        "@group(0) @binding(1) var<uniform> u:U;",
    );
}

// -------------------------------------------------------------------------
// Number formatting
// -------------------------------------------------------------------------

test "printer: number formatting" {
    try expectPrinted("const x = 0;", "const x = 0;\n");
    try expectPrinted("const x = 1;", "const x = 1;\n");
    try expectPrinted("const x = 42;", "const x = 42;\n");
    try expectPrinted("const x = 0.0;", "const x = 0.0;\n");
    try expectPrinted("const x = 1.0;", "const x = 1.0;\n");
    try expectPrinted("const x = 3.14159;", "const x = 3.14159;\n");
}

test "printer: number suffixes" {
    try expectPrinted("const x = 1i;", "const x = 1i;\n");
    try expectPrinted("const x = 1u;", "const x = 1u;\n");
    try expectPrinted("const x = 1.0f;", "const x = 1.0f;\n");
    try expectPrinted("const x = 1.0h;", "const x = 1.0h;\n");
}

test "printer: hex numbers" {
    try expectPrinted("const x = 0xFF;", "const x = 0xFF;\n");
    try expectPrinted("const x = 0xABCDEF;", "const x = 0xABCDEF;\n");
}

// -------------------------------------------------------------------------
// Binary operators
// -------------------------------------------------------------------------

test "printer: binary operators arithmetic" {
    try expectPrinted("const x = a + b;", "const x = a + b;\n");
    try expectPrinted("const x = a - b;", "const x = a - b;\n");
    try expectPrinted("const x = a * b;", "const x = a * b;\n");
    try expectPrinted("const x = a / b;", "const x = a / b;\n");
    try expectPrinted("const x = a % b;", "const x = a % b;\n");
}

test "printer: binary operators comparison" {
    try expectPrinted("const x = a == b;", "const x = a == b;\n");
    try expectPrinted("const x = a != b;", "const x = a != b;\n");
    try expectPrinted("const x = a < b;", "const x = a < b;\n");
    try expectPrinted("const x = a <= b;", "const x = a <= b;\n");
    try expectPrinted("const x = a > b;", "const x = a > b;\n");
    try expectPrinted("const x = a >= b;", "const x = a >= b;\n");
}

test "printer: binary operators logical" {
    try expectPrinted("const x = a && b;", "const x = a && b;\n");
    try expectPrinted("const x = a || b;", "const x = a || b;\n");
}

test "printer: binary operators bitwise" {
    try expectPrinted("const x = a & b;", "const x = a & b;\n");
    try expectPrinted("const x = a | b;", "const x = a | b;\n");
    try expectPrinted("const x = a ^ b;", "const x = a ^ b;\n");
    try expectPrinted("const x = a << b;", "const x = a << b;\n");
    try expectPrinted("const x = a >> b;", "const x = a >> b;\n");
}

test "printer: all binary operators numeric" {
    // Arithmetic
    try expectPrinted("const x = 1 + 2;", "const x = 1 + 2;\n");
    try expectPrinted("const x = 1 - 2;", "const x = 1 - 2;\n");
    try expectPrinted("const x = 1 * 2;", "const x = 1 * 2;\n");
    try expectPrinted("const x = 1 / 2;", "const x = 1 / 2;\n");
    try expectPrinted("const x = 1 % 2;", "const x = 1 % 2;\n");
    // Bitwise
    try expectPrinted("const x = 1 & 2;", "const x = 1 & 2;\n");
    try expectPrinted("const x = 1 | 2;", "const x = 1 | 2;\n");
    try expectPrinted("const x = 1 ^ 2;", "const x = 1 ^ 2;\n");
    try expectPrinted("const x = 1 << 2;", "const x = 1 << 2;\n");
    try expectPrinted("const x = 1 >> 2;", "const x = 1 >> 2;\n");
    // Logical
    try expectPrinted("const x = true && false;", "const x = true && false;\n");
    try expectPrinted("const x = true || false;", "const x = true || false;\n");
    // Comparison
    try expectPrinted("const x = 1 == 2;", "const x = 1 == 2;\n");
    try expectPrinted("const x = 1 != 2;", "const x = 1 != 2;\n");
    try expectPrinted("const x = 1 < 2;", "const x = 1 < 2;\n");
    try expectPrinted("const x = 1 <= 2;", "const x = 1 <= 2;\n");
    try expectPrinted("const x = 1 > 2;", "const x = 1 > 2;\n");
    try expectPrinted("const x = 1 >= 2;", "const x = 1 >= 2;\n");
}

// -------------------------------------------------------------------------
// Unary operators
// -------------------------------------------------------------------------

test "printer: unary operators" {
    try expectPrinted("const x = -a;", "const x = -a;\n");
    try expectPrinted("const x = !a;", "const x = !a;\n");
    try expectPrinted("const x = ~a;", "const x = ~a;\n");
    try expectPrinted("const x = -1;", "const x = -1;\n");
    try expectPrinted("const x = !true;", "const x = !true;\n");
    try expectPrinted("const x = ~1;", "const x = ~1;\n");
}

// -------------------------------------------------------------------------
// Assignment operators
// -------------------------------------------------------------------------

test "printer: assignment operators" {
    try expectPrinted("fn f() { x = 1; }", "fn f() {\n    x = 1;\n}\n");
    try expectPrinted("fn f() { x += 1; }", "fn f() {\n    x += 1;\n}\n");
    try expectPrinted("fn f() { x -= 1; }", "fn f() {\n    x -= 1;\n}\n");
    try expectPrinted("fn f() { x *= 2; }", "fn f() {\n    x *= 2;\n}\n");
    try expectPrinted("fn f() { x /= 2; }", "fn f() {\n    x /= 2;\n}\n");
    try expectPrinted("fn f() { x %= 2; }", "fn f() {\n    x %= 2;\n}\n");
    try expectPrinted("fn f() { x &= 1; }", "fn f() {\n    x &= 1;\n}\n");
    try expectPrinted("fn f() { x |= 1; }", "fn f() {\n    x |= 1;\n}\n");
    try expectPrinted("fn f() { x ^= 1; }", "fn f() {\n    x ^= 1;\n}\n");
    try expectPrinted("fn f() { x <<= 1; }", "fn f() {\n    x <<= 1;\n}\n");
    try expectPrinted("fn f() { x >>= 1; }", "fn f() {\n    x >>= 1;\n}\n");
}

test "printer: compound assignment operators with var" {
    try expectPrinted("fn f() { var x: i32; x += 1; }", "fn f() {\n    var x: i32;\n    x += 1;\n}\n");
    try expectPrinted("fn f() { var x: i32; x -= 1; }", "fn f() {\n    var x: i32;\n    x -= 1;\n}\n");
    try expectPrinted("fn f() { var x: i32; x *= 2; }", "fn f() {\n    var x: i32;\n    x *= 2;\n}\n");
    try expectPrinted("fn f() { var x: i32; x /= 2; }", "fn f() {\n    var x: i32;\n    x /= 2;\n}\n");
    try expectPrinted("fn f() { var x: i32; x %= 3; }", "fn f() {\n    var x: i32;\n    x %= 3;\n}\n");
    try expectPrinted("fn f() { var x: i32; x &= 1; }", "fn f() {\n    var x: i32;\n    x &= 1;\n}\n");
    try expectPrinted("fn f() { var x: i32; x |= 1; }", "fn f() {\n    var x: i32;\n    x |= 1;\n}\n");
    try expectPrinted("fn f() { var x: i32; x ^= 1; }", "fn f() {\n    var x: i32;\n    x ^= 1;\n}\n");
    try expectPrinted("fn f() { var x: i32; x <<= 1; }", "fn f() {\n    var x: i32;\n    x <<= 1;\n}\n");
    try expectPrinted("fn f() { var x: i32; x >>= 1; }", "fn f() {\n    var x: i32;\n    x >>= 1;\n}\n");
}

// -------------------------------------------------------------------------
// If / while / loop / switch statements
// -------------------------------------------------------------------------

test "printer: if formatting" {
    try expectPrinted(
        "fn f() { if x { return; } }",
        "fn f() {\n    if x {\n        return;\n    }\n}\n",
    );
    try expectPrinted(
        "fn f() { if x { return; } else { return; } }",
        "fn f() {\n    if x {\n        return;\n    } else {\n        return;\n    }\n}\n",
    );
}

test "printer: while formatting" {
    try expectPrinted(
        "fn f() { while x { break; } }",
        "fn f() {\n    while x {\n        break;\n    }\n}\n",
    );
}

test "printer: while with condition and body" {
    try expectPrinted(
        "fn f() { var x: i32 = 0; while x < 10 { x += 1; } }",
        "fn f() {\n    var x: i32 = 0;\n    while x < 10 {\n        x += 1;\n    }\n}\n",
    );
}

test "printer: loop formatting" {
    try expectPrinted(
        "fn f() { loop { break; } }",
        "fn f() {\n    loop {\n        break;\n    }\n}\n",
    );
}

test "printer: switch formatting" {
    try expectPrinted(
        "fn f() { switch x { case 1: { } default: { } } }",
        "fn f() {\n    switch x {\n        case 1: {\n        }\n        default: {\n        }\n    }\n}\n",
    );
}

test "printer: switch with multiple cases" {
    try expectPrinted(
        "fn f() { switch x { case 1: { return; } case 2, 3: { return; } default: { return; } } }",
        "fn f() {\n    switch x {\n        case 1: {\n            return;\n        }\n        case 2, 3: {\n            return;\n        }\n        default: {\n            return;\n        }\n    }\n}\n",
    );
}

test "printer: switch with var and multiple cases" {
    try expectPrinted(
        "fn f() { var x: i32; switch x { case 1: { break; } case 2, 3: { break; } default: { break; } } }",
        "fn f() {\n    var x: i32;\n    switch x {\n        case 1: {\n            break;\n        }\n        case 2, 3: {\n            break;\n        }\n        default: {\n            break;\n        }\n    }\n}\n",
    );
}

test "printer: switch minified" {
    try expectPrintedMinify(
        "fn f() { switch x { case 1: { return; } default: { return; } } }",
        "fn f(){switch x{case 1:{return;}default:{return;}}}",
    );
}

// -------------------------------------------------------------------------
// If-else chains
// -------------------------------------------------------------------------

test "printer: if-else-if chain" {
    try expectPrinted(
        "fn f() { if a { return; } else if b { return; } else { return; } }",
        "fn f() {\n    if a {\n        return;\n    } else if b {\n        return;\n    } else {\n        return;\n    }\n}\n",
    );
}

test "printer: if-else-if minified" {
    try expectPrintedMinify(
        "fn f() { if a { return; } else if b { return; } }",
        "fn f(){if a{return;} else if b{return;}}",
    );
}

test "printer: if-else with compound block" {
    try expectPrinted(
        "fn f() { if a { return; } else { break; } }",
        "fn f() {\n    if a {\n        return;\n    } else {\n        break;\n    }\n}\n",
    );
}

test "printer: deep if-else chain" {
    try expectPrinted(
        "fn f() { if a { return; } else if b { return; } else if c { return; } else { return; } }",
        "fn f() {\n    if a {\n        return;\n    } else if b {\n        return;\n    } else if c {\n        return;\n    } else {\n        return;\n    }\n}\n",
    );
}

// -------------------------------------------------------------------------
// Type formatting
// -------------------------------------------------------------------------

test "printer: vector types" {
    try expectPrinted("var x: vec2<f32>;", "var x: vec2<f32>;\n");
    try expectPrinted("var x: vec3<f32>;", "var x: vec3<f32>;\n");
    try expectPrinted("var x: vec4<f32>;", "var x: vec4<f32>;\n");
    try expectPrinted("var x: vec2f;", "var x: vec2f;\n");
    try expectPrinted("var x: vec3f;", "var x: vec3f;\n");
    try expectPrinted("var x: vec4f;", "var x: vec4f;\n");
}

test "printer: vec shorthand types in params" {
    try expectPrinted("fn f(v: vec2f) {}", "fn f(v: vec2f) {\n}\n");
    try expectPrinted("fn f(v: vec3f) {}", "fn f(v: vec3f) {\n}\n");
    try expectPrinted("fn f(v: vec4f) {}", "fn f(v: vec4f) {\n}\n");
    try expectPrinted("fn f(v: vec2i) {}", "fn f(v: vec2i) {\n}\n");
    try expectPrinted("fn f(v: vec2u) {}", "fn f(v: vec2u) {\n}\n");
}

test "printer: vec generic types in params" {
    try expectPrinted("fn f(v: vec4<f32>) {}", "fn f(v: vec4<f32>) {\n}\n");
    try expectPrinted("fn f(v: vec3<i32>) {}", "fn f(v: vec3<i32>) {\n}\n");
    try expectPrinted("fn f(v: vec2<u32>) {}", "fn f(v: vec2<u32>) {\n}\n");
}

test "printer: matrix type shorthand" {
    try expectPrinted("var x: mat4x4f;", "var x: mat4x4f;\n");
    try expectPrinted("fn f(m: mat2x2f) {}", "fn f(m: mat2x2f) {\n}\n");
    try expectPrinted("fn f(m: mat3x3f) {}", "fn f(m: mat3x3f) {\n}\n");
    try expectPrinted("fn f(m: mat4x4f) {}", "fn f(m: mat4x4f) {\n}\n");
}

test "printer: matrix type generic" {
    try expectPrinted("fn f(m: mat2x2<f32>) {}", "fn f(m: mat2x2<f32>) {\n}\n");
    try expectPrinted("fn f(m: mat3x4<f16>) {}", "fn f(m: mat3x4<f16>) {\n}\n");
}

test "printer: array types" {
    try expectPrinted("var x: array<f32>;", "var x: array<f32>;\n");
    try expectPrinted("var<storage> data: array<f32>;", "var<storage> data: array<f32>;\n");
}

test "printer: pointer types" {
    try expectPrinted("var x: ptr<function, f32>;", "var x: ptr<function, f32>;\n");
    try expectPrinted("var x: ptr<storage, f32, read_write>;", "var x: ptr<storage, f32, read_write>;\n");
    try expectPrinted("fn f(p: ptr<function, i32>) {}", "fn f(p: ptr<function, i32>) {\n}\n");
    try expectPrinted("fn f(p: ptr<storage, i32, read_write>) {}", "fn f(p: ptr<storage, i32, read_write>) {\n}\n");
    try expectPrinted("fn f(p: ptr<storage, f32, read>) {}", "fn f(p: ptr<storage, f32, read>) {\n}\n");
}

test "printer: atomic types" {
    try expectPrinted("var<workgroup> counter: atomic<u32>;", "var<workgroup> counter: atomic<u32>;\n");
    try expectPrinted("var<workgroup> a: atomic<u32>;", "var<workgroup> a: atomic<u32>;\n");
    try expectPrinted("var<workgroup> a: atomic<i32>;", "var<workgroup> a: atomic<i32>;\n");
}

test "printer: sampler types" {
    try expectPrinted(
        "@group(0) @binding(0) var s: sampler;",
        "@group(0) @binding(0) var s: sampler;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var s: sampler_comparison;",
        "@group(0) @binding(0) var s: sampler_comparison;\n",
    );
}

test "printer: texture sampled types" {
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_2d<f32>;",
        "@group(0) @binding(0) var t: texture_2d<f32>;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_3d<f32>;",
        "@group(0) @binding(0) var t: texture_3d<f32>;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_cube<f32>;",
        "@group(0) @binding(0) var t: texture_cube<f32>;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_1d<f32>;",
        "@group(0) @binding(0) var t: texture_1d<f32>;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_2d_array<f32>;",
        "@group(0) @binding(0) var t: texture_2d_array<f32>;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_cube_array<f32>;",
        "@group(0) @binding(0) var t: texture_cube_array<f32>;\n",
    );
}

test "printer: texture multisampled types" {
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_multisampled_2d<f32>;",
        "@group(0) @binding(0) var t: texture_multisampled_2d<f32>;\n",
    );
}

test "printer: texture storage types" {
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, write>;",
        "@group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, write>;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, read_write>;",
        "@group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, read_write>;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_storage_3d<rgba8unorm, write>;",
        "@group(0) @binding(0) var t: texture_storage_3d<rgba8unorm, write>;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_storage_1d<rgba8unorm, write>;",
        "@group(0) @binding(0) var t: texture_storage_1d<rgba8unorm, write>;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_storage_2d_array<rgba8unorm, write>;",
        "@group(0) @binding(0) var t: texture_storage_2d_array<rgba8unorm, write>;\n",
    );
}

test "printer: texture depth types" {
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_2d;",
        "@group(0) @binding(0) var t: texture_depth_2d;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_cube;",
        "@group(0) @binding(0) var t: texture_depth_cube;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_2d_array;",
        "@group(0) @binding(0) var t: texture_depth_2d_array;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_cube_array;",
        "@group(0) @binding(0) var t: texture_depth_cube_array;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_multisampled_2d;",
        "@group(0) @binding(0) var t: texture_depth_multisampled_2d;\n",
    );
}

test "printer: texture external" {
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_external;",
        "@group(0) @binding(0) var t: texture_external;\n",
    );
}

// -------------------------------------------------------------------------
// Attribute formatting
// -------------------------------------------------------------------------

test "printer: function attributes" {
    try expectPrinted("@vertex fn main() {}", "@vertex fn main() {\n}\n");
    try expectPrinted("@fragment fn main() {}", "@fragment fn main() {\n}\n");
    try expectPrinted(
        "@compute @workgroup_size(64) fn main() {}",
        "@compute @workgroup_size(64) fn main() {\n}\n",
    );
}

test "printer: binding attributes" {
    try expectPrinted(
        "@group(0) @binding(0) var<uniform> u: U;",
        "@group(0) @binding(0) var<uniform> u: U;\n",
    );
    try expectPrinted(
        "@group(0) @binding(1) var<uniform> u: U;",
        "@group(0) @binding(1) var<uniform> u: U;\n",
    );
}

test "printer: builtin attribute on struct member" {
    try expectPrinted(
        "struct V { @builtin(position) p: vec4f, }",
        "struct V {\n    @builtin(position) p: vec4f\n}\n",
    );
}

test "printer: location attribute on struct member" {
    try expectPrinted(
        "struct V { @location(0) uv: vec2f, }",
        "struct V {\n    @location(0) uv: vec2f\n}\n",
    );
}

test "printer: workgroup_size with multiple args" {
    try expectPrinted(
        "@workgroup_size(8, 8, 1) @compute fn main() {}",
        "@workgroup_size(8, 8, 1) @compute fn main() {\n}\n",
    );
}

test "printer: function with return attribute" {
    try expectPrinted(
        "@vertex fn main() -> @builtin(position) vec4<f32> { return vec4<f32>(0.0); }",
        "@vertex fn main() -> @builtin(position) vec4<f32> {\n    return vec4<f32>(0.0);\n}\n",
    );
}

test "printer: function with parameter attribute" {
    try expectPrinted(
        "@fragment fn main(@location(0) color: vec4<f32>) -> @location(0) vec4<f32> { return color; }",
        "@fragment fn main(@location(0) color: vec4<f32>) -> @location(0) vec4<f32> {\n    return color;\n}\n",
    );
}

// -------------------------------------------------------------------------
// Directive formatting
// -------------------------------------------------------------------------

test "printer: enable directive" {
    try expectPrinted("enable f16;", "enable f16;\n");
    try expectPrinted("enable f16, clip_distances;", "enable f16, clip_distances;\n");
}

test "printer: requires directive" {
    try expectPrinted("requires foo;", "requires foo;\n");
    try expectPrinted("requires my_feature;", "requires my_feature;\n");
    try expectPrinted("requires feature1, feature2;", "requires feature1, feature2;\n");
}

test "printer: diagnostic directive" {
    try expectPrinted("diagnostic(off, bar);", "diagnostic(off, bar);\n");
    try expectPrinted("diagnostic(warning, my_category);", "diagnostic(warning, my_category);\n");
}

test "printer: directives followed by declarations" {
    // The Zig printer emits an extra newline between directives and declarations.
    try expectPrinted("enable f16; const x = 1;", "enable f16;\n\nconst x = 1;\n");
}

// -------------------------------------------------------------------------
// Complex expressions
// -------------------------------------------------------------------------

test "printer: complex expressions" {
    try expectPrinted("const x = a + b * c;", "const x = a + b * c;\n");
    try expectPrinted("const x = (a + b) * c;", "const x = (a + b) * c;\n");
    try expectPrinted("const x = a.b.c;", "const x = a.b.c;\n");
    try expectPrinted("const x = a[0].b;", "const x = a[0].b;\n");
    try expectPrinted("const x = foo(a, b).c;", "const x = foo(a, b).c;\n");
}

test "printer: call expressions" {
    try expectPrinted("const x = foo();", "const x = foo();\n");
    try expectPrinted("const x = foo(1);", "const x = foo(1);\n");
    try expectPrinted("const x = foo(1, 2, 3);", "const x = foo(1, 2, 3);\n");
    try expectPrinted("const x = vec3f(1.0, 2.0, 3.0);", "const x = vec3f(1.0, 2.0, 3.0);\n");
}

test "printer: vec constructor with template type" {
    try expectPrinted("const x = vec3<f32>(1.0, 2.0, 3.0);", "const x = vec3<f32>(1.0, 2.0, 3.0);\n");
    try expectPrinted("const x = vec2<i32>(1, 2);", "const x = vec2<i32>(1, 2);\n");
}

test "printer: array constructor" {
    try expectPrinted("const x = array<i32, 3>(1, 2, 3);", "const x = array<i32, 3>(1, 2, 3);\n");
}

// -------------------------------------------------------------------------
// Roundtrip
// -------------------------------------------------------------------------

test "printer: roundtrip" {
    const inputs: []const [:0]const u8 = &.{
        "const x = 1;",
        "var x: i32;",
        "fn foo() {}",
        "fn foo() -> i32 { return 1; }",
        "struct Foo { x: i32, }",
        "@vertex fn main() {}",
    };

    for (inputs) |input| {
        // First pass
        var tokens1 = try Lexer.tokenize(std.testing.allocator, input);
        defer tokens1.deinit(std.testing.allocator);
        var arena1 = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena1.deinit();
        const alloc1 = arena1.allocator();
        var parser1 = try Parser.init(alloc1, input, tokens1);
        const module1 = try parser1.parse();
        var printer1 = Printer.init(alloc1, .{}, module1.symbols.items);
        defer printer1.deinit();
        const output1 = try printer1.print(module1);
        const owned1 = try std.testing.allocator.dupe(u8, output1);
        defer std.testing.allocator.free(owned1);

        // Second pass using output of first
        const sentinel1 = try std.testing.allocator.dupeZ(u8, owned1);
        defer std.testing.allocator.free(sentinel1);
        var tokens2 = try Lexer.tokenize(std.testing.allocator, sentinel1);
        defer tokens2.deinit(std.testing.allocator);
        var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena2.deinit();
        const alloc2 = arena2.allocator();
        var parser2 = try Parser.init(alloc2, sentinel1, tokens2);
        const module2 = try parser2.parse();
        var printer2 = Printer.init(alloc2, .{}, module2.symbols.items);
        defer printer2.deinit();
        const output2 = try printer2.print(module2);

        try std.testing.expectEqualStrings(owned1, output2);
    }
}

// -------------------------------------------------------------------------
// For loop variants
// -------------------------------------------------------------------------

test "printer: for loop basic" {
    try expectPrinted(
        "fn f() { for (var i = 0; i < 10; i++) { break; } }",
        "fn f() {\n    for (var i = 0; i < 10; i++) {\n        break;\n    }\n}\n",
    );
}

test "printer: for loop minified" {
    try expectPrintedMinify(
        "fn f() { for (var i = 0; i < 10; i++) { break; } }",
        "fn f(){for(var i=0;i<10;i++){break;}}",
    );
}

test "printer: for loop with let init" {
    try expectPrinted(
        "fn f() { for (let i = 0; i < 10; i++) { break; } }",
        "fn f() {\n    for (let i = 0; i < 10; i++) {\n        break;\n    }\n}\n",
    );
}

test "printer: for loop with assign update" {
    try expectPrinted(
        "fn f() { for (var i = 0; i < 10; i += 2) { break; } }",
        "fn f() {\n    for (var i = 0; i < 10; i += 2) {\n        break;\n    }\n}\n",
    );
}

test "printer: for loop decrement" {
    try expectPrinted(
        "fn f() { for (var i = 10; i > 0; i--) { break; } }",
        "fn f() {\n    for (var i = 10; i > 0; i--) {\n        break;\n    }\n}\n",
    );
}

test "printer: for loop with typed var init" {
    try expectPrinted(
        "fn f() { for (var i: u32 = 0; i < 10; i++) { break; } }",
        "fn f() {\n    for (var i: u32 = 0; i < 10; i++) {\n        break;\n    }\n}\n",
    );
}

test "printer: for loop with typed let init" {
    try expectPrinted(
        "fn f() { for (let i: u32 = 0; i < 10; i++) { break; } }",
        "fn f() {\n    for (let i: u32 = 0; i < 10; i++) {\n        break;\n    }\n}\n",
    );
}

test "printer: for loop with assign init" {
    try expectPrinted(
        "fn f() { var i: i32; for (i = 0; i < 10; i++) { break; } }",
        "fn f() {\n    var i: i32;\n    for (i = 0; i < 10; i++) {\n        break;\n    }\n}\n",
    );
}

test "printer: for loop with simple assign update" {
    try expectPrinted(
        "fn f() { for (var i = 0; i < 10; i = i + 2) { break; } }",
        "fn f() {\n    for (var i = 0; i < 10; i = i + 2) {\n        break;\n    }\n}\n",
    );
}

test "printer: for loop with call update" {
    // Two functions: no blank line between them in Zig printer (unlike Go).
    try expectPrinted(
        "fn update() {} fn f() { for (var i = 0; i < 10; update()) { break; } }",
        "fn update() {\n}\nfn f() {\n    for (var i = 0; i < 10; update()) {\n        break;\n    }\n}\n",
    );
}

// -------------------------------------------------------------------------
// Override, alias, const_assert
// -------------------------------------------------------------------------

test "printer: override declaration" {
    try expectPrinted("@id(1) override x: f32 = 1.0;", "@id(1) override x: f32 = 1.0;\n");
    try expectPrinted("override y: u32;", "override y: u32;\n");
    try expectPrinted("@id(0) override x: f32;", "@id(0) override x: f32;\n");
    try expectPrinted("override x = 1.0;", "override x = 1.0;\n");
    try expectPrinted("@id(0) override x: f32 = 1.0;", "@id(0) override x: f32 = 1.0;\n");
    try expectPrinted("@id(0) override scale: f32 = 1.0;", "@id(0) override scale: f32 = 1.0;\n");
}

test "printer: alias declaration" {
    try expectPrinted("alias Float = f32;", "alias Float = f32;\n");
    try expectPrinted("alias MyFloat = f32;", "alias MyFloat = f32;\n");
    try expectPrinted("alias MyVec = vec3<f32>;", "alias MyVec = vec3<f32>;\n");
}

test "printer: const_assert" {
    try expectPrinted("const_assert true;", "const_assert true;\n");
    try expectPrinted("const_assert 1 == 1;", "const_assert 1 == 1;\n");
}

// -------------------------------------------------------------------------
// Bool literals
// -------------------------------------------------------------------------

test "printer: bool literals" {
    try expectPrinted("const x = true;", "const x = true;\n");
    try expectPrinted("const x = false;", "const x = false;\n");
}

// -------------------------------------------------------------------------
// Address-of and deref
// -------------------------------------------------------------------------

test "printer: address-of and deref" {
    try expectPrinted("fn f() { let x = &y; }", "fn f() {\n    let x = &y;\n}\n");
    try expectPrinted("fn f() { let x = *y; }", "fn f() {\n    let x = *y;\n}\n");
}

// -------------------------------------------------------------------------
// Variable declarations
// -------------------------------------------------------------------------

test "printer: var declaration global" {
    try expectPrinted("var x: i32;", "var x: i32;\n");
    try expectPrinted("var<private> x: i32;", "var<private> x: i32;\n");
    try expectPrinted("var<storage, read> data: array<f32>;", "var<storage, read> data: array<f32>;\n");
}

test "printer: var declaration in function" {
    try expectPrinted("fn f() { var x: i32; }", "fn f() {\n    var x: i32;\n}\n");
    try expectPrinted("fn f() { var x: i32 = 5; }", "fn f() {\n    var x: i32 = 5;\n}\n");
    try expectPrinted("fn f() { var<private> x: i32; }", "fn f() {\n    var<private> x: i32;\n}\n");
    try expectPrinted("fn f() { var<storage, read_write> x: i32; }", "fn f() {\n    var<storage, read_write> x: i32;\n}\n");
}

test "printer: let declaration in function" {
    try expectPrinted("fn f() { let x = 1; }", "fn f() {\n    let x = 1;\n}\n");
    try expectPrinted("fn f() { let x: f32 = 1.0; }", "fn f() {\n    let x: f32 = 1.0;\n}\n");
    try expectPrinted("fn f() { let x: i32 = 5; }", "fn f() {\n    let x: i32 = 5;\n}\n");
}

test "printer: const declaration with type" {
    try expectPrinted("const x: i32 = 1;", "const x: i32 = 1;\n");
    try expectPrinted("fn f() { const x: i32 = 1; }", "fn f() {\n    const x: i32 = 1;\n}\n");
    try expectPrinted("fn f() { const x: i32 = 1; }", "fn f() {\n    const x: i32 = 1;\n}\n");
    try expectPrinted("fn f() { let x: f32 = 1.0; }", "fn f() {\n    let x: f32 = 1.0;\n}\n");
}

// -------------------------------------------------------------------------
// Statements: continue, discard, call, incr/decr, break-if
// -------------------------------------------------------------------------

test "printer: continue statement" {
    try expectPrinted(
        "fn f() { loop { continue; } }",
        "fn f() {\n    loop {\n        continue;\n    }\n}\n",
    );
}

test "printer: discard statement" {
    try expectPrinted(
        "@fragment fn f() { discard; }",
        "@fragment fn f() {\n    discard;\n}\n",
    );
}

test "printer: call statement" {
    try expectPrinted(
        "fn f() { foo(); }",
        "fn f() {\n    foo();\n}\n",
    );
    try expectPrinted(
        "fn f() { bar(1, 2, 3); }",
        "fn f() {\n    bar(1, 2, 3);\n}\n",
    );
}

test "printer: increment and decrement statements" {
    try expectPrinted("fn f() { i++; }", "fn f() {\n    i++;\n}\n");
    try expectPrinted("fn f() { i--; }", "fn f() {\n    i--;\n}\n");
    try expectPrinted(
        "fn f() { var x: i32 = 0; x++; }",
        "fn f() {\n    var x: i32 = 0;\n    x++;\n}\n",
    );
    try expectPrinted(
        "fn f() { var x: i32 = 10; x--; }",
        "fn f() {\n    var x: i32 = 10;\n    x--;\n}\n",
    );
}

test "printer: break-if statement" {
    try expectPrinted(
        "fn f() { loop { break if x; } }",
        "fn f() {\n    loop {\n        break if x;\n    }\n}\n",
    );
}

test "printer: return without value" {
    try expectPrinted("fn f() { return; }", "fn f() {\n    return;\n}\n");
}

// -------------------------------------------------------------------------
// Nested compound statement
// -------------------------------------------------------------------------

test "printer: nested compound statement" {
    try expectPrinted(
        "fn f() { { let x = 1; } }",
        "fn f() {\n    {\n        let x = 1;\n    }\n}\n",
    );
}

// -------------------------------------------------------------------------
// Struct formatting
// -------------------------------------------------------------------------

test "printer: struct multiple members" {
    try expectPrinted(
        "struct Foo { x: i32, y: f32, z: u32 }",
        "struct Foo {\n    x: i32,\n    y: f32,\n    z: u32\n}\n",
    );
}

// -------------------------------------------------------------------------
// Function formatting
// -------------------------------------------------------------------------

test "printer: function with multiple params" {
    try expectPrinted(
        "fn add(a: i32, b: i32) -> i32 { return a + b; }",
        "fn add(a: i32, b: i32) -> i32 {\n    return a + b;\n}\n",
    );
}

// -------------------------------------------------------------------------
// MinifySyntax (mangle)
// -------------------------------------------------------------------------

test "printer: minify syntax leading zero" {
    // Strip leading zero before decimal point.
    try expectPrintedMangle("const x = 0.5;", "const x = .5;\n");
    try expectPrintedMangle("const x = 0.25;", "const x = .25;\n");
    try expectPrintedMangle("const x = 0.123;", "const x = .123;\n");
}

test "printer: minify syntax trailing zero" {
    // Strip trailing zeros after decimal point.
    try expectPrintedMangle("const x = 1.0;", "const x = 1.;\n");
    try expectPrintedMangle("const x = 2.50;", "const x = 2.5;\n");
    try expectPrintedMangle("const x = 3.100;", "const x = 3.1;\n");
}

test "printer: minify syntax scientific notation" {
    // Use scientific notation when shorter.
    try expectPrintedMangle("const x = 1000000.0;", "const x = 1e6;\n");
    try expectPrintedMangle("const x = 10000.0;", "const x = 1e4;\n");
    try expectPrintedMangle("const x = 200.0;", "const x = 2e2;\n");
}

test "printer: minify syntax no change when not shorter" {
    // Don't apply when result would be same length or longer.
    try expectPrintedMangle("const x = 1.5;", "const x = 1.5;\n");
    try expectPrintedMangle("const x = 100;", "const x = 100;\n");
    try expectPrintedMangle("const x = 12.3;", "const x = 12.3;\n");
}

test "printer: minify syntax preserves hex and suffixed" {
    // Hex literals left as-is.
    try expectPrintedMangle("const x = 0xFF;", "const x = 0xFF;\n");
    // Suffixed literals preserve suffix.
    try expectPrintedMangle("const x = 0.5f;", "const x = .5f;\n");
    try expectPrintedMangle("const x = 1.0f;", "const x = 1.f;\n");
    try expectPrintedMangle("const x = 1.0h;", "const x = 1.h;\n");
}

test "printer: minify syntax preserves scientific input" {
    // Already scientific — don't double-process.
    try expectPrintedMangle("const x = 1e6;", "const x = 1e6;\n");
    try expectPrintedMangle("const x = 2.5e3;", "const x = 2.5e3;\n");
}

test "printer: minify syntax edge cases" {
    // "0.0" → "0." (can't strip both leading and trailing).
    try expectPrintedMangle("const x = 0.0;", "const x = 0.;\n");
    // Single digit — no change.
    try expectPrintedMangle("const x = 0;", "const x = 0;\n");
    try expectPrintedMangle("const x = 1;", "const x = 1;\n");
}

test "printer: bare dot float literal must not be produced" {
    // ".00" must NOT become "." (invalid WGSL). Must stay as ".00".
    // This triggered a shader compilation failure when unary minus
    // produced `-.` from `-.00` in minified output.
    try expectPrintedMangle("const x = .00;", "const x = .00;\n");
    try expectPrintedMangle("const x = .000;", "const x = .000;\n");
    // ".0" is already minimal — no change.
    try expectPrintedMangle("const x = .0;", "const x = .0;\n");
    // ".10" → ".1" is fine (non-zero fractional digit remains).
    try expectPrintedMangle("const x = .10;", "const x = .1;\n");
    // "0.00" → "0." is valid (has integer part).
    try expectPrintedMangle("const x = 0.00;", "const x = 0.;\n");
    // Negative context: unary minus + .00 in an expression.
    try expectPrintedMangle(
        "fn f() -> vec3f { return vec3f(-.00, .47, .58); }",
        "fn f() -> vec3f {\n    return vec3f(-.00, .47, .58);\n}\n",
    );
}

// -------------------------------------------------------------------------
// Builtin identifier (no Ref)
// -------------------------------------------------------------------------

test "printer: builtin identifier" {
    try expectPrinted("fn f() { let x = abs(-1); }", "fn f() {\n    let x = abs(-1);\n}\n");
}

// -------------------------------------------------------------------------
// Multiple declarations — Zig printer does NOT insert blank lines between
// top-level declarations (unlike Go's printer).
// -------------------------------------------------------------------------

test "printer: multiple declarations no blank line" {
    try expectPrinted(
        "const a = 1; const b = 2; const c = 3;",
        "const a = 1;\nconst b = 2;\nconst c = 3;\n",
    );
}

test "printer: two functions no blank line" {
    // Zig printer: no blank line between top-level declarations.
    try expectPrinted(
        "fn helper() {} fn f() { helper(); }",
        "fn helper() {\n}\nfn f() {\n    helper();\n}\n",
    );
}
