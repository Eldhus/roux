//! `rocstache-gen lsp`: a small language server for *.rocstache files.
//!
//! JSON-RPC over stdio. Every request re-runs the generator's parse and
//! inference on the open buffer (microseconds for real templates), so the
//! server keeps no state beyond the open documents:
//!   - diagnostics: the generator's parse/type error, at its position (an
//!     error inside a partial is reported on the `{{> Name}}` tag);
//!   - hover: the inferred Roc type of a context path segment, a formatter's
//!     signature from Formatters.roc, or a partial's context type;
//!   - completion: field names of the scope at the cursor (inferred from the
//!     rest of the template) and formatter names after `|`.
//! `Formatters.roc` is looked for in the template's directory and up to two
//! levels above it; partials are read from open buffers or from disk next to
//! the template.

const std = @import("std");
const lib = @import("rocstache_gen");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const Doc = struct { path: []const u8, text: []const u8 };

const Server = struct {
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    docs: std.StringArrayHashMapUnmanaged(Doc) = .empty,
    shutdown: bool = false,

    fn send(self: *Server, msg: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(self.gpa, msg, .{ .emit_null_optional_fields = true });
        defer self.gpa.free(body);
        try self.out.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
        try self.out.flush();
    }

    fn respond(self: *Server, id: Value, result: anytype) !void {
        try self.send(.{ .jsonrpc = "2.0", .id = id, .result = result });
    }

    fn respondError(self: *Server, id: Value, code: i32, message: []const u8) !void {
        try self.send(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } });
    }

    fn setDoc(self: *Server, uri: []const u8, text: []const u8) !void {
        const path = try uriToPath(self.gpa, uri);
        const copy = try self.gpa.dupe(u8, text);
        if (self.docs.getPtr(uri)) |d| {
            self.gpa.free(d.text);
            self.gpa.free(d.path);
            d.* = .{ .path = path, .text = copy };
        } else {
            try self.docs.put(self.gpa, try self.gpa.dupe(u8, uri), .{ .path = path, .text = copy });
        }
    }

    fn removeDoc(self: *Server, uri: []const u8) void {
        if (self.docs.fetchSwapRemove(uri)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value.path);
            self.gpa.free(kv.value.text);
        }
    }

    fn handle(self: *Server, arena: Allocator, msg: Value) !void {
        const obj = if (msg == .object) msg.object else return;
        const method = if (obj.get("method")) |m| (if (m == .string) m.string else return) else return;
        const id = obj.get("id") orelse Value.null;
        const params = obj.get("params") orelse Value.null;

        if (std.mem.eql(u8, method, "initialize")) {
            try self.respond(id, .{
                .capabilities = .{
                    .textDocumentSync = 1,
                    .hoverProvider = true,
                    .completionProvider = .{ .triggerCharacters = [_][]const u8{ "|", ".", "{" } },
                },
                .serverInfo = .{ .name = "rocstache-gen lsp" },
            });
        } else if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown = true;
            try self.respond(id, @as(?u8, null));
        } else if (std.mem.eql(u8, method, "exit")) {
            std.process.exit(if (self.shutdown) 0 else 1);
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            const td = getObj(params, "textDocument") orelse return;
            const uri = getStr(td, "uri") orelse return;
            try self.setDoc(uri, getStr(td, "text") orelse "");
            try self.publishDiagnostics(arena, uri);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            const td = getObj(params, "textDocument") orelse return;
            const uri = getStr(td, "uri") orelse return;
            const changes = getArr(params, "contentChanges") orelse return;
            if (changes.items.len == 0) return;
            // Full sync: the last change carries the whole document.
            const last = changes.items[changes.items.len - 1];
            try self.setDoc(uri, getStr(last, "text") orelse return);
            try self.publishDiagnostics(arena, uri);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            const td = getObj(params, "textDocument") orelse return;
            const uri = getStr(td, "uri") orelse return;
            self.removeDoc(uri);
            try self.send(.{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = uri, .diagnostics = [_]u8{} } });
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.hover(arena, id, params);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.completion(arena, id, params);
        } else if (id != .null) {
            try self.respondError(id, -32601, "method not found");
        }
    }

    // ------------------------------------------------------------ analysis

    const Analyzed = struct {
        scope: FormatterScope,
        result: anyerror!lib.gen.Analysis,
        diag: *lib.mustache.Diagnostic,
    };

    const Loader = struct {
        server: *Server,
        arena: Allocator,
        dir: []const u8,
        fn load(ctx: *anyopaque, name: []const u8) anyerror!?[]const u8 {
            const self: *Loader = @ptrCast(@alignCast(ctx));
            const path = try std.fs.path.join(self.arena, &.{ self.dir, try std.fmt.allocPrint(self.arena, "{s}.rocstache", .{name}) });
            for (self.server.docs.values()) |d| if (std.mem.eql(u8, d.path, path)) return d.text;
            return Io.Dir.cwd().readFileAlloc(self.server.io, path, self.arena, .unlimited) catch |err| switch (err) {
                error.FileNotFound => null,
                else => err,
            };
        }
    };

    /// The formatters a template can use, with signatures: what its
    /// `{{% %}}` block imports (from `pf.Rocstache`, or a module file next
    /// to the template) and defines itself.
    fn formatterScope(self: *Server, arena: Allocator, dir: []const u8, text: []const u8) !FormatterScope {
        var out: std.ArrayList(Known) = .empty;
        const block = pragmaText(text);
        const p = try lib.pragma.parse(arena, block);
        for (p.imports) |imp| {
            if (imp.exposing.len == 0) continue;
            const src: ?[]const u8 = if (std.mem.eql(u8, imp.module, "pf.Rocstache"))
                lib.formatters.builtin_src
            else if (try lib.pragma.relativeFile(arena, dir, imp.module)) |path|
                Io.Dir.cwd().readFileAlloc(self.io, path, arena, .unlimited) catch null
            else
                null;
            const table: lib.formatters.Table = if (src) |s_| try lib.formatters.parse(arena, s_) else .empty;
            for (imp.exposing) |name| try out.append(arena, .{ .name = name, .sig = table.find(name), .from = imp.module });
        }
        const locals = try lib.formatters.parseTopLevel(arena, block);
        for (p.locals) |name| try out.append(arena, .{ .name = name, .sig = locals.find(name), .from = "" });
        return .{ .known = out.items };
    }

    fn analyzeDoc(self: *Server, arena: Allocator, doc: Doc, text: []const u8) !Analyzed {
        const dir = std.fs.path.dirname(doc.path) orelse ".";
        const loader = try arena.create(Loader);
        loader.* = .{ .server = self, .arena = arena, .dir = dir };
        const diag = try arena.create(lib.mustache.Diagnostic);
        diag.* = .{};
        const stem = std.fs.path.stem(doc.path);
        const result = lib.gen.analyze(arena, text, stem, .{ .ctx = loader, .loadFn = Loader.load }, diag);
        return .{ .scope = try self.formatterScope(arena, dir, text), .result = result, .diag = diag };
    }

    fn publishDiagnostics(self: *Server, arena: Allocator, uri: []const u8) !void {
        const doc = self.docs.get(uri) orelse return;
        const a = try self.analyzeDoc(arena, doc, doc.text);
        const Diag = struct { range: Range, severity: u8, source: []const u8, message: []const u8 };
        var list: std.ArrayList(Diag) = .empty;
        if (a.result) |_| {} else |err| switch (err) {
            error.ParseError, error.TypeError => {
                const d = a.diag.*;
                var start: u32 = d.offset;
                var end: u32 = d.offset;
                var message = d.message;
                if (d.file.len != 0) {
                    // Error inside a partial: point at the tag that includes it.
                    message = try std.fmt.allocPrint(arena, "in {s}.rocstache: {s}", .{ d.file, d.message });
                    start = 0;
                    end = 0;
                    if (findPartialTag(doc.text, d.file)) |span| {
                        start = span[0];
                        end = span[1];
                    }
                } else {
                    end = tokenEnd(doc.text, start);
                }
                try list.append(arena, .{ .range = rangeOf(doc.text, start, end), .severity = 1, .source = "rocstache", .message = message });
            },
            else => {
                try list.append(arena, .{ .range = rangeOf(doc.text, 0, 0), .severity = 1, .source = "rocstache", .message = @errorName(err) });
            },
        }
        try self.send(.{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = uri, .diagnostics = list.items } });
    }

    // --------------------------------------------------------------- hover

    fn hover(self: *Server, arena: Allocator, id: Value, params: Value) !void {
        const td = getObj(params, "textDocument") orelse return self.respond(id, @as(?u8, null));
        const uri = getStr(td, "uri") orelse return self.respond(id, @as(?u8, null));
        const doc = self.docs.get(uri) orelse return self.respond(id, @as(?u8, null));
        const pos = getPosition(params) orelse return self.respond(id, @as(?u8, null));
        const offset = offsetOf(doc.text, pos.line, pos.character);
        const a = try self.analyzeDoc(arena, doc, doc.text);
        // A formatter name (after `|`, or in the `{{% %}}` block) is described
        // from the formatter scope alone, so it works while the template has
        // an error elsewhere.
        if (formatterAt(doc.text, offset)) |name| if (a.scope.knows(name) or std.mem.indexOfScalar(u8, name, '.') != null) {
            return self.respond(id, .{ .contents = .{ .kind = "markdown", .value = try a.scope.describe(arena, name) } });
        };
        const an = a.result catch return self.respond(id, @as(?u8, null));
        const text = (try hoverText(arena, an, a.scope, offset)) orelse return self.respond(id, @as(?u8, null));
        try self.respond(id, .{ .contents = .{ .kind = "markdown", .value = text } });
    }

    /// Walks the template like inference does (a stack of scopes) and
    /// describes whatever is under `offset`.
    fn hoverText(arena: Allocator, a: lib.gen.Analysis, scope: FormatterScope, offset: u32) !?[]const u8 {
        const tpl = &a.tpl;
        var walk = ScopeWalk.init(a);
        defer walk.deinit(arena);
        for (tpl.nodes, 0..) |node, i| {
            try walk.enter(arena, @intCast(i));
            const cur = walk.current();
            switch (node.kind) {
                .text => {},
                .partial => if (inTag(tpl.src, node, offset)) {
                    const name = tpl.partials[node.expr];
                    for (a.partials) |p| if (std.mem.eql(u8, p.name, name)) {
                        return try std.fmt.allocPrint(arena, "`{s}.rocstache` reads:\n```roc\n{s}\n```", .{ name, try typeText(arena, a.inf, p.root) });
                    };
                    return null;
                },
                .variable, .section, .inverted, .conditional => if (inTag(tpl.src, node, offset)) {
                    const e = tpl.exprs[node.expr];
                    _ = cur;
                    if (try pathHover(arena, a, walk.scopeFor(tpl.path(e.path_start, e.path_len)), tpl.path(e.path_start, e.path_len), e.offset, offset)) |t| return t;
                    for (tpl.fmts[e.fmt_start .. e.fmt_start + e.fmt_len]) |f| {
                        if (offset >= f.offset and offset <= f.offset + f.name.len) {
                            return try scope.describe(arena, f.name);
                        }
                        for (tpl.args[f.arg_start .. f.arg_start + f.arg_len]) |arg| if (arg.kind == .path) {
                            if (try pathHover(arena, a, walk.scopeFor(tpl.path(arg.path_start, arg.path_len)), tpl.path(arg.path_start, arg.path_len), arg.offset, offset)) |t| return t;
                        };
                    }
                    // Anywhere else in the tag: the value's type.
                    const leaf = walk.resolve(tpl.path(e.path_start, e.path_len)) orelse return null;
                    return try std.fmt.allocPrint(arena, "```roc\n{s} : {s}\n```", .{ pathText(tpl, e.path_start, e.path_len), try typeText(arena, a.inf, leaf) });
                },
            }
            try walk.leave(arena, @intCast(i));
        }
        return null;
    }

    fn pathHover(arena: Allocator, a: lib.gen.Analysis, scope: u32, segs_in: []const []const u8, path_offset: u32, offset: u32) !?[]const u8 {
        // `..` hops were already applied by the caller's scope choice.
        const segs = segs_in[lib.mustache.pathPrefix(segs_in)..];
        if (segs.len == 0) {
            // `{{.}}`: the scope itself.
            if (offset >= path_offset and offset <= path_offset + 1)
                return try std.fmt.allocPrint(arena, "```roc\n. : {s}\n```", .{try typeText(arena, a.inf, scope)});
            return null;
        }
        const src = a.tpl.src;
        for (segs, 0..) |seg, i| {
            const seg_off: u32 = @intCast(@intFromPtr(seg.ptr) - @intFromPtr(src.ptr));
            if (offset >= seg_off and offset <= seg_off + seg.len) {
                const shape = resolveExisting(a.inf, scope, segs[0 .. i + 1]) orelse return null;
                const note: []const u8 = switch (a.inf.resolvedKind(shape)) {
                    .value => "\nPrinted with its `to_str`: Str, any number, anything with a `to_str` method. Its type is whatever the handler passes.",
                    .unknown => "\nOnly passed to formatters: its type is whatever they take.",
                    else => "",
                };
                return try std.fmt.allocPrint(arena, "```roc\n{s} : {s}\n```{s}", .{ seg, try typeText(arena, a.inf, shape), note });
            }
        }
        return null;
    }

    // ---------------------------------------------------------- completion

    fn completion(self: *Server, arena: Allocator, id: Value, params: Value) !void {
        const td = getObj(params, "textDocument") orelse return self.respond(id, @as(?u8, null));
        const uri = getStr(td, "uri") orelse return self.respond(id, @as(?u8, null));
        const doc = self.docs.get(uri) orelse return self.respond(id, @as(?u8, null));
        const pos = getPosition(params) orelse return self.respond(id, @as(?u8, null));
        const cursor = offsetOf(doc.text, pos.line, pos.character);
        const Item = struct { label: []const u8, kind: u8, detail: []const u8 };
        var items: std.ArrayList(Item) = .empty;

        // Inside the `{{% %}}` block, on `import pf.Rocstache exposing [`:
        // the platform's formatters.
        const before = doc.text[0..cursor];
        const block = pragmaText(doc.text);
        const block_start: usize = @intFromPtr(block.ptr) - @intFromPtr(doc.text.ptr);
        if (block.len != 0 and cursor >= block_start and cursor <= block_start + block.len) {
            // Inside `import M exposing [ ... ]` (on one line or several):
            // M's functions, filtered by what is typed.
            const open = try lib.pragma.openExposing(arena, before[block_start..]) orelse return self.respond(id, items.items);
            const module = open.module;
            const typed = open.typed;
            const dir = std.fs.path.dirname(doc.path) orelse ".";
            const src: ?[]const u8 = if (std.mem.eql(u8, module, "pf.Rocstache"))
                lib.formatters.builtin_src
            else if (try lib.pragma.relativeFile(arena, dir, module)) |path|
                Io.Dir.cwd().readFileAlloc(self.io, path, arena, .unlimited) catch null
            else
                null;
            if (src) |text| {
                const table = try lib.formatters.parse(arena, text);
                for (table.sigs) |sig| {
                    if (std.mem.eql(u8, sig.name, "escape") or !std.mem.startsWith(u8, sig.name, typed)) continue;
                    try items.append(arena, .{ .label = sig.name, .kind = 3, .detail = try sigText(arena, sig) });
                }
            }
            return self.respond(id, items.items);
        }
        // Are we inside a tag? Find the last `{{` before the cursor with no `}}` after it.
        const open = std.mem.lastIndexOf(u8, before, "{{") orelse return self.respond(id, items.items);
        if (std.mem.indexOfPos(u8, before, open, "}}") != null) return self.respond(id, items.items);
        const in_tag = before[open + 2 ..];
        if (std.mem.lastIndexOfScalar(u8, in_tag, '|')) |bar| {
            // `| name` prefix: formatter names.
            const typed = std.mem.trimStart(u8, in_tag[bar + 1 ..], " \t");
            if (std.mem.indexOfAny(u8, typed, " \t\"") == null) {
                // Cut the in-progress tag out so the rest of the template still analyzes
                // and we can filter formatters by the value's type.
                const a = try self.analyzeDoc(arena, doc, try spliceOut(arena, doc.text, open, cursor));
                for (a.scope.known) |k| {
                    if (!std.mem.startsWith(u8, k.name, typed)) continue;
                    try items.append(arena, .{ .label = k.name, .kind = 3, .detail = try k.detail(arena) });
                }
            }
            return self.respond(id, items.items);
        }
        // A context path: fields of the scope at the cursor, or of `a.b.` so far.
        var body = std.mem.trimStart(u8, in_tag, " \t");
        if (body.len != 0 and (body[0] == '#' or body[0] == '^' or body[0] == '/' or body[0] == '&')) body = std.mem.trimStart(u8, body[1..], " \t");
        if (body.len != 0 and (body[0] == '>' or body[0] == '!' or body[0] == '=' or body[0] == '{')) return self.respond(id, items.items);
        if (std.mem.indexOfAny(u8, body, " \t") != null) return self.respond(id, items.items);
        const a = try self.analyzeDoc(arena, doc, try spliceOut(arena, doc.text, open, cursor));
        const an = a.result catch return self.respond(id, items.items);
        var scope = try scopeAt(arena, an, @intCast(open));
        var typed = body;
        if (std.mem.lastIndexOfScalar(u8, body, '.')) |dot| {
            var segs: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, body[0..dot], '.');
            while (it.next()) |s| if (s.len != 0) try segs.append(arena, s);
            scope = resolveExisting(an.inf, scope, segs.items) orelse return self.respond(id, items.items);
            typed = body[dot + 1 ..];
        }
        const fields = an.inf.sortedFields(scope) catch return self.respond(id, items.items);
        for (fields) |f| {
            if (!std.mem.startsWith(u8, f.name, typed)) continue;
            try items.append(arena, .{ .label = f.name, .kind = 5, .detail = try typeText(arena, an.inf, f.shape) });
        }
        return self.respond(id, items.items);
    }
};

