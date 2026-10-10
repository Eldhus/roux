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

pub const stats_path = "/_dev/stats";

/// `POST /_dev/restart`: the app exits with `restart_code`, which roux dev
/// takes as "start me again" (tools/roux/dev.zig): the button on the page
/// of an `init!` that failed, once its cause is gone (a database deleted).
pub const restart_path = "/_dev/restart";
pub const restart_code = 75;

/// `/_dev/race`: roux-load against this app. `POST /_dev/race?paths=/a,/b`
/// starts it (a lane a path, `race_seconds` each, one after another);
/// `&mode=events` races server-sent event streams, in events a second;
/// `GET` says where it is, as JSON.
pub const race_path = "/_dev/race";
pub const race_lanes_max = 8;
pub const race_path_bytes_max = 120;
pub const race_seconds = 2;

pub fn is_race(target: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return std.mem.eql(u8, target[0..end], race_path);
}

/// The lanes' paths in a race request's `paths=`, comma-separated: each an
/// absolute path of plain characters (no query, nothing to escape); null if
/// any is not, or there are none or too many.
pub fn race_paths(target: []const u8, out: *[race_lanes_max][]const u8) ?[]const []const u8 {
    const query_at = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[query_at + 1 ..];
    if (!std.mem.startsWith(u8, query, "paths=")) return null;
    const end = std.mem.indexOfScalar(u8, query, '&') orelse query.len;
    var count: usize = 0;
    var paths = std.mem.splitScalar(u8, query["paths=".len..end], ',');
    while (paths.next()) |path| {
        if (count == race_lanes_max) return null;
        if (path.len < 1 or path.len > race_path_bytes_max or path[0] != '/') return null;
        for (path) |byte| switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '/', '.', '_', '-' => {},
            else => return null,
        };
        out[count] = path;
        count += 1;
    }
    return if (count == 0) null else out[0..count];
}

/// What roux-load measures: answers a second, or server-sent events a
/// second (roux-load's `--mode`).
pub const RaceMode = enum { requests, events };

/// The race's mode: after the paths, nothing (requests) or `&mode=` and
/// a mode; null for anything else.
pub fn race_mode(target: []const u8) ?RaceMode {
    const query_at = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[query_at + 1 ..];
    const end = std.mem.indexOfScalar(u8, query, '&') orelse return .requests;
    const rest = query[end + 1 ..];
    if (!std.mem.startsWith(u8, rest, "mode=")) return null;
    return std.meta.stringToEnum(RaceMode, rest["mode=".len..]);
}

test "dev: a race's mode" {
    try std.testing.expectEqual(RaceMode.requests, race_mode("/_dev/race?paths=/a").?);
    try std.testing.expectEqual(RaceMode.events, race_mode("/_dev/race?paths=/a&mode=events").?);
    try std.testing.expect(race_mode("/_dev/race?paths=/a&mode=stream") == null);
    try std.testing.expect(race_mode("/_dev/race?paths=/a&x=1") == null);
    try std.testing.expect(race_mode("/_dev/race?paths=/a&mode=events&x=1") == null);
    var out: [race_lanes_max][]const u8 = undefined;
    const paths = race_paths("/_dev/race?paths=/race/stream&mode=events", &out).?;
    try std.testing.expectEqualStrings("/race/stream", paths[0]);
}

test "dev: a race's paths" {
    var out: [race_lanes_max][]const u8 = undefined;
    const two = race_paths("/_dev/race?paths=/race/text,/favicon.svg", &out).?;
    try std.testing.expectEqual(@as(usize, 2), two.len);
    try std.testing.expectEqualStrings("/favicon.svg", two[1]);
    try std.testing.expect(race_paths("/_dev/race", &out) == null);
    try std.testing.expect(race_paths("/_dev/race?paths=race", &out) == null);
    try std.testing.expect(race_paths("/_dev/race?paths=/a b", &out) == null);
    try std.testing.expect(race_paths("/_dev/race?paths=/a?x=1", &out) == null);
}

