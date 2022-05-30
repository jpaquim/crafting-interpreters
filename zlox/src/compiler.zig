const std = @import("std");
const Allocator = std.mem.Allocator;

const chk = @import("./chunk.zig");
const Chunk = chk.Chunk;
const OpCode = chk.OpCode;
const addConstant = chk.addConstant;
const writeChunk = chk.writeChunk;

const common = @import("./common.zig");
const DEBUG_PRINT_CODE = common.DEBUG_PRINT_CODE;
const U8_COUNT = common.U8_COUNT;
const debug = @import("./debug.zig");
const disassembleChunk = debug.disassembleChunk;

const object = @import("./object.zig");
const copyString = object.copyString;

const scanner = @import("./scanner.zig");
const Token = scanner.Token;
const TokenType = scanner.TokenType;
const initScanner = scanner.initScanner;
const scanToken = scanner.scanToken;

const v = @import("./value.zig");
const Value = v.Value;
const NUMBER_VAL = v.NUMBER_VAL;
const OBJ_VAL = v.OBJ_VAL;

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

const Parser = struct {
    current: Token,
    previous: Token,
    had_error: bool,
    panic_mode: bool,
};

const Precedence = enum {
    NONE,
    ASSIGNMENT, // =
    OR, // or
    AND, // and
    EQUALITY, // == !=
    COMPARISON, // < > <= >=
    TERM, // + -
    FACTOR, // * /
    UNARY, // ! -
    CALL, // . ()
    PRIMARY,
};

const ParseFn = fn (allocator: Allocator, can_assign: bool) void;

const ParseRule = struct {
    prefix: ?ParseFn = null,
    infix: ?ParseFn = null,
    precedence: Precedence,
};

const Local = struct {
    name: Token,
    depth: i32,
};

const Compiler = struct {
    locals: [U8_COUNT]Local,
    local_count: usize,
    scope_depth: i32,
};

var parser: Parser = undefined;
var current: ?*Compiler = null;
var compiling_chunk: *Chunk = undefined;

fn currentChunk() *Chunk {
    return compiling_chunk;
}

fn errorAt(token: *Token, message: []const u8) void {
    if (parser.panic_mode) return;
    parser.panic_mode = true;
    stderr.print("[line {d}] Error", .{token.line}) catch unreachable;

    if (token.t_type == .EOF) {
        stderr.writeAll(" at end") catch unreachable;
    } else if (token.t_type == .ERROR) {} else {
        stderr.print(" at '{s}'", .{token.start[0..token.length]}) catch unreachable;
    }

    stderr.print(": {s}\n", .{message}) catch unreachable;
    parser.had_error = true;
}

fn err(message: []const u8) void {
    errorAt(&parser.previous, message);
}

fn errorAtCurrent(message: []const u8) void {
    errorAt(&parser.current, message);
}

fn advance() void {
    parser.previous = parser.current;

    while (true) {
        parser.current = scanToken();
        if (parser.current.t_type != .ERROR) break;

        errorAtCurrent(parser.current.start[0..parser.current.length]);
    }
}

fn consume(t_type: TokenType, message: []const u8) void {
    if (parser.current.t_type == t_type) {
        advance();
        return;
    }

    errorAtCurrent(message);
}

fn check(t_type: TokenType) bool {
    return parser.current.t_type == t_type;
}

fn match(t_type: TokenType) bool {
    if (!check(t_type)) return false;
    advance();
    return true;
}

fn emitByte(allocator: Allocator, byte: u8) void {
    writeChunk(allocator, currentChunk(), byte, parser.previous.line);
}

fn emitBytes(allocator: Allocator, byte1: u8, byte2: u8) void {
    emitByte(allocator, byte1);
    emitByte(allocator, byte2);
}

fn emitJump(allocator: Allocator, instruction: u8) usize {
    emitByte(allocator, instruction);
    emitByte(allocator, 0xff);
    emitByte(allocator, 0xff);
    return currentChunk().count - 2;
}

fn emitReturn(allocator: Allocator) void {
    emitByte(allocator, @enumToInt(OpCode.op_return));
}

fn makeConstant(allocator: Allocator, value: Value) u8 {
    const constant = addConstant(allocator, currentChunk(), value);
    if (constant > std.math.maxInt(u8)) {
        err("Too many constants in one chunk.");
        return 0;
    }

    return @intCast(u8, constant);
}

fn emitConstant(allocator: Allocator, value: Value) void {
    emitBytes(allocator, @enumToInt(OpCode.op_constant), makeConstant(allocator, value));
}