// ------------------------------------------------------ formatter scope

const Known = struct {
    name: []const u8,
    sig: ?lib.formatters.Sig,
    /// The module it is imported from, or "" when the template defines it.
    from: []const u8,

    fn detail(k: Known, arena: Allocator) ![]const u8 {
        return if (k.sig) |sig| try sigText(arena, sig) else if (k.from.len != 0) k.from else "defined in this template";
    }
};

const FormatterScope = struct {
    known: []const Known,

    fn knows(self: FormatterScope, name: []const u8) bool {
        for (self.known) |k| if (std.mem.eql(u8, k.name, name)) return true;
        return false;
    }

    fn describe(self: FormatterScope, arena: Allocator, name: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, name, '.') != null) {
            // `M.fn`: a function of an imported module (or a builtin one).
            const dot = std.mem.lastIndexOfScalar(u8, name, '.').?;
            if (dot + 1 < name.len and std.ascii.isUpper(name[dot + 1]) or std.mem.startsWith(u8, name, "pf."))
                return try std.fmt.allocPrint(arena, "module `{s}`", .{name});
            return try std.fmt.allocPrint(arena, "`{s}`: called with the piped value as its first argument", .{name});
        }
        for (self.known) |k| if (std.mem.eql(u8, k.name, name)) {
            const origin = if (k.from.len != 0) try std.fmt.allocPrint(arena, "from `{s}`", .{k.from}) else "defined in this template";
            if (k.sig) |sig| {
                const doc = if (sig.doc.len != 0) try std.fmt.allocPrint(arena, "\n\n{s}", .{sig.doc}) else "";
                return try std.fmt.allocPrint(arena, "```roc\n{s} : {s}\n```\n{s}; the piped value is the first argument.{s}", .{ name, try sigText(arena, sig), origin, doc });
            }
            return try std.fmt.allocPrint(arena, "`{s}`, {s}", .{ name, origin });
        };
        return try std.fmt.allocPrint(arena, "`{s}` is not defined here: import it in the `{{{{% %}}}}` block", .{name});
    }
};

