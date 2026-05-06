//! Call Hierarchy: prepare a target item, then traverse incoming /
//! outgoing calls. The traversal walks every function body in the
//! module looking for ident-call expressions that match the target.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const Position = Handler.Position;
const Range = Handler.Range;
const SymbolKind = Handler.SymbolKind;
const NodeAtOffset = @import("node_at_offset.zig");
const Ast = wgslender.Ast;

pub const CallHierarchyItem = struct {
    name: []const u8,
    kind: SymbolKind,
    range: Range,
    selection_range: Range,
};

pub const IncomingCall = struct {
    from: CallHierarchyItem,
    from_ranges: []const Range,
};

pub const OutgoingCall = struct {
    to: CallHierarchyItem,
    from_ranges: []const Range,
};

pub fn prepareCallHierarchy(handler: *Handler, uri: []const u8, position: Position) !?CallHierarchyItem {
    const doc = handler.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(Handler.lspPositionToOffset(source, position) orelse return null);
    const analysis = try handler.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = NodeAtOffset.find(module, offset);
    const sym_idx: Ast.SymbolIndex = switch (node) {
        .ident => |id| id.ref,
        .decl_name => |dn| dn.sym_idx,
        else => return null,
    };
    if (!sym_idx.isValid()) return null;
    const sym = module.symbols.items[sym_idx.index()];
    if (sym.kind != .function) return null;

    const sel_range = Handler.offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse return null;
    return .{
        .name = sym.original_name,
        .kind = .function,
        .range = sel_range,
        .selection_range = sel_range,
    };
}

pub fn computeIncomingCalls(handler: *Handler, uri: []const u8, target_name: []const u8) ![]IncomingCall {
    const analysis = handler.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};
    const source = module.source;

    var calls: std.ArrayList(IncomingCall) = .empty;
    defer calls.deinit(handler.gpa);

    // For each function, check if it calls the target
    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (!f.name.isValid()) continue;
                if (f.body == null) continue;
                const caller_sym = module.symbols.items[f.name.index()];
                if (std.mem.eql(u8, caller_sym.original_name, target_name)) continue; // skip self

                // Scan for calls to target in this function body
                var call_locs: std.ArrayList(Range) = .empty;
                defer call_locs.deinit(handler.gpa);
                findCallsInCompound(handler.gpa, module, f.body.?, target_name, source, &call_locs);

                if (call_locs.items.len > 0) {
                    const sel_range = Handler.offsetRangeToLspRange(source, caller_sym.loc, caller_sym.loc + @as(u32, @intCast(caller_sym.original_name.len))) orelse continue;
                    try calls.append(handler.gpa, .{
                        .from = .{
                            .name = caller_sym.original_name,
                            .kind = .function,
                            .range = sel_range,
                            .selection_range = sel_range,
                        },
                        .from_ranges = try handler.gpa.dupe(Range, call_locs.items),
                    });
                }
            },
            else => {},
        }
    }

    return try handler.gpa.dupe(IncomingCall, calls.items);
}

pub fn computeOutgoingCalls(handler: *Handler, uri: []const u8, caller_name: []const u8) ![]OutgoingCall {
    const analysis = handler.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};
    const source = module.source;

    // Find the caller function
    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (!f.name.isValid()) continue;
                if (f.body == null) continue;
                const sym = module.symbols.items[f.name.index()];
                if (!std.mem.eql(u8, sym.original_name, caller_name)) continue;

                // Collect all outgoing calls
                var calls_map = std.StringHashMapUnmanaged(std.ArrayList(Range)){};
                defer {
                    var it = calls_map.iterator();
                    while (it.next()) |entry| entry.value_ptr.deinit(handler.gpa);
                    calls_map.deinit(handler.gpa);
                }

                collectOutgoingCalls(handler.gpa, module, f.body.?, source, &calls_map);

                var results: std.ArrayList(OutgoingCall) = .empty;
                defer results.deinit(handler.gpa);

                var it = calls_map.iterator();
                while (it.next()) |entry| {
                    const callee_name = entry.key_ptr.*;
                    // Find callee symbol for range info
                    for (module.symbols.items) |callee_sym| {
                        if (std.mem.eql(u8, callee_sym.original_name, callee_name) and callee_sym.kind == .function) {
                            const sel_range = Handler.offsetRangeToLspRange(source, callee_sym.loc, callee_sym.loc + @as(u32, @intCast(callee_sym.original_name.len))) orelse break;
                            results.append(handler.gpa, .{
                                .to = .{
                                    .name = callee_name,
                                    .kind = .function,
                                    .range = sel_range,
                                    .selection_range = sel_range,
                                },
                                .from_ranges = handler.gpa.dupe(Range, entry.value_ptr.items) catch &.{},
                            }) catch {};
                            break;
                        }
                    }
                }

                return try handler.gpa.dupe(OutgoingCall, results.items);
            },
            else => {},
        }
    }
    return &.{};
}

