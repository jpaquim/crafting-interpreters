const std = @import("std");
const Allocator = std.mem.Allocator;
const memory = @import("./memory.zig");
const FREE_ARRAY = memory.FREE_ARRAY;
const GROW_ARRAY = memory.GROW_ARRAY;
const GROW_CAPACITY = memory.GROW_CAPACITY;
const v = @import("./value.zig");
const Value = v.Value;
const ValueArray = v.ValueArray;
const freeValueArray = v.freeValueArray;
const initValueArray = v.initValueArray;
const writeValueArray = v.writeValueArray;

pub const OpCode = enum(u8) {
    op_constant,
    op_return,
};

pub const Chunk = struct {
    count: usize,
    capacity: usize,
    code: ?[]u8,
    constants: ValueArray,
};

pub fn initChunk(chunk: *Chunk) void {
    chunk.count = 0;
    chunk.capacity = 0;
    chunk.code = null;
    initValueArray(&chunk.constants);
}

pub fn freeChunk(allocator: Allocator, chunk: *Chunk) void {
    FREE_ARRAY(allocator, u8, chunk.code, chunk.capacity);
    freeValueArray(allocator, &chunk.constants);
    initChunk(chunk);
}

pub fn writeChunk(allocator: Allocator, chunk: *Chunk, byte: u8) void {
    if (chunk.capacity < chunk.count + 1) {
        const old_capacity = chunk.capacity;
        chunk.capacity = GROW_CAPACITY(old_capacity);
        chunk.code = GROW_ARRAY(allocator, u8, chunk.code, old_capacity, chunk.capacity);
    }

    chunk.code.?[chunk.count] = byte;
    chunk.count += 1;
}

pub fn addConstant(allocator: Allocator, chunk: *Chunk, value: Value) u8 {
    writeValueArray(allocator, &chunk.constants, value);
    return @intCast(u8, chunk.constants.count - 1);
}
