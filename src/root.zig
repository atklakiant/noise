const std = @import("std");

pub const c = @cImport({
    @cInclude("stdbool.h");
    @cInclude("FastNoise/FastNoise_C.h");
});

pub const Noise = struct {
    handle: c.fnNodeHandle,
    seed: i32,

    pub const Error = error{
        InvalidEncodedNodeTree,
    };

    pub fn init(encoded_node_tree: [:0]const u8, seed: i32) Error!Noise {
        const handle = c.fnNewFromEncodedNodeTree(encoded_node_tree.ptr, std.math.maxInt(c_uint));

        if (handle == null) return Error.InvalidEncodedNodeTree;

        return .{
            .handle = handle,
            .seed = seed,
        };
    }

    pub fn deinit(self: *Noise) void {
        c.fnDeleteNodeRef(self.handle);
    }

    pub fn sample(self: Noise, comptime dimensions: usize, position: @Vector(dimensions, f32)) f32 {
        return switch (dimensions) {
            2 => c.fnGenSingle2D(self.handle, position[0], position[1], self.seed),
            3 => c.fnGenSingle3D(self.handle, position[0], position[1], position[2], self.seed),
            4 => c.fnGenSingle4D(self.handle, position[0], position[1], position[2], position[3], self.seed),
            else => @compileError("sample only supports 2, 3, or 4 dimensions"),
        };
    }
};
