//! Development mode: what the host does when `roux dev` runs it
//! (docs/dev-server.md). `ROUX_DEV` names the build, read once at startup;
//! without it none of this runs, and a request costs one comparison.
//!
//! - What a page shows is named `<build>.<program>`: the build roux dev
//!   started, and how many times the templates' program has been reread
//!   since (templates.zig, `requested`). A markup edit rereads the program
//!   with no restart; any other edit restarts the app as a new build.
//! - `GET /_dev/events` is a server-sent event stream the host answers
//!   itself: the name now, then the name again each time the program is
//!   reread, and a comment every 15 s until the client leaves. A restart
//!   drops the stream; the browser's EventSource reconnects (after
//!   `retry`, 50 ms) and hears the new build's name.
//! - Every `text/html` answer of the app gets a script appended that
//!   knows the name the page was made under, and reloads the page when
//!   the stream says another. The name is read before the page is
//!   rendered: a page made while the program was reread names the older
//!   one, and reloads once more, never one time too few.

const std = @import("std");
const assert = std.debug.assert;

pub const events_path = "/_dev/events";

pub const keepalive_seconds = 15;

/// What a page or the stream was made under: `<build>.<program>`.
pub fn name(build: []const u8, program: u32, buffer: []u8) []const u8 {
    assert(build.len > 0);
    return std.fmt.bufPrint(buffer, "{s}.{d}", .{ build, program }) catch unreachable;
}

/// An event naming what serves now; the first of a stream says how soon
/// to reconnect, too.
pub fn event(current: []const u8, first: bool, buffer: []u8) []const u8 {
    const retry = if (first) "retry: 50\n" else "";
    return std.fmt.bufPrint(buffer, "{s}data: {s}\n\n", .{ retry, current }) catch unreachable;
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

const script_head = "<script>(()=>{const b=\"";
const script_tail = "\";new EventSource(\"" ++ events_path ++ "\").onmessage=" ++
    "(m)=>{if(m.data!==b)location.reload()}})()</script>\n";

/// The body with the script after it, naming `made` (the page's name), in
/// `gpa`'s memory (freed at release).
pub fn with_script(
    gpa: std.mem.Allocator,
    body: []const u8,
    made: []const u8,
) error{OutOfMemory}![]u8 {
    const parts = [_][]const u8{ body, script_head, made, script_tail };
    return std.mem.concat(gpa, u8, &parts);
}

test "dev: names, events, the script, html" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("7.0", name("7", 0, &buffer));
    var event_buffer: [64]u8 = undefined;
    const first = event("7.0", true, &event_buffer);
    try std.testing.expectEqualStrings("retry: 50\ndata: 7.0\n\n", first);
    try std.testing.expectEqualStrings("data: 7.3\n\n", event("7.3", false, &event_buffer));
    try std.testing.expect(is_events("/_dev/events?x=1"));
    try std.testing.expect(!is_events("/_dev/eventsx"));
    try std.testing.expect(is_html("text/html; charset=utf-8"));
    try std.testing.expect(!is_html("text/event-stream"));
    const page = try with_script(std.testing.allocator, "<p>x</p>", "7.2");
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.startsWith(u8, page, "<p>x</p><script>"));
    try std.testing.expect(std.mem.indexOf(u8, page, "const b=\"7.2\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, page, "</script>\n"));
}
