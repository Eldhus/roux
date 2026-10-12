//! The templates' language server, `roux lsp`: the Language Server
//! Protocol over stdio, for rocstache's Zed extension
//! (https://github.com/Eldhus/rocstache).
//! It keeps the documents the editor has open and, after each change,
//! checks every open template as `roux build` does (analysis.zig) and
//! publishes what is wrong in each: an edit to a partial changes what its
//! includers report, so all are checked again (a few, each microseconds).
//!
//! What comes from the editor is validated, never asserted: a message it
//! cannot frame ends the server; one it can frame but not read is skipped.
//! Each message is handled in an arena of its own, freed after it.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const generate = @import("generate.zig");
const analysis = @import("analysis.zig");
const assist = @import("assist.zig");

pub const documents_max = generate.templates_max;
/// A source's bytes, escaped in JSON (`\u0001` is six bytes for one).
pub const message_bytes_max = 6 * parse.source_bytes_max + 4096;
const header_lines_max = 8;

pub const Options = struct {
    input: *Io.Reader,
    output: *Io.Writer,
    /// What the server has to say about itself (Zed's language server log).
    log: *Io.Writer,
};

pub const Error = Allocator.Error || Io.Writer.Error || Io.Reader.Error ||
    error{ StreamTooLong, HeaderInvalid };

/// Serves until the editor says `exit`, or its end of the pipe closes.
/// Returns the exit status: 0 after a `shutdown` request, else 1 (the
/// protocol's rule).
pub fn run(gpa: Allocator, io: Io, options: Options) Error!u8 {
    var server: Server = .{ .gpa = gpa, .io = io, .output = options.output, .log = options.log };
    defer server.deinit();
    // Not bounded: it serves for as long as the editor runs.
    while (true) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const body = try read_message(arena, options.input, options.log) orelse return 1;
        if (try server.handle(arena, body)) |status| return status;
    }
}

const Document = struct { uri: []const u8, path: []const u8, text: []const u8 };

