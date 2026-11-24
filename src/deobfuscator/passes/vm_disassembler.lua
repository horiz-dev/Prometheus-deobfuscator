
local Parser = require("prometheus.parser")
local Unparser = require("prometheus.unparser")
local Ast = require("prometheus.ast")
local Enums = require("prometheus.enums")
local Source = require("prometheus.source")
local visitast = require("prometheus.visitast")

local VmDisassembler = {}

local semanticSignatures = {
    { name = "LOAD", pat = "%[j%]%s*=%s*h%[O%]" },
    { name = "GLOBAL", pat = "%[j%]%s*=%s*f%[h%[O%]%]" },
    { name = "SETGLOBAL", pat = "f%[h%[j%]%]%s*=%s*A%[O%]" },
    { name = "GETTABLE", pat = "%[j%]%s*=%s*A%[O%]%[A%[b%]%]" },
    { name = "SETTABLE", pat = "%[j%]%[A%[O%]%]%s*=%s*A%[b%]" },
    { name = "TABLE", pat = "%[j%]%s*=%s*%{ %}" },
    { name = "CELL", pat = "%[j%]%s*=%s*%{ t %}" },
    { name = "GETCELL", pat = "%[j%]%s*=%s*A%[O%]%[1%]" },
    { name = "SETCELL", pat = "%[j%]%[1%]%s*=%s*A%[O%]" },
    { name = "GETUP", pat = "%[j%]%s*=%s*o%[O%]%[1%]" },
    { name = "SETUP", pat = "o%[j%]%[1%]%s*=%s*A%[O%]" },
    { name = "CONCAT", pat = "%[j%]%s*=%s*A%[O%]%s*%.%.%s*A%[b%]" },
    { name = "ADD", pat = "%[j%]%s*=%s*A%[O%]%s*%+%s*A%[b%]" },
    { name = "SUB", pat = "%[j%]%s*=%s*A%[O%]%s*%-%s*A%[b%]" },
    { name = "MUL", pat = "%[j%]%s*=%s*A%[O%]%s*%*%s*A%[b%]" },
    { name = "DIV", pat = "%[j%]%s*=%s*A%[O%]%s*/%s*A%[b%]" },
    { name = "MOD", pat = "%[j%]%s*=%s*A%[O%]%s*%%%s*A%[b%]" },
    { name = "POW", pat = "%[j%]%s*=%s*A%[O%]%s*%^%s*A%[b%]" },
    { name = "LT", pat = "%[j%]%s*=%s*A%[O%]%s*<%s*A%[b%]" },
    { name = "LE", pat = "%[j%]%s*=%s*A%[O%]%s*<=%s*A%[b%]" },
    { name = "GT", pat = "%[j%]%s*=%s*A%[O%]%s*>%s*A%[b%]" },
    { name = "GE", pat = "%[j%]%s*=%s*A%[O%]%s*>=%s*A%[b%]" },
    { name = "EQ", pat = "%[j%]%s*=%s*A%[O%]%s*==%s*A%[b%]" },
    { name = "NE", pat = "%[j%]%s*=%s*A%[O%]%s*~=%s*A%[b%]" },
    { name = "NOT", pat = "%[j%]%s*=%s*not%s+A%[O%]" },
    { name = "NEG", pat = "%[j%]%s*=%s*%-A%[O%]" },
    { name = "LEN", pat = "%[j%]%s*=%s*#A%[O%]" },
    { name = "MOVE", pat = "%[j%]%s*=%s*A%[O%]" },
    { name = "CLEAR", pat = "%[j%]%s*=%s*nil" },
    { name = "CLEARS", pat = "for%s+%a+=1,#j" },
    { name = "JMP", pat = "r%s*=%s*j" },
    { name = "JFALSE", pat = "if%s+not%s+t%s+then%s*r%s*=%s*O" },
    { name = "JTRUE", pat = "if%s+t%s+then%s*r%s*=%s*O" },
    { name = "CLOSURE", pat = "B%(" },
    { name = "RETURN", pat = "return%s+q%(t" },
    { name = "RETURN3", pat = "return%s+A%[j%],%s*A%[O%],%s*A%[b%]" },
    { name = "RETURN2", pat = "return%s+A%[j%],%s*A%[O%]" },
    { name = "RETURN1", pat = "return%s+A%[j%]" },
    { name = "RETURN0", pat = "return" },
    { name = "CALL0", pat = "t%(%)" },
    { name = "CALL1", pat = "t%(A%[b%[1%]%]%)" },
    { name = "CALL2", pat = "t%(A%[b%[1%]%],%s*A%[b%[2%]%]%)" },
    { name = "CALL3", pat = "t%(A%[b%[1%]%],%s*A%[b%[2%]%],%s*A%[b%[3%]%]%)" },
    { name = "CALL", pat = "t%(q%(X" },
    { name = "TAILCALL0", pat = "return%s+t%(%)" },
    { name = "TAILCALL1", pat = "return%s+t%(A%[O%[1%]%]%)" },
    { name = "TAILCALL2", pat = "return%s+t%(A%[O%[1%]%],%s*A%[O%[2%]%]%)" },
    { name = "TAILCALL3", pat = "return%s+t%(A%[O%[1%]%],%s*A%[O%[2%]%],%s*A%[O%[3%]%]%)" },
    { name = "TAILCALL", pat = "return%s+t%(q%(X" },
    { name = "ARGS", pat = "%(O%)" },
    { name = "EXPAND", pat = "%(O%+E%)" },
    { name = "VARARG", pat = "A%[j%]%s*=%s*F" },
    { name = "FORPREP", pat = "initial%s+value%s+must%s+be%s+a%s+number" },
}

