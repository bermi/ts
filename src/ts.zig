//! # ts - timestamp input
//!
//! ## Synopsis
//!
//!     ts [-i | -s | -l] [-m] [format]
//!
//! ## Description
//!
//! ts adds a timestamp to the beginning of each line of input.
//!
//! The optional format parameter controls how the timestamp is formatted,
//! as used by L<strftime(3)>. The default format is "%b %d %H:%M:%S". In
//! addition to the regular strftime conversion specifications,
//! "%.S" and "%.s" and "%.T"
//! are like "%S" and "%s" and "%T", but provide subsecond resolution
//! (ie, "30.00001" and "1301682593.00001" and "1:15:30.00001").
//! If the -i or -s switch is passed, ts timestamps incrementally instead. In case
//! of -i, every timestamp will be the time elapsed since the last timestamp. In
//! case of -s, the time elapsed since start of the program is used.
//! The default format changes to "%H:%M:%S", and "%.S" and "%.s" can be used
//! as well.
//! The -m switch makes the system's monotonic clock be used.
//!
//! ## Environment
//!
//! The standard TZ environment variable controls what time zone dates
//! are assumed to be in, if a timezone is not specified as part of the date.
//!

// This is a partial port of git://git.joeyh.name/moreutils
// from perl to zig. This version is missing the -r switch.

const std = @import("std");
const os = std.os;
const mem = std.mem;
const fmt = std.fmt;
const time = std.time;
const io = std.io;
const assert = std.debug.assert;
const c = @cImport(@cInclude("time.h"));

const PREPEND_MAX_LEN = 96;
const LINE_MAX_LEN = (2 * 1024 * 1024) + PREPEND_MAX_LEN;

const USAGE = "usage: ts [-i | -s] [-m] [format]\n";

const stderr = std.io.getStdErr().writer();

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const leaks = gpa.deinit();
        // stderr.print("leaks: {any}\n", .{leaks}) catch {};
        assert(!leaks);
    }

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // skip program name

    var monotonic = false;
    // var incremental = false;
    // var since_start = false;
    var format_slice = std.ArrayList(u8).init(allocator);
    defer format_slice.deinit();

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "-m")) {
            monotonic = true;
        } else if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-")) {
            try stderr.writeAll(USAGE);
            return;
        } else {
            try format_slice.appendSlice(arg);
        }
    }

    const format = try format_slice.toOwnedSliceSentinel(0);
    defer allocator.free(format);

    var options = .{
        .format = if (format.len > 0) format[0..] else "%b %d %H:%M:%S",
        // .incremental = false,
        // .since_start = false,
    };

    // TODO: Keep compat with ts from moreutils
    // if (incremental or since_start) {
    //     format = "%H:%M:%S";
    // }

    var tsPrefixer = TsPrefixer.init(allocator, options) catch |err| {
        try stderr.print("ts: {any}\n", .{err});
        os.exit(1);
    };
    defer tsPrefixer.deinit(allocator);

    try tsPrefixer.prependWithStdin();
    // try tsPrefixer.prependWithReader(std.io.getStdIn().reader(), std.io.getStdOut().writer());
}

pub const TsPrefixerError = error{
    InvalidFormat,
};

