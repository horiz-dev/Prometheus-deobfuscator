
local Ast = require("prometheus.ast")
local visitast = require("prometheus.visitast")
local AstKind = Ast.AstKind

local ConstantFolding = {}

function ConstantFolding:apply(ast)
    local totalFolded = 0
    local changed = true

    while changed do
        changed = false
        ast = visitast(ast, nil, function(node, data)
            if node.kind == AstKind.AddExpression and node.lhs.kind == AstKind.NumberExpression and node.rhs.kind == AstKind.NumberExpression then
                changed = true
                totalFolded = totalFolded + 1
                return Ast.NumberExpression(node.lhs.value + node.rhs.value)
            elseif node.kind == AstKind.SubExpression and node.lhs.kind == AstKind.NumberExpression and node.rhs.kind == AstKind.NumberExpression then
                changed = true
                totalFolded = totalFolded + 1
                return Ast.NumberExpression(node.lhs.value - node.rhs.value)
            elseif node.kind == AstKind.MulExpression and node.lhs.kind == AstKind.NumberExpression and node.rhs.kind == AstKind.NumberExpression then
                changed = true
                totalFolded = totalFolded + 1
                return Ast.NumberExpression(node.lhs.value * node.rhs.value)
            elseif node.kind == AstKind.DivExpression and node.lhs.kind == AstKind.NumberExpression and node.rhs.kind == AstKind.NumberExpression and node.rhs.value ~= 0 then
                changed = true
                totalFolded = totalFolded + 1
                return Ast.NumberExpression(node.lhs.value / node.rhs.value)
            elseif node.kind == AstKind.ModExpression and node.lhs.kind == AstKind.NumberExpression and node.rhs.kind == AstKind.NumberExpression and node.rhs.value ~= 0 then
                changed = true
                totalFolded = totalFolded + 1
                return Ast.NumberExpression(node.lhs.value % node.rhs.value)
            elseif node.kind == AstKind.PowExpression and node.lhs.kind == AstKind.NumberExpression and node.rhs.kind == AstKind.NumberExpression then
                changed = true
                totalFolded = totalFolded + 1
                return Ast.NumberExpression(node.lhs.value ^ node.rhs.value)
            elseif node.kind == AstKind.NegateExpression and node.rhs.kind == AstKind.NumberExpression then
                changed = true
                totalFolded = totalFolded + 1
                return Ast.NumberExpression(-node.rhs.value)
            elseif node.kind == AstKind.StrCatExpression and node.lhs.kind == AstKind.StringExpression and node.rhs.kind == AstKind.StringExpression then
                changed = true
                totalFolded = totalFolded + 1
                return Ast.StringExpression(node.lhs.value .. node.rhs.value)
            end
        end)
    end

    return ast, totalFolded
end

return ConstantFolding
