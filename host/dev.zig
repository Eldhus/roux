//! Development mode: what the host does when `roux dev` runs it
//! (docs/dev-server.md). `ROUX_DEV` names the build, read once at startup;
//! without it none of this runs, and a request costs one comparison.
//!
//! - `GET /_dev/events` is a server-sent event stream the host answers
//!   itself: the build's name, then a comment every 15 s until the client
//!   leaves. When `roux dev` restarts the app the stream drops; the
//!   browser's EventSource reconnects (after `retry`, 50 ms), hears another
//!   name, and reloads.
//! - Every `text/html` answer of the app gets the script that listens,
//!   appended. The templates' own output stays production's.

const std = @import("std");
const assert = std.debug.assert;

pub const events_path = "/_dev/events";

/// Appended to HTML in development: the first name heard is this page's
/// build; another one means a new build is serving.
pub const reload_script =
    "<script>(()=>{let b;const e=new EventSource(\"" ++ events_path ++ "\");" ++
    "e.onmessage=(m)=>{if(b===undefined)b=m.data;else if(m.data!==b)location.reload()}})()" ++
    "</script>\n";

pub const keepalive_seconds = 15;

/// The stream's first bytes: how soon to reconnect, and the build's name.
pub fn first_event(build: []const u8, buffer: []u8) []const u8 {
    assert(build.len > 0);
    return std.fmt.bufPrint(buffer, "retry: 50\ndata: {s}\n\n", .{build}) catch unreachable;
}

/// Whether a request's target (path and query) is the events stream.
pub fn is_events(target: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return std.mem.eql(u8, target[0..end], events_path);
}

/// Whether an answer is a page the script belongs in.
pub fn is_html(content_type: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(content_type, "text/html");
}

/// The body with the script after it, in `gpa`'s memory (freed at release).
pub fn with_script(gpa: std.mem.Allocator, body: []const u8) error{OutOfMemory}![]u8 {
    const result = try gpa.alloc(u8, body.len + reload_script.len);
    @memcpy(result[0..body.len], body);
    @memcpy(result[body.len..], reload_script);
    return result;
}

test "dev: the first event, the script, html" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("retry: 50\ndata: 7\n\n", first_event("7", &buffer));
    try std.testing.expect(is_events("/_dev/events?x=1"));
    try std.testing.expect(!is_events("/_dev/eventsx"));
    try std.testing.expect(is_html("text/html; charset=utf-8"));
    try std.testing.expect(!is_html("text/event-stream"));
    const page = try with_script(std.testing.allocator, "<p>x</p>");
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.endsWith(u8, page, "</script>\n"));
}
