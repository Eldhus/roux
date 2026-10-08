//! One template compiled alone: a part of an app's templates, its own
//! object, so an edit recompiles only the templates it touches (DIARY,
//! 2026-10-07: the dragrace site's 12 templates in one Debug object took
//! ~1 s; one alone 110-390 ms). roux build writes a root per template,
//! `part_Page.zig`, which names the template's index in the registry and
//! imports this file; the dispatcher (object.zig) calls the two functions
//! this exports, by the template's id.

const registry = @import("templates.zig");
const render = @import("render.zig");
const symbols = @import("symbols.zig");

comptime {
    _ = Part(@import("root").index);
}

fn Part(comptime index: usize) type {
    const entry = registry.all[index];
    const T = render.Compiled(registry, index);
    return struct {
        fn measure(ctx: *const T.Ctx) callconv(.c) usize {
            return T.measure(ctx);
        }

        fn draw(ctx: *const T.Ctx, out: *render.Out) callconv(.c) void {
            T.render(ctx, out);
        }

        comptime {
            @export(&measure, .{ .name = symbols.measure_name(entry.id) });
            @export(&draw, .{ .name = symbols.render_name(entry.id) });
        }
    };
}
