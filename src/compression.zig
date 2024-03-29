const types = @import("types.zig");
const Node = types.Node;
const NodeType = types.NodeType;
const util = @import("util.zig");
const std = @import("std");
const fs = std.fs;
const log = std.log;
const Allocator = std.mem.Allocator;
const PriorityQueue = std.PriorityQueue(Node, void, lessThan);
const ArrayList = std.ArrayList;
const BitPair = std.AutoHashMap(u8, []u1);

pub fn compressDir(allocator: Allocator, dir_name: []const u8, out_file: *fs.File) !void {
    var writer = out_file.writer();
    try out_file.writeAll(dir_name);
    try writer.writeByte(0);
    const dir = try fs.cwd().openDir(dir_name, .{});
    var iter = (try dir.openIterableDir(".", .{})).iterate();
    const num_files_offset = try out_file.getPos();
    try out_file.seekBy(@sizeOf(u32));
    var num_files: u32 = 0;
    while (try iter.next()) |e| : (num_files += 1) {
        log.info("Compressing {s}", .{e.name});
        var file = try dir.openFile(e.name, .{});
        defer file.close();
        try compressFile(allocator, e.name, file, out_file, &writer);
    }
    try out_file.seekTo(num_files_offset);
    try writer.writeIntNative(u32, num_files);
    log.info("Compressed {} files", .{num_files});
}

fn lessThan(context: void, a: Node, b: Node) std.math.Order {
    _ = context;
    return std.math.order(a.frequency, b.frequency);
}

fn compressFile(allocator: Allocator, filename: []const u8, file: fs.File, out_file: *fs.File, writer: *fs.File.Writer) !void {
    _ = out_file;
    try writer.writeAll(filename);
    try writer.writeByte(0);
    var pq = PriorityQueue.init(allocator, {});
    defer pq.deinit();
    try pq.add(.{ .node_type = NodeType.PSEUDO_NODE, .left = null, .right = null, .frequency = 0, .char = 0 });
    try readFile(allocator, file, &pq);
    var root = try genTree(allocator, &pq);
    defer util.freeTree(allocator, root);
    var pseudo_bits: []u1 = undefined;
    var bitpair = try genBitPair(allocator, root, &pseudo_bits);
    defer allocator.free(pseudo_bits);
    defer {
        freeBitPair(allocator, bitpair);
        bitpair.deinit();
    }
    try serializeTree(root, writer);
    try file.seekTo(0);
    try serializeFile(allocator, bitpair, file, writer, pseudo_bits);
}

fn readFile(allocator: Allocator, file: fs.File, pq: *PriorityQueue) !void {
    var buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(buffer);
    var l: usize = try file.readAll(buffer);
    var chars = std.AutoHashMap(u8, usize).init(allocator);
    defer chars.deinit();
    while (l > 0) : (l = try file.readAll(buffer)) {
        for (buffer[0..l]) |c| {
            const v = try chars.getOrPut(c);
            if (v.found_existing) {
                v.value_ptr.* += 1;
            } else {
                v.value_ptr.* = 1;
            }
        }
    }
    var iter = chars.keyIterator();
    while (iter.next()) |c| {
        try pq.add(.{ .node_type = NodeType.LEAF_NODE, .frequency = chars.get(c.*).?, .left = null, .right = null, .char = c.* });
    }
}

fn genTree(allocator: Allocator, pq: *PriorityQueue) !*Node {
    while (pq.len > 1) {
        var a = try allocator.create(Node);
        a.* = pq.remove();
        var b = try allocator.create(Node);
        b.* = pq.remove();
        try pq.add(.{ .node_type = NodeType.INTERNAL_NODE, .frequency = a.frequency + b.frequency, .left = a, .right = b, .char = 0 });
    }
    const root = try allocator.create(Node);
    root.* = pq.remove();
    return root;
}

fn genBitPair(allocator: Allocator, root: *Node, pseudo_bits: *[]u1) !BitPair {
    var cur_bits = ArrayList(u1).init(allocator);
    defer cur_bits.deinit();
    var bitpair = BitPair.init(allocator);
    try genBitPairInner(allocator, root, &cur_bits, pseudo_bits, &bitpair);
    return bitpair;
}

fn genBitPairInner(allocator: Allocator, node: *Node, cur_bits: *ArrayList(u1), pseudo_bits: *[]u1, bitpair: *BitPair) !void {
    switch (node.node_type) {
        NodeType.INTERNAL_NODE => {
            var a = try cur_bits.clone();
            defer a.deinit();
            try a.append(0);
            try genBitPairInner(allocator, node.left.?, &a, pseudo_bits, bitpair);
            var b = try cur_bits.clone();
            defer b.deinit();
            try b.append(1);
            try genBitPairInner(allocator, node.right.?, &b, pseudo_bits, bitpair);
        },
        NodeType.PSEUDO_NODE => {
            pseudo_bits.* = try allocator.alloc(u1, cur_bits.items.len);
            std.mem.copy(u1, pseudo_bits.*, cur_bits.items);
        },
        NodeType.LEAF_NODE => {
            var items = try allocator.alloc(u1, cur_bits.items.len);
            std.mem.copy(u1, items, cur_bits.items);
            try bitpair.put(node.char, items);
        },
    }
}

fn freeBitPair(allocator: Allocator, bitpair: BitPair) void {
    var iter = bitpair.valueIterator();
    while (iter.next()) |v| {
        allocator.free(v.*);
    }
}

fn serializeTree(root: *Node, writer: *fs.File.Writer) !void {
    try writer.writeByte(@intFromEnum(root.node_type));
    switch (root.node_type) {
        .INTERNAL_NODE => {
            try serializeTree(root.left.?, writer);
            try serializeTree(root.right.?, writer);
        },
        .LEAF_NODE => try writer.writeByte(root.char),
        else => {},
    }
}

fn serializeFile(allocator: Allocator, bitpair: BitPair, in_file: fs.File, writer: *fs.File.Writer, pseudo_bits: []u1) !void {
    var buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(buffer);
    var byte: u8 = 0;
    var bit_idx: u4 = 0;
    var l: usize = try in_file.readAll(buffer);
    while (l > 0) : (l = try in_file.readAll(buffer)) {
        for (buffer[0..l]) |c| {
            for (bitpair.get(c).?) |b|
                try writeBit(&byte, &bit_idx, b, writer);
        }
    }
    for (pseudo_bits) |b|
        try writeBit(&byte, &bit_idx, b, writer);
}

fn writeBit(byte: *u8, bit_idx: *u4, bit: u1, writer: *fs.File.Writer) !void {
    if (bit == 1)
        byte.* |= std.math.shl(u8, 1, bit_idx.*);
    bit_idx.* += 1;
    if (bit_idx.* == 8) {
        try writer.writeByte(byte.*);
        byte.* = 0;
        bit_idx.* = 0;
    }
}
