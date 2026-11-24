
local Ast = require("prometheus.ast")
local Source = require("prometheus.source")
local AstKind = Ast.AstKind

local CffDeflatten = {}

local function routeId(block, id, posVar)
    if not block or not block.statements then return block end
    if type(id) == "table" and id.value then
        id = id.value
    end
    if type(id) ~= "number" then
        return block
    end
    if #block.statements == 1 and block.statements[1].kind == AstKind.IfStatement then
        local ifStat = block.statements[1]
        local ifCond = ifStat.condition
        local isPosCond = false
        local isLessThan, isGreaterThan, bound = false, false, 0

        if ifCond.kind == AstKind.LessThanExpression then
            if (ifCond.lhs.getName and ifCond.lhs:getName() or ifCond.lhs.name) == posVar and ifCond.rhs.kind == AstKind.NumberExpression then
                isPosCond = true; isLessThan = true; bound = ifCond.rhs.value
            elseif (ifCond.rhs.getName and ifCond.rhs:getName() or ifCond.rhs.name) == posVar and ifCond.lhs.kind == AstKind.NumberExpression then
                isPosCond = true; isGreaterThan = true; bound = ifCond.lhs.value
            end
        elseif ifCond.kind == AstKind.GreaterThanExpression then
            if (ifCond.lhs.getName and ifCond.lhs:getName() or ifCond.lhs.name) == posVar and ifCond.rhs.kind == AstKind.NumberExpression then
                isPosCond = true; isGreaterThan = true; bound = ifCond.rhs.value
            elseif (ifCond.rhs.getName and ifCond.rhs:getName() or ifCond.rhs.name) == posVar and ifCond.lhs.kind == AstKind.NumberExpression then
                isPosCond = true; isLessThan = true; bound = ifCond.lhs.value
            end
        end

        if isPosCond then
            local condTrue = (isLessThan and (id < bound)) or (isGreaterThan and (id > bound))
            if condTrue then
                return routeId(ifStat.body, id, posVar)
            end
            for _, eif in ipairs(ifStat.elseifs or {}) do
                local ec = eif.condition
                local eLessThan, eGreaterThan, eBound = false, false, 0
                if ec.kind == AstKind.LessThanExpression then
                    if (ec.lhs.getName and ec.lhs:getName() or ec.lhs.name) == posVar and ec.rhs.kind == AstKind.NumberExpression then
                        eLessThan = true; eBound = ec.rhs.value
                    elseif (ec.rhs.getName and ec.rhs:getName() or ec.rhs.name) == posVar and ec.lhs.kind == AstKind.NumberExpression then
                        eGreaterThan = true; eBound = ec.lhs.value
                    end
                elseif ec.kind == AstKind.GreaterThanExpression then
                    if (ec.lhs.getName and ec.lhs:getName() or ec.lhs.name) == posVar and ec.rhs.kind == AstKind.NumberExpression then
                        eGreaterThan = true; eBound = ec.rhs.value
                    elseif (ec.rhs.getName and ec.rhs:getName() or ec.rhs.name) == posVar and ec.lhs.kind == AstKind.NumberExpression then
                        eLessThan = true; eBound = ec.lhs.value
                    end
                end
                if (eLessThan and (id < eBound)) or (eGreaterThan and (id > eBound)) then
                    return routeId(eif.body, id, posVar)
                end
            end
            if ifStat.elsebody then
                return routeId(ifStat.elsebody, id, posVar)
            end
        end
    end
    return block
end

local function getVarName(node)
    if not node then return nil end
    if type(node.getName) == "function" then
        local ok, n = pcall(node.getName, node)
        if ok and n then return n end
    end
    if node.symbol and node.symbol.name then return node.symbol.name end
    return node.name
end

