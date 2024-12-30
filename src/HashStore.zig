// HashStore.zig
const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const json = std.json;

pub const HashStore = @This();

allocator: Allocator,
map: std.StringHashMap([]const u8),

pub fn init(allocator: Allocator) HashStore {
    return HashStore{
        .allocator = allocator,
        .map = std.StringHashMap([]const u8).init(allocator),
    };
}

pub fn deinit(self: *HashStore) void {
    var it = self.map.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.map.deinit();
}

pub fn load(self: *HashStore, db_path: []const u8) !void {
    const file = fs.cwd().openFile(db_path, .{}) catch {
        // If the file doesn't exist, start with an empty map
        return;
    };
    defer file.close();

    const content = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
    defer self.allocator.free(content);

    var parser = json.Parser.init(self.allocator, false);
    defer parser.deinit();

    var tree = try parser.parse(content);
    defer tree.deinit();

    const root = tree.root;
    var it = root.Object.iterator();
    while (it.next()) |entry| {
        const key = try self.allocator.dupe(u8, entry.key_ptr.*);
        const value = try self.allocator.dupe(u8, entry.value_ptr.String);
        try self.map.put(key, value);
    }
}

pub fn save(self: *HashStore, db_path: []const u8) !void {
    var string = std.ArrayList(u8).init(self.allocator);
    defer string.deinit();

    try string.append('{');

    var it = self.map.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) {
            try string.append(',');
        }
        first = false;

        try std.json.stringify(entry.key_ptr.*, .{}, string.writer());
        try string.append(':');
        try std.json.stringify(entry.value_ptr.*, .{}, string.writer());
    }

    try string.append('}');

    const file = try fs.cwd().createFile(db_path, .{});
    defer file.close();

    try file.writeAll(string.items);
}

pub fn get(self: *const HashStore, key: []const u8) ?[]const u8 {
    return self.map.get(key);
}

pub fn put(self: *HashStore, key: []const u8, value: []const u8) !void {
    const key_owned = try self.allocator.dupe(u8, key);
    const value_owned = try self.allocator.dupe(u8, value);

    if (self.map.fetchPut(key_owned, value_owned)) |old| {
        self.allocator.free(old.key);
        self.allocator.free(old.value);
    }
}