const HIGH_RES_TIME_PLACEHOLDER = ".000000";
pub const Formatter = struct {
    format: []const u8,
    // high res positions array. This stores
    // where in the format string the high res
    // timestamp is inserted.
    high_res_offsets: []usize,
    // high res format
    high_res_format: []u8,
    allocator: mem.Allocator,
    uses_high_res: bool = undefined,
    ts: i128 = 0,
    ns: [6]u8 = undefined,
    prefix: []u8 = "",
    tm: c.struct_tm = undefined,

    // We'll use this buffer to combine the timestamp and the line.
    prefix_buf: [PREPEND_MAX_LEN]u8 = [_]u8{0} ** PREPEND_MAX_LEN,

    pub fn init(allocator: mem.Allocator, format: []const u8) !Formatter {
        var high_res_offsets = std.ArrayList(usize).init(allocator);
        defer high_res_offsets.deinit();

        // High res format includes the placeholder for the ns that will be set
        // before passing the format string to c's strftime.
        var high_res_format = std.ArrayList(u8).init(allocator);
        defer high_res_format.deinit();

        var i: usize = 0;
        while (i < format.len) : (i += 1) {
            if (format[i] == '%' and i + 1 < format.len and format[i + 1] == '.') {
                i += 1;
                if (format[i] == '%') {
                    // %% is a literal %
                    try high_res_format.append(format[i]);
                } else if (format[i] == '.') {
                    // %.s is the high res timestamp
                    try high_res_format.appendSlice(format[i - 1 .. i]);
                    try high_res_format.appendSlice(format[i + 1 .. i + 2]);
                    try high_res_format.appendSlice(HIGH_RES_TIME_PLACEHOLDER);
                    try high_res_offsets.append(high_res_format.items.len - HIGH_RES_TIME_PLACEHOLDER.len + 1);
                    i += 1;
                } else {
                    try high_res_format.append(format[i]);
                }
            } else {
                // a is a literal a
                try high_res_format.append(format[i]);
            }
        }

        const uses_high_res: bool = high_res_offsets.items.len > 0;
        // Add sentinel to high_res_format
        try high_res_format.append(0);
        const high_res_format_slice = try high_res_format.toOwnedSlice();

        // Read TZ env var
        c.tzset();
        // To avoid reading /etc/localtime on every call to strftime, we'll
        // save timezone info on the .tm struct which will be passed
        // to localtime_r.
        const ts_s: i64 = @divTrunc(@intCast(i64, time.nanoTimestamp()), time.ns_per_s);
        const tm = c.localtime(&ts_s);

        return Formatter{
            .format = format,
            .allocator = allocator,
            .high_res_offsets = try high_res_offsets.toOwnedSlice(),
            .high_res_format = high_res_format_slice[0 .. high_res_format_slice.len - 1 :0],
            .uses_high_res = uses_high_res,
            .tm = tm.*,
        };
    }

    fn deinit(self: *Formatter) void {
        self.allocator.free(self.high_res_offsets);
        self.allocator.free(self.high_res_format);
    }

    fn setTs(self: *Formatter, ts: i128) !void {
        self.ts = ts;
        if (self.uses_high_res) {
            self.addNsToHighResFormat();
        }
        try self.setPreffix(ts);
    }

    fn addNsToHighResFormat(self: *Formatter) void {
        const ns: u64 = @intCast(u64, @mod(self.ts, 1_000_000_000));
        self.ns[0] = @intCast(u8, ns / 100_000_000) + '0';
        self.ns[1] = @intCast(u8, (ns % 100_000_000) / 10_000_000) + '0';
        self.ns[2] = @intCast(u8, (ns % 10_000_000) / 1_000_000) + '0';
        self.ns[3] = @intCast(u8, (ns % 1_000_000) / 100_000) + '0';
        self.ns[4] = @intCast(u8, (ns % 100_000) / 10_000) + '0';
        self.ns[5] = @intCast(u8, (ns % 10_000) / 1_000) + '0';
        for (self.high_res_offsets) |offset| {
            inline for (self.ns, 0..) |n, i| {
                self.high_res_format[offset + i] = n;
            }
        }
    }

    // sets .prefix using c's strftime.
    fn setPreffix(self: *Formatter, ts: i128) !void {
        // If we are using high res, the format will already
        // include the high res timestamp.
        const format_ptr = @ptrCast([*]const u8, if (self.uses_high_res) self.high_res_format else self.format);
        const ts_s: i64 = @divTrunc(@intCast(i64, ts), time.ns_per_s);
        // Using localtime_r instead of localtime to avoid reading /etc/localtime
        // on every call.
        _ = c.localtime_r(&ts_s, &self.tm);
        const nlen: usize = c.strftime(&self.prefix_buf, PREPEND_MAX_LEN, format_ptr, &self.tm);
        if (nlen == 0) {
            return TsPrefixerError.InvalidFormat;
        }
        self.prefix = self.prefix_buf[0..nlen];
    }
};

pub const Clock = struct {
    monotonic: bool = false,
    simulate: bool = false,
    nsPerTick: i128 = time.us_per_s,
    ts: i128 = 0,
    fn tick(self: *Clock) i128 {
        if (self.simulate) {
            self.ts += self.nsPerTick;
            return self.ts;
        }
        self.ts = time.nanoTimestamp();
        // stderr.print("tick: {d} ", .{self.ts}) catch unreachable;
        return self.ts;
    }
};