/// The formatter name under `offset`: a word right after `|` in a tag, or a
/// word inside the `{{% %}}` block.
fn formatterAt(text: []const u8, offset: u32) ?[]const u8 {
    const isWord = struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
        }
    }.f;
    if (offset > text.len) return null;
    var start: usize = offset;
    while (start > 0 and isWord(text[start - 1])) start -= 1;
    var end: usize = offset;
    while (end < text.len and isWord(text[end])) end += 1;
    if (start == end) return null;
    const word = text[start..end];
    const block = pragmaText(text);
    const block_start: usize = @intFromPtr(block.ptr) - @intFromPtr(text.ptr);
    if (block.len != 0 and start >= block_start and end <= block_start + block.len) return word;
    var before = start;
    while (before > 0 and (text[before - 1] == ' ' or text[before - 1] == '\t')) before -= 1;
    if (before > 0 and text[before - 1] == '|') return word;
    return null;
}

/// The body of the template's leading `{{% %}}` block, or "" (a slice of
/// `text`, found without a full parse so it works while editing).
fn pragmaText(text: []const u8) []const u8 {
    const lead = std.mem.indexOfNone(u8, text, " \t\r\n") orelse return text[0..0];
    if (!std.mem.startsWith(u8, text[lead..], "{{%")) return text[0..0];
    if (std.mem.indexOfPos(u8, text, lead + 3, "%}}")) |end| return text[lead + 3 .. end];
    // Still being typed: the block runs to the first line of markup.
    var i = lead + 3;
    while (i < text.len) {
        const le = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = std.mem.trimStart(u8, text[i..le], " \t");
        if (std.mem.startsWith(u8, line, "<") or std.mem.startsWith(u8, line, "{{")) return text[lead + 3 .. i];
        i = le + 1;
    }
    return text[lead + 3 ..];
}