const Server = struct {
    gpa: Allocator,
    io: Io,
    output: *Io.Writer,
    log: *Io.Writer,
    documents: std.ArrayList(Document) = .empty,
    shutdown: bool = false,

    const Method = enum {
        initialize,
        initialized,
        shutdown,
        exit,
        @"textDocument/didOpen",
        @"textDocument/didChange",
        @"textDocument/didClose",
        @"textDocument/hover",
    };

    const Message = struct {
        id: ?std.json.Value = null,
        method: ?[]const u8 = null,
        params: std.json.Value = .null,
    };

    fn deinit(server: *Server) void {
        for (server.documents.items) |document| server.free(document);
        server.documents.deinit(server.gpa);
    }

    /// One message; the exit status when it is `exit`.
    fn handle(server: *Server, arena: Allocator, body: []const u8) Error!?u8 {
        const json: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const message = std.json.parseFromSliceLeaky(Message, arena, body, json) catch {
            try note(server.log, "a message that is not JSON-RPC, skipped", .{});
            return null;
        };
        // Without a method it is a response, and the server asks nothing.
        const name = message.method orelse return null;
        const method = std.meta.stringToEnum(Method, name) orelse {
            if (message.id) |id| try server.refuse(arena, id, "method not found");
            return null; // a notification the server does not use
        };
        switch (method) {
            .initialize => try server.respond(arena, message.id, initialize_result),
            .initialized => {},
            .shutdown => {
                server.shutdown = true;
                try server.respond(arena, message.id, null);
            },
            .exit => return if (server.shutdown) 0 else 1,
            .@"textDocument/didOpen",
            .@"textDocument/didChange",
            .@"textDocument/didClose",
            => {
                const closed = server.change(arena, method, message.params) catch |err|
                    switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Invalid => {
                            try note(server.log, "{s} unreadable, skipped", .{name});
                            return null;
                        },
                    };
                // A closed document's diagnostics go with it.
                if (closed) |uri| try server.notify(arena, uri, &.{});
                try server.publish(arena);
            },
            .@"textDocument/hover" => {
                const text = try server.hover(arena, message.params);
                if (text) |markdown| {
                    const contents = .{ .kind = "markdown", .value = markdown };
                    try server.respond(arena, message.id, .{ .contents = contents });
                } else try server.respond(arena, message.id, null);
            },
        }
        return null;
    }

    const initialize_result = .{
        .capabilities = .{
            .positionEncoding = "utf-16",
            // Whole documents: a template is small, and it is parsed whole.
            .textDocumentSync = .{ .openClose = true, .change = 1 },
            .hoverProvider = true,
        },
        .serverInfo = .{ .name = "roux lsp" },
    };

    /// A point in an open document, as a request names it.
    const At = struct { textDocument: struct { uri: []const u8 }, position: Position };

    /// The document a request names, and the offset of its point; null
    /// for a document not open, or a request not readable.
    fn at(server: *const Server, arena: Allocator, params: std.json.Value) ?struct {
        document: Document,
        offset: u32,
    } {
        const json: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const request = std.json.parseFromValueLeaky(At, arena, params, json) catch return null;
        const index = server.find(request.textDocument.uri) orelse return null;
        const document = server.documents.items[index];
        return .{ .document = document, .offset = offset_of(document.text, request.position) };
    }

    /// Markdown about the point a hover request names, or null.
    fn hover(server: *Server, arena: Allocator, params: std.json.Value) Error!?[]const u8 {
        const point = server.at(arena, params) orelse return null;
        const result = try analysis.analyze(arena, server.io, .{
            .path = point.document.path,
            .source = point.document.text,
            .buffers = try server.buffers(arena),
        });
        return assist.hover(arena, result, point.offset);
    }

    /// The open documents, as the analysis reads partials from them.
    fn buffers(server: *const Server, arena: Allocator) Allocator.Error![]const analysis.Buffer {
        const result = try arena.alloc(analysis.Buffer, server.documents.items.len);
        for (server.documents.items, result) |document, *buffer| {
            buffer.* = .{ .path = document.path, .text = document.text };
        }
        return result;
    }

    const Opened = struct { textDocument: struct { uri: []const u8, text: []const u8 } };
    const Changed = struct {
        textDocument: struct { uri: []const u8 },
        contentChanges: []const struct { text: []const u8 },
    };
    const Closed = struct { textDocument: struct { uri: []const u8 } };

    /// A document opened, changed or closed; the URI when it was closed.
    fn change(
        server: *Server,
        arena: Allocator,
        method: Method,
        params: std.json.Value,
    ) error{ OutOfMemory, Invalid }!?[]const u8 {
        const json: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        switch (method) {
            .@"textDocument/didOpen" => {
                const opened = std.json.parseFromValueLeaky(Opened, arena, params, json) catch
                    return error.Invalid;
                try server.keep(opened.textDocument.uri, opened.textDocument.text);
            },
            .@"textDocument/didChange" => {
                const changed = std.json.parseFromValueLeaky(Changed, arena, params, json) catch
                    return error.Invalid;
                // Whole documents (initialize_result): the last change is all of it.
                const changes = changed.contentChanges;
                if (changes.len == 0) return error.Invalid;
                try server.keep(changed.textDocument.uri, changes[changes.len - 1].text);
            },
            .@"textDocument/didClose" => {
                const closed = std.json.parseFromValueLeaky(Closed, arena, params, json) catch
                    return error.Invalid;
                const index = server.find(closed.textDocument.uri) orelse return error.Invalid;
                server.free(server.documents.swapRemove(index));
                return closed.textDocument.uri;
            },
            else => unreachable,
        }
        return null;
    }

    /// The document `uri` holds `text` now.
    fn keep(server: *Server, uri: []const u8, text: []const u8) error{ OutOfMemory, Invalid }!void {
        if (text.len > parse.source_bytes_max) return error.Invalid;
        const kept_text = try server.gpa.dupe(u8, text);
        errdefer server.gpa.free(kept_text);
        if (server.find(uri)) |index| {
            const document = &server.documents.items[index];
            server.gpa.free(document.text);
            document.text = kept_text;
            return;
        }
        if (server.documents.items.len == documents_max) return error.Invalid;
        const path = try path_of(server.gpa, uri);
        errdefer server.gpa.free(path);
        const kept_uri = try server.gpa.dupe(u8, uri);
        errdefer server.gpa.free(kept_uri);
        const document: Document = .{ .uri = kept_uri, .path = path, .text = kept_text };
        try server.documents.append(server.gpa, document);
    }

    fn find(server: *const Server, uri: []const u8) ?usize {
        for (server.documents.items, 0..) |document, index| {
            if (std.mem.eql(u8, document.uri, uri)) return index;
        }
        return null;
    }

    fn free(server: *Server, document: Document) void {
        server.gpa.free(document.uri);
        server.gpa.free(document.path);
        server.gpa.free(document.text);
    }

    /// Every open template checked, and what is wrong in each published.
    fn publish(server: *Server, arena: Allocator) Error!void {
        const open = try server.buffers(arena);
        for (server.documents.items) |document| {
            const result = try analysis.analyze(arena, server.io, .{
                .path = document.path,
                .source = document.text,
                .buffers = open,
            });
            const problem = result.problem orelse {
                try server.notify(arena, document.uri, &.{});
                continue;
            };
            const start = position_of(document.text, problem.offset);
            const end = position_of(document.text, problem.offset + problem.length);
            try server.notify(arena, document.uri, &.{.{
                .range = .{ .start = start, .end = end },
                .severity = 1, // an error
                .source = "roux",
                .message = problem.message,
            }});
        }
    }

    const Diagnostic = struct {
        range: struct { start: Position, end: Position },
        severity: u8,
        source: []const u8,
        message: []const u8,
    };

    /// The document's diagnostics, all of them: none clears what it had.
    fn notify(
        server: *Server,
        arena: Allocator,
        uri: []const u8,
        diagnostics: []const Diagnostic,
    ) Error!void {
        const method = "textDocument/publishDiagnostics";
        const params = .{ .uri = uri, .diagnostics = diagnostics };
        try server.send(arena, .{ .jsonrpc = "2.0", .method = method, .params = params });
    }

    fn respond(server: *Server, arena: Allocator, id: ?std.json.Value, result: anytype) Error!void {
        try server.send(arena, .{ .jsonrpc = "2.0", .id = id orelse .null, .result = result });
    }

    /// An error response: the request `id` is one the server does not serve.
    fn refuse(server: *Server, arena: Allocator, id: std.json.Value, text: []const u8) Error!void {
        const failure = .{ .code = -32601, .message = text };
        try server.send(arena, .{ .jsonrpc = "2.0", .id = id, .@"error" = failure });
    }

    /// `value` as JSON, framed.
    fn send(server: *Server, arena: Allocator, value: anytype) Error!void {
        var body: Io.Writer.Allocating = .init(arena);
        std.json.Stringify.value(value, .{}, &body.writer) catch return error.OutOfMemory;
        try server.output.print("Content-Length: {d}\r\n\r\n", .{body.written().len});
        try server.output.writeAll(body.written());
        try server.output.flush();
    }
};

