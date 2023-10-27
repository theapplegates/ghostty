const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const fastmem = @import("fastmem.zig");

/// Returns a circular buffer containing type T.
pub fn CircBuf(comptime T: type, comptime default: T) type {
    return struct {
        const Self = @This();

        // Implementation note: there's a lot of unsafe addition of usize
        // here in this implementation that can technically overflow. If someone
        // wants to fix this and make it overflow safe (use subtractions for
        // checks prior to additions) then I welcome it. In reality, we'd
        // have to be a really, really large terminal screen to even worry
        // about this so I'm punting it.

        storage: []T,
        head: usize,
        tail: usize,

        // We could remove this and just use math with head/tail to figure
        // it out, but our usage of circular buffers stores so much data that
        // this minor overhead is not worth optimizing out.
        full: bool,

        pub const Iterator = struct {
            buf: Self,
            idx: usize,
            direction: Direction,

            pub const Direction = enum { forward, reverse };

            pub fn next(self: *Iterator) ?*T {
                if (self.idx >= self.buf.len()) return null;

                // Get our index from the tail
                const tail_idx = switch (self.direction) {
                    .forward => self.idx,
                    .reverse => self.buf.len() - self.idx - 1,
                };

                // Translate the tail index to a storage index
                const storage_idx = (self.buf.tail + tail_idx) % self.buf.capacity();
                self.idx += 1;
                return &self.buf.storage[storage_idx];
            }
        };

        /// Initialize a new circular buffer that can store size elements.
        pub fn init(alloc: Allocator, size: usize) !Self {
            var buf = try alloc.alloc(T, size);
            @memset(buf, default);

            return Self{
                .storage = buf,
                .head = 0,
                .tail = 0,
                .full = false,
            };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            alloc.free(self.storage);
            self.* = undefined;
        }

        /// Append a single value to the buffer. If the buffer is full,
        /// an error will be returned.
        pub fn append(self: *Self, v: T) !void {
            if (self.full) return error.OutOfMemory;
            self.storage[self.head] = v;
            self.head += 1;
            if (self.head >= self.storage.len) self.head = 0;
            self.full = self.head == self.tail;
        }

        /// Clear the buffer.
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.full = false;
        }

        /// Iterate over the circular buffer.
        pub fn iterator(self: Self, direction: Iterator.Direction) Iterator {
            return Iterator{
                .buf = self,
                .idx = 0,
                .direction = direction,
            };
        }

        /// Resize the buffer to the given size (larger or smaller).
        /// If larger, new values will be set to the default value.
        pub fn resize(self: *Self, alloc: Allocator, size: usize) !void {
            // Rotate to zero so it is aligned.
            try self.rotateToZero(alloc);

            // Reallocate, this adds to the end so we're ready to go.
            const prev_len = self.len();
            const prev_cap = self.storage.len;
            self.storage = try alloc.realloc(self.storage, size);

            // If we grew, we need to set our new defaults. We can add it
            // at the end since we rotated to start.
            if (size > prev_cap) {
                @memset(self.storage[prev_cap..], default);

                // Fix up our head/tail
                if (self.full) {
                    self.head = prev_len;
                    self.full = false;
                }
            }
        }

        /// Rotate the data so that it is zero-aligned.
        fn rotateToZero(self: *Self, alloc: Allocator) !void {
            // TODO: this does this in the worst possible way by allocating.
            // rewrite to not allocate, its possible, I'm just lazy right now.

            // If we're already at zero then do nothing.
            if (self.tail == 0) return;

            var buf = try alloc.alloc(T, self.storage.len);
            defer {
                self.head = if (self.full) 0 else self.len();
                self.tail = 0;
                alloc.free(self.storage);
                self.storage = buf;
            }

            if (!self.full and self.head >= self.tail) {
                fastmem.copy(T, buf, self.storage[self.tail..self.head]);
                return;
            }

            const middle = self.storage.len - self.tail;
            fastmem.copy(T, buf, self.storage[self.tail..]);
            fastmem.copy(T, buf[middle..], self.storage[0..self.head]);
        }

        /// Returns if the buffer is currently empty. To check if its
        /// full, just check the "full" attribute.
        pub fn empty(self: Self) bool {
            return !self.full and self.head == self.tail;
        }

        /// Returns the total capacity allocated for this buffer.
        pub fn capacity(self: Self) usize {
            return self.storage.len;
        }

        /// Returns the length in elements that are used.
        pub fn len(self: Self) usize {
            if (self.full) return self.storage.len;
            if (self.head >= self.tail) return self.head - self.tail;
            return self.storage.len - (self.tail - self.head);
        }

        /// Delete the oldest n values from the buffer. If there are less
        /// than n values in the buffer, it'll delete everything.
        pub fn deleteOldest(self: *Self, n: usize) void {
            assert(n <= self.storage.len);

            // Clear the values back to default
            const slices = self.getPtrSlice(0, n);
            inline for (slices) |slice| @memset(slice, default);

            // If we're not full, we can just advance the tail. We know
            // it'll be less than the length because otherwise we'd be full.
            self.tail += @min(self.len(), n);
            if (self.tail >= self.storage.len) self.tail -= self.storage.len;
            self.full = false;
        }

        /// Returns a pointer to the value at offset with the given length,
        /// and considers this full amount of data "written" if it is beyond
        /// the end of our buffer. This never "rotates" the buffer because
        /// the offset can only be within the size of the buffer.
        pub fn getPtrSlice(self: *Self, offset: usize, slice_len: usize) [2][]T {
            // Note: this assertion is very important, it hints the compiler
            // which generates ~10% faster code than without it.
            assert(offset + slice_len <= self.capacity());

            // End offset is the last offset (exclusive) for our slice.
            // We use exclusive because it makes the math easier and it
            // matches Zigs slicing parameterization.
            const end_offset = offset + slice_len;

            // If our slice can't fit it in our length, then we need to advance.
            if (end_offset > self.len()) self.advance(end_offset - self.len());

            // Our start and end indexes into the storage buffer
            const start_idx = self.storageOffset(offset);
            const end_idx = self.storageOffset(end_offset - 1);
            // std.log.warn("A={} B={}", .{ start_idx, end_idx });

            // Optimistically, our data fits in one slice
            if (end_idx >= start_idx) {
                return .{
                    self.storage[start_idx .. end_idx + 1],
                    self.storage[0..0], // So there is an empty slice
                };
            }

            return .{
                self.storage[start_idx..],
                self.storage[0 .. end_idx + 1],
            };
        }

        /// Advances the head/tail so that we can store amount.
        fn advance(self: *Self, amount: usize) void {
            assert(amount <= self.storage.len - self.len());

            // Optimistically add our amount
            self.head += amount;

            // If we exceeded the length of the buffer, wrap around.
            if (self.head >= self.storage.len) self.head = self.head - self.storage.len;

            // If we're full, we have to keep tail lined up.
            if (self.full) self.tail = self.head;

            // We're full if the head reached the tail. The head can never
            // pass the tail because advance asserts amount is only in
            // available space left
            self.full = self.head == self.tail;
        }

        /// For a given offset from zero, this returns the offset in the
        /// storage buffer where this data can be found.
        fn storageOffset(self: Self, offset: usize) usize {
            assert(offset < self.storage.len);

            // This should be subtraction ideally to avoid overflows but
            // it would take a really, really, huge buffer to overflow.
            const fits_offset = self.tail + offset;
            if (fits_offset < self.storage.len) return fits_offset;
            return fits_offset - self.storage.len;
        }
    };
}