local function parseTerminator(block, posVar)
    local stats = block.statements or {}
    local nonTermStats = {}
    local termType = "exit"
    local jumpTarget = nil
    local branchCond = nil
    local trueTarget = nil
    local falseTarget = nil

    for idx, stat in ipairs(stats) do
        if stat.kind == AstKind.AssignmentStatement and stat.lhs and #stat.lhs >= 1 then
            local nonPosLhs, nonPosRhs = {}, {}

            for i, target in ipairs(stat.lhs) do
                local name = getVarName(target)
                local rhsVal = stat.rhs[i]
                if name == posVar then
                    if rhsVal.kind == AstKind.NilExpression then
                        termType = "exit"
                    elseif rhsVal.kind == AstKind.NumberExpression then
                        termType = "jump"
                        jumpTarget = rhsVal.value
                    elseif rhsVal.kind == AstKind.VariableExpression then
                        termType = "jump"
                        jumpTarget = rhsVal
                    elseif rhsVal.kind == AstKind.OrExpression then
                        local lhsOr = rhsVal.lhs
                        local rhsOr = rhsVal.rhs
                        local fVal = rhsOr.kind == AstKind.NumberExpression and rhsOr.value or rhsOr
                        if lhsOr.kind == AstKind.AndExpression then
                            termType = "branch"
                            branchCond = lhsOr.lhs
                            trueTarget = lhsOr.rhs.kind == AstKind.NumberExpression and lhsOr.rhs.value or lhsOr.rhs
                            falseTarget = fVal
                        elseif getVarName(lhsOr) == posVar then
                            termType = "branch"
                            falseTarget = fVal
                        else
                            termType = "branch"
                            falseTarget = fVal
                        end
                    elseif rhsVal.kind == AstKind.AndExpression then
                        termType = "branch"
                        branchCond = rhsVal.lhs
                        trueTarget = rhsVal.rhs.kind == AstKind.NumberExpression and rhsVal.rhs.value or rhsVal.rhs
                    end
                else
                    table.insert(nonPosLhs, target)
                    table.insert(nonPosRhs, rhsVal)
                end
            end

            if #nonPosLhs > 0 then
                local allNil = true
                for _, r in ipairs(nonPosRhs) do
                    if r.kind ~= AstKind.NilExpression then allNil = false break end
                end
                if not allNil then
                    table.insert(nonTermStats, Ast.AssignmentStatement(nonPosLhs, nonPosRhs))
                end
            end
        else
            local isCleanup = false
            if stat.kind == AstKind.AssignmentStatement and stat.rhs and #stat.rhs >= 1 then
                local allNil = true
                for _, r in ipairs(stat.rhs) do
                    if r.kind ~= AstKind.NilExpression then allNil = false break end
                end
                if allNil then
                    isCleanup = true
                end
            end
            if not isCleanup then
                table.insert(nonTermStats, stat)
            end
        end
    end

    local function resolveTarget(target)
        if not target then return nil end
        if type(target) == "number" then return target end
        if target.kind == AstKind.NumberExpression then return target.value end
        if target.kind == AstKind.VariableExpression then
            local tName = getVarName(target)
            for i = #nonTermStats, 1, -1 do
                local s = nonTermStats[i]
                if s.kind == AstKind.AssignmentStatement and #s.lhs == 1 then
                    if getVarName(s.lhs[1]) == tName then
                        if s.rhs[1].kind == AstKind.NumberExpression then
                            local val = s.rhs[1].value
                            table.remove(nonTermStats, i)
                            return val
                        end
                    end
                end
            end
        end
        return nil
    end

    if termType == "jump" and type(jumpTarget) ~= "number" then
        jumpTarget = resolveTarget(jumpTarget)
        if not jumpTarget then termType = "exit" end
    end

    if termType == "branch" then
        trueTarget = resolveTarget(trueTarget)
        falseTarget = resolveTarget(falseTarget)
        if not trueTarget or not falseTarget then
            termType = "exit"
        end
    end

    if branchCond and branchCond.kind == AstKind.VariableExpression then
        local condName = getVarName(branchCond)
        for i = #nonTermStats, 1, -1 do
            local s = nonTermStats[i]
            if s.kind == AstKind.AssignmentStatement and #s.lhs == 1 then
                local tName = getVarName(s.lhs[1])
                if tName == condName then
                    branchCond = s.rhs[1]
                    table.remove(nonTermStats, i)
                    break
                end
            end
        end
    end

    return {
        statements = nonTermStats,
        termType = termType,
        jumpTarget = jumpTarget,
        branchCond = branchCond,
        trueTarget = trueTarget,
        falseTarget = falseTarget,
    }
