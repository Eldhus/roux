const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const scripty = @import("root.zig"); // In your case this would be @import("scripty")

/// A Scripty VM is created by providing a Value union which defines the
/// Scripty evaluation context.
const ExampleVM = scripty.VM(Value);

test ExampleVM {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    // This is the Scripty expression that we're going to evaluate.
    const src = "$site.link().append('/', $site.link().len())";

    // The Scripty expression will be evaluated starting from this
    // value. For example '$version' will evaluate to 'v0'.
    //
    // Note that this type defines also some builtin functions that
    // can be invoked by Scripty (eg 'link', 'len'). See below the
    // definition of 'Value'.
    var root: Value.Root = .{
        .version = "v0",
        .page = .{
            .title = "Home",
            .content = "<p>Welcome!</p>",
        },
        .site = .{
            .name = "Example Website",
            .hostname = "example.com",
        },
        ._force_https = true,
    };

    var vm: ExampleVM = .{};
    const result = while (true) break vm.run(arena, &root, src, .{}) catch |err| switch (err) {
        error.OutOfMemory => std.process.fatal("oom", .{}),
        error.Quota => unreachable, // we are running with infinite quota, see RunOptions
    };

    const value: Value = result.value;
    try std.testing.expectEqualStrings("https://example.com/19", value.string.value);
}