pub fn is_restart(target: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return std.mem.eql(u8, target[0..end], restart_path);
}

/// The most of roux dev's stats file the host serves.
pub const stats_bytes_max = 4096;

/// Whether a request's target is `/_dev/stats`.
pub fn is_stats(target: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return std.mem.eql(u8, target[0..end], stats_path);
}

/// Whether a request's target (path and query) is the events stream.
pub fn is_events(target: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return std.mem.eql(u8, target[0..end], events_path);
}

/// Whether the answer will be a page the browser shows, by the request's
/// `Sec-Fetch-Dest`: a navigation's `document` (or `iframe`), not a
/// `fetch()`'s `empty` (a Datastar fragment sent as HTML), which would
/// gain one more event stream per patch. A client that sends none (curl,
/// an agent) gets the script, as before.
pub fn wants_script(fetch_dest: ?[]const u8) bool {
    const dest = fetch_dest orelse return true;
    return std.ascii.eqlIgnoreCase(dest, "document") or std.ascii.eqlIgnoreCase(dest, "iframe");
}

/// Whether an answer is a page the script belongs in.
pub fn is_html(content_type: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(content_type, "text/html");
}

/// The most of a failure's text a page is shown (the terminal has it all).
pub const failure_bytes_max = 16 * 1024;

/// A failed build's report as an event (`build-failed`), a `data:` line
/// per line, at most `failure_bytes_max` of it; empty text is
/// `build-ok`, which takes the overlay away. In `buffer`.
pub fn failure_event(text: []const u8, buffer: []u8) []const u8 {
    assert(buffer.len >= 64);
    const shown = std.mem.trimEnd(u8, text[0..@min(text.len, failure_bytes_max)], "\r\n");
    if (shown.len == 0) return "event: build-ok\ndata:\n\n";
    // The last byte is kept for the event's end; text that does not fit is
    // cut at a line's end.
    var writer: std.Io.Writer = .fixed(buffer[0 .. buffer.len - 1]);
    writer.writeAll("event: build-failed\n") catch unreachable;
    var lines = std.mem.splitScalar(u8, shown, '\n');
    var whole = writer.end;
    write: while (lines.next()) |line| {
        writer.writeAll("data: ") catch break :write;
        // A carriage return would end the line early: dropped.
        for (line) |byte| {
            if (byte != '\r') writer.writeByte(byte) catch break :write;
        }
        writer.writeAll("\n") catch break :write;
        whole = writer.end;
    }
    buffer[whole] = '\n';
    return buffer[0 .. whole + 1];
}

const script_head = "<script>(()=>{const b=\"";
// The overlay: what roc or roux said, over the page, until a good build
// reloads it (the page keeps working underneath; Escape hides it).
const script_tail = "\";const e=new EventSource(\"" ++ events_path ++ "\");" ++
    "e.onmessage=(m)=>{if(m.data!==b)location.reload()};" ++
    "let o;e.addEventListener(\"build-failed\",(m)=>{if(!o){o=document.createElement(\"pre\");" ++
    "o.style.cssText=\"position:fixed;inset:auto 1rem 1rem 1rem;max-height:60vh;overflow:auto;" ++
    "margin:0;padding:1rem 1.25rem;background:#1b1210;color:#f6e9dd;border:2px solid #e0603a;" ++
    "border-radius:10px;font:13px/1.5 ui-monospace,monospace;white-space:pre-wrap;" ++
    "z-index:2147483647;box-shadow:0 12px 40px #0008\";" ++
    "o.onclick=()=>o.remove();" ++
    "addEventListener(\"keydown\",(k)=>{if(k.key===\"Escape\")o.remove()});}" ++
    "o.textContent=m.data;" ++
    "document.body.append(o)});" ++
    "e.addEventListener(\"build-ok\",()=>{if(o)o.remove()})})()</script>\n";