// ----------------------------------------------------------- scope walking

/// Tracks the current context scope while iterating a template's nodes in
/// order, mirroring `infer.inferTemplate`.
const ScopeWalk = struct {
    a: lib.gen.Analysis,
    stack: std.ArrayList(u32) = .empty,
    ends: std.ArrayList(struct { at: u32, pushed: bool }) = .empty,

    fn init(a: lib.gen.Analysis) ScopeWalk {
        return .{ .a = a };
    }
    fn deinit(self: *ScopeWalk, arena: Allocator) void {
        self.stack.deinit(arena);
        self.ends.deinit(arena);
    }
    fn current(self: *ScopeWalk) u32 {
        return if (self.stack.items.len == 0) self.a.root else self.stack.items[self.stack.items.len - 1];
    }
    /// The scope a path starts from after its `..` hops (root at the bottom).
    fn scopeFor(self: *ScopeWalk, path: []const []const u8) u32 {
        if (lib.mustache.isRootPath(path)) return self.a.groot;
        const hops = lib.mustache.parentHops(path);
        if (hops >= self.stack.items.len + 1) return self.a.root;
        if (hops == self.stack.items.len) return self.a.root;
        return self.stack.items[self.stack.items.len - 1 - hops];
    }
    /// Resolves a path (with hops) without creating fields.
    fn resolve(self: *ScopeWalk, path: []const []const u8) ?u32 {
        return resolveExisting(self.a.inf, self.scopeFor(path), path[lib.mustache.pathPrefix(path)..]);
    }
    /// Call before handling node `i`: closes blocks that end here.
    fn enter(self: *ScopeWalk, _: Allocator, i: u32) !void {
        while (self.ends.items.len > 0 and self.ends.items[self.ends.items.len - 1].at == i) {
            const e = self.ends.pop().?;
            if (e.pushed) _ = self.stack.pop();
        }
    }
    /// Call after handling node `i`: opens a section's element scope.
    fn leave(self: *ScopeWalk, arena: Allocator, i: u32) !void {
        const node = self.a.tpl.nodes[i];
        if (node.kind == .conditional) {
            try self.ends.append(arena, .{ .at = node.close, .pushed = false });
            return;
        }
        if (node.kind != .section and node.kind != .inverted) return;
        const e = self.a.tpl.exprs[node.expr];
        const leaf = self.resolve(self.a.tpl.path(e.path_start, e.path_len)) orelse return;
        try self.stack.append(arena, self.a.inf.get(leaf).elem);
        try self.ends.append(arena, .{ .at = node.close, .pushed = true });
    }
};