/// A message's body, or null when the editor's end of the pipe closed. A
/// body too long is skipped (logged) and the next one read, a few at most.
fn read_message(arena: Allocator, input: *Io.Reader, log: *Io.Writer) Error!?[]const u8 {
    const skipped_max = 4;
    for (0..skipped_max + 1) |_| {
        const length = read_headers(input) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        if (length <= message_bytes_max) {
            const body = try arena.alloc(u8, length);
            input.readSliceAll(body) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return err,
            };
            return body;
        }
        try note(log, "a message of {d} bytes, skipped", .{length});
        input.discardAll(length) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
    }
    return error.HeaderInvalid; // the editor sends nothing but huge messages
}

/// A line in the log, at once: the editor shows the log as it comes.
fn note(log: *Io.Writer, comptime format: []const u8, arguments: anytype) Io.Writer.Error!void {
    try log.print("roux lsp: " ++ format ++ "\n", arguments);
    try log.flush();
}

/// The headers, up to the blank line: the body's length.
fn read_headers(input: *Io.Reader) (Error || error{EndOfStream})!usize {
    var length: ?usize = null;
    for (0..header_lines_max) |_| {
        const line = std.mem.trimEnd(u8, try input.takeDelimiterInclusive('\n'), "\r\n");
        if (line.len == 0) return length orelse error.HeaderInvalid;
        const name = "content-length:";
        if (line.len > name.len and std.ascii.startsWithIgnoreCase(line, name)) {
            const digits = std.mem.trim(u8, line[name.len..], " \t");
            length = std.fmt.parseInt(usize, digits, 10) catch return error.HeaderInvalid;
        }
    }
    return error.HeaderInvalid;
}

