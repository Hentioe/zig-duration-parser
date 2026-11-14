//! 展示如何导入库 API，并将常见时长字符串转换成纳秒。
const std = @import("std");
const duration = @import("zig_duration_parser");

/// 逐个解析示例输入，展示解析结果；遇到不合法输入时向调用方返回错误。
pub fn main(_: std.process.Init) !void {
    const samples = [_][]const u8{
        "2d",
        "1h30m45s",
        "5000ms",
        "1.5us",
    };

    for (samples) |input| {
        const nanoseconds = try duration.parse(input, .{});
        std.debug.print("{s} = {d} ns\n", .{ input, nanoseconds });
    }
}
