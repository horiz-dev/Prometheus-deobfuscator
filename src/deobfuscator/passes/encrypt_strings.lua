
local Ast = require("prometheus.ast")
local visitast = require("prometheus.visitast")
local AstKind = Ast.AstKind

local EncryptStrings = {}

function EncryptStrings:apply(ast, unparser)
    local stats = ast.body.statements
    if #stats < 2 then
        return ast, 0
    end

    local stat1 = stats[1]
    local stat2 = stats[2]

    if stat1.kind ~= AstKind.LocalVariableDeclaration or not stat1.symbols or #stat1.symbols ~= 2 then
        return ast, 0
    end
    if stat2.kind ~= AstKind.DoStatement then
        return ast, 0
    end

    local decryptFnName = stat1.symbols[1].name
    local stringsTableName = stat1.symbols[2].name

    local setupCode = unparser:unparseStatement(stat1, 0) .. "\n"
                   .. unparser:unparseStatement(stat2, 0) .. "\n"
                   .. "return " .. decryptFnName .. ", " .. stringsTableName .. "\n"

    local env = {
        setmetatable = setmetatable,
        table = table,
        string = string,
        math = math,
        type = type,
    }

    local fn, loadErr = loadstring(setupCode)
    if not fn then
        return ast, 0
    end
    setfenv(fn, env)

    local ok, decryptFn, stringsTable = pcall(fn)
    if not ok or type(decryptFn) ~= "function" or type(stringsTable) ~= "table" then
        return ast, 0
    end

    local inlinedCount = 0
    local decryptedList = {}

    ast = visitast(ast, nil, function(node, data)
        if node.kind == AstKind.IndexExpression then
            local index = node.index
            if index.kind == AstKind.FunctionCallExpression and index.args and #index.args == 2 then
                local arg1 = index.args[1]
                local arg2 = index.args[2]
                if arg1.kind == AstKind.StringExpression and arg2.kind == AstKind.NumberExpression then
                    local okCall, key = pcall(decryptFn, arg1.value, arg2.value)
                    if okCall and key then
                        local decrypted = stringsTable[key]
                        if decrypted then
                            inlinedCount = inlinedCount + 1
                            table.insert(decryptedList, decrypted)
                            return Ast.StringExpression(decrypted)
                        end
                    end
                end
            end
        end
    end)

    if inlinedCount > 0 then
        table.remove(ast.body.statements, 1)
        table.remove(ast.body.statements, 1)
    end

    return ast, inlinedCount, decryptedList
end

return EncryptStrings