fn patchJump(offset: usize) void {
    const jump = currentChunk().count - offset - 2;

    if (jump > std.math.maxInt(u16)) {
        err("Too much code to jump over.");
    }

    currentChunk().code.?[offset] = @intCast(u8, jump >> 8) & 0xff;
    currentChunk().code.?[offset + 1] = @intCast(u8, jump) & 0xff;
}

fn initCompiler(compiler: *Compiler) void {
    compiler.local_count = 0;
    compiler.scope_depth = 0;
    current = compiler;
}

fn endCompiler(allocator: Allocator) !void {
    emitReturn(allocator);
    if (DEBUG_PRINT_CODE) {
        try disassembleChunk(currentChunk(), "code");
    }
}

fn beginScope() void {
    current.?.scope_depth += 1;
}

fn endScope(allocator: Allocator) void {
    current.?.scope_depth -= 1;

    while (current.?.local_count > 0 and current.?.locals[current.?.local_count - 1].depth > current.?.scope_depth) {
        emitByte(allocator, @enumToInt(OpCode.op_pop));
        current.?.local_count -= 1;
    }
}

fn binary(allocator: Allocator, _: bool) void {
    const operator_type = parser.previous.t_type;
    const rule = getRule(operator_type);
    parsePrecedence(allocator, @intToEnum(Precedence, @enumToInt(rule.precedence) + 1));

    switch (operator_type) {
        .BANG_EQUAL => emitBytes(allocator, @enumToInt(OpCode.op_equal), @enumToInt(OpCode.op_not)),
        .EQUAL_EQUAL => emitByte(allocator, @enumToInt(OpCode.op_equal)),
        .GREATER => emitByte(allocator, @enumToInt(OpCode.op_greater)),
        .GREATER_EQUAL => emitBytes(allocator, @enumToInt(OpCode.op_less), @enumToInt(OpCode.op_not)),
        .LESS => emitByte(allocator, @enumToInt(OpCode.op_less)),
        .LESS_EQUAL => emitBytes(allocator, @enumToInt(OpCode.op_greater), @enumToInt(OpCode.op_not)),
        .PLUS => emitByte(allocator, @enumToInt(OpCode.op_add)),
        .MINUS => emitByte(allocator, @enumToInt(OpCode.op_subtract)),
        .STAR => emitByte(allocator, @enumToInt(OpCode.op_multiply)),
        .SLASH => emitByte(allocator, @enumToInt(OpCode.op_divide)),
        else => unreachable,
    }
}

fn literal(allocator: Allocator, _: bool) void {
    switch (parser.previous.t_type) {
        .FALSE => emitByte(allocator, @enumToInt(OpCode.op_false)),
        .NIL => emitByte(allocator, @enumToInt(OpCode.op_nil)),
        .TRUE => emitByte(allocator, @enumToInt(OpCode.op_true)),
        else => unreachable,
    }
}

fn grouping(allocator: Allocator, _: bool) void {
    expression(allocator);
    consume(.RIGHT_PAREN, "Expect ')' after expression.");
}

fn expression(allocator: Allocator) void {
    parsePrecedence(allocator, .ASSIGNMENT);
}

fn block(allocator: Allocator) void {
    while (!check(.RIGHT_BRACE) and !check(.EOF)) {
        declaration(allocator);
    }

    consume(.RIGHT_BRACE, "Expect '}' after block.");
}

fn varDeclaration(allocator: Allocator) void {
    const global = parseVariable(allocator, "Expect variable name.");

    if (match(.EQUAL)) {
        expression(allocator);
    } else {
        emitByte(allocator, @enumToInt(OpCode.op_nil));
    }
    consume(.SEMICOLON, "Expect ';' after variable declaration.");

    defineVariable(allocator, global);
}

fn expressionStatement(allocator: Allocator) void {
    expression(allocator);
    consume(.SEMICOLON, "Expect ';' after expression.");
    emitByte(allocator, @enumToInt(OpCode.op_pop));
}

fn ifStatement(allocator: Allocator) void {
    consume(.LEFT_PAREN, "Expect '(' after 'if'.");
    expression(allocator);
    consume(.RIGHT_PAREN, "Expect ')' after condition.");

    const then_jump = emitJump(allocator, @enumToInt(OpCode.op_jump_if_false));
    emitByte(allocator, @enumToInt(OpCode.op_pop));
    statement(allocator);

    const else_jump = emitJump(allocator, @enumToInt(OpCode.op_jump));

    patchJump(then_jump);
    emitByte(allocator, @enumToInt(OpCode.op_pop));

    if (match(.ELSE)) statement(allocator);
    patchJump(else_jump);
}

fn printStatement(allocator: Allocator) void {
    expression(allocator);
    consume(.SEMICOLON, "Expect ';' after value.");
    emitByte(allocator, @enumToInt(OpCode.op_print));
}