/// The scope in effect at a source offset (the innermost enclosing section's
/// element shape, else the root).
fn scopeAt(arena: Allocator, a: lib.gen.Analysis, offset: u32) !u32 {
    var walk = ScopeWalk.init(a);
    defer walk.deinit(arena);
    for (a.tpl.nodes, 0..) |node, i| {
        try walk.enter(arena, @intCast(i));
        if (node.start > offset) return walk.current();
        try walk.leave(arena, @intCast(i));
    }
    return walk.current();
}

/// Whether `offset` is inside a tag node, delimiters included. A node's
/// `start`/`end` span its content; the `{{` sits shortly before `start`.
fn inTag(src: []const u8, node: lib.mustache.Node, offset: u32) bool {
    const open = std.mem.lastIndexOf(u8, src[0..node.start], "{{") orelse node.start;
    var close: usize = node.end;
    while (close < src.len and src[close] != '}') close += 1;
    while (close < src.len and src[close] == '}') close += 1;
    return offset >= open and offset <= close;
}

/// Resolves a path without creating fields (inference already ran).
fn resolveExisting(inf: *lib.infer.Infer, scope: u32, segs: []const []const u8) ?u32 {
    var cur = scope;
    for (segs) |seg| cur = inf.field(cur, seg) orelse return null;
    return cur;
}