/// This union defines the various value types that can be returned by a Scripty
/// expression.
///
/// It's your job to map literals to their corresponding union case (see
/// `fromStringLiteral()` for example), including mapping them to an
/// evaluation error, if so desired.
///
/// What values should exist in your evaluation context is entirely up to you
/// except for two fields which are mandatory:
///  - 'root' must be a struct that represents the starting point from which
///    Scripty expressions are evaluated
///  - 'err: []const u8' is the case that represents runtime evaluation errors
///
/// When a Scripty VM is embedded in a host language it's also possible
/// that the host language will place additional requirements on the
/// structure of the evaluation context. For example SuperHTML requires the
/// existence of Optionals, Iterators, and a few other things.
pub const Value = union(enum) {
    // These are the mandatory fields ('err' must be a string, 'root' must be a struct)
    root: *const Root,
    err: []const u8, // error message

    // These are the fields that correspond to the values that are specific
    // to our evaluation context, including both aggregate types (eg Site, Page)
    // and primitive types, such as strings and booleans.
    //
    // Note that you are not required to have support for each primitive type.
    // If for example you're buliding a calculator and you have no use for
    // strings, you can avoid having a corresponding field. There's a function
    // called 'fromStringLiteral' (listed below) that Scripty will invoke to
    // map a string literal to a Value. Since you controll the implemetation
    // of that function, you will have the ability to map all string literals
    // to 'err' values, if you so desire.
    //
    // A second important thing about primitive values is that, if you want to
    // give them builtin functions, you will have to wrap them in a struct.
    //
    // This is completely transparent to your users (when done correctly) and
    // will give you the opportunity to create a 'Builtins' decl inside the
    // struct definition. In this example we do it with the 'string' case
    // but obviously the same could be done for all primitive types.
    // While not mandatory, it's likely that you will want to give builtins
    // to all the primitive types that you intend to support so wrapping
    // them in a struct is almost always the right move.
    site: *const Root.Site,
    page: *const Root.Page,
    string: String,
    bool: bool,
    int: i64,
    float: f64,

    /// This is the type definition for the root of your evaluation context.
    /// Every Scripty expression will start by accessing a field of this struct
    /// (e.g. `$version`, `$page`, `$site`).
    ///
    /// Field navigation (eg '$page.title') maps 1:1 to struct field navigation
    /// when the corresponding struct definition contains a `Dot` decl set to
    /// true (all fields will be private otherwise). If you want a field to NOT
    /// be accessible by users via Scripty, when `Dot = true`, prefix it with
    /// '_'. This is useful to make available resources such as allocators to
    /// builtin function implementations.
    const Root = struct {
        version: []const u8,
        page: Page,
        site: Site,

        // Private, won't be accessible to users.
        _force_https: bool,

        pub const PassByRef = true;
        pub const Dot = true;
        pub const Builtins = struct {};

        pub const Site = struct {
            name: []const u8,
            hostname: []const u8,

            // Marks this type as being navigable via dot syntax (eg '$site.name').
            // Note that this is unrelated to being able to call builtin functions
            // on this type (eg '$foo.baz()').
            // Fields prefixed by an underscore will remain private (ie not
            // navigable by users).
            pub const Dot = true;

            // Whether the value should be passed by copy or by pointer to
            // builtin functions (the builtin function signature must match).
            pub const PassByRef = true;

            /// Each definition inside of `Builtins` is a builtin function that
            /// users will be able to call on the original value (e.g.
            /// `$site.link()`).
            pub const Builtins = struct {
                ///This decl name defines what the builtin will be called.
                ///
                ///In the future builtin definitions will require more
                ///parameters in order to support features like static analysis
                ///and automatic docs generation.
                pub const link = struct {
                    pub fn call(
                        site: *const Site,
                        gpa: Allocator,
                        // Root context is always made available to give you easy access
                        // to resources hidden in private fields.
                        ctx: *const Root,
                        args: []const Value,
                    ) !Value {
                        // Make sure to validate your arguments!
                        const bad_arg: Value = .{ .err = "expected 0 arguments" };
                        if (args.len != 0) return bad_arg;

                        return .{
                            .string = .{
                                .value = try std.fmt.allocPrint(gpa, "http{s}://{s}", .{
                                    if (ctx._force_https) "s" else "",
                                    site.hostname,
                                }),
                            },
                        };
                    }
                };
            };
        };

        pub const Page = struct {
            title: []const u8,
            content: []const u8,

            pub const Dot = true;
            pub const PassByRef = true;
            pub const Builtins = struct {};
        };
    };

    const String = struct {
        value: []const u8,

        // Note that this struct does not have a Dot decl, making it
        // non-navigable by users.

        pub const Builtins = struct {
            pub const len = struct {
                pub fn call(
                    str: String,
                    gpa: std.mem.Allocator,
                    _: *const Root,
                    args: []const Value,
                ) !Value {
                    if (args.len != 0) return .{ .err = "'len' wants no arguments" };
                    return Value.from(gpa, @as(i64, @intCast(str.value.len)));
                }
            };

            pub const append = struct {
                pub fn call(
                    str: String,
                    gpa: std.mem.Allocator,
                    _: *const Root,
                    args: []const Value,
                ) !Value {
                    if (args.len == 0) return .{ .err = "missing arguments" };

                    var out: Io.Writer.Allocating = .init(gpa);
                    errdefer out.deinit();

                    const w = &out.writer;

                    w.writeAll(str.value) catch return error.OutOfMemory;
                    for (args) |arg| switch (arg) {
                        .string => |s| w.writeAll(s.value),
                        .int => |i| w.print("{}", .{i}),
                        else => {
                            out.deinit();
                            return .{ .err = "invalid argument" };
                        },
                    } catch return error.OutOfMemory;

                    return Value.from(gpa, try out.toOwnedSlice());
                }
            };
        };
    };

    // This function is called by the Scripty VM to turn a string literal
    // into a Value.
    pub fn fromStringLiteral(bytes: []const u8) Value {
        return .{ .string = .{ .value = bytes } };
    }

    /// In most cases you will want to parse numbers into i64 and f64, but for
    /// cases where you have special needs
    /// you will have full control over the parsing process.
    ///
    /// Example usecases:
    /// - you want to use bigints in a financial application
    /// - you want to run scripty on a small device and prefer f32 (or f16) over f64
    ///
    /// Note that the numeric literal will have to conform to the scripty grammar
    /// (i.e. the value will be validated before being passed to this function).
    pub fn fromIntegerLiteral(bytes: []const u8) Value {
        const num = std.fmt.parseInt(i64, bytes, 10) catch {
            return .{ .err = "error parsing int" };
        };
        return .{ .int = num };
    }

    pub fn fromFloatLiteral(bytes: []const u8) Value {
        const num = std.fmt.parseFloat(f64, bytes) catch {
            return .{ .err = "error parsing float" };
        };
        return .{ .float = num };
    }

    pub fn fromBooleanLiteral(b: bool) Value {
        return .{ .bool = b };
    }

    /// This function is invoked by the Scripty VM to turn a raw Zig value into
    /// a Value instance. This is necessary because, for example, when navigating
    /// a struct (e.g. when evaluating dot field notation such as '$foo.bar'),
    /// Scripty will need to take the raw Zig value and turn it into a Value instance.
    ///
    /// This function can also be handy to use in your own code, particularly
    /// when implementing a builtin function.
    pub fn from(gpa: std.mem.Allocator, value: anytype) !Value {
        _ = gpa;
        const T = @TypeOf(value);
        switch (T) {
            *Root, *const Root => return .{ .root = value },
            *const Root.Site => return .{ .site = value },
            *const Root.Page => return .{ .page = value },
            []const u8, []u8 => return .{ .string = .{ .value = value } },
            i64 => return .{ .int = value },
            else => @compileError("TODO: add support for " ++ @typeName(T)),
        }
    }
};