fn findCallsInCompound(
    gpa: std.mem.Allocator,
    module: *const Ast.Module,
    compound: *const Ast.CompoundStmt,
    target_name: []const u8,
    source: [:0]const u8,
    locations: *std.ArrayList(Range),
) void {
    for (compound.stmts.items) |stmt| {
        findCallsInStmt(gpa, module, stmt, target_name, source, locations);
    }
}

fn findCallsInStmt(
    gpa: std.mem.Allocator,
    module: *const Ast.Module,
    stmt: Ast.Stmt,
    target_name: []const u8,
    source: [:0]const u8,
    locations: *std.ArrayList(Range),
) void {
    switch (stmt) {
        .compound => |c| findCallsInCompound(gpa, module, c, target_name, source, locations),
        .@"return" => |r| {
            if (r.value) |v| findCallsInExprTree(gpa, module, v, target_name, source, locations);
        },
        .@"if" => |i| {
            findCallsInExprTree(gpa, module, i.condition, target_name, source, locations);
            findCallsInCompound(gpa, module, i.body, target_name, source, locations);
            if (i.else_branch) |eb| findCallsInStmt(gpa, module, eb, target_name, source, locations);
        },
        .@"for" => |f| {
            if (f.init_stmt) |init_s| findCallsInStmt(gpa, module, init_s, target_name, source, locations);
            if (f.condition) |cond| findCallsInExprTree(gpa, module, cond, target_name, source, locations);
            if (f.update) |upd| findCallsInStmt(gpa, module, upd, target_name, source, locations);
            findCallsInCompound(gpa, module, f.body, target_name, source, locations);
        },
        .@"while" => |w| {
            findCallsInExprTree(gpa, module, w.condition, target_name, source, locations);
            findCallsInCompound(gpa, module, w.body, target_name, source, locations);
        },
        .loop => |l| {
            findCallsInCompound(gpa, module, l.body, target_name, source, locations);
            if (l.continuing) |cont| findCallsInCompound(gpa, module, cont, target_name, source, locations);
        },
        .assign => |a| {
            findCallsInExprTree(gpa, module, a.left, target_name, source, locations);
            findCallsInExprTree(gpa, module, a.right, target_name, source, locations);
        },
        .call => |c| findCallsInExprTree(gpa, module, .{ .call = c.call }, target_name, source, locations),
        .decl => |d| {
            switch (d.decl) {
                .let => |l| {
                    if (l.initializer) |e| findCallsInExprTree(gpa, module, e, target_name, source, locations);
                },
                .@"var" => |v| {
                    if (v.initializer) |e| findCallsInExprTree(gpa, module, e, target_name, source, locations);
                },
                .@"const" => |cc| {
                    if (cc.initializer) |e| findCallsInExprTree(gpa, module, e, target_name, source, locations);
                },
                else => {},
            }
        },
        .incr_decr => |i| findCallsInExprTree(gpa, module, i.expr, target_name, source, locations),
        .break_if => |b| findCallsInExprTree(gpa, module, b.condition, target_name, source, locations),
        else => {},
    }
}

fn findCallsInExprTree(
    gpa: std.mem.Allocator,
    module: *const Ast.Module,
    expr: Ast.Expr,
    target_name: []const u8,
    source: [:0]const u8,
    locations: *std.ArrayList(Range),
) void {
    switch (expr) {
        .call => |e| {
            if (e.func) |func| {
                switch (func) {
                    .ident => |id| {
                        if (std.mem.eql(u8, id.name, target_name)) {
                            if (Handler.offsetRangeToLspRange(source, id.loc, id.loc + @as(u32, @intCast(id.name.len)))) |range| {
                                locations.append(gpa, range) catch {};
                            }
                        }
                    },
                    else => {},
                }
                findCallsInExprTree(gpa, module, func, target_name, source, locations);
            }
            for (e.args.items) |arg| findCallsInExprTree(gpa, module, arg, target_name, source, locations);
        },
        .binary => |e| {
            findCallsInExprTree(gpa, module, e.left, target_name, source, locations);
            findCallsInExprTree(gpa, module, e.right, target_name, source, locations);
        },
        .unary => |e| findCallsInExprTree(gpa, module, e.operand, target_name, source, locations),
        .index => |e| {
            findCallsInExprTree(gpa, module, e.base, target_name, source, locations);
            findCallsInExprTree(gpa, module, e.idx, target_name, source, locations);
        },
        .paren => |e| findCallsInExprTree(gpa, module, e.expr, target_name, source, locations),
        .member => |e| findCallsInExprTree(gpa, module, e.base, target_name, source, locations),
        .ident, .literal => {},
    }
}

