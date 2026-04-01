const std = @import("std");
const builtin = std.builtin;

fn isStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct";
}

fn assertStruct(comptime T: type, comptime what: []const u8) void {
    if (!isStruct(T)) {
        @compileError(what ++ " must be a struct, got `" ++ @typeName(T) ++ "`");
    }
}

fn isFnType(comptime T: type) bool {
    return @typeInfo(T) == .@"fn";
}

fn isSingleItemPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .one,
        else => false,
    };
}

fn isConstPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.is_const,
        else => false,
    };
}

fn childTypeOfPointer(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => @compileError("expected pointer type, got `" ++ @typeName(T) ++ "`"),
    };
}

fn normalizeSelfBaseType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

/// associated type parser:
/// - interface provides a default value `Default`
/// - if the impl type (removing one level of `*` from `T`) defines
/// a `pub const <name>: type = ...` field, it is used instead
pub fn associatedType(comptime T: type, comptime name: []const u8, comptime Default: type) type {
    const ImplBase = normalizeSelfBaseType(T);

    if (!@hasDecl(ImplBase, name)) return Default;

    const v = @field(ImplBase, name);
    if (@TypeOf(v) != type) {
        @compileError("associated decl `" ++ name ++ "` on `" ++ @typeName(ImplBase) ++ "` must have type `type`, got `" ++ @typeName(@TypeOf(v)) ++ "`");
    }
    return v;
}

fn hasFieldNamed(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| blk: {
            inline for (s.fields) |f| {
                if (std.mem.eql(u8, f.name, name)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn fieldInfoByName(comptime T: type, comptime name: []const u8) builtin.Type.StructField {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| blk: {
            inline for (s.fields) |f| {
                if (std.mem.eql(u8, f.name, name)) break :blk f;
            }
            @compileError("field `" ++ name ++ "` not found in `" ++ @typeName(T) ++ "`");
        },
        else => @compileError("expected struct type, got `" ++ @typeName(T) ++ "`"),
    };
}

fn countFnFields(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| blk: {
            var n: usize = 0;
            inline for (s.fields) |f| {
                if (isFnType(f.type)) n += 1;
            }
            break :blk n;
        },
        else => @compileError("expected struct type, got `" ++ @typeName(T) ++ "`"),
    };
}

fn fnInfo(comptime F: type) builtin.Type.Fn {
    return switch (@typeInfo(F)) {
        .@"fn" => |fi| fi,
        else => @compileError("expected fn type, got `" ++ @typeName(F) ++ "`"),
    };
}

fn fnParams(comptime F: type) []const builtin.Type.Fn.Param {
    return fnInfo(F).params;
}

fn fnReturnType(comptime F: type) type {
    return fnInfo(F).return_type orelse
        @compileError("function must have explicit return type: `" ++ @typeName(F) ++ "`");
}

fn isErrorUnionType(comptime T: type) bool {
    return @typeInfo(T) == .error_union;
}

fn errorUnionPayload(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| eu.payload,
        else => @compileError("expected error union, got `" ++ @typeName(T) ++ "`"),
    };
}

fn usesAnyError(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .error_union => |eu| eu.error_set == anyerror,
        else => false,
    };
}

fn isSupportedSelfParam(comptime ParamT: type, comptime Base: type) bool {
    if (ParamT == Base) return true;

    return switch (@typeInfo(ParamT)) {
        .pointer => |p| p.size == .one and p.child == Base,
        else => false,
    };
}

fn canSatisfyRequiredSelf(comptime Required: type, comptime Provided: type, comptime Base: type) bool {
    if (!isSupportedSelfParam(Required, Base)) return false;
    if (!isSupportedSelfParam(Provided, Base)) return false;

    if (Required == Provided) return true;

    if (Required == Base) return false;
    if (Provided == Base) return false;

    const rq = @typeInfo(Required).pointer;
    const pv = @typeInfo(Provided).pointer;

    if (rq.child != Base or pv.child != Base) return false;
    if (rq.size != .one or pv.size != .one) return false;

    // allow *Self to satisfy *const Self
    if (Required == *const Base and Provided == *Base) return true;

    return false;
}