test {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 12);
    defer buf.deinit(alloc);

    try testing.expect(buf.empty());
    try testing.expectEqual(@as(usize, 0), buf.len());
}

test "append" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 3);
    defer buf.deinit(alloc);

    try buf.append(1);
    try buf.append(2);
    try buf.append(3);
    try testing.expectError(error.OutOfMemory, buf.append(4));
    buf.deleteOldest(1);
    try buf.append(4);
    try testing.expectError(error.OutOfMemory, buf.append(5));
}

test "forward iterator" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 3);
    defer buf.deinit(alloc);

    // Empty
    {
        var it = buf.iterator(.forward);
        try testing.expect(it.next() == null);
    }

    // Partially full
    try buf.append(1);
    try buf.append(2);
    {
        var it = buf.iterator(.forward);
        try testing.expect(it.next().?.* == 1);
        try testing.expect(it.next().?.* == 2);
        try testing.expect(it.next() == null);
    }

    // Full
    try buf.append(3);
    {
        var it = buf.iterator(.forward);
        try testing.expect(it.next().?.* == 1);
        try testing.expect(it.next().?.* == 2);
        try testing.expect(it.next().?.* == 3);
        try testing.expect(it.next() == null);
    }

    // Delete and add
    buf.deleteOldest(1);
    try buf.append(4);
    {
        var it = buf.iterator(.forward);
        try testing.expect(it.next().?.* == 2);
        try testing.expect(it.next().?.* == 3);
        try testing.expect(it.next().?.* == 4);
        try testing.expect(it.next() == null);
    }
}

