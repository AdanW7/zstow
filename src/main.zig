const std = @import("std");
const fs = std.fs;
const process = std.process;
const mem = std.mem;
const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

const Command = enum {
    stow,
    unstow,
    restow,
};

const Config = struct {
    command: Command,
    package_names: ArrayList([]const u8),
    stow_dir: []const u8,
    target_dir: []const u8,
    verbose: bool,
    dry_run: bool,
    ignore_patterns: ArrayList([]const u8),

    fn deinit(self: *Config, allocator: Allocator) void {
        self.package_names.deinit(allocator);
        self.ignore_patterns.deinit(allocator);
    }
};

const Stow = struct {
    allocator: Allocator,
    config: Config,

    const Self = @This();

    pub fn init(allocator: Allocator, config: Config) Stow {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn run(self: *Self) !void {
        if (self.config.verbose) {
            self.printVerboseHeader();
        }

        for (self.config.package_names.items) |package_name| {
            switch (self.config.command) {
                .stow => try self.stowPackage(package_name),
                .unstow => try self.unstowPackage(package_name),
                .restow => {
                    try self.unstowPackage(package_name);
                    try self.stowPackage(package_name);
                },
            }
            std.debug.print("Successfully {s}ed {s}\n", .{ @tagName(self.config.command), package_name });
        }
    }

    fn printVerboseHeader(self: *Stow) void {
        std.debug.print("Command: {s}\n", .{@tagName(self.config.command)});
        std.debug.print("Packages: ", .{});
        for (self.config.package_names.items) |pkg| {
            std.debug.print("{s} ", .{pkg});
        }
        std.debug.print("\n", .{});
        std.debug.print("Stow dir: {s}\n", .{self.config.stow_dir});
        std.debug.print("Target dir: {s}\n", .{self.config.target_dir});
        if (self.config.ignore_patterns.items.len > 0) {
            std.debug.print("Ignore patterns: ", .{});
            for (self.config.ignore_patterns.items) |pattern| {
                std.debug.print("{s} ", .{pattern});
            }
            std.debug.print("\n", .{});
        }
    }

    fn stowPackage(self: *Stow, package_name: []const u8) !void {
        const package_path = try fs.path.join(self.allocator, &.{ self.config.stow_dir, package_name });
        defer self.allocator.free(package_path);

        var package_dir = try fs.cwd().openDir(package_path, .{ .iterate = true });
        defer package_dir.close();

        try self.stowDirectory(package_dir, package_path, self.config.target_dir, "");
    }

    fn stowDirectory(
        self: *Stow,
        source_dir: fs.Dir,
        source_path: []const u8,
        target_base: []const u8,
        rel_path: []const u8,
    ) !void {
        var iter = source_dir.iterate();
        while (try iter.next()) |entry| {
            // check if file should be ignored
            if (self.shouldIgnore(entry.name)) {
                if (self.config.verbose) std.debug.print("Ignoring: {s}\n", .{entry.name});
                continue;
            }

            const source_rel = if (rel_path.len > 0)
                try fs.path.join(self.allocator, &.{ rel_path, entry.name })
            else
                try self.allocator.dupe(u8, entry.name);
            defer self.allocator.free(source_rel);

            const target_path = try fs.path.join(self.allocator, &.{ target_base, source_rel });
            defer self.allocator.free(target_path);

            const full_source = try fs.path.join(self.allocator, &.{ source_path, source_rel });
            defer self.allocator.free(full_source);

            switch (entry.kind) {
                .directory => {
                    // check if target exists
                    var existing_dir = fs.cwd().openDir(target_path, .{}) catch |err| {
                        if (err == error.FileNotFound) {
                            // target doesn't exist, create directory and recurse
                            if (self.config.verbose) std.debug.print("mkdir: {s}\n", .{target_path});
                            if (!self.config.dry_run) {
                                try fs.cwd().makePath(target_path);
                            }
                            var sub_source = try source_dir.openDir(entry.name, .{ .iterate = true });
                            defer sub_source.close();
                            try self.stowDirectory(sub_source, source_path, target_base, source_rel);
                            continue;
                        }
                        return err;
                    };
                    existing_dir.close();
                    // target exists, recurse into it
                    var sub_source = try source_dir.openDir(entry.name, .{ .iterate = true });
                    defer sub_source.close();
                    try self.stowDirectory(sub_source, source_path, target_base, source_rel);
                },
                .file, .sym_link => {
                    try self.createSymlink(full_source, target_path);
                },
                else => {},
            }
        }
    }

    fn createSymlink(self: *Stow, full_source: []const u8, target_path: []const u8) !void {
        const abs_source = try fs.cwd().realpathAlloc(self.allocator, full_source);
        defer self.allocator.free(abs_source);

        if (self.config.verbose) std.debug.print("link: {s} -> {s}\n", .{ target_path, abs_source });

        if (!self.config.dry_run) {
            // check if target already exists
            var link_buffer: [4096]u8 = undefined;
            if (fs.cwd().readLink(target_path, &link_buffer)) |existing| {
                if (mem.eql(u8, existing, abs_source)) {
                    // already points to the right place
                    return;
                }
                std.debug.print("Warning: {s} already exists and points elsewhere\n", .{target_path});
                return;
            } else |_| {
                // doesn't exist or not a symlink, try to create
                fs.cwd().symLink(abs_source, target_path, .{}) catch |err| {
                    if (err == error.PathAlreadyExists) {
                        std.debug.print("Warning: {s} already exists\n", .{target_path});
                        return;
                    }
                    return err;
                };
            }
        }
    }

    fn unstowPackage(self: *Stow, package_name: []const u8) !void {
        const package_path = try fs.path.join(self.allocator, &.{ self.config.stow_dir, package_name });
        defer self.allocator.free(package_path);

        var package_dir = try fs.cwd().openDir(package_path, .{ .iterate = true });
        defer package_dir.close();

        try self.unstowDirectory(package_dir, package_path, self.config.target_dir, "");
    }

    fn unstowDirectory(
        self: *Stow,
        source_dir: fs.Dir,
        source_path: []const u8,
        target_base: []const u8,
        rel_path: []const u8,
    ) !void {
        var iter = source_dir.iterate();
        while (try iter.next()) |entry| {
            // check if file should be ignored
            if (self.shouldIgnore(entry.name)) {
                if (self.config.verbose) std.debug.print("Ignoring: {s}\n", .{entry.name});
                continue;
            }

            const source_rel = if (rel_path.len > 0)
                try fs.path.join(self.allocator, &.{ rel_path, entry.name })
            else
                try self.allocator.dupe(u8, entry.name);
            defer self.allocator.free(source_rel);

            const target_path = try fs.path.join(self.allocator, &.{ target_base, source_rel });
            defer self.allocator.free(target_path);

            const full_source = try fs.path.join(self.allocator, &.{ source_path, source_rel });
            defer self.allocator.free(full_source);

            switch (entry.kind) {
                .directory => {
                    var sub_source = try source_dir.openDir(entry.name, .{ .iterate = true });
                    defer sub_source.close();
                    try self.unstowDirectory(sub_source, source_path, target_base, source_rel);

                    // try to remove directory if empty
                    if (!self.config.dry_run) {
                        fs.cwd().deleteDir(target_path) catch |err| {
                            if (err != error.DirNotEmpty and err != error.FileNotFound) {
                                if (self.config.verbose) {
                                    std.debug.print("Could not remove directory {s}: {}\n", .{ target_path, err });
                                }
                            }
                        };
                    }
                },
                .file, .sym_link => {
                    try self.removeSymlink(full_source, target_path);
                },
                else => {},
            }
        }
    }

    fn removeSymlink(self: *Stow, full_source: []const u8, target_path: []const u8) !void {
        const abs_source = try fs.cwd().realpathAlloc(self.allocator, full_source);
        defer self.allocator.free(abs_source);

        // check if symlink points to our package
        var link_buffer: [4096]u8 = undefined;
        if (fs.cwd().readLink(target_path, &link_buffer)) |existing| {
            if (mem.eql(u8, existing, abs_source)) {
                if (self.config.verbose) std.debug.print("unlink: {s}\n", .{target_path});
                if (!self.config.dry_run) {
                    try fs.cwd().deleteFile(target_path);
                }
            }
        } else |_| {
            // not a symlink or doesn't exist
        }
    }

    fn shouldIgnore(self: *Stow, filename: []const u8) bool {
        for (self.config.ignore_patterns.items) |pattern| {
            if (matchesPattern(filename, pattern)) {
                return true;
            }
        }
        return false;
    }
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try process.argsWithAllocator(allocator);
    defer args.deinit();

    var config = parseArgsIterator(allocator, &args) catch {
        printUsage();
        return;
    };
    defer config.deinit(allocator);

    var stow = Stow.init(allocator, config);
    try stow.run();
}

fn parseArgsIterator(allocator: Allocator, args: *process.ArgIterator) !Config {
    var config = Config{
        .command = .stow,
        .package_names = ArrayList([]const u8).empty,
        .stow_dir = ".",
        .target_dir = "..",
        .verbose = false,
        .dry_run = false,
        .ignore_patterns = ArrayList([]const u8).empty,
    };
    errdefer config.deinit(allocator);

    // Skip program name
    _ = args.skip();

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "-D") or mem.eql(u8, arg, "--delete")) {
            config.command = .unstow;
        } else if (mem.eql(u8, arg, "-R") or mem.eql(u8, arg, "--restow")) {
            config.command = .restow;
        } else if (mem.eql(u8, arg, "-S") or mem.eql(u8, arg, "--stow")) {
            config.command = .stow;
        } else if (mem.eql(u8, arg, "-v") or mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else if (mem.eql(u8, arg, "-n") or mem.eql(u8, arg, "--no") or mem.eql(u8, arg, "--simulate") or mem.eql(u8, arg, "--dry-run")) {
            config.dry_run = true;
        } else if (mem.eql(u8, arg, "-d") or mem.eql(u8, arg, "--dir")) {
            const next_arg = args.next() orelse return error.InvalidArgs;
            config.stow_dir = try allocator.dupe(u8, next_arg);
        } else if (mem.eql(u8, arg, "-t") or mem.eql(u8, arg, "--target")) {
            const next_arg = args.next() orelse return error.InvalidArgs;
            config.target_dir = try allocator.dupe(u8, next_arg);
        } else if (mem.eql(u8, arg, "--ignore")) {
            const next_arg = args.next() orelse return error.InvalidArgs;
            try config.ignore_patterns.append(allocator, try allocator.dupe(u8, next_arg));
        } else if (mem.startsWith(u8, arg, "--ignore=")) {
            const pattern = arg[9..];
            try config.ignore_patterns.append(allocator, try allocator.dupe(u8, pattern));
        } else if (mem.eql(u8, arg, "-V") or mem.eql(u8, arg, "--version")) {
            printVersion();
            return error.ExitSuccess;
        } else if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            return error.InvalidArgs;
        } else if (mem.startsWith(u8, arg, "-") and arg.len > 1 and arg[1] != '-') {
            // Handle combined short flags like -nv, -Dv, -Rv
            for (arg[1..]) |flag_char| {
                switch (flag_char) {
                    'D' => config.command = .unstow,
                    'R' => config.command = .restow,
                    'S' => config.command = .stow,
                    'v' => config.verbose = true,
                    'n' => config.dry_run = true,
                    'V' => {
                        printVersion();
                        return error.ExitSuccess;
                    },
                    'h' => return error.InvalidArgs,
                    else => {
                        std.debug.print("Unknown option: -{c}\n", .{flag_char});
                        return error.InvalidArgs;
                    },
                }
            }
        } else if (!mem.startsWith(u8, arg, "-")) {
            // Assume it's a package name
            try config.package_names.append(allocator, try allocator.dupe(u8, arg));
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.InvalidArgs;
        }
    }

    if (config.package_names.items.len == 0) return error.InvalidArgs;
    return config;
}