fn assertMethodShape(
    comptime IfcName: []const u8,
    comptime MethodName: []const u8,
    comptime RequiredFn: type,
    comptime ProvidedFn: type,
    comptime Base: type,
) void {
    const rf = fnInfo(RequiredFn);
    const pf = fnInfo(ProvidedFn);

    if (rf.is_var_args or pf.is_var_args) {
        @compileError("varargs methods are not supported: `" ++ MethodName ++ "`");
    }

    if (rf.params.len == 0 or pf.params.len == 0) {
        @compileError("method `" ++ MethodName ++ "` in interface `" ++ IfcName ++ "` must have self as first parameter");
    }

    if (rf.params[0].type == null or pf.params[0].type == null) {
        @compileError("generic self parameter is not supported for method `" ++ MethodName ++ "`");
    }

    const req_self = rf.params[0].type.?;
    const prov_self = pf.params[0].type.?;

    if (!isSupportedSelfParam(req_self, Base)) {
        @compileError("interface method `" ++ MethodName ++ "` first parameter must be Self / *Self / *const Self, got `" ++
            @typeName(req_self) ++ "`");
    }

    if (!isSupportedSelfParam(prov_self, Base)) {
        @compileError("impl method `" ++ MethodName ++ "` first parameter must be Self / *Self / *const Self, got `" ++
            @typeName(prov_self) ++ "`");
    }

    if (!canSatisfyRequiredSelf(req_self, prov_self, Base)) {
        @compileError("impl method `" ++ MethodName ++ "` self parameter `" ++ @typeName(prov_self) ++
            "` does not satisfy interface requirement `" ++ @typeName(req_self) ++ "`");
    }

    if (rf.params.len != pf.params.len) {
        @compileError("impl method `" ++ MethodName ++ "` parameter count mismatch, expected " ++
            std.fmt.comptimePrint("{d}", .{rf.params.len}) ++ ", got " ++
            std.fmt.comptimePrint("{d}", .{pf.params.len}));
    }

    inline for (rf.params[1..], 1..) |rp, i| {
        const pp = pf.params[i];

        if (rp.type == null or pp.type == null) {
            @compileError("generic method parameters are not supported for `" ++ MethodName ++ "`");
        }
        if (rp.is_generic or pp.is_generic) {
            @compileError("generic methods are not supported for `" ++ MethodName ++ "`");
        }
        if (rp.type.? != pp.type.?) {
            @compileError("impl method `" ++ MethodName ++ "` parameter type mismatch at index " ++
                std.fmt.comptimePrint("{d}", .{i}) ++ ", expected `" ++
                @typeName(rp.type.?) ++ "`, got `" ++ @typeName(pp.type.?) ++ "`");
        }
    }

    const rr = rf.return_type orelse @compileError("required fn must have explicit return type");
    const pr = pf.return_type orelse @compileError("provided fn must have explicit return type");

    if (rr != pr) {
        @compileError("impl method `" ++ MethodName ++ "` return type mismatch, expected `" ++
            @typeName(rr) ++ "`, got `" ++ @typeName(pr) ++ "`");
    }
}

fn assertDataFieldRequirement(
    comptime ImplBase: type,
    comptime FieldName: []const u8,
    comptime FieldType: type,
) void {
    assertStruct(ImplBase, "impl base type");

    if (!@hasField(ImplBase, FieldName)) {
        @compileError("type `" ++ @typeName(ImplBase) ++ "` is missing required field `" ++ FieldName ++ "`");
    }

    const actual_ty = @TypeOf(@field(@as(ImplBase, undefined), FieldName));
    if (actual_ty != FieldType) {
        @compileError("field `" ++ FieldName ++ "` type mismatch on `" ++ @typeName(ImplBase) ++
            "`, expected `" ++ @typeName(FieldType) ++ "`, got `" ++ @typeName(actual_ty) ++ "`");
    }
}

