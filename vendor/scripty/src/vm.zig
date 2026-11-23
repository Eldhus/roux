const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const tracy = @import("tracy");
const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");

const log = std.log.scoped(.scripty);

pub const Diagnostics = struct {
    loc: Tokenizer.Token.Loc,
};

pub const RunError = error{ OutOfMemory, Quota };

fn validateValue(V: type) void {
    const info = @typeInfo(V);
    if (info != .@"union") @compileError("Value must be a tagged union.");
    const u = info.@"union";
    if (u.tag_type == null) @compileError("Value must be a tagged union.");
    if (!@hasField(V, "root"))
        @compileError("Value must have a 'root' field");

    switch (@typeInfo(@FieldType(V, "root"))) {
        .@"struct" => {},
        .pointer => |ptr| switch (@typeInfo(ptr.child)) {
            .@"struct" => {
                if (ptr.size != .one)
                    @compileError("Value.root must be a struct or a pointer to a struct");
            },
            else => @compileError("Value.root must be a struct or a pointer to a struct"),
        },
        else => @compileError("Value.root must be a struct or a pointer to a struct"),
    }

    if (!@hasField(V, "err") or @FieldType(V, "err") != []const u8)
        @compileError("Value must have a 'err: []const u8' field.");
}

pub fn VM(comptime _Value: type) type {
    validateValue(_Value);
    return struct {
        parser: Parser = .{},
        stack: std.MultiArrayList(Result) = .{},
        state: enum { ready, pending } = .ready,

        pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
            self.stack.deinit(gpa);
        }

        pub const Value = _Value;
        pub const RootRef = @FieldType(Value, "root");

        pub const Result = struct {
            debug: if (builtin.mode == .debug)
                enum { unset, set }
            else
                enum { set } = .set,
            value: Value,
            loc: Tokenizer.Token.Loc,
        };

        const unset = if (builtin.mode == .debug) .unset else undefined;

        pub const RunOptions = struct {
            diag: ?*Diagnostics = null,
            quota: usize = 0,
        };

        const ScriptyVM = @This();

        pub fn reset(vm: *ScriptyVM) void {
            vm.stack.shrinkRetainingCapacity(0);
            vm.state = .ready;
            vm.parser = .{};
        }

        pub fn run(
            vm: *ScriptyVM,
            gpa: std.mem.Allocator,
            ctx: RootRef,
            src: []const u8,
            opts: RunOptions,
        ) RunError!Result {
            const res = vm.runInternal(gpa, ctx, src, opts);
            _ = res catch |err| switch (@as(RunError, err)) {
                error.Quota => {},
                // On error make the vm usable again.
                else => vm.reset(),
            };
            return res;
        }

        fn runInternal(
            vm: *ScriptyVM,
            gpa: std.mem.Allocator,
            ctx: RootRef,
            src: []const u8,
            opts: RunOptions,
        ) RunError!Result {
            log.debug("Starting ScriptyVM", .{});
            log.debug("State: {s}", .{@tagName(vm.state)});
            switch (vm.state) {
                .ready => {},
                .pending => {
                    const result = vm.stack.get(vm.stack.len - 1);
                    if (result.value == .err) {
                        vm.reset();
                        return .{ .loc = result.loc, .value = result.value };
                    }
                },
            }

            var quota = opts.quota;
            if (opts.diag != null) @panic("TODO: implement diagnostics");
            if (quota == 1) return error.Quota;

            while (vm.parser.next(src)) |node| : ({
                if (quota == 1) return error.Quota;
                if (quota > 1) quota -= 1;
            }) {
                if (builtin.mode == .debug) {
                    if (vm.stack.len == 0) {
                        log.debug("Stack is empty", .{});
                    } else {
                        const last = vm.stack.get(vm.stack.len - 1);
                        log.debug("Top of stack: ({}) '{s}' {s}", .{
                            vm.stack.len,
                            last.loc.slice(src),
                            if (last.debug == .unset)
                                "<unset>"
                            else
                                @tagName(last.value),
                        });

                        if (@hasField(Value, "page")) {
                            if (last.debug != .unset and last.value == .page) {
                                log.debug("Page: {*}", .{last.value.page});
                            }
                        }
                    }
                }
                log.debug("Now processing node: '{s}' {any}", .{
                    node.loc.slice(src),
                    node,
                });
                switch (node.tag) {
                    .err_invalid_token,
                    .err_unexpected_token,
                    .err_missing_dollar,
                    .err_not_identifier,
                    .err_not_callable,
                    .err_outside_call,
                    .err_truncated,
                    => {
                        vm.reset();
                        return .{
                            .loc = node.loc,
                            .value = .{ .err = node.tag.errorMessage() },
                        };
                    },
                    .string => try vm.stack.append(gpa, .{
                        .debug = .set,
                        .value = Value.fromStringLiteral(try node.loc.unquote(gpa, src)),
                        .loc = node.loc,
                    }),
                    .integer => try vm.stack.append(gpa, .{
                        .debug = .set,
                        .value = Value.fromIntegerLiteral(node.loc.slice(src)),
                        .loc = node.loc,
                    }),
                    .float => try vm.stack.append(gpa, .{
                        .debug = .set,
                        .value = Value.fromFloatLiteral(node.loc.slice(src)),
                        .loc = node.loc,
                    }),
                    .true => try vm.stack.append(gpa, .{
                        .debug = .set,
                        .value = Value.fromBooleanLiteral(true),
                        .loc = node.loc,
                    }),
                    .false => try vm.stack.append(gpa, .{
                        .debug = .set,
                        .value = Value.fromBooleanLiteral(false),
                        .loc = node.loc,
                    }),
                    .call => {
                        // std.debug.assert(vm.stack.len > 0);
                        // @breakpoint();
                        if (vm.stack.len == 0) {
                            vm.reset();
                            return .{
                                .loc = node.loc,
                                .value = .{
                                    .err = "top-level builtin calls are not allowed",
                                },
                            };
                        }
                        std.debug.assert(src[node.loc.end] == '(');
                        try vm.stack.append(gpa, .{
                            .loc = node.loc,
                            .value = undefined,
                            .debug = unset,
                        });
                    },

                    .path => {
                        // log.err("(vm) {any} `{s}`", .{
                        //     node.loc,
                        //     code[node.loc.start..node.loc.end],
                        // });
                        const slice = vm.stack.slice();
                        const stack_locs = slice.items(.loc);
                        const stack_values = slice.items(.value);
                        const global = src[node.loc.start] == '$';
                        const start = node.loc.start + @intFromBool(global);
                        const end = node.loc.end;
                        const path = src[start..end];

                        const old_value = if (global)
                            try Value.from(gpa, ctx)
                        else blk: {
                            if (builtin.mode == .debug) {
                                const stack_debug = slice.items(.debug);

                                std.debug.assert(
                                    stack_debug[stack_debug.len - 1] == .set,
                                );
                            }
                            break :blk stack_values[stack_values.len - 1];
                        };

                        const new_value = try dotPath(gpa, old_value, path);
                        if (new_value == .err) {
                            vm.reset();
                            return .{ .loc = node.loc, .value = new_value };
                        }
                        if (global) {
                            try vm.stack.append(gpa, .{
                                .loc = node.loc,
                                .value = new_value,
                                .debug = .set,
                            });
                        } else {
                            stack_locs[stack_locs.len - 1] = node.loc;
                            stack_values[stack_values.len - 1] = new_value;
                            if (builtin.mode == .debug) {
                                const stack_debug = slice.items(.debug);
                                stack_debug[stack_values.len - 1] = .set;
                            }
                        }
                    },
                    .apply => {
                        const slice = vm.stack.slice();
                        const stack_locs = slice.items(.loc);
                        const stack_values = slice.items(.value);

                        var call_idx = stack_locs.len - 1;
                        const call_loc = while (true) : (call_idx -= 1) {
                            const current = stack_locs[call_idx];
                            if (src[current.end] == '(') {
                                break current;
                            }
                        };

                        const fn_name = src[call_loc.start..call_loc.end];
                        const args = stack_values[call_idx + 1 ..];
                        // // TODO: this is actually a parsing error
                        if (call_idx == 0) {
                            vm.reset();
                            return .{
                                .loc = call_loc,
                                .value = .{
                                    .err = "cannot call a function directly from the global scope",
                                },
                            };
                        }

                        // Remove arguments and fn_name
                        vm.stack.shrinkRetainingCapacity(call_idx);

                        // center on the old value
                        call_idx -= 1;
                        const old_value = stack_values[call_idx];
                        if (builtin.mode == .debug) {
                            const stack_debug = slice.items(.debug);
                            std.debug.assert(
                                stack_debug[call_idx] == .set,
                            );
                        }

                        // disarm location as a call
                        stack_locs[call_idx].start = call_loc.start;
                        stack_locs[call_idx].end = call_loc.end + 1;

                        const new_value = blk: {
                            const apply_zone = tracy.traceNamed(@src(), "apply");
                            defer apply_zone.end();

                            break :blk call(RootRef, Value, gpa, old_value, ctx, fn_name, args) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                            };
                        };

                        if (new_value == .err) {
                            vm.reset();
                            return .{ .loc = call_loc, .value = new_value };
                        }

                        // old value becomes the new result
                        stack_values[call_idx] = new_value;
                        if (builtin.mode == .debug) {
                            const stack_debug = slice.items(.debug);
                            stack_debug[call_idx] = .set;
                        }
                    },
                }
            }

            std.debug.assert(vm.stack.items(.loc).len == 1);
            const result = vm.stack.pop().?;
            std.debug.assert(result.value != .err);
            vm.reset();
            log.debug("returning = '{any}'", .{result});
            return result;
        }

        fn dotPath(gpa: std.mem.Allocator, value: Value, path: []const u8) !Value {
            var it = std.mem.tokenizeScalar(u8, path, '.');
            var val = value;
            while (it.next()) |component| {
                val = try dot(gpa, Value, val, component);
                if (val == .err) break;
            }

            return val;
        }
    };
}

