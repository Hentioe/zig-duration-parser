//! 本模块先把数字切成原始数字片段，再以整数算法换算，避免浮点误差。
const std = @import("std");

pub const Scanned = struct {
    /// 小数点前的数字切片，语法扫描保证它至少包含一位数字。
    int_digits: []const u8,
    /// 小数点后的数字切片；没有小数点时为 null。
    frac_digits: ?[]const u8,
    /// 数字结束位置，也是解析单位后缀的起始位置。
    end: usize,
};

// 只在数字换算时需要单位的纳秒倍率，扫描过程本身与单位无关。
const Unit = @import("unit.zig").Unit;

/// 从指定位置读取一个完整数字，但不消费后缀或解释数值大小。
pub fn scan(input: []const u8, start: usize) error{InvalidNumber}!Scanned {
    // 禁止空整数位能统一拒绝 .5s、符号和段间空白等非数字开头。
    if (start >= input.len or !isDigit(input[start])) return error.InvalidNumber;
    const int_start = start;
    var cursor = start;
    // 先收集整数部分，留下输入切片而不是复制或转换成数值。
    while (cursor < input.len and isDigit(input[cursor])) : (cursor += 1) {}
    const int_digits = input[int_start..cursor];
    var frac_digits: ?[]const u8 = null;
    if (cursor < input.len and input[cursor] == '.') {
        cursor += 1;
        const frac_start = cursor;
        // 小数点必须跟随至少一位数字，且不能再出现第二个小数点。
        while (cursor < input.len and isDigit(input[cursor])) : (cursor += 1) {}
        if (cursor == frac_start or (cursor < input.len and input[cursor] == '.')) {
            return error.InvalidNumber;
        }
        frac_digits = input[frac_start..cursor];
    }
    return .{ .int_digits = int_digits, .frac_digits = frac_digits, .end = cursor };
}

/// 只接受 ASCII 十进制数字，避免其他 Unicode 数字符号进入算术路径。
fn isDigit(char: u8) bool {
    return char >= '0' and char <= '9';
}

/// 将扫描结果换算成纳秒；任何无法精确落到整数纳秒的值都会报错。
pub fn toNanoseconds(scanned: Scanned, unit: Unit) error{ Overflow, PrecisionLoss }!u128 {
    const integer = try accumulate(scanned.int_digits);
    // 整数部分先换算，整数运算的每一步都检测溢出而不允许回绕。
    const whole_ns = std.math.mul(u128, integer, unit.nanoseconds()) catch {
        return error.Overflow;
    };
    // 分数部分独立换算后再相加，确保精度错误不会被截断隐藏。
    const fraction_ns = if (scanned.frac_digits) |digits|
        try fraction(digits, unit.nanoseconds())
    else
        0;
    return std.math.add(u128, whole_ns, fraction_ns) catch error.Overflow;
}

/// 将十进制字符逐位转换为 u128，并在乘十或加数字时报告越界。
fn accumulate(digits: []const u8) error{Overflow}!u128 {
    var value: u128 = 0;
    for (digits) |digit| {
        value = std.math.mul(u128, value, 10) catch return error.Overflow;
        value = std.math.add(u128, value, digit - '0') catch return error.Overflow;
    }
    return value;
}

/// 用分子/分母的整数运算换算小数，避免 0.3 等值被浮点舍入。
fn fraction(digits: []const u8, unit_ns: u128) error{ Overflow, PrecisionLoss }!u128 {
    // 去尾零不会改变分数的值，还能让形如 0.1000 的表示继续保持可接受。
    const significant_digits = trimTrailingZeros(digits);
    if (significant_digits.len == 0) return 0;
    // 超过 38 位有效小数时明确拒绝，避免把实现边界伪装成数值溢出。
    if (significant_digits.len > 38) return error.PrecisionLoss;
    const numerator = try accumulate(significant_digits);
    const denominator = try pow10(significant_digits.len);
    // 乘积最多接近 u128 * 单位倍率，因此先扩成 u256 再判断能否整除。
    const scaled: u256 = std.math.mulWide(u128, numerator, unit_ns);
    // 余数代表不足一纳秒的部分；向下取整会静默改变输入含义。
    if (scaled % denominator != 0) return error.PrecisionLoss;
    return @intCast(scaled / denominator);
}

/// 返回去掉末尾十进制零后的切片，同时保留前导零以维持正确位数。
fn trimTrailingZeros(digits: []const u8) []const u8 {
    var end = digits.len;
    // 末尾零不改变小数值；先去掉它们可避免无意义的超长精度拒绝。
    while (end > 0 and digits[end - 1] == '0') : (end -= 1) {}
    return digits[0..end];
}

/// 通过受检乘法构造 10 的幂，作为小数分母。
fn pow10(exponent: usize) error{Overflow}!u256 {
    var value: u256 = 1;
    for (0..exponent) |_| {
        value = std.math.mul(u256, value, 10) catch return error.Overflow;
    }
    return value;
}

// 这些测试确认扫描只返回切片与边界，不提前解释单位后缀。
test "scans integer and fractional digits" {
    const scanned = try scan("12.34ms", 0);
    try std.testing.expectEqualStrings("12", scanned.int_digits);
    try std.testing.expectEqualStrings("34", scanned.frac_digits.?);
    try std.testing.expectEqual(@as(usize, 5), scanned.end);
}

// 小数点两侧缺少数字或出现多个小数点都属于数字语法错误。
test "rejects malformed numbers" {
    try std.testing.expectError(error.InvalidNumber, scan(".5s", 0));
    try std.testing.expectError(error.InvalidNumber, scan("1.s", 0));
    try std.testing.expectError(error.InvalidNumber, scan("1.2.3s", 0));
}