/// The path a `file://` URI names, its `%XX` escapes decoded.
fn path_of(gpa: Allocator, uri: []const u8) error{ OutOfMemory, Invalid }![]const u8 {
    const scheme = "file://";
    if (!std.mem.startsWith(u8, uri, scheme)) return error.Invalid;
    const encoded = uri[scheme.len..];
    const path = try gpa.alloc(u8, encoded.len);
    errdefer gpa.free(path);
    var length: usize = 0;
    var at: usize = 0;
    while (at < encoded.len) : (length += 1) {
        assert(length < encoded.len);
        if (encoded[at] != '%') {
            path[length] = encoded[at];
            at += 1;
            continue;
        }
        if (at + 3 > encoded.len) return error.Invalid;
        path[length] = std.fmt.parseInt(u8, encoded[at + 1 .. at + 3], 16) catch
            return error.Invalid;
        at += 3;
    }
    assert(length <= encoded.len);
    return gpa.realloc(path, length);
}

const Position = struct { line: u32, character: u32 };

/// A byte offset as the protocol counts: lines, and UTF-16 code units
/// within the line (a 4-byte UTF-8 sequence is two).
fn position_of(source: []const u8, offset: u32) Position {
    assert(offset <= source.len);
    const before = source[0..offset];
    const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |n| n + 1 else 0;
    var character: u32 = 0;
    var at = line_start;
    while (at < offset) {
        const length = std.unicode.utf8ByteSequenceLength(source[at]) catch 1;
        character += if (length == 4) 2 else 1;
        at += length;
    }
    return .{ .line = @intCast(std.mem.count(u8, before, "\n")), .character = character };
}

/// The byte offset of a position: past its line's end is the line's end,
/// past the last line the source's end.
fn offset_of(source: []const u8, position: Position) u32 {
    var line_start: usize = 0;
    for (0..position.line) |_| {
        const newline = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse
            return @intCast(source.len);
        line_start = newline + 1;
    }
    var at = line_start;
    var character: u32 = 0;
    while (at < source.len and source[at] != '\n' and character < position.character) {
        const length = std.unicode.utf8ByteSequenceLength(source[at]) catch 1;
        character += if (length == 4) 2 else 1;
        at = @min(at + length, source.len);
    }
    assert(at <= source.len);
    return @intCast(at);
}

const testing = std.testing;

/// `json` framed as the protocol frames it.
fn frame(arena: Allocator, json: []const u8) ![]const u8 {
    return arena.print("Content-Length: {d}\r\n\r\n{s}", .{ json.len, json });
}

test "lsp: positions count UTF-16 units, URIs decode" {
    const source = "ab\nc\u{e9}\u{1f600}{{ x }}\n";
    try testing.expectEqual(Position{ .line = 0, .character = 2 }, position_of(source, 2));
    // `é` is two bytes and one unit; the emoji four bytes and two units.
    try testing.expectEqual(Position{ .line = 1, .character = 4 }, position_of(source, 10));
    // And back, a position past its line or the source clamped.
    for ([_]u32{ 0, 2, 3, 4, 10, 18 }) |offset| {
        try testing.expectEqual(offset, offset_of(source, position_of(source, offset)));
    }
    try testing.expectEqual(@as(u32, 2), offset_of(source, .{ .line = 0, .character = 9 }));
    try testing.expectEqual(source.len, offset_of(source, .{ .line = 7, .character = 0 }));
    const path = try path_of(testing.allocator, "file:///a/b%20c/T.rocstache");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/a/b c/T.rocstache", path);
    try testing.expectError(error.Invalid, path_of(testing.allocator, "file:///a%2"));
    try testing.expectError(error.Invalid, path_of(testing.allocator, "untitled:1"));
}