fn call(
    RootRef: type,
    ValueUnion: type,
    gpa: Allocator,
    value: ValueUnion,
    root: RootRef,
    fn_name: []const u8,
    args: []ValueUnion,
) error{OutOfMemory}!ValueUnion {
    const not_found: ValueUnion = .{ .err = "builtin function not found" };
    const no_builtins: ValueUnion = .{ .err = "this type has no builtin functions" };

    switch (value) {
        inline else => |v| {
            const Builtins = switch (@typeInfo(@TypeOf(v))) {
                .@"struct" => @TypeOf(v).Builtins,
                .pointer => |ptr| switch (@typeInfo(ptr.child)) {
                    .@"struct" => ptr.child.Builtins,
                    else => return no_builtins,
                },
                else => return no_builtins,
            };

            inline for (@typeInfo(Builtins).@"struct".decl_names) |decl| {
                if (decl[0] == '_') continue;
                if (std.mem.eql(u8, decl, fn_name)) {
                    return @field(Builtins, decl).call(
                        v,
                        gpa,
                        root,
                        args,
                    );
                }
            }

            if (hasDecl(@TypeOf(v), "fallbackCall")) {
                return v.fallbackCall(
                    gpa,
                    root,
                    fn_name,
                    args,
                );
            }

            return not_found;
        },
    }
}