/// The page a development app answers with when its `init!` failed: what it
/// said, escaped, and the script, which reloads it when the next build
/// serves. In `gpa`'s memory (freed at release).
pub fn failure_page(
    gpa: std.mem.Allocator,
    text: []const u8,
    made: []const u8,
) error{OutOfMemory}![]u8 {
    var page: std.Io.Writer.Allocating = .init(gpa);
    defer page.deinit();
    const writer = &page.writer;
    writer.writeAll("<!doctype html><meta charset=\"utf-8\">" ++
        "<title>roux dev: init! failed</title>" ++
        "<body style=\"margin:0;padding:2rem;background:#15100e;color:#f3e8dc;" ++
        "font:15px/1.6 system-ui,sans-serif\"><h1 style=\"font-size:1.3rem;color:#ec7a41\">" ++
        "The app's <code>init!</code> failed</h1><p>The build compiled, but would not start. " ++
        "This page reloads when the next build runs.</p><pre style=\"white-space:pre-wrap;" ++
        "padding:1rem;background:#241a16;border:1px solid #3a2c25;border-radius:8px;" ++
        "font:13px/1.5 ui-monospace,monospace\">") catch return error.OutOfMemory;
    for (text) |byte| {
        const escaped: []const u8 = switch (byte) {
            '<' => "&lt;",
            '>' => "&gt;",
            '&' => "&amp;",
            '"' => "&quot;",
            else => &.{byte},
        };
        writer.writeAll(escaped) catch return error.OutOfMemory;
    }
    // Once the cause is gone (a file deleted, a secret written), the app is
    // started again, and the page reloads when it answers.
    writer.writeAll("</pre><button style=\"font:600 15px system-ui;padding:.6rem 1.1rem;" ++
        "border:0;border-radius:8px;background:#ec7a41;color:#1b0f09;cursor:pointer\" " ++
        "onclick=\"this.disabled=true;this.textContent='Starting…';" ++
        "fetch('" ++ restart_path ++ "',{method:'POST'}).catch(()=>{});" ++
        "const t=setInterval(()=>fetch('/',{cache:'no-store'}).then(()=>{clearInterval(t);" ++
        "location.reload()}).catch(()=>{}),300)\">Start it again</button>") catch
        return error.OutOfMemory;
    return with_script(gpa, page.written(), made);
}

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
    try std.testing.expect(wants_script(null));
    try std.testing.expect(wants_script("document"));
    try std.testing.expect(!wants_script("empty"));
    const page = try with_script(std.testing.allocator, "<p>x</p>", "7.2");
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.startsWith(u8, page, "<p>x</p><script>"));
    try std.testing.expect(std.mem.indexOf(u8, page, "const b=\"7.2\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, page, "</script>\n"));
}

test "dev: init!'s failure as a page, escaped" {
    const page = try failure_page(std.testing.allocator, "ERROR init!: <db> & \"x\"\n", "3.0");
    defer std.testing.allocator.free(page);
    const escaped = "ERROR init!: &lt;db&gt; &amp; &quot;x&quot;";
    try std.testing.expect(std.mem.indexOf(u8, page, escaped) != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "const b=\"3.0\"") != null);
}

test "dev: a failure as an event" {
    var buffer: [failure_bytes_max + 4096]u8 = undefined;
    try std.testing.expectEqualStrings(
        "event: build-failed\ndata: main.roc:3:1: oops\ndata: \ndata: Str\n\n",
        failure_event("main.roc:3:1: oops\r\n\nStr\n", &buffer),
    );
    const ok = "event: build-ok\ndata:\n\n";
    try std.testing.expectEqualStrings(ok, failure_event("", &buffer));
    try std.testing.expectEqualStrings(ok, failure_event("\n\n", &buffer));
    // Long text is cut, never past the buffer, and still an event.
    var lines: [failure_bytes_max]u8 = undefined;
    for (0..failure_bytes_max / 2) |i| lines[2 * i ..][0..2].* = "a\n".*;
    const cut = failure_event(&lines, &buffer);
    try std.testing.expect(cut.len <= buffer.len);
    try std.testing.expect(std.mem.endsWith(u8, cut, "\ndata: a\n\n"));
}
