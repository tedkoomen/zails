/// ClickHouse field type mappings
/// Maps Zig types to ClickHouse column types

const std = @import("std");

/// ClickHouse column types
pub const ClickHouseType = enum {
    // Integers
    UInt8,
    UInt16,
    UInt32,
    UInt64,
    Int8,
    Int16,
    Int32,
    Int64,

    // Floating point
    Float32,
    Float64,

    // String types
    String,
    FixedString, // FixedString(N)

    // Date/Time
    Date,
    DateTime,
    DateTime64, // DateTime64(precision)

    // Special types
    UUID,
    IPv4,
    IPv6,

    // Composite types
    Array, // Array(T)
    LowCardinality, // LowCardinality(T)
    Nullable, // Nullable(T)

    pub fn toString(self: ClickHouseType) []const u8 {
        return switch (self) {
            .UInt8 => "UInt8",
            .UInt16 => "UInt16",
            .UInt32 => "UInt32",
            .UInt64 => "UInt64",
            .Int8 => "Int8",
            .Int16 => "Int16",
            .Int32 => "Int32",
            .Int64 => "Int64",
            .Float32 => "Float32",
            .Float64 => "Float64",
            .String => "String",
            .FixedString => "FixedString",
            .Date => "Date",
            .DateTime => "DateTime",
            .DateTime64 => "DateTime64",
            .UUID => "UUID",
            .IPv4 => "IPv4",
            .IPv6 => "IPv6",
            .Array => "Array",
            .LowCardinality => "LowCardinality",
            .Nullable => "Nullable",
        };
    }
};

/// Field definition for model
pub const FieldDef = struct {
    type: ClickHouseType,
    primary_key: bool = false,
    nullable: bool = false,
    default_value: ?[]const u8 = null,
    low_cardinality: bool = false,

    /// Get full ClickHouse type declaration
    pub fn getTypeDecl(self: FieldDef, buffer: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buffer);
        const writer = fbs.writer();

        if (self.low_cardinality) {
            try writer.writeAll("LowCardinality(");
        }

        if (self.nullable) {
            try writer.writeAll("Nullable(");
        }

        try writer.writeAll(self.type.toString());

        if (self.nullable) {
            try writer.writeAll(")");
        }

        if (self.low_cardinality) {
            try writer.writeAll(")");
        }

        return fbs.getWritten();
    }
};

// Tests
test "field type declarations" {
    const field1 = FieldDef{
        .type = .UInt64,
        .primary_key = true,
    };

    var buffer: [128]u8 = undefined;
    const decl1 = try field1.getTypeDecl(&buffer);
    try std.testing.expectEqualStrings("UInt64", decl1);

    const field2 = FieldDef{
        .type = .String,
        .nullable = true,
    };

    const decl2 = try field2.getTypeDecl(&buffer);
    try std.testing.expectEqualStrings("Nullable(String)", decl2);

    const field3 = FieldDef{
        .type = .String,
        .low_cardinality = true,
    };

    const decl3 = try field3.getTypeDecl(&buffer);
    try std.testing.expectEqualStrings("LowCardinality(String)", decl3);
}