inline fn hasDecl(T: type, comptime decl: []const u8) bool {
    return switch (@typeInfo(T)) {
        else => false,
        .pointer => |p| return hasDecl(p.child, decl),
        .@"struct", .@"union", .@"enum", .@"opaque" => return @hasDecl(T, decl),
    };
}

fn dot(
    gpa: Allocator,
    ValueUnion: type,
    value: ValueUnion,
    component: []const u8,
) error{OutOfMemory}!ValueUnion {
    const not_found: ValueUnion = .{ .err = "field not found" };
    const no_fields: ValueUnion = .{ .err = "type has no fields" };

    switch (value) {
        inline else => |v| {
            const info, const T = switch (@typeInfo(@TypeOf(v))) {
                .@"struct" => |str| .{ str, @TypeOf(v) },
                .pointer => |ptr| switch (@typeInfo(ptr.child)) {
                    .@"struct" => |str| .{ str, ptr.child },
                    else => return no_fields,
                },
                else => return no_fields,
                // else => @compileError("TODO: add support for " ++ @typeName(@TypeOf(v))),
            };

            if (@hasDecl(T, "dynamicDot") and @typeInfo(@TypeOf(T.dynamicDot)) == .@"fn") {
                return v.dynamicDot(gpa, component);
            }

            if (!@hasDecl(T, "Dot") or !T.Dot) return no_fields;

            inline for (info.field_names, info.field_types) |name, t| {
                if (name[0] == '_') continue;
                if (std.mem.eql(u8, name, component)) {
                    const by_ref = @typeInfo(t) == .@"struct" and
                        @hasDecl(t, "PassByRef") and t.PassByRef;
                    if (by_ref) {
                        return ValueUnion.from(gpa, &@field(v, name));
                    } else {
                        return ValueUnion.from(gpa, @field(v, name));
                    }
                }
            }

            return not_found;
        },
    }
}

