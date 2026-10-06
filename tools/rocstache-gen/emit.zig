//! Roc code generation. One linear pass over the node array with a small
//! scope stack; output goes straight to a writer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const m = @import("mustache.zig");
const inference = @import("infer.zig");
const Infer = inference.Infer;
const pragma_mod = @import("pragma.zig");

pub const Options = struct {
    module_name: []const u8,
    /// Shown in the generated header comment.
    source_name: []const u8,
    /// What the template's `{{% %}}` block declares.
    pragma: pragma_mod.Pragma = .{},
};

pub const PartialInfo = struct {
    name: []const u8,
    /// The partial's own (canonical) context shape.
    root: u32,
    /// The partial reads `@` fields (itself or through its partials), so it
    /// is called as `Name.render_into(out, scope, root)`.
    uses_root: bool = false,
};

const Scope = struct {
    var_name: []const u8,
    shape: u32,
};

pub const Error = inference.Error || std.Io.Writer.Error || error{ TypeError, MissingPartial };

/// Writes `bytes` as a Roc string literal (with quotes).
pub fn writeRocString(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var run_start: usize = 0;
    for (bytes, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '$' => "\\$",
            '\n' => "\\n",
            '\t' => "\\t",
            '\r' => "\\r",
            else => null,
        };
        if (esc) |e| {
            try w.writeAll(bytes[run_start..i]);
            try w.writeAll(e);
            run_start = i + 1;
        } else if (c < 0x20 or c == 0x7f) {
            try w.writeAll(bytes[run_start..i]);
            try w.print("\\u({x})", .{c});
            run_start = i + 1;
        }
    }
    try w.writeAll(bytes[run_start..]);
    try w.writeByte('"');
}

