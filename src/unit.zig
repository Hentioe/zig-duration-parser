//! 本模块集中维护单位优先级、纳秒倍率、后缀匹配及选项查询。
const std = @import("std");
const Options = @import("Options.zig");

// 用相邻单位之间的进率构造倍率，让每个数字都能对应到明确的时间关系。
const nanoseconds_per_nanosecond: u128 = 1;
const nanoseconds_per_microsecond: u128 = 1_000;
const microseconds_per_millisecond: u128 = 1_000;
const milliseconds_per_second: u128 = 1_000;
const seconds_per_minute: u128 = 60;
const minutes_per_hour: u128 = 60;
const hours_per_day: u128 = 24;

// 这些常量在编译期逐级推导，避免维护互不关联的超大倍率数字。
const nanoseconds_per_millisecond = nanoseconds_per_microsecond * microseconds_per_millisecond;
const nanoseconds_per_second = nanoseconds_per_millisecond * milliseconds_per_second;
const nanoseconds_per_minute = nanoseconds_per_second * seconds_per_minute;
const nanoseconds_per_hour = nanoseconds_per_minute * minutes_per_hour;
const nanoseconds_per_day = nanoseconds_per_hour * hours_per_day;

/// 枚举声明顺序就是组合时长从大到小的合法顺序。
pub const Unit = enum {
    /// 天，固定按 24 小时换算，不涉及日历时间。
    d,
    /// 小时。
    h,
    /// 分钟。
    m,
    /// 秒。
    s,
    /// 毫秒。
    ms,
    /// 微秒。
    us,
    /// 纳秒。
    ns,

    /// 返回一个单位对应的纳秒数，所有倍率都能被整数精确表示。
    pub fn nanoseconds(self: Unit) u128 {
        return switch (self) {
            .d => nanoseconds_per_day,
            .h => nanoseconds_per_hour,
            .m => nanoseconds_per_minute,
            .s => nanoseconds_per_second,
            .ms => nanoseconds_per_millisecond,
            .us => nanoseconds_per_microsecond,
            .ns => nanoseconds_per_nanosecond,
        };
    }
};

/// 后缀匹配同时返回长度，调用方据此准确推进输入游标。
pub const Match = struct {
    unit: Unit,
    length: usize,
};

/// 把文本后缀和对应单位放在一起，避免匹配逻辑与换算表分离。
const Suffix = struct {
    text: []const u8,
    unit: Unit,
};

// 长后缀在前，避免 ms 被误认成 m，也避免 us/ns 被误认成 s。
const suffixes = [_]Suffix{
    .{ .text = "ms", .unit = .ms },
    .{ .text = "us", .unit = .us },
    .{ .text = "ns", .unit = .ns },
    .{ .text = "d", .unit = .d },
    .{ .text = "h", .unit = .h },
    .{ .text = "m", .unit = .m },
    .{ .text = "s", .unit = .s },
};

// 编译期保护匹配顺序：未来添加后缀时不能意外破坏最长优先规则。
comptime {
    for (suffixes[0 .. suffixes.len - 1], suffixes[1..]) |left, right| {
        std.debug.assert(left.text.len >= right.text.len);
    }
}

/// 在数字之后的切片中查找第一个合法单位后缀。
pub fn match(input: []const u8) ?Match {
    // 毫秒、微秒、纳秒与单字母单位共享首字母，必须优先匹配完整后缀。
    for (suffixes) |suffix| {
        if (std.mem.startsWith(u8, input, suffix.text)) {
            return .{ .unit = suffix.unit, .length = suffix.text.len };
        }
    }
    return null;
}

/// Options 字段名与枚举标签一一对应，因此无需维护重复的 switch。
pub fn isEnabled(options: Options, unit: Unit) bool {
    // unit 在解析期间才确定，而 @field 的字段名必须编译期已知，因此逐项映射。
    return switch (unit) {
        .d => options.d,
        .h => options.h,
        .m => options.m,
        .s => options.s,
        .ms => options.ms,
        .us => options.us,
        .ns => options.ns,
    };
}