function VmDisassembler:detect(content)
    return content:find("return tables%[root%]") ~= nil or content:find("unknown VM opcode") ~= nil
end

function VmDisassembler:extractMetadata(content)
    local meta = {}
    local codeKey, constKey = content:match("local %a+,%a+%s*=%s*%a+%[(%d+)%],%s*%a+%[(%d+)%]")
    meta.code = tonumber(codeKey)
    meta.constants = tonumber(constKey)
    meta.children = tonumber(content:match("%a+%[(%d+)%]%[%a+%]"))
    meta.captures = tonumber(content:match("#%a+%[(%d+)%]"))

    local s1, s2, s3, s4 = content:match("%a+,%a+,%a+,%a+%s*=%s*%a+%[(%d+)%],%s*%a+%[(%d+)%],%s*%a+%[(%d+)%],%s*%a+%[(%d+)%]")
    if s1 and s2 and s3 and s4 then
        meta.operandSlots = { tonumber(s1), tonumber(s2), tonumber(s3), tonumber(s4) }
    else
        meta.operandSlots = { 2, 3, 4, 5 }
    end

    return meta
end

function VmDisassembler:extractOpcodes(content, meta)
    local parser = Parser:new({ LuaVersion = Enums.LuaVersion.Lua51 })
    local unparser = Unparser:new({ LuaVersion = Enums.LuaVersion.Lua51 })
    local ast = parser:parse(content, Source.new("vm_runtime.lua", content))

    local opcodes = {}

    visitast(ast, function(node, data)
        if node.kind == Ast.AstKind.IfStatement then
            local cond = node.condition
            if cond and cond.kind == Ast.AstKind.EqualsExpression then
                local idNode = (cond.lhs.kind == Ast.AstKind.NumberExpression and cond.lhs)
                            or (cond.rhs.kind == Ast.AstKind.NumberExpression and cond.rhs)
                if idNode then
                    local id = idNode.value
                    local bodyCode = unparser:unparseBlock(node.body, 0)

                    for _, sig in ipairs(semanticSignatures) do
                        if bodyCode:find(sig.pat) then
                            opcodes[id] = sig.name
                            break
                        end
                    end
                    if not opcodes[id] then
                        opcodes[id] = "OP_" .. id
                    end
                end
            end
        end
    end)

    return opcodes