test "reverse iterator" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 3);
    defer buf.deinit(alloc);

    // Empty
    {
        var it = buf.iterator(.reverse);
        try testing.expect(it.next() == null);
    }

    // Partially full
    try buf.append(1);
    try buf.append(2);
    {
        var it = buf.iterator(.reverse);
        try testing.expect(it.next().?.* == 2);
        try testing.expect(it.next().?.* == 1);
        try testing.expect(it.next() == null);
    }

    // Full
    try buf.append(3);
    {
        var it = buf.iterator(.reverse);
        try testing.expect(it.next().?.* == 3);
        try testing.expect(it.next().?.* == 2);
        try testing.expect(it.next().?.* == 1);
        try testing.expect(it.next() == null);
    }

    // Delete and add
    buf.deleteOldest(1);
    try buf.append(4);
    {
        var it = buf.iterator(.reverse);
        try testing.expect(it.next().?.* == 4);
        try testing.expect(it.next().?.* == 3);
        try testing.expect(it.next().?.* == 2);
        try testing.expect(it.next() == null);
    }
}

test "getPtrSlice fits" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 12);
    defer buf.deinit(alloc);

    const slices = buf.getPtrSlice(0, 11);
    try testing.expectEqual(@as(usize, 11), slices[0].len);
    try testing.expectEqual(@as(usize, 0), slices[1].len);
    try testing.expectEqual(@as(usize, 11), buf.len());
}

test "getPtrSlice wraps" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 4);
    defer buf.deinit(alloc);

    // Fill the buffer
    _ = buf.getPtrSlice(0, buf.capacity());
    try testing.expect(buf.full);
    try testing.expectEqual(@as(usize, 4), buf.len());

    // Delete
    buf.deleteOldest(2);
    try testing.expect(!buf.full);
    try testing.expectEqual(@as(usize, 2), buf.len());

    // Get a slice that doesn't grow
    {
        const slices = buf.getPtrSlice(0, 2);
        try testing.expectEqual(@as(usize, 2), slices[0].len);
        try testing.expectEqual(@as(usize, 0), slices[1].len);
        try testing.expectEqual(@as(usize, 2), buf.len());
        slices[0][0] = 1;
        slices[0][1] = 2;
    }

    // Get a slice that does grow, and forces wrap
    {
        const slices = buf.getPtrSlice(2, 2);
        try testing.expectEqual(@as(usize, 2), slices[0].len);
        try testing.expectEqual(@as(usize, 0), slices[1].len);
        try testing.expectEqual(@as(usize, 4), buf.len());

        // should be empty
        try testing.expectEqual(@as(u8, 0), slices[0][0]);
        try testing.expectEqual(@as(u8, 0), slices[0][1]);
        slices[0][0] = 3;
        slices[0][1] = 4;
    }

    // Get a slice across boundaries
    {
        const slices = buf.getPtrSlice(0, 4);
        try testing.expectEqual(@as(usize, 2), slices[0].len);
        try testing.expectEqual(@as(usize, 2), slices[1].len);
        try testing.expectEqual(@as(usize, 4), buf.len());

        try testing.expectEqual(@as(u8, 1), slices[0][0]);
        try testing.expectEqual(@as(u8, 2), slices[0][1]);
        try testing.expectEqual(@as(u8, 3), slices[1][0]);
        try testing.expectEqual(@as(u8, 4), slices[1][1]);
    }
}

test "rotateToZero" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 12);
    defer buf.deinit(alloc);

    _ = buf.getPtrSlice(0, 11);
    try buf.rotateToZero(alloc);
}

test "rotateToZero offset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 4);
    defer buf.deinit(alloc);

    // Fill the buffer
    _ = buf.getPtrSlice(0, 3);
    try testing.expectEqual(@as(usize, 3), buf.len());

    // Delete
    buf.deleteOldest(2);
    try testing.expect(!buf.full);
    try testing.expectEqual(@as(usize, 1), buf.len());
    try testing.expect(buf.tail > 0 and buf.head >= buf.tail);

    // Rotate to zero
    try buf.rotateToZero(alloc);
    try testing.expectEqual(@as(usize, 0), buf.tail);
    try testing.expectEqual(@as(usize, 1), buf.head);
}