pub const TestValue = union(enum) {
    root: *const TestContext,
    site: *const TestContext.Site,
    page: *const TestContext.Page,
    string: String,
    bool: bool,
    int: usize,
    float: f64,
    err: []const u8, // error message
    nil,

    pub const String = struct {
        value: []const u8,

        pub const Builtins = struct {
            pub const len = struct {
                pub fn call(
                    str: String,
                    gpa: std.mem.Allocator,
                    _: *const TestContext,
                    args: []const TestValue,
                ) !TestValue {
                    if (args.len != 0) return .{
                        .err = "'len' wants no arguments",
                    };
                    return TestValue.from(gpa, str.value.len);
                }
            };
            pub const crash = struct {
                pub fn call(
                    _: String,
                    _: std.mem.Allocator,
                    _: *const TestContext,
                    _: []const TestValue,
                ) !TestValue {
                    @panic("crash found!");
                }
            };
        };
    };

    pub fn fromStringLiteral(bytes: []const u8) TestValue {
        return .{ .string = .{ .value = bytes } };
    }

    pub fn fromIntegerLiteral(bytes: []const u8) TestValue {
        _ = bytes;
        return .{ .int = 0 };
    }

    pub fn fromFloatLiteral(bytes: []const u8) TestValue {
        _ = bytes;
        return .{ .float = 0 };
    }

    pub fn fromBooleanLiteral(b: bool) TestValue {
        return .{ .bool = b };
    }

    pub fn from(gpa: std.mem.Allocator, value: anytype) !TestValue {
        _ = gpa;
        const T = @TypeOf(value);
        switch (T) {
            *TestContext, *const TestContext => return .{ .root = value },
            *const TestContext.Site => return .{ .site = value },
            *const TestContext.Page => return .{ .page = value },
            []const u8 => return .{ .string = .{ .value = value } },
            usize => return .{ .int = value },
            else => @compileError("TODO: add support for " ++ @typeName(T)),
        }
    }
};

const TestContext = struct {
    version: []const u8,
    page: Page,
    site: Site,

    pub const Site = struct {
        name: []const u8,

        pub const Dot = true;
        pub const PassByRef = true;
        pub const Builtins = struct {};
    };
    pub const Page = struct {
        title: []const u8,
        content: []const u8,

        pub const Dot = true;
        pub const PassByRef = true;
        pub const Builtins = struct {};
    };

    pub const Dot = true;
    pub const PassByRef = true;
    pub const Builtins = struct {};
};

const test_ctx: TestContext = .{
    .version = "v0",
    .page = .{
        .title = "Home",
        .content = "<p>Welcome!</p>",
    },
    .site = .{
        .name = "Loris Cro's Personal Blog",
    },
};

const TestInterpreter = VM(TestValue);

test "basic" {
    const code = "$page.title";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var t = test_ctx;
    var vm: TestInterpreter = .{};
    const result = try vm.run(arena.allocator(), &t, code, .{});

    const ex: TestInterpreter.Result = .{
        .loc = .{ .start = 0, .end = code.len },
        .value = .{ .string = .{ .value = "Home" } },
    };

    errdefer log.debug("result = `{s}`\n", .{result.value.string.value});

    try std.testing.expectEqualDeep(ex, result);
}

test "builtin" {
    const code = "$page.title.len()";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var t = test_ctx;
    var vm: TestInterpreter = .{};
    const result = try vm.run(arena.allocator(), &t, code, .{});

    const ex: TestInterpreter.Result = .{
        .loc = .{ .start = 12, .end = 16 },
        .value = .{ .int = 4 },
    };

    errdefer log.debug("result = `{s}`\n", .{result.value.string.value});

    try std.testing.expectEqualDeep(ex, result);
}

test "fuzz" {
    // const fuzz_log = try Io.Dir.cwd().createFile(std.testing.io, "fuzz.log", .{ .truncate = false });
    // var file_writer = fuzz_log.writerStreaming(std.testing.io, &.{});
    // try std.testing.fuzz(&file_writer.interface, testOne, .{});
    try std.testing.fuzz({}, testOne, .{});
}

// fn testOne(l: *Io.Writer, smith: *std.testing.Smith) !void {
fn testOne(_: void, smith: *std.testing.Smith) !void {
    var buf: [1024]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];

    // try l.print("[{f}]\n", .{std.zig.fmtString(input)});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var t = test_ctx;
    var vm: TestInterpreter = .{};
    while (true) {
        _ = vm.run(arena.allocator(), &t, input, .{}) catch |err| switch (err) {
            error.OutOfMemory => return,
            error.Quota => unreachable,
        };
        return;
    }
}