end

function VmDisassembler:disassembleProto(proto, protoId, opcodes, meta, indent)
    indent = indent or ""
    local code = meta.code and proto[meta.code] or {}
    local constants = meta.constants and proto[meta.constants] or {}
    local children = meta.children and proto[meta.children] or {}

    local lines = {}
    table.insert(lines, indent .. string.format("=== Prototype %s (Instructions: %d, Constants: %d, Children: %d) ===", tostring(protoId), #code, #constants, #children))

    if #constants > 0 then
        table.insert(lines, indent .. "  Constants:")
        for i, c in ipairs(constants) do
            table.insert(lines, indent .. string.format("    [%d] %s", i, type(c) == "string" and string.format("%q", c) or tostring(c)))
        end
    end

    table.insert(lines, indent .. "  Bytecode:")
    local slots = meta.operandSlots
    for pc, inst in ipairs(code) do
        local opcodeId = inst[1]
        local opName = opcodes[opcodeId] or ("OP_" .. tostring(opcodeId))

        local a = inst[slots[1]]
        local b = inst[slots[2]]
        local c = inst[slots[3]]
        local d = inst[slots[4]]

        local extra = ""
        if (opName == "LOAD") and b and constants[b] ~= nil then
            extra = " ; " .. (type(constants[b]) == "string" and string.format("%q", constants[b]) or tostring(constants[b]))
        elseif (opName == "GLOBAL" or opName == "SETGLOBAL") and (b or a) then
            local kidx = (opName == "GLOBAL") and b or a
            if constants[kidx] ~= nil then
                extra = " ; " .. tostring(constants[kidx])
            end
        elseif (opName == "JMP" or opName == "JFALSE" or opName == "JTRUE") and (a or b) then
            local target = (opName == "JMP") and a or b
            extra = string.format(" -> PC %s", tostring(target))
        elseif (opName == "CLOSURE") and b then
            extra = string.format(" ; Child Proto %s", tostring(b))
        end

        local operands = {}
        if a ~= nil then table.insert(operands, "R" .. tostring(a)) end
        if b ~= nil then table.insert(operands, (type(b) == "table" and "tbl" or tostring(b))) end
        if c ~= nil then table.insert(operands, (type(c) == "table" and "tbl" or tostring(c))) end
        if d ~= nil then table.insert(operands, (type(d) == "table" and "tbl" or tostring(d))) end

        table.insert(lines, indent .. string.format("    [%03d] %-12s %-22s%s", pc, opName, table.concat(operands, ", "), extra))
    end

    for i, child in ipairs(children) do
        table.insert(lines, "")
        local childLines = self:disassembleProto(child, tostring(protoId) .. "." .. tostring(i), opcodes, meta, indent .. "  ")
        for _, l in ipairs(childLines) do
            table.insert(lines, l)
        end
    end

    return lines
end

function VmDisassembler:disassemble(content)
    local rebuildDef = content:match("(local function %w+%(%w+,%w+,%w+%).-return %w+%[%w+%]end)")
    local shardsCall = content:match("(%w+%({{{.-%)[^%)]*)")
    if not rebuildDef or not shardsCall then
        return nil, "Failed to locate VM rebuild data"
    end

    local meta = self:extractMetadata(content)
    local opcodes = self:extractOpcodes(content, meta)

    local runnerCode = rebuildDef .. "\nreturn " .. shardsCall .. "\n"
    local fn, loadErr = loadstring(runnerCode)
    if not fn then
        return nil, "Failed to compile rebuild routine: " .. tostring(loadErr)
    end

    local ok, root = pcall(fn)
    if not ok or type(root) ~= "table" then
        return nil, "Failed to reconstruct root prototype"
    end

    local mainProto = root[1] or root
    local lines = self:disassembleProto(mainProto, "0 (Main)", opcodes, meta, "")
    return table.concat(lines, "\n")
end

return VmDisassembler