pub const TsPrefixer = struct {
    const Options = struct {
        // incremental: bool = false,
        // since_start: bool = false,
        format: []const u8,
    };

    options: Options,
    allocator: mem.Allocator,
    format_ptr: [*]const u8 = undefined,
    formatter: ?Formatter = undefined,
    stdout_fd: os.fd_t = undefined,
    clock: Clock = Clock{ .monotonic = false },

    // We'll use this buffer to combine the timestamp and the line.
    prefix_buf: [PREPEND_MAX_LEN]u8 = [_]u8{0} ** PREPEND_MAX_LEN,
    // We'll use this buffer to combine the timestamp and the line.
    output_buf: [LINE_MAX_LEN]u8 = [_]u8{0} ** LINE_MAX_LEN,

    pub fn init(allocator: mem.Allocator, options: Options) !TsPrefixer {
        var formatter = try Formatter.init(allocator, options.format);

        return TsPrefixer{
            .allocator = allocator,
            .options = options,
            .format_ptr = @ptrCast([*]const u8, options.format),
            .formatter = formatter,
        };
    }

    pub fn deinit(self: *TsPrefixer, allocator: mem.Allocator) void {
        _ = allocator;
        self.formatter.?.deinit();
    }

    fn prepend(self: *TsPrefixer, input: []const u8) ![]const u8 {
        const ts = self.clock.tick();
        try self.formatter.?.setTs(ts);
        // TODO: This create an unnecessary copy of the input, we'll need to directly
        // interact with the output buffer and write the input to it directly.
        return std.fmt.allocPrint(self.allocator, "{s} {s}", .{ self.formatter.?.prefix, input });
    }

    // Copies the timestamp to the write_buffer at the given offset.
    fn timestampBuffer(self: *TsPrefixer, write_buffer: *[]u8, offset: *usize) !void {
        try self.formatter.?.setTs(self.clock.tick());
        try self.bufferedWrite(write_buffer, offset, self.formatter.?.prefix);
        // TODO: pointlessly adding the space to the prefix when it could be
        // baked into the prefix.
        try self.bufferedWrite(write_buffer, offset, " ");
    }

    fn flushBuffer(self: *TsPrefixer, write_buffer: *[]u8, offset: *usize) !void {
        _ = try os.write(self.stdout_fd, write_buffer.*[0..offset.*]);
        offset.* = 0;
    }

    fn bufferedWrite(self: *TsPrefixer, write_buffer: *[]u8, offset: *usize, input: []const u8) !void {
        // Flush the buffer if it's full.
        if (offset.* + input.len >= write_buffer.len - 1) {
            try self.flushBuffer(write_buffer, offset);
        }
        // try self.flushBuffer(write_buffer, offset);
        // Copy the input to the output buffer.
        mem.copy(u8, write_buffer.*[offset.*..], input);
        offset.* += input.len;
    }

    fn prependWithStdin(self: *TsPrefixer) !void {
        const buffer_size = 48 * 1024;
        const read_buffer = try self.allocator.alloc(u8, buffer_size);
        defer self.allocator.free(read_buffer);
        mem.set(u8, read_buffer, 0);

        var write_buffer = try self.allocator.alloc(u8, buffer_size * 2);
        defer self.allocator.free(write_buffer);
        mem.set(u8, write_buffer, 0);

        var stdout_fd = std.io.getStdOut().handle;
        self.stdout_fd = stdout_fd;

        var stdin_fd = std.io.getStdIn().handle;

        var timestamped = false;
        var write_buffer_idx: usize = 0;
        while (true) {
            mem.set(u8, read_buffer, 0);
            const read_bytes = try std.os.read(stdin_fd, read_buffer);
            if (read_bytes == 0) {
                break;
            }
            if (write_buffer_idx > 0) {
                try self.flushBuffer(&write_buffer, &write_buffer_idx);
            }

            if (timestamped == false) {
                timestamped = true;
                try timestampBuffer(self, &write_buffer, &write_buffer_idx);
            }

            var read_buffer_idx: usize = 0;
            var next_nl_offset: usize = 0;
            var print_partial = false;
            line_breaker: while (true) {
                const nl_pos_idx = std.mem.indexOf(u8, read_buffer[read_buffer_idx..read_bytes], "\n");
                // We've got a newline
                if (nl_pos_idx == null) {
                    print_partial = true;
                    break :line_breaker;
                }
                if (timestamped == false) {
                    timestamped = true;
                    try self.timestampBuffer(&write_buffer, &write_buffer_idx);
                }
                // Copy the line to the write buffer.
                next_nl_offset = read_buffer_idx + (nl_pos_idx.? + 1);
                try self.bufferedWrite(&write_buffer, &write_buffer_idx, read_buffer[read_buffer_idx..next_nl_offset]);
                read_buffer_idx = next_nl_offset;
                timestamped = false;
            }
            if (print_partial) {
                if (timestamped == false and read_bytes > read_buffer_idx) {
                    timestamped = true;
                    try self.timestampBuffer(&write_buffer, &write_buffer_idx);
                }
                // No newline found, copy the rest of the buffer to the write buffer.
                try self.bufferedWrite(&write_buffer, &write_buffer_idx, read_buffer[read_buffer_idx..read_bytes]);
            }
            if (write_buffer_idx > 0) {
                try self.flushBuffer(&write_buffer, &write_buffer_idx);
            }
        }
        if (write_buffer_idx > 0) {
            try self.flushBuffer(&write_buffer, &write_buffer_idx);
        }
        os.close(stdin_fd);
    }

    fn prependWithReader(self: *TsPrefixer, reader: anytype, writer: anytype) !void {
        // read each line until \n and prepend the timestamp to it on the writer.
        // const line = try reader.readUntilDelimiter(&self.output_buf, '\n');
        // writer.writeAll(line) catch unreachable;
        while (true) {
            const line = (try reader.readUntilDelimiterOrEof(&self.output_buf, '\n')) orelse break;
            try self.formatter.?.setTs(self.clock.tick());
            writer.writeAll(self.formatter.?.prefix) catch unreachable;
            // TODO: The space should already be part of the prefix.
            writer.writeAll(" ") catch unreachable;
            writer.writeAll(line) catch unreachable;
            writer.writeAll("\n") catch unreachable;
        }
    }
};