end

local function canReach(fromId, targetId, blocks, visited)
    if fromId == targetId then return true end
    visited = visited or {}
    if visited[fromId] or not blocks[fromId] then return false end
    visited[fromId] = true
    local b = blocks[fromId]
    if b.termType == "jump" and b.jumpTarget then
        return canReach(b.jumpTarget, targetId, blocks, visited)
    elseif b.termType == "branch" then
        return (b.trueTarget and canReach(b.trueTarget, targetId, blocks, visited)) or
               (b.falseTarget and canReach(b.falseTarget, targetId, blocks, visited))
    end
    return false
end

local function findBranchMerge(trueTarget, falseTarget, blocks, stopId)
    if not trueTarget or not falseTarget then return stopId end
    if trueTarget == falseTarget then return trueTarget end

    if blocks[trueTarget] and blocks[trueTarget].termType == "jump" and blocks[trueTarget].jumpTarget == falseTarget then
        return falseTarget
    end
    if blocks[falseTarget] and blocks[falseTarget].termType == "jump" and blocks[falseTarget].jumpTarget == trueTarget then
        return trueTarget
    end

    local falseReachable = {}
    local q = { falseTarget }
    while #q > 0 do
        local u = table.remove(q, 1)
        if u and not falseReachable[u] and u ~= stopId and blocks[u] then
            falseReachable[u] = true
            local b = blocks[u]
            if b.termType == "jump" and b.jumpTarget then
                table.insert(q, b.jumpTarget)
            elseif b.termType == "branch" then
                if b.trueTarget then table.insert(q, b.trueTarget) end
                if b.falseTarget then table.insert(q, b.falseTarget) end
            end
        end
    end

    local trueVisited = {}
    local tq = { trueTarget }
    while #tq > 0 do
        local u = table.remove(tq, 1)
        if u and not trueVisited[u] and u ~= stopId and blocks[u] then
            if falseReachable[u] then
                return u
            end
            trueVisited[u] = true
            local b = blocks[u]
            if b.termType == "jump" and b.jumpTarget then
                table.insert(tq, b.jumpTarget)
            elseif b.termType == "branch" then
                if b.trueTarget then table.insert(tq, b.trueTarget) end
                if b.falseTarget then table.insert(tq, b.falseTarget) end
            end
        end
    end

    return stopId
end