test "rotateToZero wraps" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 4);
    defer buf.deinit(alloc);

    // Fill the buffer
    _ = buf.getPtrSlice(0, 3);
    try testing.expectEqual(@as(usize, 3), buf.len());
    try testing.expect(buf.tail == 0 and buf.head == 3);

    // Delete all
    buf.deleteOldest(3);
    try testing.expectEqual(@as(usize, 0), buf.len());
    try testing.expect(buf.tail == 3 and buf.head == 3);

    // Refill to force a wrap
    {
        const slices = buf.getPtrSlice(0, 3);
        slices[0][0] = 1;
        slices[1][0] = 2;
        slices[1][1] = 3;
        try testing.expectEqual(@as(usize, 3), buf.len());
        try testing.expect(buf.tail == 3 and buf.head == 2);
    }

    // Rotate to zero
    try buf.rotateToZero(alloc);
    try testing.expectEqual(@as(usize, 0), buf.tail);
    try testing.expectEqual(@as(usize, 3), buf.head);
    {
        const slices = buf.getPtrSlice(0, 3);
        try testing.expectEqual(@as(u8, 1), slices[0][0]);
        try testing.expectEqual(@as(u8, 2), slices[0][1]);
        try testing.expectEqual(@as(u8, 3), slices[0][2]);
    }
}

test "rotateToZero full no wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 4);
    defer buf.deinit(alloc);

    // Fill the buffer
    _ = buf.getPtrSlice(0, 3);

    // Delete all
    buf.deleteOldest(3);

    // Refill to force a wrap
    {
        const slices = buf.getPtrSlice(0, 4);
        try testing.expect(buf.full);
        slices[0][0] = 1;
        slices[1][0] = 2;
        slices[1][1] = 3;
        slices[1][2] = 4;
    }

    // Rotate to zero
    try buf.rotateToZero(alloc);
    try testing.expect(buf.full);
    try testing.expectEqual(@as(usize, 0), buf.tail);
    try testing.expectEqual(@as(usize, 0), buf.head);
    {
        const slices = buf.getPtrSlice(0, 4);
        try testing.expectEqual(@as(u8, 1), slices[0][0]);
        try testing.expectEqual(@as(u8, 2), slices[0][1]);
        try testing.expectEqual(@as(u8, 3), slices[0][2]);
        try testing.expectEqual(@as(u8, 4), slices[0][3]);
    }
}

test "resize grow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 4);
    defer buf.deinit(alloc);

    // Fill and write
    {
        const slices = buf.getPtrSlice(0, 4);
        try testing.expect(buf.full);
        slices[0][0] = 1;
        slices[0][1] = 2;
        slices[0][2] = 3;
        slices[0][3] = 4;
    }

    // Resize
    try buf.resize(alloc, 6);
    try testing.expect(!buf.full);
    try testing.expectEqual(@as(usize, 4), buf.len());
    try testing.expectEqual(@as(usize, 6), buf.capacity());

    {
        const slices = buf.getPtrSlice(0, 4);
        try testing.expectEqual(@as(u8, 1), slices[0][0]);
        try testing.expectEqual(@as(u8, 2), slices[0][1]);
        try testing.expectEqual(@as(u8, 3), slices[0][2]);
        try testing.expectEqual(@as(u8, 4), slices[0][3]);
    }
}

test "resize shrink" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 4);
    defer buf.deinit(alloc);

    // Fill and write
    {
        const slices = buf.getPtrSlice(0, 4);
        try testing.expect(buf.full);
        slices[0][0] = 1;
        slices[0][1] = 2;
        slices[0][2] = 3;
        slices[0][3] = 4;
    }

    // Resize
    try buf.resize(alloc, 3);
    try testing.expect(buf.full);
    try testing.expectEqual(@as(usize, 3), buf.len());
    try testing.expectEqual(@as(usize, 3), buf.capacity());

    {
        const slices = buf.getPtrSlice(0, 3);
        try testing.expectEqual(@as(u8, 1), slices[0][0]);
        try testing.expectEqual(@as(u8, 2), slices[0][1]);
        try testing.expectEqual(@as(u8, 3), slices[0][2]);
    }
}