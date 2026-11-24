local Ast = require("prometheus.ast")
local visitast = require("prometheus.visitast")
local AstKind = Ast.AstKind

local AntiTamper = {}

local function isInfiniteLoop(stat)
    if stat.kind == AstKind.WhileStatement then
        local cond = stat.condition
        if cond.kind == AstKind.BooleanExpression and cond.value == true then
            local bodyStats = stat.body.statements
            if #bodyStats == 0 then
                return true
            end
        end
    end
    return false
end

function AntiTamper:apply(ast)
    local strippedCount = 0

    local function filterBlock(block)
        local filtered = {}
        for _, stat in ipairs(block.statements) do
            local drop = false

            if stat.kind == AstKind.DoStatement and stat.body and stat.body.statements then
                local inner = stat.body.statements
                for _, s in ipairs(inner) do
                    if isInfiniteLoop(s) then
                        drop = true
                        break
                    end
                    if s.kind == AstKind.ForStatement or s.kind == AstKind.ForInStatement then
                        if s.body and s.body.statements then
                            for _, nested in ipairs(s.body.statements) do
                                if isInfiniteLoop(nested) or (nested.kind == AstKind.IfStatement and nested.elsebody and #nested.elsebody.statements > 0 and isInfiniteLoop(nested.elsebody.statements[1])) then
                                    drop = true
                                    break
                                end
                            end
                        end
                    end
                end
            end

            if isInfiniteLoop(stat) then
                drop = true
            end

            if drop then
                strippedCount = strippedCount + 1
            else
                table.insert(filtered, stat)
            end
        end
        block.statements = filtered
    end

    visitast(ast, function(node, data)
        if node.kind == AstKind.Block then
            filterBlock(node)
        end
    end)

    return ast, strippedCount
end

return AntiTamper