fn typeText(arena: Allocator, inf: *lib.infer.Infer, id: u32) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    try inf.writeType(&aw.writer, id);
    return aw.written();
}

fn sigText(arena: Allocator, sig: lib.formatters.Sig) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    for (sig.params, 0..) |p, i| {
        if (i != 0) try aw.writer.writeAll(", ");
        try aw.writer.writeAll(p);
    }
    try aw.writer.print(" -> {s}", .{sig.ret});
    return aw.written();
}

fn pathText(tpl: *const lib.mustache.Template, start: u32, len: u32) []const u8 {
    if (len == 0) return ".";
    const first = tpl.segs[start];
    const last = tpl.segs[start + len - 1];
    const s = @intFromPtr(first.ptr) - @intFromPtr(tpl.src.ptr);
    const e = @intFromPtr(last.ptr) + last.len - @intFromPtr(tpl.src.ptr);
    return tpl.src[s..e];
}

/// `text` with `[from, to)` removed.
fn spliceOut(arena: Allocator, text: []const u8, from: usize, to: usize) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ text[0..from], text[to..] });
}

/// Span of the first `{{> Name}}` tag in `src`, for reporting a partial's error.
fn findPartialTag(src: []const u8, name: []const u8) ?[2]u32 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, src, pos, "{{")) |open| {
        const close = std.mem.indexOfPos(u8, src, open, "}}") orelse return null;
        const content = std.mem.trim(u8, src[open + 2 .. close], " \t\r\n");
        if (content.len > 1 and content[0] == '>' and std.mem.eql(u8, std.mem.trim(u8, content[1..], " \t\r\n"), name))
            return .{ @intCast(open), @intCast(close + 2) };
        pos = close + 2;
    }
    return null;
}