pub fn Compose(comptime T: type, comptime Parents: anytype, comptime Extra: type) type {
    comptime {
        // Composition does a fair bit of comptime bookkeeping (duplicate checks, etc.).
        @setEvalBranchQuota(20_000);
    }

    assertStruct(Extra, "Compose extra interface");
    const ei = @typeInfo(Extra).@"struct";

    comptime var total_fields: usize = ei.fields.len;

    inline for (Parents) |Parent| {
        const P = Parent(T);
        assertStruct(P, "parent interface");
        const pi = @typeInfo(P).@"struct";
        total_fields += pi.fields.len;
    }

    var fields: [total_fields]builtin.Type.StructField = undefined;

    var fi: usize = 0;

    inline for (Parents) |Parent| {
        const P = Parent(T);
        const pi = @typeInfo(P).@"struct";

        inline for (pi.fields) |f| {
            comptime var existing_idx: ?usize = null;
            inline for (fields[0..fi], 0..) |ef, idx| {
                if (std.mem.eql(u8, ef.name, f.name)) {
                    existing_idx = idx;
                    break;
                }
            }

            if (existing_idx) |ei_idx| {
                // Allow duplicates when they are the *same* field (common in interface composition).
                if (fields[ei_idx].type != f.type) {
                    @compileError("Compose field conflict: `" ++ f.name ++ "` type mismatch");
                }

                const prev_def = fields[ei_idx].default_value_ptr;
                const next_def = f.default_value_ptr;

                // If one side provides a default method and the other doesn't, keep the default.
                if (prev_def == null and next_def != null) {
                    fields[ei_idx] = f;
                } else if (prev_def != null and next_def != null and prev_def.? != next_def.?) {
                    @compileError("Compose field conflict: `" ++ f.name ++ "` has different default implementations");
                }

                continue;
            }

            fields[fi] = f;
            fi += 1;
        }
    }

    inline for (ei.fields) |f| {
        comptime var existing_idx: ?usize = null;
        inline for (fields[0..fi], 0..) |ef, idx| {
            if (std.mem.eql(u8, ef.name, f.name)) {
                existing_idx = idx;
                break;
            }
        }

        if (existing_idx) |ei_idx| {
            if (fields[ei_idx].type != f.type) {
                @compileError("Compose field conflict: `" ++ f.name ++ "` type mismatch");
            }

            const prev_def = fields[ei_idx].default_value_ptr;
            const next_def = f.default_value_ptr;
            if (prev_def == null and next_def != null) {
                fields[ei_idx] = f;
            } else if (prev_def != null and next_def != null and prev_def.? != next_def.?) {
                @compileError("Compose field conflict: `" ++ f.name ++ "` has different default implementations");
            }
            continue;
        }

        fields[fi] = f;
        fi += 1;
    }

    const final_fields = fields[0..fi];

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .backing_integer = null,
            .fields = final_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

fn methodBindingFieldCount(comptime IfcSpec: type) usize {
    const si = @typeInfo(IfcSpec).@"struct";
    comptime var n: usize = 0;
    inline for (si.fields) |f| {
        if (isFnType(f.type)) n += 1;
    }
    return n;
}

pub fn Impl(comptime Ifc: fn (type) type, comptime T: type) type {
    const IfcSpec = Ifc(T);
    assertStruct(IfcSpec, "interface specialization");
    const si = @typeInfo(IfcSpec).@"struct";
    const ImplBase = normalizeSelfBaseType(T);

    const method_count = methodBindingFieldCount(IfcSpec);
    var fields: [method_count]builtin.Type.StructField = undefined;
    var fi: usize = 0;

    inline for (si.fields) |f| {
        if (isFnType(f.type)) {
            const default_ptr = blk: {
                if (@hasDecl(ImplBase, f.name)) {
                    const dv = @field(ImplBase, f.name);
                    const dt = @TypeOf(dv);

                    if (!isFnType(dt)) {
                        @compileError("impl member `" ++ f.name ++ "` on `" ++ @typeName(ImplBase) ++
                            "` must be pub fn");
                    }

                    assertMethodShape(@typeName(IfcSpec), f.name, f.type, dt, ImplBase);

                    const Holder = struct {
                        const value: f.type = dv;
                    };
                    break :blk @as(*const anyopaque, @ptrCast(&Holder.value));
                }

                if (f.default_value_ptr) |p| break :blk p;

                @compileError("type `" ++ @typeName(ImplBase) ++ "` does not provide required pub fn `" ++ f.name ++
                    "` for interface `" ++ @typeName(IfcSpec) ++ "`");
            };

            fields[fi] = .{
                .name = f.name,
                .type = f.type,
                .default_value_ptr = default_ptr,
                .is_comptime = false,
                .alignment = @alignOf(f.type),
            };
            fi += 1;
        } else {
            assertDataFieldRequirement(ImplBase, f.name, f.type);
        }
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .backing_integer = null,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub fn assertImpl(comptime Ifc: fn (type) type, comptime T: type) void {
    _ = Impl(Ifc, T){};
}

fn erasedMethodType(comptime MethodType: type, comptime ImplBase: type) type {
    const fi = fnInfo(MethodType);

    if (fi.is_var_args) {
        @compileError("varargs methods are not supported");
    }
    if (fi.params.len == 0) {
        @compileError("interface methods must have self as first parameter");
    }
    if (fi.params[0].type == null) {
        @compileError("generic self parameter is not supported");
    }

    const self_ty = fi.params[0].type.?;
    if (!isSupportedSelfParam(self_ty, ImplBase)) {
        @compileError("dyn method self parameter must be Self / *Self / *const Self, got `" ++ @typeName(self_ty) ++ "`");
    }

    if (self_ty == ImplBase) {
        @compileError("Dyn(...) does not support value receiver methods; use *Self or *const Self in interface method");
    }

    var params: [fi.params.len]builtin.Type.Fn.Param = undefined;

    params[0] = .{
        .is_generic = false,
        .is_noalias = fi.params[0].is_noalias,
        .type = *anyopaque,
    };

    inline for (fi.params[1..], 0..) |p, idx| {
        if (p.type == null or p.is_generic) {
            @compileError("generic methods are not supported in dyn mode");
        }
        params[idx + 1] = p;
    }

    var ret = fi.return_type orelse @compileError("method must have explicit return type");
    if (isErrorUnionType(ret)) {
        const payload = errorUnionPayload(ret);
        ret = anyerror!payload;
    }

    return @Type(.{
        .@"fn" = .{
            .calling_convention = fi.calling_convention,
            .is_generic = false,
            .is_var_args = false,
            .return_type = ret,
            .params = &params,
        },
    });
}

fn canDynReturnCoerce(comptime StaticRet: type, comptime DynRet: type) bool {
    if (StaticRet == DynRet) return true;

    if (isErrorUnionType(StaticRet) and isErrorUnionType(DynRet)) {
        return errorUnionPayload(StaticRet) == errorUnionPayload(DynRet) and usesAnyError(DynRet);
    }

    return false;
}

pub fn ErasedVTableOf(comptime Ifc: fn (type) type, comptime ImplBase: type) type {
    const IfcSpec = Ifc(*const ImplBase);
    assertStruct(IfcSpec, "erased interface specialization");
    const si = @typeInfo(IfcSpec).@"struct";

    const n = countFnFields(IfcSpec);
    var fields: [n]builtin.Type.StructField = undefined;
    var i: usize = 0;

    inline for (si.fields) |f| {
        if (!isFnType(f.type)) continue;

        const ErasedFn = erasedMethodType(f.type, ImplBase);
        fields[i] = .{
            .name = f.name,
            .type = *const ErasedFn,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(*const ErasedFn),
        };
        i += 1;
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .backing_integer = null,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

fn makeThunk0(
    comptime Ifc: fn (type) type,
    comptime T: type,
    comptime ImplBase: type,
    comptime MethodName: []const u8,
    comptime DynMethodType: type,
) *const DynMethodType {
    const ImplType = Impl(Ifc, T);
    const StaticMethodType = fieldInfoByName(ImplType, MethodName).type;

    const sp = fnParams(StaticMethodType);
    const dp = fnParams(DynMethodType);
    const sr = fnReturnType(StaticMethodType);
    const dr = fnReturnType(DynMethodType);

    if (sp.len != 1 or dp.len != 1) {
        @compileError("internal thunk arity mismatch: `" ++ MethodName ++ "`");
    }
    if (!canDynReturnCoerce(sr, dr)) {
        @compileError("dyn return coercion failed for method `" ++ MethodName ++ "`");
    }

    const self_ty = sp[0].type.?;

    const Holder = struct {
        fn call(ctx: *anyopaque) dr {
            const impl = Impl(Ifc, T){};
            const method = @field(impl, MethodName);

            const self = if (self_ty == *ImplBase)
                @as(*ImplBase, @ptrCast(@alignCast(ctx)))
            else if (self_ty == *const ImplBase)
                @as(*const ImplBase, @ptrCast(@alignCast(ctx)))
            else
                @compileError("dyn only supports pointer receivers");

            return method(self);
        }
    };

    return &Holder.call;
}

fn makeThunk1(
    comptime Ifc: fn (type) type,
    comptime T: type,
    comptime ImplBase: type,
    comptime MethodName: []const u8,
    comptime DynMethodType: type,
) *const DynMethodType {
    const ImplType = Impl(Ifc, T);
    const StaticMethodType = fieldInfoByName(ImplType, MethodName).type;

    const sp = fnParams(StaticMethodType);
    const dp = fnParams(DynMethodType);
    const sr = fnReturnType(StaticMethodType);
    const dr = fnReturnType(DynMethodType);

    if (sp.len != 2 or dp.len != 2) {
        @compileError("internal thunk arity mismatch: `" ++ MethodName ++ "`");
    }
    if (sp[1].type == null or dp[1].type == null or sp[1].type.? != dp[1].type.?) {
        @compileError("dyn param mismatch for method `" ++ MethodName ++ "`");
    }
    if (!canDynReturnCoerce(sr, dr)) {
        @compileError("dyn return coercion failed for method `" ++ MethodName ++ "`");
    }

    const self_ty = sp[0].type.?;
    const A1 = sp[1].type.?;

    const Holder = struct {
        fn call(ctx: *anyopaque, a1: A1) dr {
            const impl = Impl(Ifc, T){};
            const method = @field(impl, MethodName);

            const self = if (self_ty == *ImplBase)
                @as(*ImplBase, @ptrCast(@alignCast(ctx)))
            else if (self_ty == *const ImplBase)
                @as(*const ImplBase, @ptrCast(@alignCast(ctx)))
            else
                @compileError("dyn only supports pointer receivers");

            return method(self, a1);
        }
    };

    return &Holder.call;
}

fn makeThunk2(
    comptime Ifc: fn (type) type,
    comptime T: type,
    comptime ImplBase: type,
    comptime MethodName: []const u8,
    comptime DynMethodType: type,
) *const DynMethodType {
    const ImplType = Impl(Ifc, T);
    const StaticMethodType = fieldInfoByName(ImplType, MethodName).type;

    const sp = fnParams(StaticMethodType);
    const dp = fnParams(DynMethodType);
    const sr = fnReturnType(StaticMethodType);
    const dr = fnReturnType(DynMethodType);

    if (sp.len != 3 or dp.len != 3) {
        @compileError("internal thunk arity mismatch: `" ++ MethodName ++ "`");
    }
    inline for (1..3) |i| {
        if (sp[i].type == null or dp[i].type == null or sp[i].type.? != dp[i].type.?) {
            @compileError("dyn param mismatch for method `" ++ MethodName ++ "`");
        }
    }
    if (!canDynReturnCoerce(sr, dr)) {
        @compileError("dyn return coercion failed for method `" ++ MethodName ++ "`");
    }

    const self_ty = sp[0].type.?;
    const A1 = sp[1].type.?;
    const A2 = sp[2].type.?;

    const Holder = struct {
        fn call(ctx: *anyopaque, a1: A1, a2: A2) dr {
            const impl = Impl(Ifc, T){};
            const method = @field(impl, MethodName);

            const self = if (self_ty == *ImplBase)
                @as(*ImplBase, @ptrCast(@alignCast(ctx)))
            else if (self_ty == *const ImplBase)
                @as(*const ImplBase, @ptrCast(@alignCast(ctx)))
            else
                @compileError("dyn only supports pointer receivers");

            return method(self, a1, a2);
        }
    };

    return &Holder.call;
}

fn makeThunk3(
    comptime Ifc: fn (type) type,
    comptime T: type,
    comptime ImplBase: type,
    comptime MethodName: []const u8,
    comptime DynMethodType: type,
) *const DynMethodType {
    const ImplType = Impl(Ifc, T);
    const StaticMethodType = fieldInfoByName(ImplType, MethodName).type;

    const sp = fnParams(StaticMethodType);
    const dp = fnParams(DynMethodType);
    const sr = fnReturnType(StaticMethodType);
    const dr = fnReturnType(DynMethodType);

    if (sp.len != 4 or dp.len != 4) {
        @compileError("internal thunk arity mismatch: `" ++ MethodName ++ "`");
    }
    inline for (1..4) |i| {
        if (sp[i].type == null or dp[i].type == null or sp[i].type.? != dp[i].type.?) {
            @compileError("dyn param mismatch for method `" ++ MethodName ++ "`");
        }
    }
    if (!canDynReturnCoerce(sr, dr)) {
        @compileError("dyn return coercion failed for method `" ++ MethodName ++ "`");
    }

    const self_ty = sp[0].type.?;
    const A1 = sp[1].type.?;
    const A2 = sp[2].type.?;
    const A3 = sp[3].type.?;

    const Holder = struct {
        fn call(ctx: *anyopaque, a1: A1, a2: A2, a3: A3) dr {
            const impl = Impl(Ifc, T){};
            const method = @field(impl, MethodName);

            const self = if (self_ty == *ImplBase)
                @as(*ImplBase, @ptrCast(@alignCast(ctx)))
            else if (self_ty == *const ImplBase)
                @as(*const ImplBase, @ptrCast(@alignCast(ctx)))
            else
                @compileError("dyn only supports pointer receivers");

            return method(self, a1, a2, a3);
        }
    };

    return &Holder.call;
}

fn makeThunk(
    comptime Ifc: fn (type) type,
    comptime T: type,
    comptime ImplBase: type,
    comptime MethodName: []const u8,
    comptime DynMethodType: type,
) *const DynMethodType {
    return switch (fnParams(DynMethodType).len) {
        1 => makeThunk0(Ifc, T, ImplBase, MethodName, DynMethodType),
        2 => makeThunk1(Ifc, T, ImplBase, MethodName, DynMethodType),
        3 => makeThunk2(Ifc, T, ImplBase, MethodName, DynMethodType),
        4 => makeThunk3(Ifc, T, ImplBase, MethodName, DynMethodType),
        else => @compileError("ztrait v1 dyn supports at most 3 non-self parameters"),
    };
}

pub fn makeVTable(comptime Ifc: fn (type) type, comptime T: type) *const ErasedVTableOf(Ifc, normalizeSelfBaseType(T)) {
    const ImplBase = normalizeSelfBaseType(T);
    const VTable = ErasedVTableOf(Ifc, ImplBase);
    const IfcSpec = Ifc(T);
    const si = @typeInfo(IfcSpec).@"struct";

    comptime assertImpl(Ifc, T);

    const Cache = struct {
        const value: VTable = blk: {
            var vt: VTable = undefined;

            for (si.fields) |f| {
                if (!isFnType(f.type)) continue;
                const ErasedFn = @typeInfo(@TypeOf(@field(vt, f.name))).pointer.child;
                @field(vt, f.name) = makeThunk(Ifc, T, ImplBase, f.name, ErasedFn);
            }

            break :blk vt;
        };
    };

    return &Cache.value;
}

/// A fully type-erased vtable shape that does NOT depend on the concrete implementation type.
///
/// This is the key difference between `Dyn(Ifc, T)` and `AnyDyn(Ifc)`:
/// - `Dyn` keeps `T` in the type (monomorphized per impl type).
/// - `AnyDyn` erases impl type and keeps only `Ifc` in the type.
pub fn ErasedVTable(comptime Ifc: fn (type) type) type {
    return ErasedVTableOf(Ifc, anyopaque);
}

fn makeVTableErased(comptime Ifc: fn (type) type, comptime T: type) *const ErasedVTable(Ifc) {
    const ImplBase = normalizeSelfBaseType(T);
    const VTable = ErasedVTable(Ifc);
    const IfcSpec = Ifc(T);
    const si = @typeInfo(IfcSpec).@"struct";

    comptime assertImpl(Ifc, T);

    const Cache = struct {
        const value: VTable = blk: {
            var vt: VTable = undefined;

            for (si.fields) |f| {
                if (!isFnType(f.type)) continue;
                const ErasedFn = @typeInfo(@TypeOf(@field(vt, f.name))).pointer.child;
                @field(vt, f.name) = makeThunk(Ifc, T, ImplBase, f.name, ErasedFn);
            }

            break :blk vt;
        };
    };

    return &Cache.value;
}

pub fn Dyn(comptime Ifc: fn (type) type, comptime T: type) type {
    const ImplBase = normalizeSelfBaseType(T);
    const VTable = ErasedVTableOf(Ifc, ImplBase);

    return struct {
        ctx: *anyopaque,
        vtable: *const VTable,

        pub fn init(value: T) @This() {
            comptime assertImpl(Ifc, T);

            if (!comptime isSingleItemPointer(T)) {
                @compileError("Dyn only supports pointer receiver specializations");
            }

            return .{
                .ctx = @ptrCast(@constCast(value)),
                .vtable = comptime makeVTable(Ifc, T),
            };
        }

        pub fn project(self: @This(), comptime TargetIfc: fn (type) type) Dyn(TargetIfc, T) {
            return upcast(TargetIfc, T, self);
        }
    };
}

/// Real type-erasure: same Dyn type for different impl types.
///
/// - Only depends on the interface `Ifc`.
/// - Stores erased ctx + an erased vtable value.
/// - `init(...)` infers the impl pointer type from the passed value.
pub fn AnyDyn(comptime Ifc: fn (type) type) type {
    const VTable = ErasedVTable(Ifc);

    return struct {
        ctx: *anyopaque,
        vtable: VTable,

        pub fn init(value: anytype) @This() {
            const T = @TypeOf(value);
            comptime assertImpl(Ifc, T);

            if (!comptime isSingleItemPointer(T)) {
                @compileError("AnyDyn only supports pointer receiver specializations");
            }

            return .{
                .ctx = @ptrCast(@constCast(value)),
                .vtable = comptime makeVTableErased(Ifc, T).*,
            };
        }

        pub fn project(self: @This(), comptime TargetIfc: fn (type) type) AnyDyn(TargetIfc) {
            const SrcVTable = VTable;
            const TargetVTable = ErasedVTable(TargetIfc);

            var tmp: TargetVTable = undefined;
            inline for (@typeInfo(TargetVTable).@"struct".fields) |tf| {
                if (!@hasField(SrcVTable, tf.name)) {
                    @compileError("Cannot project dyn object: missing method `" ++ tf.name ++ "` in source vtable");
                }
                @field(tmp, tf.name) = @field(self.vtable, tf.name);
            }

            return .{ .ctx = self.ctx, .vtable = tmp };
        }
    };
}

fn upcast(comptime TargetIfc: fn (type) type, comptime T: type, src: anytype) Dyn(TargetIfc, T) {
    // Build the projected vtable directly from the implementation type.
    // This avoids capturing `src` in a comptime initializer and keeps vtables canonical per (Ifc, T).
    comptime assertImpl(TargetIfc, T);

    return Dyn(TargetIfc, T){
        .ctx = src.ctx,
        .vtable = comptime makeVTable(TargetIfc, T),
    };
}