const Emitter = struct {
    gpa: Allocator,
    w: *std.Io.Writer,
    inf: *Infer,
    tpl: *const m.Template,
    partials: []const PartialInfo,
    /// For `# Name.rocstache:LINE` trailers on generated lines.
    source_name: []const u8,
    line: u32 = 1,
    line_pos: usize = 0,
    /// Where `@name` paths resolve: `context` in a page, `root` in `render_in`.
    root_var: []const u8,
    root_shape: u32,
    scopes: std.ArrayList(Scope) = .empty,
    /// (node index that closes the block, whether it pushed a scope)
    ends: std.ArrayList(struct { at: u32, pushed: bool }) = .empty,
    depth: u32 = 2,

    fn indent(self: *Emitter) !void {
        try self.w.splatByteAll('\t', self.depth);
    }

    fn scope(self: *Emitter) Scope {
        return self.scopes.items[self.scopes.items.len - 1];
    }

    /// The scope a path starts from, after its leading `..` hops.
    fn scopeFor(self: *Emitter, path: []const []const u8) Scope {
        if (m.isRootPath(path)) return .{ .var_name = self.root_var, .shape = self.root_shape };
        const hops = m.parentHops(path);
        return self.scopes.items[self.scopes.items.len - 1 - @min(hops, self.scopes.items.len - 1)];
    }

    fn shapeOf(self: *Emitter, path: []const []const u8, offset: u32) !u32 {
        var shapes: [64]u32 = undefined;
        const n = @min(self.scopes.items.len, shapes.len);
        for (self.scopes.items[self.scopes.items.len - n ..], 0..) |sc, k| shapes[k] = sc.shape;
        return inference.resolveScoped(self.inf, self.root_shape, shapes[0..n], path, offset);
    }

    fn writePath(self: *Emitter, start: u32, len: u32) !void {
        const path = self.tpl.path(start, len);
        try self.w.writeAll(self.scopeFor(path).var_name);
        for (path[m.pathPrefix(path)..]) |seg| {
            try self.w.writeByte('.');
            try self.w.writeAll(seg);
        }
    }

    /// `{{ x | f a | g }}` is `Rocstache.escape(g(f(x, a)).to_str())`: the
    /// formatters are ordinary calls, and the result is made text with
    /// `to_str`, which roc resolves for whatever type it is (Str itself,
    /// any number, anything else with a `to_str` method).
    fn writeValue(self: *Emitter, e: m.Expr, escape: bool) !void {
        const w = self.w;
        if (escape) try w.writeAll("Rocstache.escape(");
        const fmts = self.tpl.fmts[e.fmt_start .. e.fmt_start + e.fmt_len];
        var i: usize = fmts.len;
        while (i > 0) {
            i -= 1;
            try w.print("{s}(", .{fmts[i].name});
        }
        try self.writePath(e.path_start, e.path_len);
        for (fmts) |f| {
            for (self.tpl.args[f.arg_start .. f.arg_start + f.arg_len]) |a| {
                try w.writeAll(", ");
                switch (a.kind) {
                    .string => try writeRocString(w, a.text),
                    .number => try w.writeAll(a.text),
                    .path => try self.writePath(a.path_start, a.path_len),
                }
            }
            try w.writeByte(')');
        }
        try w.writeAll(".to_str()");
        if (escape) try w.writeByte(')');
    }

    /// ` # Home.rocstache:12`: where the code on this line comes from, so an
    /// error roc reports in the generated module leads back to the template.
    /// Tags are emitted in document order, so the line count only moves
    /// forward from the last tag.
    fn trace(self: *Emitter, offset: u32) !void {
        const to = @min(offset, self.tpl.src.len);
        if (to > self.line_pos) {
            self.line += @intCast(std.mem.count(u8, self.tpl.src[self.line_pos..to], "\n"));
            self.line_pos = to;
        }
        try self.w.print(" # {s}:{d}", .{ self.source_name, self.line });
    }

    fn body(self: *Emitter) Error!void {
        const tpl = self.tpl;
        const w = self.w;
        var i: u32 = 0;
        while (i < tpl.nodes.len) : (i += 1) {
            while (self.ends.items.len > 0 and self.ends.items[self.ends.items.len - 1].at == i) {
                const e = self.ends.pop().?;
                if (e.pushed) _ = self.scopes.pop();
                self.depth -= 1;
                try self.indent();
                try w.writeAll("}\n");
            }
            const node = tpl.nodes[i];
            switch (node.kind) {
                .text => {
                    try self.indent();
                    try w.writeAll("$out = $out.concat(");
                    try writeRocString(w, tpl.src[node.start..node.end]);
                    try w.writeAll(")\n");
                },
                .variable => {
                    try self.indent();
                    try w.writeAll("$out = $out.concat(");
                    try self.writeValue(tpl.exprs[node.expr], node.escape);
                    try w.writeAll(")");
                    try self.trace(node.start);
                    try w.writeAll("\n");
                },
                .conditional => {
                    const e = tpl.exprs[node.expr];
                    try self.indent();
                    try w.writeAll("if ");
                    try self.writePath(e.path_start, e.path_len);
                    try w.writeAll(" {");
                    try self.trace(node.start);
                    try w.writeAll("\n");
                    if (node.close == i + 1) {
                        try self.w.splatByteAll('\t', self.depth + 1);
                        try w.writeAll("{}\n");
                    }
                    try self.ends.append(self.gpa, .{ .at = node.close, .pushed = false });
                    self.depth += 1;
                },
                .section, .inverted => {
                    const e = tpl.exprs[node.expr];
                    const shape = try self.shapeOf(tpl.path(e.path_start, e.path_len), e.offset);
                    const kind = self.inf.resolvedKind(shape);
                    try self.indent();
                    var new_scope = self.scope();
                    if (kind == .bool) {
                        try w.writeAll(if (node.kind == .section) "if " else "if !");
                        try self.writePath(e.path_start, e.path_len);
                        try w.writeAll(" {");
                        try self.trace(node.start);
                        try w.writeAll("\n");
                    } else if (node.kind == .inverted) {
                        try w.writeAll("if ");
                        try self.writePath(e.path_start, e.path_len);
                        try w.writeAll(".is_empty() {");
                        try self.trace(node.start);
                        try w.writeAll("\n");
                    } else {
                        const loop_depth = self.scopes.items.len;
                        const name = if (loop_depth == 1) "item" else try std.fmt.allocPrint(self.gpa, "item{d}", .{loop_depth});
                        try w.print("for {s} in ", .{name});
                        try self.writePath(e.path_start, e.path_len);
                        try w.writeAll(" {");
                        try self.trace(node.start);
                        try w.writeAll("\n");
                        new_scope = .{ .var_name = name, .shape = self.inf.get(shape).elem };
                    }
                    if (node.close == i + 1) {
                        // Empty body: Roc needs a statement.
                        try self.w.splatByteAll('\t', self.depth + 1);
                        try w.writeAll("{}\n");
                    }
                    try self.scopes.append(self.gpa, new_scope);
                    try self.ends.append(self.gpa, .{ .at = node.close, .pushed = true });
                    self.depth += 1;
                },
                .partial => {
                    // The partial's `render` takes an open record, and the
                    // current scope was unified with the partial's context, so
                    // the scope value is passed as it is.
                    const name = tpl.partials[node.expr];
                    var found: ?PartialInfo = null;
                    for (self.partials) |p| if (std.mem.eql(u8, p.name, name)) {
                        found = p;
                    };
                    const p = found orelse return error.MissingPartial;
                    try self.indent();
                    // A partial that reads no fields of its own takes exactly `{}`.
                    const arg = if ((try self.inf.sortedFields(p.root)).len == 0) "{}" else self.scope().var_name;
                    if (p.uses_root) {
                        try w.print("$out = {s}.render_into($out, {s}, {s})", .{ name, arg, self.root_var });
                    } else {
                        try w.print("$out = {s}.render_into($out, {s})", .{ name, arg });
                    }
                    try self.trace(node.start);
                    try w.writeAll("\n");
                },
            }
        }
        while (self.ends.items.len > 0) {
            const e = self.ends.pop().?;
            if (e.pushed) _ = self.scopes.pop();
            self.depth -= 1;
            try self.indent();
            try w.writeAll("}\n");
        }
    }
};

