//! 本模块按段消费输入，并集中执行选项、单位顺序和总范围校验。
const std = @import("std");
const Options = @import("Options.zig");
const number = @import("number.zig");
const units = @import("unit.zig");

pub const ParseError = error{
    /// 输入为空，没有任何可解析的时长段。
    Empty,
    /// 数字开头或数字内部不符合定义的十进制语法。
    InvalidNumber,
    /// 数字已结束但输入中没有紧随的单位后缀。
    MissingUnit,
    /// 单位位置没有匹配到已支持的后缀。
    UnknownUnit,
    /// 单位已知，但调用方通过 Options 将它关闭。
    DisabledUnit,
    /// 单位重复或顺序不是从大到小。
    InvalidUnitOrder,
    /// 小数部分无法精确换算成整数纳秒。
    PrecisionLoss,
    /// 数字、中间换算、总和或最终 i96 结果超出范围。
    Overflow,
};

/// 一段只有在单位和数字都验证成功后才形成，供主循环累加。
const Segment = struct {
    unit: units.Unit,
    nanoseconds: u128,
};

/// 将一个或多个相邻的“数字 + 单位”段解析为非负整数纳秒。
pub fn parse(input: []const u8, options: Options) ParseError!i96 {
    // 空串与其他语法错误分开报告，方便调用方诊断缺失输入。
    if (input.len == 0) return error.Empty;
    var cursor: usize = 0;
    var total: u128 = 0;
    var previous: ?units.Unit = null;
    while (cursor < input.len) {
        const segment = try parseSegment(input, &cursor, options, previous);
        // 每段先留在无符号宽整数中累加，最后才统一核对 i96 的正数上限。
        total = std.math.add(u128, total, segment.nanoseconds) catch return error.Overflow;
        previous = segment.unit;
    }
    // 只有最终结果要求符合公开返回类型；解析过程中保留更宽的安全累加空间。
    if (total > std.math.maxInt(i96)) return error.Overflow;
    return @intCast(total);
}

/// 解析单段并依设计规定的先后次序报告第一个错误。
fn parseSegment(
    input: []const u8,
    cursor: *usize,
    options: Options,
    previous: ?units.Unit,
) ParseError!Segment {
    // 先扫描数字切片，再判断结束位置是否仍有单位可读。
    const scanned = try number.scan(input, cursor.*);
    if (scanned.end == input.len) return error.MissingUnit;
    // 匹配未知单位先于选项和顺序检查，以保留错误类别的明确性。
    const matched = units.match(input[scanned.end..]) orelse return error.UnknownUnit;
    // 关闭某单位时先报告 DisabledUnit，即使这个单位随后也会违反顺序。
    if (!units.isEnabled(options, matched.unit)) return error.DisabledUnit;
    if (previous) |unit| {
        // 枚举次序代表从大到小，严格递增可同时拒绝逆序和重复单位。
        if (@backingInt(matched.unit) <= @backingInt(unit)) return error.InvalidUnitOrder;
    }
    // 仅在语法、开关和顺序均通过后做可能溢出的数值换算。
    const nanoseconds = try number.toNanoseconds(scanned, matched.unit);
    // 只在完整段成功后推进游标，出错时不留下半消费状态。
    cursor.* = scanned.end + matched.length;
    return .{ .unit = matched.unit, .nanoseconds = nanoseconds };
}

// 基础案例覆盖常用单位、组合段、前导零和允许的跳级。
test "parses basic and combined durations exactly" {
    try expectParse("2d", 172_800_000_000_000);
    try expectParse("1h30m45s", 5_445_000_000_000);
    try expectParse("5000ms", 5_000_000_000);
    try expectParse("1.5us", 1_500);
    try expectParse("0s", 0);
    try expectParse("1d1s", 86_401_000_000_000);
    try expectParse("007s", 7_000_000_000);
}

// 小数测试验证十进制精确换算以及亚纳秒精度拒绝策略。
test "fraction arithmetic is exact and rejects subnanosecond values" {
    try expectParse("0.1s", 100_000_000);
    try expectParse("0.3s", 300_000_000);
    try expectParse("0.000000001s", 1);
    try expectParse("0.5d", 43_200_000_000_000);
    try expectParse("1.0000s", 1_000_000_000);
    try expectError("0.5ns", error.PrecisionLoss);
    try expectError("1.0000000005s", error.PrecisionLoss);
}

// 语法与顺序错误分开断言，确保调用方得到稳定的错误分类。
test "validates unit order, syntax, and missing units" {
    try expectParse("1s1ms", 1_001_000_000);
    try expectError("1ms1s", error.InvalidUnitOrder);
    try expectError("1h1h", error.InvalidUnitOrder);
    try expectError("30m1h", error.InvalidUnitOrder);
    try expectError("", error.Empty);
    try expectError("h", error.InvalidNumber);
    try expectError("-1h", error.InvalidNumber);
    try expectError("1h 30m", error.InvalidNumber);
    try expectError("1.s", error.InvalidNumber);
    try expectError(".5s", error.InvalidNumber);
    try expectError("1..5s", error.InvalidNumber);
    try expectError("1.2.3s", error.InvalidNumber);
    try expectError("1", error.MissingUnit);
    try expectError("1h30", error.MissingUnit);
    try expectError("1x", error.UnknownUnit);
    try expectError("1H", error.UnknownUnit);
    try expectError("1!", error.UnknownUnit);
}

// 每个单位开关独立生效，短单位的字母重叠不能导致连带关闭。
test "options disable each unit independently" {
    try expectErrorWithOptions("1d", error.DisabledUnit, .{ .d = false });
    try expectErrorWithOptions("1h", error.DisabledUnit, .{ .h = false });
    try expectErrorWithOptions("1m", error.DisabledUnit, .{ .m = false });
    try expectErrorWithOptions("1s", error.DisabledUnit, .{ .s = false });
    try expectErrorWithOptions("1ms", error.DisabledUnit, .{ .ms = false });
    try expectErrorWithOptions("1us", error.DisabledUnit, .{ .us = false });
    try expectErrorWithOptions("1ns", error.DisabledUnit, .{ .ns = false });
    try expectParseWithOptions("1ms", 1_000_000, .{ .s = false });
    try expectParseWithOptions("1m30s", 90_000_000_000, .{ .ms = false });
    try expectErrorWithOptions("1d1d", error.DisabledUnit, .{ .d = false });
}

// 最大 i96 值允许通过，超出一纳秒或中间单位范围则必须报溢出。
test "checks u128 arithmetic and the i96 result limit" {
    try expectParse("39614081257132168796771975167ns", std.math.maxInt(i96));
    try expectError("39614081257132168796771975168ns", error.Overflow);
    try expectError("99999999999999999d", error.Overflow);
}

/// 常用选项下的断言封装，避免测试重复展开相同的调用。
fn expectParse(input: []const u8, expected: i96) !void {
    try expectParseWithOptions(input, expected, .{});
}

/// 显式选项版本用于验证单位开关不互相影响。
fn expectParseWithOptions(input: []const u8, expected: i96, options: Options) !void {
    try std.testing.expectEqual(expected, try parse(input, options));
}

/// 默认选项下检查指定错误，以免错误路径被成功结果掩盖。
fn expectError(input: []const u8, expected: anyerror) !void {
    try expectErrorWithOptions(input, expected, .{});
}

/// 显式选项版本让错误测试可确认选项检查的先后行为。
fn expectErrorWithOptions(input: []const u8, expected: anyerror, options: Options) !void {
    try std.testing.expectError(expected, parse(input, options));
}