fn synchronize() void {
    parser.panic_mode = false;

    while (parser.current.t_type != .EOF) {
        if (parser.previous.t_type == .SEMICOLON) return;
        switch (parser.current.t_type) {
            .CLASS, .FUN, .VAR, .FOR, .IF, .WHILE, .PRINT, .RETURN => return,
            else => {},
        }

        advance();
    }
}

fn declaration(allocator: Allocator) void {
    if (match(.VAR)) {
        varDeclaration(allocator);
    } else {
        statement(allocator);
    }

    if (parser.panic_mode) synchronize();
}

fn statement(allocator: Allocator) void {
    if (match(.PRINT)) {
        printStatement(allocator);
    } else if (match(.IF)) {
        ifStatement(allocator);
    } else if (match(.LEFT_BRACE)) {
        beginScope();
        block(allocator);
        endScope(allocator);
    } else {
        expressionStatement(allocator);
    }
}

fn number(allocator: Allocator, _: bool) void {
    const value = std.fmt.parseFloat(f64, parser.previous.start[0..parser.previous.length]) catch unreachable;
    emitConstant(allocator, NUMBER_VAL(value));
}

fn or_(allocator: Allocator, _: bool) void {
    const else_jump = emitJump(allocator, @enumToInt(OpCode.op_jump_if_false));
    const end_jump = emitJump(allocator, @enumToInt(OpCode.op_jump));

    patchJump(else_jump);
    emitByte(allocator, @enumToInt(OpCode.op_pop));

    parsePrecedence(allocator, .OR);
    patchJump(end_jump);
}

fn string(allocator: Allocator, _: bool) void {
    emitConstant(allocator, OBJ_VAL(&copyString(allocator, parser.previous.start + 1, parser.previous.length - 2).obj));
}

fn namedVariable(allocator: Allocator, name: Token, can_assign: bool) void {
    var arg = resolveLocal(current.?, &name);
    var get_op: OpCode = undefined;
    var set_op: OpCode = undefined;
    if (arg != null) {
        get_op = .op_get_local;
        set_op = .op_set_local;
    } else {
        arg = identifierConstant(allocator, &name);
        get_op = .op_get_global;
        set_op = .op_set_global;
    }

    if (can_assign and match(.EQUAL)) {
        expression(allocator);
        emitBytes(allocator, @enumToInt(set_op), arg.?);
    } else {
        emitBytes(allocator, @enumToInt(get_op), arg.?);
    }
}

fn variable(allocator: Allocator, can_assign: bool) void {
    namedVariable(allocator, parser.previous, can_assign);
}

fn unary(allocator: Allocator, _: bool) void {
    const operator_type = parser.previous.t_type;

    parsePrecedence(allocator, .UNARY);

    switch (operator_type) {
        .BANG => emitByte(allocator, @enumToInt(OpCode.op_not)),
        .MINUS => emitByte(allocator, @enumToInt(OpCode.op_negate)),
        else => unreachable,
    }
}

const rules = [_]ParseRule{
    .{ .prefix = grouping, .precedence = .NONE }, // LEFT_PAREN
    .{ .precedence = .NONE }, // RIGHT_PAREN
    .{ .precedence = .NONE }, // LEFT_BRACE
    .{ .precedence = .NONE }, // RIGHT_BRACE
    .{ .precedence = .NONE }, // COMMA
    .{ .precedence = .NONE }, // DOT
    .{ .prefix = unary, .infix = binary, .precedence = .TERM }, // MINUS
    .{ .infix = binary, .precedence = .TERM }, // PLUS
    .{ .precedence = .NONE }, // SEMICOLON
    .{ .infix = binary, .precedence = .FACTOR }, // SLASH
    .{ .infix = binary, .precedence = .FACTOR }, // STAR
    .{ .prefix = unary, .precedence = .NONE }, // BANG
    .{ .infix = binary, .precedence = .EQUALITY }, // BANG_EQUAL
    .{ .precedence = .NONE }, // EQUAL
    .{ .infix = binary, .precedence = .COMPARISON }, // EQUAL_EQUAL
    .{ .infix = binary, .precedence = .COMPARISON }, // GREATER
    .{ .infix = binary, .precedence = .COMPARISON }, // GREATER_EQUAL
    .{ .infix = binary, .precedence = .COMPARISON }, // LESS
    .{ .infix = binary, .precedence = .COMPARISON }, // LESS_EQUAL
    .{ .prefix = variable, .precedence = .NONE }, // IDENTIFIER
    .{ .prefix = string, .precedence = .NONE }, // STRING
    .{ .prefix = number, .precedence = .NONE }, // NUMBER
    .{ .infix = and_, .precedence = .AND }, // AND
    .{ .precedence = .NONE }, // CLASS
    .{ .precedence = .NONE }, // ELSE
    .{ .prefix = literal, .precedence = .NONE }, // FALSE
    .{ .precedence = .NONE }, // FOR
    .{ .precedence = .NONE }, // FUN
    .{ .precedence = .NONE }, // IF
    .{ .prefix = literal, .precedence = .NONE }, // NIL
    .{ .infix = or_, .precedence = .OR }, // OR
    .{ .precedence = .NONE }, // PRINT
    .{ .precedence = .NONE }, // RETURN
    .{ .precedence = .NONE }, // SUPER
    .{ .precedence = .NONE }, // THIS
    .{ .prefix = literal, .precedence = .NONE }, // TRUE
    .{ .precedence = .NONE }, // VAR
    .{ .precedence = .NONE }, // WHILE
    .{ .precedence = .NONE }, // ERROR
    .{ .precedence = .NONE }, // EOF
};

