
local Ast = require("prometheus.ast")
local AstKind = Ast.AstKind

local Unwrap = {}

function Unwrap:apply(ast)
    local unwrappedCount = 0
    local stats = ast.body.statements
    while #stats >= 1 do
        local stat = stats[#stats]
        local callExpr
        if stat.kind == AstKind.FunctionCallStatement then
            callExpr = stat.base
        elseif stat.kind == AstKind.ReturnStatement and stat.args and #stat.args == 1 then
            callExpr = stat.args[1]
        end

        if callExpr and callExpr.kind == AstKind.FunctionCallExpression and callExpr.base.kind == AstKind.FunctionLiteralExpression then
            local fnLit = callExpr.base
            local innerStats = fnLit.body.statements
            local newStats = {}
            for i = 1, #stats - 1 do
                table.insert(newStats, stats[i])
            end

            if fnLit.args and #fnLit.args > 0 and callExpr.args and #callExpr.args > 0 then
                local paramSymbols = {}
                for _, arg in ipairs(fnLit.args) do
                    if arg.kind == "LocalSymbol" then
                        table.insert(paramSymbols, arg)
                    elseif arg.kind == AstKind.VariableExpression and arg.symbol then
                        table.insert(paramSymbols, arg.symbol)
                    end
                end
                if #paramSymbols > 0 then
                    table.insert(newStats, Ast.LocalVariableDeclaration(paramSymbols, callExpr.args))
                end
            end

            for _, s in ipairs(innerStats) do
                table.insert(newStats, s)
            end

            ast.body.statements = newStats
            stats = ast.body.statements
            unwrappedCount = unwrappedCount + 1
        else
            break
        end
    end
    return ast, unwrappedCount
end

return Unwrap
