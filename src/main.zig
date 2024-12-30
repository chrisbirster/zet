const std = @import("std");
const fs = std.fs;
const HashStore = @import("HashStore.zig").HashStore;

const Command = enum { init, new, edit, list, search };

const DEFAULT_TEMPLATE =
    \\---
    \\id: <id>
    \\title: <title>
    \\created: <created>
    \\tags: []
    \\links: [] 
    \\backlinks: []
    \\---
    \\# <title>
    \\
    \\Content goes here.
    \\
;

const Zet = struct {
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    hash_store: HashStore,

    pub fn init(allocator: std.mem.Allocator) !Zet {
        const home = std.posix.getenv("HOME") orelse ".";
        const base_dir = try fs.path.join(allocator, &.{ home, ".zet" });

        return Zet{
            .allocator = allocator,
            .base_dir = base_dir,
            .hash_store = HashStore.init(allocator),
        };
    }

    pub fn deinit(self: *Zet) void {
        self.hash_store.deinit();
        self.allocator.free(self.base_dir);
    }

    pub fn ensureDirectories(self: *Zet) !void {
        // Create base directory
        try fs.cwd().makePath(self.base_dir);

        // Create notes directory
        const notes_path = try fs.path.join(self.allocator, &.{ self.base_dir, "notes" });
        defer self.allocator.free(notes_path);
        try fs.cwd().makePath(notes_path);

        // Create template file if it doesn't exist
        const template_path = try fs.path.join(self.allocator, &.{ self.base_dir, "template.md" });
        defer self.allocator.free(template_path);

        const template_file = fs.createFileAbsolute(template_path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return,
            else => |e| return e,
        };
        defer template_file.close();

        try template_file.writeAll(DEFAULT_TEMPLATE);
    }

    pub fn createNote(self: *Zet, title: []const u8) !void {
        const notes_dir = try fs.path.join(self.allocator, &.{ self.base_dir, "notes" });
        defer self.allocator.free(notes_dir);

        const timestamp = std.time.timestamp();
        const note_name = try std.fmt.allocPrint(self.allocator, "{d}-{s}.md", .{ timestamp, title });
        defer self.allocator.free(note_name);

        const note_path = try fs.path.join(self.allocator, &.{ notes_dir, note_name });
        defer self.allocator.free(note_path);

        const template = try self.getTemplate();
        defer self.allocator.free(template);

        var replacements = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var it = replacements.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.*);
            }
            replacements.deinit();
        }

        // Format the timestamp for different fields
        const id = try std.fmt.allocPrint(self.allocator, "{d}", .{timestamp});
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();

        const created = try std.fmt.allocPrint(self.allocator, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });

        try replacements.put("id", id);
        try replacements.put("title", try self.allocator.dupe(u8, title));
        try replacements.put("created", created);

        const content = try self.replaceTemplateValues(template, &replacements);
        defer self.allocator.free(content);
        // try fs.cwd().writeFile(note_path, content);
        const file = try fs.createFileAbsolute(note_path, .{ .truncate = true });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(content);

        try self.openInEditor(note_path);
    }

    fn getTemplate(self: *Zet) ![]const u8 {
        const template_path = try fs.path.join(self.allocator, &.{ self.base_dir, "template.md" });
        defer self.allocator.free(template_path);
        return fs.cwd().readFileAlloc(self.allocator, template_path, std.math.maxInt(usize));
    }

    fn replaceTemplateValues(self: *Zet, template: []const u8, replacements: *std.StringHashMap([]const u8)) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < template.len) : (i += 1) {
            if (template[i] == '<') {
                const end = std.mem.indexOfPos(u8, template, i, ">") orelse {
                    try result.append(template[i]);
                    continue;
                };
                const key = template[i + 1 .. end];
                if (replacements.get(key)) |value| {
                    try result.appendSlice(value);
                    i = end;
                } else {
                    try result.append(template[i]);
                }
            } else {
                try result.append(template[i]);
            }
        }
        return result.toOwnedSlice();
    }

    fn openInEditor(self: *Zet, path: []const u8) !void {
        const editor = std.posix.getenv("EDITOR") orelse "nvim";
        var child = std.process.Child.init(&.{ editor, path }, self.allocator);
        const term_status = try child.spawnAndWait();
        std.debug.print("Editor terminated with status: {}\n", .{term_status});
    }

    pub fn listNotes(self: *Zet) !void {
        const notes_dir = try fs.path.join(self.allocator, &.{ self.base_dir, "notes" });
        defer self.allocator.free(notes_dir);

        var dir = try fs.openDirAbsolute(notes_dir, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
                std.debug.print("{s}\n", .{entry.name});
            }
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var zet = try Zet.init(allocator);
    defer zet.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.next();

    const cmd = args.next() orelse {
        std.debug.print("Usage: zet <command> [args...]\n", .{});
        std.debug.print("Commands: init, new, edit, list, search\n", .{});
        return;
    };

    if (std.mem.eql(u8, cmd, "init")) {
        try zet.ensureDirectories();
        std.debug.print("Initialized Zettelkasten at {s}\n", .{zet.base_dir});
    } else if (std.mem.eql(u8, cmd, "new")) {
        const title = args.next() orelse {
            std.debug.print("Usage: zet new <title>\n", .{});
            return;
        };
        try zet.createNote(title);
    } else if (std.mem.eql(u8, cmd, "list")) {
        try zet.listNotes();
    } else {
        std.debug.print("Unknown command: {s}\n", .{cmd});
    }
}
