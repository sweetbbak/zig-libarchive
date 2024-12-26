//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const fs = std.fs;
const fmt = std.fmt;
const print = std.debug.print;
const string = []const u8;

const arc = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

const AE_IFDIR: c_int = 40000;
const AE_IFREG: c_int = 100000;

pub fn add_to_archive(
    allocator: Allocator,
    archive: *arc.archive,
    path: string,
    base_path: string,
) !void {
    const stat = try std.fs.cwd().statFile(path);
    const entry: *arc.archive_entry = arc.archive_entry_new() orelse unreachable;

    const pathname: [:0]const u8 = try allocator.dupeZ(u8, path);
    defer allocator.free(pathname);

    arc.archive_entry_set_pathname(entry, pathname);
    arc.archive_entry_set_size(entry, @intCast(stat.size));

    const m: c_uint = if (stat.kind == .directory) AE_IFDIR else AE_IFREG;
    arc.archive_entry_set_filetype(entry, m);
    arc.archive_entry_set_perm(entry, @intCast(stat.mode));

    // Write entry header to archive
    if (arc.archive_write_header(archive, entry) != arc.ARCHIVE_OK) {
        print("Error writing header: {s}\n", .{arc.archive_error_string(archive)});
        arc.archive_entry_free(entry);
        return error.ArchiveWriteError;
    }

    // Write file content to archive (only for regular files)
    if (stat.kind == .file) {
        const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch {
            print("Error: Unable to open {s}\n", .{path});
            arc.archive_entry_free(entry);
            return error.FileError;
        };

        var reader = file.reader();
        defer file.close();

        std.debug.print("adding file: {s}\n", .{path});

        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = try reader.read(&buffer);
            // std.debug.print("buffer: {s}\n", .{buffer});

            if (n <= 0) {
                break;
            }

            if (arc.archive_write_data(archive, &buffer, n) < 0) {
                print("Error writing file data: {s}\n", .{arc.archive_error_string(archive)});
                arc.archive_entry_free(entry);
                return error.FileRead;
            }
        }
    }

    arc.archive_entry_free(entry);

    // Recurse into directories
    if (stat.kind == .directory) {
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |ent| {
            if (mem.eql(u8, ent.name, ".") or mem.eql(u8, ent.name, ".")) {
                continue;
            }

            std.debug.print("adding {s}\n", .{ent.name});

            // var child_path: [1024]u8 = undefined;
            const child_path = try std.fs.path.join(allocator, &.{
                path,
                ent.name,
            });
            defer allocator.free(child_path);

            add_to_archive(allocator, archive, child_path, base_path) catch |err| {
                print("error: {s}\n", .{@errorName(err)});
                return error.RecursiveError;
            };
        }
    }

    return;
}

const Archive = extern struct {};

pub fn compress_dir(
    allocator: Allocator,
    archive_name: string,
    dir_path: string,
) !void {
    // struct archive *archive
    const archive: *arc.archive = arc.archive_write_new() orelse unreachable;
    _ = arc.archive_write_set_format_7zip(archive);
    // arc.archive_write_set_options(archive, "compression=deflate");

    if (arc.archive_write_open_filename(archive, @ptrCast(archive_name)) != arc.ARCHIVE_OK) {
        _ = arc.archive_write_free(archive);
        return error.ArchiveWriteError;
    }

    // add the directory and its contents to the archive
    add_to_archive(allocator, archive, dir_path, dir_path) catch |err| {
        print("error: {s}\n", .{@errorName(err)});
        _ = arc.archive_write_close(archive);
        _ = arc.archive_write_free(archive);
        return error.AddToArchive;
    };

    // finalize and free resources
    _ = arc.archive_write_close(archive);
    _ = arc.archive_write_free(archive);
    return;
}

pub fn example() !void {
    var _dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer _dir.close();
    var it = _dir.iterate();
    while (try it.next()) |ent| {
        if (mem.eql(u8, ent.name, ".") or mem.eql(u8, ent.name, ".")) {
            continue;
        }
        std.debug.print("{s}\n", .{ent.name});
    }

    const dir = "./src";
    const archive = "./src.7z";

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    try compress_dir(allocator, archive, dir);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var dir: []const u8 = undefined;
    var archive: []const u8 = undefined;

    if (args.len < 2) {
        print("usage: {s} <dir> <output.7z>\n", .{std.fs.path.basename(args[0])});
        std.os.linux.exit(0);
    } else {
        dir = args[1];
    }

    if (args.len < 3) {
        const bname = try allocator.dupe(u8, std.fs.path.basename(dir));
        for (bname) |*e| {
            if (e.* == ' ')
                e.* = '_';
            e.* = std.ascii.toLower(e.*);
        }

        archive = try std.fmt.allocPrint(allocator, "{s}.7z", .{bname});
    } else {
        archive = args[2];
    }

    try compress_dir(allocator, archive, dir);
}
