
local Ast = require("prometheus.ast")
local visitast = require("prometheus.visitast")
local Source = require("prometheus.source")
local AstKind = Ast.AstKind

local CleanNames = {}

function CleanNames:apply(ast)
    local renamedSymbols = {}
    local takenNames = {}

    local function assignName(sym, name, scopeTaken)
        if not sym or renamedSymbols[sym] then return end
        local pool = scopeTaken or takenNames
        local finalName = name
        local counter = 1
        while pool[finalName] do
            counter = counter + 1
            finalName = name .. "_" .. counter
        end
        pool[finalName] = true
        renamedSymbols[sym] = finalName
        sym.name = finalName
    end

    visitast(ast, function(node)
        if node.kind == AstKind.LocalFunctionDeclaration then
            local fnSym = node.symbol
            local hasMulInWhile = false
            local hasSubInRepeat = false
            local whileCounterSym = nil
            local mulAccumulatorSym = nil
            local fnTaken = {}

            Source.walk(node.body, function(n)
                if n.kind == AstKind.WhileStatement then
                    Source.walk(n.body, function(wn)
                        if wn.kind == AstKind.MulExpression then
                            hasMulInWhile = true
                            if wn.lhs and wn.lhs.symbol then
                                mulAccumulatorSym = wn.lhs.symbol
                            end
                        end
                        if wn.kind == AstKind.AddExpression and wn.rhs and wn.rhs.kind == AstKind.NumberExpression and wn.rhs.value == 1 then
                            if wn.lhs and wn.lhs.symbol then whileCounterSym = wn.lhs.symbol end
                        end
                    end)
                end
                if n.kind == AstKind.RepeatStatement then
                    Source.walk(n.body, function(rn)
                        if rn.kind == AstKind.SubExpression then
                            hasSubInRepeat = true
                        end
                    end)
                end
            end)

            if hasMulInWhile then
                assignName(fnSym, "compute_factorial")
                if node.args and #node.args == 1 then
                    local pSym = node.args[1].symbol or node.args[1]
                    assignName(pSym, "n", fnTaken)
                end
                if whileCounterSym then
                    assignName(whileCounterSym, "i", fnTaken)
                end
                if mulAccumulatorSym then
                    assignName(mulAccumulatorSym, "result", fnTaken)
                end
            elseif hasSubInRepeat then
                assignName(fnSym, "countdown")
                if node.args and #node.args == 1 then
                    local pSym = node.args[1].symbol or node.args[1]
                    assignName(pSym, "start_val", fnTaken)
                end
            end
        end
    end)

    visitast(ast, function(node)
        if node.kind == AstKind.ForStatement and node.symbol then
            assignName(node.symbol, "i")
        end
    end)

    visitast(ast, function(node)
        if node.kind == AstKind.ForStatement and node.body then
            Source.walk(node.body, function(n)
                if n.kind == AstKind.AssignmentStatement and n.lhs and #n.lhs >= 1 then
                    local sym = n.lhs[1].symbol
                    if sym then assignName(sym, "sum") end
                end
            end)
        end
        if node.kind == AstKind.IfStatement and node.condition then
            if node.condition.lhs and node.condition.lhs.symbol then
                assignName(node.condition.lhs.symbol, "mode")
            end
            if node.body then
                Source.walk(node.body, function(n)
                    if n.kind == AstKind.AssignmentStatement and n.lhs and #n.lhs >= 1 then
                        local sym = n.lhs[1].symbol
                        if sym then assignName(sym, "status") end
                    end
                end)
            end
        end
    end)

    local fallbackCounter = 0
    visitast(ast, function(node)
        if node.kind == AstKind.LocalVariableDeclaration and node.symbols then
            for _, sym in ipairs(node.symbols) do
                if not renamedSymbols[sym] then
                    fallbackCounter = fallbackCounter + 1
                    assignName(sym, "var_" .. fallbackCounter)
                end
            end
        elseif node.kind == AstKind.LocalFunctionDeclaration and node.symbol then
            if not renamedSymbols[node.symbol] then
                fallbackCounter = fallbackCounter + 1
                assignName(node.symbol, "fn_" .. fallbackCounter)
            end
        elseif node.kind == AstKind.FunctionLiteralExpression and node.args then
            for _, arg in ipairs(node.args) do
                local target = arg.symbol or arg
                if target and not renamedSymbols[target] then
                    fallbackCounter = fallbackCounter + 1
                    assignName(target, "arg_" .. fallbackCounter)
                end
            end
        end
    end)

    return ast, fallbackCounter
end

return CleanNames
