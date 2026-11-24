
local Ast = require("prometheus.ast")
local visitast = require("prometheus.visitast")
local AstKind = Ast.AstKind

local ConstantArray = {}

local function statRefsVar(stat, varName, varSymbol)
    local refs = false
    local visited = {}
    local function walk(node)
        if not node or type(node) ~= "table" or refs or visited[node] then return end
        visited[node] = true
        if node.kind == AstKind.VariableExpression then
            if node.name == varName or (node.symbol and node.symbol == varSymbol) then
                refs = true
                return
            end
        end
        for k, v in pairs(node) do
            if type(v) == "table" and k ~= "scope" and k ~= "parent" and k ~= "symbol" and k ~= "symbols" and k ~= "parentScope" then
                walk(v)
            end
        end
    end
    walk(stat)
    return refs
end

local function findSetup(stats)
    local arrVarName, arrStatIdx, arrSymbol
    local wrapperName, wrapperOffset, wrapperStatIdx, wrapperSymbol
    local setupIndices = {}

    for i = 1, math.min(#stats, 15) do
        local stat = stats[i]
        if stat.kind == AstKind.LocalVariableDeclaration and stat.symbols and stat.symbols[1] and stat.expressions and stat.expressions[1] and stat.expressions[1].kind == AstKind.TableConstructorExpression then
            arrSymbol = stat.symbols[1]
            arrVarName = arrSymbol.name
            arrStatIdx = i
            setupIndices[i] = true
            break
        end
    end

    if not arrSymbol then
        return nil
    end

    for i = 1, math.min(#stats, 30) do
        local stat = stats[i]
        if stat.kind == AstKind.LocalFunctionDeclaration then
            local retStat = stat.body.statements[1]
            if retStat and retStat.kind == AstKind.ReturnStatement and retStat.args and retStat.args[1] then
                local retArg = retStat.args[1]
                if retArg.kind == AstKind.IndexExpression and retArg.base and retArg.base.kind == AstKind.VariableExpression then
                    local baseName = retArg.base.name
                    if baseName == arrVarName or (retArg.base.symbol and retArg.base.symbol == arrSymbol) then
                        local idxExpr = retArg.index
                        local offset = 0
                        if idxExpr.kind == AstKind.AddExpression and idxExpr.rhs.kind == AstKind.NumberExpression then
                            offset = idxExpr.rhs.value
                        elseif idxExpr.kind == AstKind.SubExpression and idxExpr.rhs.kind == AstKind.NumberExpression then
                            offset = -idxExpr.rhs.value
                        elseif idxExpr.kind == AstKind.NumberExpression then
                            offset = idxExpr.value
                        end
                        wrapperSymbol = stat.symbol
                        wrapperName = wrapperSymbol.name
                        wrapperOffset = offset
                        wrapperStatIdx = i
                        setupIndices[i] = true
                    end
                end
            end
        end

        if i ~= arrStatIdx and i <= (wrapperStatIdx or 15) + 5 then
            if statRefsVar(stat, arrVarName, arrSymbol) then
                setupIndices[i] = true
            end
        end
    end

    return arrVarName, arrStatIdx, wrapperName, wrapperOffset, wrapperStatIdx, setupIndices, arrSymbol, wrapperSymbol
end

function ConstantArray:apply(ast, unparser)
    local stats = ast.body.statements
    local arrVarName, arrStatIdx, wrapperName, wrapperOffset, wrapperStatIdx, setupIndices, arrSymbol, wrapperSymbol = findSetup(stats)

    if not arrVarName or not wrapperName then
        return ast, 0
    end

    local setupCode = ""
    for i = 1, #stats do
        if setupIndices[i] then
            setupCode = setupCode .. unparser:unparseStatement(stats[i], 0) .. "\n"
        end
    end
    setupCode = setupCode .. "return " .. tostring(arrVarName) .. "\n"

    local env = {
        ipairs = ipairs,
        pairs = pairs,
        table = { concat = table.concat, insert = table.insert, remove = table.remove },
        string = { sub = string.sub, char = string.char, len = string.len, byte = string.byte },
        math = { floor = math.floor },
        type = type,
    }

    local fn, loadErr = loadstring(setupCode)
    if not fn then
        return ast, 0
    end
    setfenv(fn, env)

    local ok, evaluatedArr = pcall(fn)
    if not ok or type(evaluatedArr) ~= "table" then
        return ast, 0
    end

    local inlinedCount = 0

    ast = visitast(ast, nil, function(node, data)
        if node.kind == AstKind.FunctionCallExpression then
            local isWrapperCall = false
            if node.base.kind == AstKind.VariableExpression then
                if node.base.symbol == wrapperSymbol or (node.base.getName and node.base:getName() == wrapperName) or node.base.name == wrapperName then
                    isWrapperCall = true
                end
            end

            if isWrapperCall and node.args and node.args[1] and node.args[1].kind == AstKind.NumberExpression then
                local realIdx = node.args[1].value + wrapperOffset
                local val = evaluatedArr[realIdx]
                if val ~= nil then
                    inlinedCount = inlinedCount + 1
                    if type(val) == "string" then
                        return Ast.StringExpression(val)
                    elseif type(val) == "number" then
                        return Ast.NumberExpression(val)
                    elseif type(val) == "boolean" then
                        return Ast.BooleanExpression(val)
                    end
                end
            end
        end

        if node.kind == AstKind.IndexExpression then
            local isArrAccess = false
            if node.base.kind == AstKind.VariableExpression then
                if node.base.symbol == arrSymbol or (node.base.getName and node.base:getName() == arrVarName) or node.base.name == arrVarName then
                    isArrAccess = true
                end
            end

            if isArrAccess and node.index.kind == AstKind.NumberExpression then
                local val = evaluatedArr[node.index.value]
                if val ~= nil then
                    inlinedCount = inlinedCount + 1
                    if type(val) == "string" then
                        return Ast.StringExpression(val)
                    elseif type(val) == "number" then
                        return Ast.NumberExpression(val)
                    elseif type(val) == "boolean" then
                        return Ast.BooleanExpression(val)
                    end
                end
            end
        end
    end)

    local newStats = {}
    for i = 1, #stats do
        if not setupIndices[i] then
            table.insert(newStats, stats[i])
        end
    end
    ast.body.statements = newStats

    return ast, inlinedCount, evaluatedArr
end

return ConstantArray