local function structureRegion(currentId, stopId, blocks, regionVisited, statsRecovered, activeHeaders, depth)
    depth = (depth or 0) + 1
    if depth > 40 then return {} end

    local stats = {}
    regionVisited = regionVisited or {}
    activeHeaders = activeHeaders or {}

    while currentId and currentId ~= stopId do
        if regionVisited[currentId] or activeHeaders[currentId] then
            break
        end
        regionVisited[currentId] = true

        local blk = blocks[currentId]
        if not blk then break end

        if blk.termType == "exit" then
            for _, s in ipairs(blk.statements) do
                table.insert(stats, s)
            end
            break
        elseif blk.termType == "jump" then
            for _, s in ipairs(blk.statements) do
                table.insert(stats, s)
            end
            if activeHeaders[blk.jumpTarget] then
                break
            end
            currentId = blk.jumpTarget
        elseif blk.termType == "branch" then
            if blk.falseTarget == currentId then
                local repeatBody = Ast.Block(blk.statements)
                table.insert(stats, Ast.RepeatStatement(blk.branchCond, repeatBody))
                statsRecovered.repeats = (statsRecovered.repeats or 0) + 1
                currentId = blk.trueTarget
            else
                local trueTarget = blk.trueTarget
                local falseTarget = blk.falseTarget
                local mergeId = findBranchMerge(trueTarget, falseTarget, blocks, stopId)

                if mergeId and mergeId ~= currentId and mergeId ~= stopId then
                    for _, s in ipairs(blk.statements) do
                        table.insert(stats, s)
                    end
                    local childVisitedT = {}
                    local childVisitedF = {}
                    local trueBody = structureRegion(trueTarget, mergeId, blocks, childVisitedT, statsRecovered, activeHeaders, depth)
                    local falseBody = structureRegion(falseTarget, mergeId, blocks, childVisitedF, statsRecovered, activeHeaders, depth)
                    table.insert(stats, Ast.IfStatement(blk.branchCond, Ast.Block(trueBody), {}, Ast.Block(falseBody)))
                    statsRecovered.ifs = (statsRecovered.ifs or 0) + 1
                    currentId = mergeId
                elseif trueTarget and not activeHeaders[currentId] and canReach(trueTarget, currentId, blocks) then
                    for _, s in ipairs(blk.statements) do
                        table.insert(stats, s)
                    end
                    local loopHeaders = {}
                    for k, v in pairs(activeHeaders) do loopHeaders[k] = v end
                    loopHeaders[currentId] = true
                    local loopBody = structureRegion(trueTarget, currentId, blocks, {}, statsRecovered, loopHeaders, depth)
                    for _, s in ipairs(blk.statements) do
                        table.insert(loopBody, s)
                    end
                    table.insert(stats, Ast.WhileStatement(Ast.Block(loopBody), blk.branchCond))
                    statsRecovered.whiles = (statsRecovered.whiles or 0) + 1
                    currentId = falseTarget
                elseif falseTarget and not activeHeaders[currentId] and canReach(falseTarget, currentId, blocks) then
                    for _, s in ipairs(blk.statements) do
                        table.insert(stats, s)
                    end
                    local loopHeaders = {}
                    for k, v in pairs(activeHeaders) do loopHeaders[k] = v end
                    loopHeaders[currentId] = true
                    local loopBody = structureRegion(falseTarget, currentId, blocks, {}, statsRecovered, loopHeaders, depth)
                    for _, s in ipairs(blk.statements) do
                        table.insert(loopBody, s)
                    end
                    table.insert(stats, Ast.WhileStatement(Ast.Block(loopBody), Ast.NotExpression(blk.branchCond)))
                    statsRecovered.whiles = (statsRecovered.whiles or 0) + 1
                    currentId = trueTarget
                else
                    for _, s in ipairs(blk.statements) do
                        table.insert(stats, s)
                    end
                    local childVisitedT = {}
                    local childVisitedF = {}
                    local trueBody = structureRegion(trueTarget, mergeId, blocks, childVisitedT, statsRecovered, activeHeaders, depth)
                    local falseBody = structureRegion(falseTarget, mergeId, blocks, childVisitedF, statsRecovered, activeHeaders, depth)
                    table.insert(stats, Ast.IfStatement(blk.branchCond, Ast.Block(trueBody), {}, Ast.Block(falseBody)))
                    statsRecovered.ifs = (statsRecovered.ifs or 0) + 1
                    currentId = mergeId
                end
            end
        else
            break
        end
    end

    return stats
end