test "prependTimestamp" {
    const allocator = std.testing.allocator;
    const ts: i128 = 1664291179_020_990_000;
    var clock = Clock{ .monotonic = false, .simulate = true, .ts = ts };

    var tsPrefixer = try TsPrefixer.init(allocator, .{
        .format = "%Y",
    });
    defer tsPrefixer.deinit(allocator);
    tsPrefixer.clock = clock;

    const input = "foo";
    const result = try tsPrefixer.prepend(input);
    defer allocator.free(result);

    const expected = "2022 foo";
    try std.testing.expectEqualStrings(expected, result);
}

test "Formatter.high_res_format" {
    const format = "% %S %.S %s %.s %T %.T % %%";
    const expected = "% %S %S.000000 %s %s.000000 %T %T.000000 % %%";
    var f = try Formatter.init(std.testing.allocator, format);
    defer f.deinit();
    try std.testing.expectEqualStrings(expected, f.high_res_format);
}

test "Formatter.high_res_format compact" {
    const format = "%.T";
    const expected = "%T.000000";
    var f = try Formatter.init(std.testing.allocator, format);
    defer f.deinit();
    try std.testing.expectEqualStrings(expected, f.high_res_format);
}

// test "Formatter.high_res_offsets" {
//     const offsets = "% %S %.S %s %.s %T %.T % %%";
//     var f = try Formatter.init(std.testing.allocator, offsets);
//     defer f.deinit();
//     try std.testing.expectEqual(.{ 8, 21, 34 }, f.high_res_offsets);
// }

test "setNs adds ns to high res format" {
    const ts: i128 = 1664291179_020_990_000;
    const format = "%Y %.T";
    const expected = "%Y %T.020990";
    var f = try Formatter.init(std.testing.allocator, format);
    defer f.deinit();
    try f.setTs(ts);
    try std.testing.expectEqualStrings(expected, f.high_res_format);
}

test "generates prefix" {
    const ts: i128 = 1664291179_020_990_000;
    const format = "%Y-%m-%d %.T";
    const expected = "2022-09-27 15:06:19.020990";
    var f = try Formatter.init(std.testing.allocator, format);
    defer f.deinit();
    try f.setTs(ts);
    var result = f.prefix[0..];
    try std.testing.expectEqualStrings(expected, result);
}

test "append prefix to buffer on each newline" {
    const format = "%Y %.T";
    const allocator = std.testing.allocator;
    const ts: i128 = 1664291179_020_990_000;
    var clock = Clock{ .monotonic = false, .simulate = true, .ts = ts };

    // Clock{ .monotonic = false },
    var tsPrefixer = try TsPrefixer.init(allocator, .{
        .format = format,
    });
    defer tsPrefixer.deinit(allocator);
    tsPrefixer.clock = clock;

    var input = io.fixedBufferStream("a\nb\nc\nd\n");
    const reader = input.reader();

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    const writer = output.writer();

    try tsPrefixer.prependWithReader(reader, writer);
    const expected =
        \\2022 15:06:19.021990 a
        \\2022 15:06:19.022990 b
        \\2022 15:06:19.023990 c
        \\2022 15:06:19.024990 d
        \\
    ;
    try std.testing.expectEqualStrings(expected, output.items);
}