pub fn emit(
    gpa: Allocator,
    w: *std.Io.Writer,
    inf: *Infer,
    tpl: *const m.Template,
    root: u32,
    groot: u32,
    uses_root: bool,
    partials: []const PartialInfo,
    opts: Options,
) Error!void {
    var escapes = false;
    for (tpl.nodes) |n| if (n.kind == .variable and n.escape) {
        escapes = true;
    };
    try w.print("# Generated by rocstache-gen from {s}. DO NOT EDIT.\n", .{opts.source_name});
    if (escapes) try w.writeAll("import pf.Rocstache\n");
    for (tpl.partials) |p| try w.print("import {s}\n", .{p});
    // The template's own Roc, as written, except `Ctx`, which goes into
    // the module below so an app can name it (`Home.Ctx`).
    const pr = opts.pragma;
    const outside = if (pr.declares_ctx)
        try std.mem.concat(gpa, u8, &.{ tpl.pragma[0..pr.ctx_start], tpl.pragma[pr.ctx_end..] })
    else
        tpl.pragma;
    const block = std.mem.trim(u8, outside, "\r\n");
    if (block.len != 0) {
        // Where the block starts in the template, so a roc error inside it
        // (reported against this file) leads back to the template line.
        const lead = std.mem.indexOfNone(u8, outside, "\r\n") orelse 0;
        const first_line = 1 + std.mem.count(u8, tpl.src[0..tpl.pragma_offset], "\n") + std.mem.count(u8, outside[0..lead], "\n");
        try w.print("\n# ---- {{{{% %}}}} block of {s}, from line {d}\n{s}\n# ----\n", .{ opts.source_name, first_line, block });
    }
    try w.writeAll("\n");

    var n_vars: u32 = 0;
    var n_sections: u32 = 0;
    var n_partials: u32 = 0;
    for (tpl.nodes) |n| switch (n.kind) {
        .variable => n_vars += 1,
        .section, .inverted, .conditional => n_sections += 1,
        .partial => n_partials += 1,
        .text => {},
    };
    const estimate: u64 = @as(u64, tpl.static_bytes) + 32 * @as(u64, n_vars) + 256 * @as(u64, n_sections) + 256 * @as(u64, n_partials);
    const capacity = std.math.ceilPowerOfTwo(u64, @max(64, estimate)) catch unreachable;
    const uses_ctx = (try inf.sortedFields(root)).len != 0;
    const ctx_name = if (uses_ctx) "context" else "_context";
    const m_name = opts.module_name;
    // A declared `Ctx` types what a handler calls, `render` (and `render_in`);
    // `Ctx(_)` when it is open. `render_into`, what an including template
    // calls with its own scope (usually more fields), stays structural.
    const ctx_t: ?[]const u8 = if (!opts.pragma.declares_ctx) null else if (opts.pragma.ctx_params == 0) "Ctx" else blk: {
        var t: std.ArrayList(u8) = .empty;
        try t.appendSlice(gpa, "Ctx(_");
        for (1..opts.pragma.ctx_params) |_| try t.appendSlice(gpa, ", _");
        try t.appendSlice(gpa, ")");
        break :blk t.items;
    };
    // An open `Ctx(..)` also types `render_into`, so it holds when another
    // template includes this one (passing its own, larger scope). A closed
    // `Ctx` cannot: the including scope has more fields.
    const into_t: ?[]const u8 = if (opts.pragma.ctx_params > 0) ctx_t else null;

    try w.print("## Compiled from `{s}`. `{s}.render(context)` is the HTML, with every\n", .{ opts.source_name, m_name });
    try w.writeAll("## `{{ value }}` made text by its `to_str` and HTML-escaped. The context is any\n");
    try w.writeAll("## record with the fields the template reads");
    if (ctx_t != null) try w.writeAll("; this template declares its type, `Ctx`");
    try w.writeAll(".\n");
    try w.print("{s} :: [].{{\n\n", .{m_name});
    if (pr.declares_ctx) {
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, tpl.pragma[pr.ctx_start..pr.ctx_end], "\r\n"), '\n');
        while (lines.next()) |line| try w.print("\t{s}\n", .{std.mem.trimEnd(u8, line, "\r")});
        try w.writeAll("\n");
    }
    if (uses_root) {
        // `@name` reads the root record. The page form passes the context as
        // the root; `render_in(context, root)` renders it inside a page (an
        // SSE fragment, say) with the page's root given separately.
        // The page form passes one record as context and root, so it has
        // the root's fields too: a declared `Ctx` types `render_in` only.
        try w.print("\trender = |context| render_into(Str.with_capacity({d}), context, context)\n\n", .{capacity});
        try w.writeAll("\t## Renders the template on its own inside a page whose root record is `root`.\n");
        if (ctx_t) |t| try w.print("\trender_in : {s}, _ -> Str\n", .{t});
        try w.print("\trender_in = |context, root| render_into(Str.with_capacity({d}), context, root)\n\n", .{capacity});
        try w.writeAll("\t## `render_in`, appending to `out`: how a template that includes this one renders it.\n");
        if (into_t) |t| try w.print("\trender_into : Str, {s}, _ -> Str\n", .{t});
        try w.print("\trender_into = |out, {s}, root| {{\n", .{ctx_name});
    } else {
        if (ctx_t) |t| try w.print("\trender : {s} -> Str\n", .{t});
        try w.print("\trender = |context| render_into(Str.with_capacity({d}), context)\n\n", .{capacity});
        try w.writeAll("\t## `render`, appending to `out`: how a template that includes this one renders it.\n");
        if (into_t) |t| try w.print("\trender_into : Str, {s} -> Str\n", .{t});
        try w.print("\trender_into = |out, {s}| {{\n", .{ctx_name});
    }
    try w.writeAll("\t\tvar $out = out\n");

    var em = Emitter{ .gpa = gpa, .w = w, .inf = inf, .tpl = tpl, .partials = partials, .source_name = opts.source_name, .root_var = if (uses_root) "root" else "context", .root_shape = if (uses_root) groot else root };
    try em.scopes.append(gpa, .{ .var_name = "context", .shape = root });
    try em.body();

    try w.writeAll("\t\t$out\n\t}\n}\n");
}

test "roc string escaping" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeRocString(&aw.writer, "a\"b\\c$d\n\te\x01é");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\$d\\n\\te\\u(1)é\"", aw.written());
}