function CffDeflatten:apply(ast)
    local recoveredCount = { ifs = 0, whiles = 0, repeats = 0 }
    local totalRecovered = 0
    local cffMeta = nil

    local stringPool = {}
    Source.walk(ast, function(node)
        if node.kind == AstKind.LocalVariableDeclaration and node.symbols and node.expressions and node.expressions[1] then
            local exp = node.expressions[1]
            if exp.kind == AstKind.TableConstructorExpression and exp.entries and #exp.entries > 0 then
                local allStrings = true
                local tbl = {}
                for idx, entry in ipairs(exp.entries) do
                    if entry.value and entry.value.kind == AstKind.StringExpression then
                        tbl[idx] = entry.value.value
                    else
                        allStrings = false
                        break
                    end
                end
                if allStrings then
                    local sym = node.symbols[1]
                    stringPool[sym] = tbl
                    local sName = (sym.getName and sym:getName()) or sym.name
                    if sName then stringPool[sName] = tbl end
                end
            end
        end
    end)

    local seenPool = {}
    local function inlineStringPool(node)
        if not node or type(node) ~= "table" or seenPool[node] then return end
        seenPool[node] = true
        if node.kind == AstKind.IndexExpression and node.base and node.index and node.index.kind == AstKind.NumberExpression then
            local sym = node.base.symbol or node.base
            local sName = (node.base.getName and node.base:getName()) or (node.base.symbol and node.base.symbol.name) or node.base.name
            local tbl = stringPool[sym] or (sName and stringPool[sName])
            if tbl and tbl[node.index.value] then
                node.kind = AstKind.StringExpression
                node.value = tbl[node.index.value]
                node.base = nil
                node.index = nil
            end
        end
        for k, v in pairs(node) do
            if type(v) == "table" and k ~= "parent" and k ~= "scope" then
                inlineStringPool(v)
            end
        end
    end

    if next(stringPool) then
        inlineStringPool(ast)
    end

    local startIds = {}
    Source.walk(ast, function(node)
        if node.kind == AstKind.FunctionCallExpression and node.args and #node.args >= 2 then
            if node.args[1].kind == AstKind.NumberExpression and node.args[2].kind == AstKind.TableConstructorExpression then
                table.insert(startIds, node.args[1].value)
            end
        end
    end)

    if #startIds == 0 then
        return ast, totalRecovered, recoveredCount
    end

    local cffLoops = {}
    Source.walk(ast, function(node)
        if node.kind == AstKind.WhileStatement then
            local cond = node.condition
            if cond and cond.kind == AstKind.VariableExpression then
                local pName = cond.getName and cond:getName() or cond.name
                local hasBranch = false
                Source.walk(node.body, function(inner)
                    if inner.kind == AstKind.IfStatement and inner.condition then
                        local c = inner.condition
                        if (c.lhs and c.lhs.kind == AstKind.VariableExpression and (c.lhs.getName and c.lhs:getName() or c.lhs.name) == pName)
                        or (c.rhs and c.rhs.kind == AstKind.VariableExpression and (c.rhs.getName and c.rhs:getName() or c.rhs.name) == pName) then
                            hasBranch = true
                        end
                    end
                end)
                if hasBranch then
                    table.insert(cffLoops, { whileNode = node, posVar = pName })
                end
            end
        end
    end)

    if #cffLoops == 0 then
        return ast, totalRecovered, recoveredCount
    end

    for loopIdx, loopInfo in ipairs(cffLoops) do
        local rootStartId = startIds[#startIds]
        local targetWhile = loopInfo.whileNode
        local posVar = loopInfo.posVar

        local blocks = {}
        local queue = {}
        for _, sid in ipairs(startIds) do
            table.insert(queue, sid)
        end
        local visited = {}

        while #queue > 0 do
            local id = table.remove(queue, 1)
            if not visited[id] then
                visited[id] = true
                local leaf = routeId(targetWhile.body, id, posVar)
                local parsed = parseTerminator(leaf, posVar)
                parsed.id = id
                blocks[id] = parsed

                if parsed.jumpTarget and not visited[parsed.jumpTarget] then
                    table.insert(queue, parsed.jumpTarget)
                end
                if parsed.trueTarget and not visited[parsed.trueTarget] then
                    table.insert(queue, parsed.trueTarget)
                end
                if parsed.falseTarget and not visited[parsed.falseTarget] then
                    table.insert(queue, parsed.falseTarget)
                end
            end
        end

        local containerFn = nil
        local containerRegSymbols = {}
        Source.walk(ast, function(n)
            if n.kind == AstKind.FunctionLiteralExpression and n.body and n.body.statements then
                for _, s in ipairs(n.body.statements) do
                    if s == targetWhile then
                        containerFn = n
                        for _, cs in ipairs(n.body.statements) do
                            if cs.kind == AstKind.LocalVariableDeclaration and cs.symbols then
                                for _, sym in ipairs(cs.symbols) do
                                    containerRegSymbols[sym] = true
                                end
                            end
                        end
                        return
                    end
                end
            end
        end)

        local argsSymbol = nil
        if containerFn and containerFn.args and containerFn.args[2] then
            local a2 = containerFn.args[2]
            argsSymbol = a2.symbol or (a2.kind == "LocalSymbol" and a2) or Ast.LocalSymbol(getVarName(a2) or "args")
        else
            argsSymbol = Ast.LocalSymbol("args")
        end

        local recoveredStats = structureRegion(rootStartId, nil, blocks, {}, recoveredCount)

        local function rebindSymbol(node, oldSym, newSym)
            if not node or type(node) ~= "table" then return end
            if (node.kind == AstKind.VariableExpression or node.kind == AstKind.AssignmentVariable) and node.symbol == oldSym then
                node.symbol = newSym
            end
            for k, v in pairs(node) do
                if type(v) == "table" and k ~= "parent" and k ~= "scope" then
                    rebindSymbol(v, oldSym, newSym)
                end
            end
        end

        local unpackSymbol = nil
        if containerFn and containerFn.body and containerFn.body.statements then
            for _, s in ipairs(containerFn.body.statements) do
                if s.kind == AstKind.ReturnStatement and s.args and #s.args >= 1 then
                    local retExpr = s.args[1]
                    if retExpr.kind == AstKind.FunctionCallExpression and retExpr.base and retExpr.base.kind == AstKind.VariableExpression then
                        unpackSymbol = retExpr.base.symbol
                    end
                end
            end
        end

        local envSymbol = containerFn and containerFn.args and containerFn.args[5] and (containerFn.args[5].symbol or containerFn.args[5])
        local callFunctionVarSymbol = nil
        local packSymbol = nil
        local tonumberSymbol = nil
        local errorSymbol = nil

        Source.walk(targetWhile.body, function(node)
            if node.kind == AstKind.FunctionCallExpression and node.args and #node.args >= 2 then
                if envSymbol and (node.args[2].symbol == envSymbol or node.args[2] == envSymbol) then
                    if node.base and node.base.symbol then
                        callFunctionVarSymbol = node.base.symbol
                    end
                end
            end
            if node.kind == AstKind.OrExpression and node.rhs and node.rhs.kind == AstKind.FunctionCallExpression then
                local call = node.rhs
                if call.args and #call.args >= 1 and call.args[1].kind == AstKind.StringExpression and call.args[1].value:find("'for'") then
                    if call.base and call.base.symbol then
                        errorSymbol = call.base.symbol
                    end
                    if node.lhs and node.lhs.kind == AstKind.FunctionCallExpression and node.lhs.base and node.lhs.base.symbol then
                        tonumberSymbol = node.lhs.base.symbol
                    end
                end
            end
        end)

        Source.walk(targetWhile.body, function(node)
            if node.kind == AstKind.FunctionCallExpression and node.args and #node.args == 1 then
                local a1 = node.args[1]
                if a1.kind == AstKind.FunctionCallExpression and a1.base and a1.base.symbol == callFunctionVarSymbol then
                    if node.base and node.base.symbol then
                        packSymbol = node.base.symbol
                    end
                end
            end
        end)

        cffMeta = {
            envSymbol = envSymbol,
            callFunctionVar = callFunctionVarSymbol,
            packVar = packSymbol,
            unpackVar = unpackSymbol,
            tonumberVar = tonumberSymbol,
            errorVar = errorSymbol,
            stringPool = stringPool,
        }

        local function inlineClosures(statsList)
            for _, stat in ipairs(statsList) do
                if stat.kind == AstKind.AssignmentStatement and stat.rhs then
                    for rIdx, rhs in ipairs(stat.rhs) do
                        if rhs.kind == AstKind.FunctionCallExpression and rhs.args and #rhs.args >= 2 then
                            if rhs.args[1].kind == AstKind.NumberExpression and rhs.args[2].kind == AstKind.TableConstructorExpression then
                                local cId = rhs.args[1].value
                                if blocks[cId] and cId ~= rootStartId then
                                    local cBodyStats = structureRegion(cId, nil, blocks, {}, recoveredCount)
                                    inlineClosures(cBodyStats)

                                    local usedSymbols = {}
                                    local symbolList = {}
                                    local function collectSymbols(node)
                                        if not node or type(node) ~= "table" then return end
                                        if (node.kind == AstKind.VariableExpression or node.kind == AstKind.AssignmentVariable) and node.symbol then
                                            local sym = node.symbol
                                            if containerRegSymbols[sym] and not usedSymbols[sym] and sym ~= argsSymbol and sym ~= unpackSymbol then
                                                usedSymbols[sym] = true
                                                table.insert(symbolList, sym)
                                            end
                                        end
                                        for k, v in pairs(node) do
                                            if type(v) == "table" and k ~= "parent" and k ~= "scope" then
                                                collectSymbols(v)
                                            end
                                        end
                                    end
                                    collectSymbols(cBodyStats)

                                    local freshSymbols = {}
                                    local lastAssignedSym = nil
                                    for _, sym in ipairs(symbolList) do
                                        local freshSym = Ast.LocalSymbol(getVarName(sym))
                                        rebindSymbol(cBodyStats, sym, freshSym)
                                        table.insert(freshSymbols, freshSym)
                                    end

                                    local newArgsSym = Ast.LocalSymbol(getVarName(argsSymbol) or "args")
                                    rebindSymbol(cBodyStats, argsSymbol, newArgsSym)

                                    local returnExpr = nil
                                    if #cBodyStats >= 1 then
                                        local lastS = cBodyStats[#cBodyStats]
                                        if lastS.kind == AstKind.AssignmentStatement and lastS.rhs and #lastS.rhs == 1 then
                                            local r = lastS.rhs[1]
                                            if r.kind == AstKind.FunctionCallExpression and r.args and #r.args >= 1 then
                                                if packSymbol and (r.base.symbol == packSymbol or getVarName(r.base) == getVarName(packSymbol)) then
                                                    returnExpr = r.args[1]
                                                    table.remove(cBodyStats)
                                                end
                                            end
                                        end
                                    end

                                    for i = #cBodyStats, 1, -1 do
                                        local s = cBodyStats[i]
                                        if s.kind == AstKind.AssignmentStatement and s.lhs and #s.lhs >= 1 then
                                            lastAssignedSym = s.lhs[1].symbol
                                            break
                                        end
                                    end

                                    local hasReturn = false
                                    for _, s in ipairs(cBodyStats) do
                                        if s.kind == AstKind.ReturnStatement then
                                            hasReturn = true
                                            break
                                        end
                                    end
                                    if not hasReturn then
                                        if returnExpr then
                                            table.insert(cBodyStats, Ast.ReturnStatement({ returnExpr }))
                                        elseif lastAssignedSym then
                                            table.insert(cBodyStats, Ast.ReturnStatement({ Ast.VariableExpression(lastAssignedSym) }))
                                        end
                                    end

                                    local paramSymbol = nil
                                    for i = 1, math.min(#cBodyStats, 5) do
                                        local s = cBodyStats[i]
                                        if s.kind == AstKind.AssignmentStatement and s.lhs and #s.lhs >= 1 and s.rhs and #s.rhs >= 1 then
                                            local r = s.rhs[1]
                                            if r.kind == AstKind.IndexExpression and r.base and (r.base.symbol == newArgsSym or getVarName(r.base) == getVarName(newArgsSym)) then
                                                paramSymbol = s.lhs[1].symbol
                                                if #s.lhs == 1 and #s.rhs == 1 then
                                                    table.remove(cBodyStats, i)
                                                else
                                                    table.remove(s.lhs, 1)
                                                    table.remove(s.rhs, 1)
                                                end
                                                break
                                            end
                                        end
                                    end

                                    local closureArgs = {}
                                    if paramSymbol then
                                        closureArgs = { Ast.VariableExpression(paramSymbol) }
                                    else
                                        closureArgs = { Ast.VarargExpression() }
                                        local bindArgsStat = Ast.LocalVariableDeclaration({ newArgsSym }, { Ast.TableConstructorExpression({ Ast.TableEntry(Ast.VarargExpression()) }) })
                                        table.insert(cBodyStats, 1, bindArgsStat)
                                    end

                                    local declSymbols = {}
                                    for _, fs in ipairs(freshSymbols) do
                                        if fs ~= paramSymbol then
                                            table.insert(declSymbols, fs)
                                        end
                                    end
                                    if #declSymbols > 0 then
                                        table.insert(cBodyStats, 1, Ast.LocalVariableDeclaration(declSymbols, {}))
                                    end

                                    stat.rhs[rIdx] = Ast.FunctionLiteralExpression(closureArgs, Ast.Block(cBodyStats))
                                end
                            end
                        end
                    end
                end
                if stat.kind == AstKind.WhileStatement and stat.body then
                    inlineClosures(stat.body.statements or {})
                elseif stat.kind == AstKind.IfStatement then
                    if stat.body then inlineClosures(stat.body.statements or {}) end
                    if stat.elsebody then inlineClosures(stat.elsebody.statements or {}) end
                elseif stat.kind == AstKind.RepeatStatement and stat.body then
                    inlineClosures(stat.body.statements or {})
                end
            end
        end

        inlineClosures(recoveredStats)

        if #cffLoops == 1 and startIds[#startIds] == rootStartId then
            local rootSymbols = {}
            local rootSymbolList = {}
            local function collectRootSymbols(node)
                if not node or type(node) ~= "table" then return end
                if (node.kind == AstKind.VariableExpression or node.kind == AstKind.AssignmentVariable) and node.symbol then
                    if not rootSymbols[node.symbol] then
                        rootSymbols[node.symbol] = true
                        table.insert(rootSymbolList, node.symbol)
                    end
                end
                if node.kind == AstKind.FunctionLiteralExpression then
                    return
                end
                for k, v in pairs(node) do
                    if type(v) == "table" and k ~= "parent" and k ~= "scope" then
                        collectRootSymbols(v)
                    end
                end
            end

            for _, s in ipairs(recoveredStats) do
                collectRootSymbols(s)
            end

            if #rootSymbolList > 0 then
                table.insert(recoveredStats, 1, Ast.LocalVariableDeclaration(rootSymbolList, {}))
            end

            ast.body.statements = recoveredStats
            totalRecovered = totalRecovered + 1
        else
            Source.walk(ast, function(node)
                if node.kind == AstKind.Block and node.statements then
                    for i, s in ipairs(node.statements) do
                        if s == targetWhile then
                            local newStatements = {}
                            for j = 1, i - 1 do
                                table.insert(newStatements, node.statements[j])
                            end
                            for _, recStat in ipairs(recoveredStats) do
                                table.insert(newStatements, recStat)
                            end
                            for j = i + 1, #node.statements do
                                table.insert(newStatements, node.statements[j])
                            end
                            node.statements = newStatements
                            totalRecovered = totalRecovered + 1
                            return
                        end
                    end
                end
            end)
        end
    end

    return ast, totalRecovered, recoveredCount, cffMeta
end

return CffDeflatten