test "lsp: a session: opened, wrong, fixed through a partial, shut down" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const page = "file:///app/templates/Page.rocstache";
    const top = "file:///app/templates/Top.rocstache";
    const messages = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":
        ++ "{\"uri\":\"" ++ page ++ "\",\"languageId\":\"rocstache\",\"version\":1," ++
            "\"text\":\"{{ a }}\\n{{> Top}}\"}}}",
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":
        ++ "{\"uri\":\"" ++ top ++ "\",\"languageId\":\"rocstache\",\"version\":1," ++
            "\"text\":\"{{#a}}{{ b }}{{/a}}\"}}}",
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":
        ++ "{\"uri\":\"" ++ top ++ "\",\"version\":2},\"contentChanges\":" ++
            "[{\"text\":\"{{ a }}\"}]}}",
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":
        ++ "{\"uri\":\"" ++ page ++ "\"},\"position\":{\"line\":0,\"character\":3}}}",
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var input_bytes: std.ArrayList(u8) = .empty;
    for (messages) |message| try input_bytes.appendSlice(arena, try frame(arena, message));
    var input: Io.Reader = .fixed(input_bytes.items);
    var output: Io.Writer.Allocating = .init(arena);
    var log: Io.Writer.Allocating = .init(arena);
    const status = try run(testing.allocator, testing.io, .{
        .input = &input,
        .output = &output.writer,
        .log = &log.writer,
    });
    try testing.expectEqual(@as(u8, 0), status);
    try testing.expectEqualStrings("", log.written());
    const written = output.written();
    // Page's diagnostics, each set as published: they change with Top
    // alone, so every open template is checked after any change.
    const page_published = "{\"uri\":\"" ++ page ++ "\",\"diagnostics\":";
    const expected = [_][]const u8{
        // Page opened, no Top anywhere: the partial is missing.
        "[{\"range\":{\"start\":{\"line\":1,\"character\":4}," ++
            "\"end\":{\"line\":1,\"character\":7}},\"severity\":1,\"source\":\"roux\"," ++
            "\"message\":\"is not a template here (no such .rocstache)\"}]",
        // Top opened, wrong: its mistake on the tag reaching it.
        "[{\"range\":{\"start\":{\"line\":1,\"character\":0}," ++
            "\"end\":{\"line\":1,\"character\":9}},\"severity\":1,\"source\":\"roux\"," ++
            "\"message\":\"in Top.rocstache:1:1: `a` is a Str elsewhere, and a list here\"}]",
        // Top fixed: cleared.
        "[]",
    };
    var at: usize = 0;
    for (expected) |diagnostics| {
        at = std.mem.indexOfPos(u8, written, at, page_published).? + page_published.len;
        try testing.expect(std.mem.startsWith(u8, written[at..], diagnostics));
    }
    try testing.expect(std.mem.indexOfPos(u8, written, at, page_published) == null);
    try testing.expect(std.mem.indexOf(u8, written, "\"id\":2,\"error\":{\"code\":-32601") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"id\":3,\"result\":null") != null);
    const hovered = "\"id\":4,\"result\":{\"contents\":{\"kind\":\"markdown\"," ++
        "\"value\":\"```roc\\na : Str\\n```\"}}";
    try testing.expect(std.mem.indexOf(u8, written, hovered) != null);
}

test "lsp: the pipe closing without exit is status 1; a non-JSON message is skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var input: Io.Reader = .fixed(try frame(arena, "not json"));
    var output: Io.Writer.Allocating = .init(arena);
    var log: Io.Writer.Allocating = .init(arena);
    const options: Options = .{ .input = &input, .output = &output.writer, .log = &log.writer };
    try testing.expectEqual(@as(u8, 1), try run(testing.allocator, testing.io, options));
    try testing.expectEqualStrings("", output.written());
    try testing.expect(std.mem.indexOf(u8, log.written(), "skipped") != null);
}