fn printVersion() void {
    const version =
        \\zstow (Cross-platform Stow) version 0.0.1
        \\License: MIT
        \\
        \\Written in Zig. A fast, cross-platform alternative to GNU Stow.
        \\
    ;
    std.debug.print("{s}", .{version});
}

fn printUsage() void {
    const usage =
        \\zstow - Cross-platform symlink farm manager
        \\
        \\USAGE:
        \\    zstow [OPTIONS] PACKAGE [PACKAGE ...]
        \\
        \\OPTIONS:
        \\    -S, --stow      Stow the package (default)
        \\    -D, --delete    Unstow (delete) the package
        \\    -R, --restow    Restow (delete then stow again)
        \\    -d, --dir DIR   Set stow directory (default: current directory)
        \\    -t, --target DIR Set target directory (default: parent of stow dir)
        \\    --ignore REGEX  Ignore files matching this pattern (can be used multiple times)
        \\    -v, --verbose   Verbose output
        \\    -n, --simulate  Don't actually create/delete links (dry-run)
        \\    -V, --version   Show version information
        \\    -h, --help      Show this help
        \\
        \\Short flags can be combined: -nv, -Dv, -Rv, etc.
        \\Flags that take arguments (-d, -t) cannot be combined.
        \\
        \\EXAMPLES:
        \\    zstow vim               # Stow vim package to parent directory
        \\    zstow vim bash git      # Stow multiple packages at once
        \\    zstow -D vim            # Unstow vim package
        \\    zstow -nv vim           # Dry-run with verbose output
        \\    zstow -D -t ~ -d ~/dotfiles vim  # Unstow from home directory
        \\    zstow --ignore '\.git' --ignore 'README\.md' vim  # Ignore certain files
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn matchesPattern(text: []const u8, pattern: []const u8) bool {
    // Simple pattern matching implementation

    if (mem.eql(u8, text, pattern)) {
        return true;
    }

    var unescaped_pattern = std.ArrayList(u8).empty;
    defer unescaped_pattern.deinit(std.heap.page_allocator);

    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1;
            unescaped_pattern.append(std.heap.page_allocator, pattern[i]) catch return false;
        } else {
            unescaped_pattern.append(std.heap.page_allocator, pattern[i]) catch return false;
        }
    }

    const clean_pattern = unescaped_pattern.items;

    // match after unescaping
    if (mem.eql(u8, text, clean_pattern)) {
        return true;
    }

    // Ends with pattern
    if (clean_pattern.len > 0 and clean_pattern[0] == '*') {
        const suffix = clean_pattern[1..];
        if (text.len >= suffix.len) {
            if (mem.eql(u8, text[text.len - suffix.len ..], suffix)) {
                return true;
            }
        }
    }

    // Starts with pattern 
    if (clean_pattern.len > 0 and clean_pattern[clean_pattern.len - 1] == '*') {
        const prefix = clean_pattern[0 .. clean_pattern.len - 1];
        if (mem.startsWith(u8, text, prefix)) {
            return true;
        }
    }

    // Contains pattern 
    if (clean_pattern.len > 1 and clean_pattern[0] == '*' and clean_pattern[clean_pattern.len - 1] == '*') {
        const substr = clean_pattern[1 .. clean_pattern.len - 1];
        if (mem.indexOf(u8, text, substr) != null) {
            return true;
        }
    }

    return false;
}
