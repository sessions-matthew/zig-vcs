const std = @import("std");
const Io = std.Io;
const zig_vcs = @import("zig_vcs");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip program name

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(gpa);
    while (args_iter.next()) |arg| {
        try args_list.append(gpa, arg);
    }

    zig_vcs.cli.executeCommandInDir(gpa, io, ".", args_list.items, stdout) catch |err| {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        zig_vcs.cli.printCliError(gpa, err, args_list.items, &stderr_file_writer.interface);
        std.process.exit(1);
    };
}