/// End of the "token" starting at `start`, for diagnostic ranges.
fn tokenEnd(src: []const u8, start: u32) u32 {
    var i: usize = start;
    if (i < src.len and src[i] == '{') {
        // A tag: to its close (or end of line).
        if (std.mem.indexOfPos(u8, src, i, "}}")) |c| return @intCast(@min(c + 2, src.len));
    }
    while (i < src.len and !std.ascii.isWhitespace(src[i]) and src[i] != '}' and src[i] != '|') i += 1;
    return @intCast(@max(i, start + 1));
}

// ------------------------------------------------------- positions / uris

const Position = struct { line: u32, character: u32 };
const Range = struct { start: Position, end: Position };

/// Byte offset for an LSP position (line, UTF-16 code unit).
fn offsetOf(src: []const u8, line: u32, character: u32) u32 {
    var i: usize = 0;
    var l: u32 = 0;
    while (l < line) : (l += 1) {
        i = (std.mem.indexOfScalarPos(u8, src, i, '\n') orelse return @intCast(src.len)) + 1;
    }
    var units: u32 = 0;
    while (i < src.len and src[i] != '\n' and units < character) {
        const n = std.unicode.utf8ByteSequenceLength(src[i]) catch 1;
        units += if (n == 4) 2 else 1;
        i += n;
    }
    return @intCast(@min(i, src.len));
}