fn parsePrecedence(allocator: Allocator, precedence: Precedence) void {
    advance();
    const prefix_rule = getRule(parser.previous.t_type).prefix;
    if (prefix_rule == null) {
        err("Expect expression.");
        return;
    }

    const can_assign = @enumToInt(precedence) <= @enumToInt(Precedence.ASSIGNMENT);
    prefix_rule.?(allocator, can_assign);

    while (@enumToInt(precedence) <= @enumToInt(getRule(parser.current.t_type).precedence)) {
        advance();
        const infix_rule = getRule(parser.previous.t_type).infix;
        infix_rule.?(allocator, can_assign);
    }

    if (can_assign and match(.EQUAL)) {
        err("Invalid assignment target.");
    }
}

fn identifierConstant(allocator: Allocator, name: *const Token) u8 {
    return makeConstant(allocator, OBJ_VAL(&copyString(allocator, name.start, name.length).obj));
}

fn identifiersEqual(a: *const Token, b: *const Token) bool {
    if (a.length != b.length) return false;
    return std.mem.eql(u8, a.start[0..a.length], b.start[0..b.length]);
}

fn resolveLocal(compiler: *Compiler, name: *const Token) ?u8 {
    var i = compiler.local_count;
    while (i > 0) {
        i -= 1;
        const local = &compiler.locals[i];
        if (identifiersEqual(name, &local.name)) {
            if (local.depth == -1) {
                err("Can't read local variable in its own initializer.");
            }
            return @intCast(u8, i);
        }
    }

    return null;
}

fn addLocal(name: Token) void {
    if (current.?.local_count == U8_COUNT) {
        err("Too many local variables in function.");
        return;
    }

    const local = &current.?.locals[current.?.local_count];
    current.?.local_count += 1;
    local.name = name;
    local.depth = -1;
}

fn declareVariable() void {
    if (current.?.scope_depth == 0) return;

    const name = &parser.previous;
    var i: usize = current.?.local_count;
    while (i > 0) {
        i -= 1;
        const local = &current.?.locals[i];
        if (local.depth != -1 and local.depth < current.?.scope_depth) {
            break;
        }

        if (identifiersEqual(name, &local.name)) {
            err("Already a variable with this name in this scope.");
        }
    }

    addLocal(name.*);
}

fn parseVariable(allocator: Allocator, error_message: []const u8) u8 {
    consume(.IDENTIFIER, error_message);

    declareVariable();
    if (current.?.scope_depth > 0) return 0;

    return identifierConstant(allocator, &parser.previous);
}

fn markInitialized() void {
    current.?.locals[current.?.local_count - 1].depth = current.?.scope_depth;
}

fn defineVariable(allocator: Allocator, global: u8) void {
    if (current.?.scope_depth > 0) {
        markInitialized();
        return;
    }

    emitBytes(allocator, @enumToInt(OpCode.op_define_global), global);
}

fn and_(allocator: Allocator, _: bool) void {
    const end_jump = emitJump(allocator, @enumToInt(OpCode.op_jump_if_false));

    emitByte(allocator, @enumToInt(OpCode.op_pop));
    parsePrecedence(allocator, .AND);

    patchJump(end_jump);
}

fn getRule(t_type: TokenType) *const ParseRule {
    return &rules[@enumToInt(t_type)];
}

pub fn compile(allocator: Allocator, source: []const u8, chunk: *Chunk) !bool {
    initScanner(source);
    var compiler: Compiler = undefined;
    initCompiler(&compiler);
    compiling_chunk = chunk;

    parser.had_error = false;
    parser.panic_mode = false;

    advance();

    while (!match(.EOF)) {
        declaration(allocator);
    }

    try endCompiler(allocator);
    return !parser.had_error;
}