fn collectOutgoingCalls(
    gpa: std.mem.Allocator,
    module: *const Ast.Module,
    compound: *const Ast.CompoundStmt,
    source: [:0]const u8,
    calls_map: *std.StringHashMapUnmanaged(std.ArrayList(Range)),
) void {
    for (compound.stmts.items) |stmt| {
        collectOutgoingCallsStmt(gpa, module, stmt, source, calls_map);
    }
}

fn collectOutgoingCallsStmt(
    gpa: std.mem.Allocator,
    module: *const Ast.Module,
    stmt: Ast.Stmt,
    source: [:0]const u8,
    calls_map: *std.StringHashMapUnmanaged(std.ArrayList(Range)),
) void {
    switch (stmt) {
        .compound => |c| collectOutgoingCalls(gpa, module, c, source, calls_map),
        .@"return" => |r| {
            if (r.value) |v| collectOutgoingCallsExpr(gpa, module, v, source, calls_map);
        },
        .@"if" => |i| {
            collectOutgoingCallsExpr(gpa, module, i.condition, source, calls_map);
            collectOutgoingCalls(gpa, module, i.body, source, calls_map);
            if (i.else_branch) |eb| collectOutgoingCallsStmt(gpa, module, eb, source, calls_map);
        },
        .@"for" => |f| {
            if (f.init_stmt) |init_s| collectOutgoingCallsStmt(gpa, module, init_s, source, calls_map);
            if (f.condition) |cond| collectOutgoingCallsExpr(gpa, module, cond, source, calls_map);
            if (f.update) |upd| collectOutgoingCallsStmt(gpa, module, upd, source, calls_map);
            collectOutgoingCalls(gpa, module, f.body, source, calls_map);
        },
        .@"while" => |w| {
            collectOutgoingCallsExpr(gpa, module, w.condition, source, calls_map);
            collectOutgoingCalls(gpa, module, w.body, source, calls_map);
        },
        .loop => |l| {
            collectOutgoingCalls(gpa, module, l.body, source, calls_map);
            if (l.continuing) |cont| collectOutgoingCalls(gpa, module, cont, source, calls_map);
        },
        .assign => |a| {
            collectOutgoingCallsExpr(gpa, module, a.left, source, calls_map);
            collectOutgoingCallsExpr(gpa, module, a.right, source, calls_map);
        },
        .call => |c| collectOutgoingCallsExpr(gpa, module, .{ .call = c.call }, source, calls_map),
        .decl => |d| {
            switch (d.decl) {
                .let => |l| {
                    if (l.initializer) |e| collectOutgoingCallsExpr(gpa, module, e, source, calls_map);
                },
                .@"var" => |v| {
                    if (v.initializer) |e| collectOutgoingCallsExpr(gpa, module, e, source, calls_map);
                },
                .@"const" => |cc| {
                    if (cc.initializer) |e| collectOutgoingCallsExpr(gpa, module, e, source, calls_map);
                },
                else => {},
            }
        },
        else => {},
    }
}

fn collectOutgoingCallsExpr(
    gpa: std.mem.Allocator,
    module: *const Ast.Module,
    expr: Ast.Expr,
    source: [:0]const u8,
    calls_map: *std.StringHashMapUnmanaged(std.ArrayList(Range)),
) void {
    switch (expr) {
        .call => |e| {
            if (e.func) |func| {
                switch (func) {
                    .ident => |id| {
                        // Only track user function calls (not builtins)
                        if (id.ref.isValid()) {
                            const sym = module.symbols.items[id.ref.index()];
                            if (sym.kind == .function) {
                                if (Handler.offsetRangeToLspRange(source, id.loc, id.loc + @as(u32, @intCast(id.name.len)))) |range| {
                                    const gop = calls_map.getOrPut(gpa, id.name) catch return;
                                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                                    gop.value_ptr.append(gpa, range) catch {};
                                }
                            }
                        }
                    },
                    else => {},
                }
                collectOutgoingCallsExpr(gpa, module, func, source, calls_map);
            }
            for (e.args.items) |arg| collectOutgoingCallsExpr(gpa, module, arg, source, calls_map);
        },
        .binary => |e| {
            collectOutgoingCallsExpr(gpa, module, e.left, source, calls_map);
            collectOutgoingCallsExpr(gpa, module, e.right, source, calls_map);
        },
        .unary => |e| collectOutgoingCallsExpr(gpa, module, e.operand, source, calls_map),
        .index => |e| {
            collectOutgoingCallsExpr(gpa, module, e.base, source, calls_map);
            collectOutgoingCallsExpr(gpa, module, e.idx, source, calls_map);
        },
        .paren => |e| collectOutgoingCallsExpr(gpa, module, e.expr, source, calls_map),
        .member => |e| collectOutgoingCallsExpr(gpa, module, e.base, source, calls_map),
        .ident, .literal => {},
    }
}