fn positionOf(src: []const u8, offset: u32) Position {
    const end = @min(offset, src.len);
    var line: u32 = 0;
    var line_start: usize = 0;
    for (src[0..end], 0..) |c, i| if (c == '\n') {
        line += 1;
        line_start = i + 1;
    };
    var units: u32 = 0;
    var i = line_start;
    while (i < end) {
        const n = std.unicode.utf8ByteSequenceLength(src[i]) catch 1;
        units += if (n == 4) 2 else 1;
        i += n;
    }
    return .{ .line = line, .character = units };
}

fn rangeOf(src: []const u8, start: u32, end: u32) Range {
    return .{ .start = positionOf(src, start), .end = positionOf(src, end) };
}

fn uriToPath(gpa: Allocator, uri: []const u8) ![]const u8 {
    const raw = if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else uri;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '%' and i + 2 < raw.len) {
            if (std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16)) |b| {
                try out.append(gpa, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(gpa, raw[i]);
    }
    return out.toOwnedSlice(gpa);
}

fn getObj(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .object) x else null;
}
fn getArr(v: Value, key: []const u8) ?std.json.Array {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .array) x.array else null;
}
fn getStr(v: Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}
fn getInt(v: Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .integer) x.integer else null;
}
fn getPosition(params: Value) ?Position {
    const p = getObj(params, "position") orelse return null;
    const line = getInt(p, "line") orelse return null;
    const ch = getInt(p, "character") orelse return null;
    if (line < 0 or ch < 0) return null;
    return .{ .line = @intCast(line), .character = @intCast(ch) };
}

// ---------------------------------------------------------------- main loop

pub fn run(gpa: Allocator, io: Io) !void {
    var in_buf: [1 << 16]u8 = undefined;
    var out_buf: [1 << 16]u8 = undefined;
    var fr: Io.File.Reader = .initStreaming(.stdin(), io, &in_buf);
    var fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    var server = Server{ .gpa = gpa, .io = io, .out = &fw.interface };
    const r = &fr.interface;

    while (true) {
        var length: ?usize = null;
        while (true) {
            const line = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            const trimmed = std.mem.trimEnd(u8, line, "\r\n");
            if (trimmed.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                length = try std.fmt.parseInt(usize, std.mem.trim(u8, trimmed["content-length:".len..], " \t"), 10);
            }
        }
        const len = length orelse continue;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const body = try arena.alloc(u8, len);
        try r.readSliceAll(body);
        const msg = std.json.parseFromSliceLeaky(Value, arena, body, .{}) catch continue;
        server.handle(arena, msg) catch |err| {
            std.debug.print("[rocstache lsp] {s}\n", .{@errorName(err)});
        };
    }
}

// --------------------------------------------------------------------- tests

test "positions round-trip with multibyte text" {
    const src = "ab\ncé{{ x }}\n";
    try std.testing.expectEqual(@as(u32, 3), offsetOf(src, 1, 0));
    // 'é' is 2 bytes, 1 UTF-16 unit: `{{` starts at byte 6, character 2.
    try std.testing.expectEqual(@as(u32, 6), offsetOf(src, 1, 2));
    const p = positionOf(src, 6);
    try std.testing.expectEqual(@as(u32, 1), p.line);
    try std.testing.expectEqual(@as(u32, 2), p.character);
}

test "uri decoding" {
    const p = try uriToPath(std.testing.allocator, "file:///a/b%20c/T.rocstache");
    defer std.testing.allocator.free(p);
    try std.testing.expectEqualStrings("/a/b c/T.rocstache", p);
}

test "partial tag lookup and token end" {
    const src = "x {{> Nav }} {{ title | upper }}";
    try std.testing.expectEqual([2]u32{ 2, 12 }, findPartialTag(src, "Nav").?);
    try std.testing.expectEqual(@as(?[2]u32, null), findPartialTag(src, "Other"));
    try std.testing.expectEqual(@as(u32, 21), tokenEnd(src, 16)); // `title`
    try std.testing.expectEqual(@as(u32, 32), tokenEnd(src, 13)); // whole tag
}
