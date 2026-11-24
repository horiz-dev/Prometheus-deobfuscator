
local Ast = require("prometheus.ast")
local Source = require("prometheus.source")
local AstKind = Ast.AstKind

local CleanAst = {}

local syntaxFields = {
    'body', 'statements', 'lhs', 'rhs', 'args', 'expressions', 'entries',
    'key', 'value', 'base', 'index', 'condition', 'true_value', 'false_value',
    'elseifs', 'elsebody', 'initialValue', 'finalValue', 'incrementBy', 'target'
}

local function getVarName(node)
    if not node then return nil end
    if type(node.getName) == "function" then
        local ok, n = pcall(node.getName, node)
        if ok and n then return n end
    end
    if node.symbol and node.symbol.name then return node.symbol.name end
    return node.name
end

local function getSymbol(node)
    if not node then return nil end
    if node.symbol then return node.symbol end
    if node.kind == "LocalSymbol" then return node end
    return nil
end

function CleanAst:apply(ast, meta)
    meta = meta or {}
    local envSymbol = meta.envSymbol
    local callFunctionVar = meta.callFunctionVar
    local packVar = meta.packVar
    local unpackVar = meta.unpackVar
    local stringPool = meta.stringPool or {}

    local envSet = {}
    if envSymbol then
        envSet[envSymbol] = true
        local ename = getVarName(envSymbol)
        if ename then envSet[ename] = true end
    end
    envSet["_ENV"] = true
    envSet["_G"] = true
    envSet["env"] = true

    local function isEnv(node)
        if not node then return false end
        local sym = getSymbol(node)
        if sym and envSet[sym] then return true end
        local name = getVarName(node)
        if name and envSet[name] then return true end
        if node.kind == AstKind.GlobalVariableExpression and (node.name == "_ENV" or node.name == "_G") then return true end
        if node.kind == AstKind.OrExpression then return true end
        return false
    end

    local function isCallFunc(node)
        if not node then return false end
        local sym = getSymbol(node)
        if callFunctionVar and sym and sym == callFunctionVar then return true end
        local name = getVarName(node)
        if callFunctionVar and name and name == getVarName(callFunctionVar) then return true end
        return false
    end

    local function isPackFunc(node)
        if not node then return false end
        local sym = getSymbol(node)
        if packVar and sym and sym == packVar then return true end
        local name = getVarName(node)
        if packVar and name and name == getVarName(packVar) then return true end
        return false
    end

    local function isUnpackFunc(node)
        if not node then return false end
        local sym = getSymbol(node)
        if unpackVar and sym and sym == unpackVar then return true end
        local name = getVarName(node)
        if unpackVar and name and name == getVarName(unpackVar) then return true end
        if name == "unpack" then return true end
        return false
    end

    local function transformAst(root, transformer)
        local seen = {}
        local function walk(node)
            if not node or type(node) ~= "table" or seen[node] then return node end
            seen[node] = true
            node = transformer(node) or node
            for _, field in ipairs(syntaxFields) do
                local child = node[field]
                if child and type(child) == "table" then
                    node[field] = walk(child)
                end
            end
            for i, child in ipairs(node) do
                if type(child) == "table" then
                    node[i] = walk(child)
                end
            end
            return node
        end
        return walk(root)
    end

    ast = transformAst(ast, function(node)
        if node.kind == AstKind.FunctionCallExpression then
            if (isCallFunc(node.base) or (node.args and #node.args >= 2 and isEnv(node.args[2]))) and #node.args >= 2 then
                local fn = node.args[1]
                local callArgs = {}
                for i = 3, #node.args do
                    table.insert(callArgs, node.args[i])
                end
                node.base = fn
                node.args = callArgs
            end

            if isUnpackFunc(node.base) and node.args and #node.args == 1 then
                local inner = node.args[1]
                if inner.kind == AstKind.FunctionCallExpression then
                    if isPackFunc(inner.base) then
                        if inner.args and #inner.args >= 1 then
                            return inner.args[1]
                        else
                            return Ast.NilExpression()
                        end
                    else
                        return inner
                    end
                end
            end

            if isPackFunc(node.base) and node.args and #node.args == 1 then
                return node.args[1]
            end
        end
    end)

    local seenBlocks = {}
    local cleanBlock

    local function removeDeadStores(block, scopeReads)
        if not block or not block.statements then return end
        if not scopeReads then
            scopeReads = {}
            Source.walk(block, function(n)
                if n.kind == AstKind.VariableExpression and n.symbol then
                    scopeReads[n.symbol] = (scopeReads[n.symbol] or 0) + 1
                end
            end)
        end

        local kept = {}
        for _, s in ipairs(block.statements) do
            local isDead = false
            if s.kind == AstKind.AssignmentStatement and s.lhs and s.rhs then
                if #s.lhs > 1 and #s.lhs == #s.rhs then
                    local newLhs = {}
                    local newRhs = {}
                    for idx, l in ipairs(s.lhs) do
                        local sym = getSymbol(l)
                        if sym and scopeReads[sym] and scopeReads[sym] > 0 then
                            table.insert(newLhs, l)
                            table.insert(newRhs, s.rhs[idx])
                        end
                    end
                    if #newLhs > 0 then
                        s.lhs = newLhs
                        s.rhs = newRhs
                    else
                        isDead = true
                    end
                elseif #s.lhs == 1 then
                    local sym = getSymbol(s.lhs[1])
                    if sym and (not scopeReads[sym] or scopeReads[sym] == 0) then
                        local hasSideEffects = false
                        Source.walk(s.rhs, function(n)
                            if n.kind == AstKind.FunctionCallExpression or n.kind == AstKind.PassSelfFunctionCallExpression then
                                hasSideEffects = true
                            end
                        end)
                        if not hasSideEffects then
                            isDead = true
                        end
                    end
                end
            end
            if not isDead then
                if s.kind == AstKind.WhileStatement and s.body then
                    removeDeadStores(s.body, scopeReads)
                elseif s.kind == AstKind.RepeatStatement and s.body then
                    removeDeadStores(s.body, scopeReads)
                elseif s.kind == AstKind.IfStatement then
                    if s.body then removeDeadStores(s.body, scopeReads) end
                    for _, eif in ipairs(s.elseifs or {}) do
                        if eif.body then removeDeadStores(eif.body, scopeReads) end
                    end
                    if s.elsebody then removeDeadStores(s.elsebody, scopeReads) end
                elseif s.kind == AstKind.LocalFunctionDeclaration and s.body then
                    removeDeadStores(s.body)
                elseif s.kind == AstKind.AssignmentStatement and s.rhs then
                    for _, rhs in ipairs(s.rhs) do
                        if rhs.kind == AstKind.FunctionLiteralExpression and rhs.body then
                            removeDeadStores(rhs.body)
                        end
                    end
                end
                table.insert(kept, s)
            end
        end
        block.statements = kept
    end

    local function cleanFunctionNode(fnNode)
        if not fnNode or not fnNode.body or not fnNode.body.statements then return end

        if fnNode.args and #fnNode.args == 1 then
            local paramSym = getSymbol(fnNode.args[1])
            if paramSym then
                for sIdx = 1, math.min(3, #fnNode.body.statements) do
                    local s = fnNode.body.statements[sIdx]
                    if s.kind == AstKind.AssignmentStatement and s.lhs and #s.lhs == 1 and s.rhs and #s.rhs == 1 then
                        if s.rhs[1].kind == AstKind.VariableExpression and getSymbol(s.rhs[1]) == paramSym then
                            local aliasSym = getSymbol(s.lhs[1])
                            Source.walk(fnNode.body, function(node)
                                if (node.kind == AstKind.VariableExpression or node.kind == AstKind.AssignmentVariable) and getSymbol(node) == aliasSym then
                                    node.symbol = paramSym
                                end
                            end)
                            table.remove(fnNode.body.statements, sIdx)
                            break
                        end
                    end
                end
            end
        end

        cleanBlock(fnNode.body)

        removeDeadStores(fnNode.body)

        if fnNode.body.statements and #fnNode.body.statements > 0 then
            local fStat = fnNode.body.statements[1]
            if fStat.kind == AstKind.LocalVariableDeclaration and fStat.symbols then
                local usedInFn = {}
                for k = 2, #fnNode.body.statements do
                    Source.walk(fnNode.body.statements[k], function(n)
                        if (n.kind == AstKind.VariableExpression or n.kind == AstKind.AssignmentVariable) and n.symbol then
                            usedInFn[n.symbol] = true
                        end
                    end)
                end
                local keptSyms = {}
                for _, sym in ipairs(fStat.symbols) do
                    if usedInFn[sym] then table.insert(keptSyms, sym) end
                end
                if #keptSyms == 0 then
                    table.remove(fnNode.body.statements, 1)
                else
                    fStat.symbols = keptSyms
                    local nxtStat = fnNode.body.statements[2]
                    if nxtStat and nxtStat.kind == AstKind.AssignmentStatement and #nxtStat.lhs == #keptSyms then
                        local matches = true
                        for idx, l in ipairs(nxtStat.lhs) do
                            if getSymbol(l) ~= keptSyms[idx] then matches = false; break end
                        end
                        if matches then
                            fStat.expressions = nxtStat.rhs
                            table.remove(fnNode.body.statements, 2)
                        end
                    end
                end
            end
        end
    end

    cleanBlock = function(block)
        if not block or not block.statements or seenBlocks[block] then return end
        seenBlocks[block] = true

        local stats = block.statements
        local newStats = {}
        local valMap = {}
        local i = 1

        local function cloneExpr(e)
            if not e or type(e) ~= "table" then return e end
            if e.kind == AstKind.StringExpression then
                return Ast.StringExpression(e.value)
            elseif e.kind == AstKind.NumberExpression then
                return Ast.NumberExpression(e.value)
            elseif e.kind == AstKind.GlobalVariableExpression then
                return Ast.GlobalVariableExpression(e.name)
            elseif e.kind == AstKind.VariableExpression then
                return Ast.VariableExpression(e.symbol)
            end
            return e
        end

        local function getVal(key)
            if not key then return nil end
            local sym = getSymbol(key)
            if sym and valMap[sym] then return valMap[sym] end
            local name = getVarName(key)
            if name and valMap[name] then return valMap[name] end
            return valMap[key]
        end

        local function setVal(key, val)
            if not key then return end
            if val and val.kind == AstKind.VariableExpression then
                local resolved = getVal(val)
                if resolved and (resolved.kind == AstKind.NumberExpression or resolved.kind == AstKind.StringExpression or resolved.kind == AstKind.GlobalVariableExpression) then
                    val = cloneExpr(resolved)
                end
            end
            valMap[key] = val
            local n = getVarName(key)
            if n then valMap[n] = val end
            local sym = getSymbol(key)
            if sym then valMap[sym] = val end
        end

        while i <= #stats do
            local s = stats[i]

            local isForPattern = false
            local forInitExpr, forLimitExpr, forStepExpr = nil, nil, Ast.NumberExpression(1)
            local forLoopVarSym = nil
            local forBodyStats = {}
            local whileIdx = nil
            local counterSym = nil
            local initRegSym, limitRegSym, stepRegSym = nil, nil, nil

            local function checkIsForTypeCheck(stat, checkName)
                if stat and stat.kind == AstKind.AssignmentStatement and stat.rhs and #stat.rhs == 1 then
                    local r = stat.rhs[1]
                    if r.kind == AstKind.OrExpression and r.rhs and r.rhs.kind == AstKind.FunctionCallExpression then
                        local call = r.rhs
                        if call.args and #call.args >= 1 and call.args[1].kind == AstKind.StringExpression then
                            if call.args[1].value:find(checkName, 1, true) then
                                return true
                            end
                        end
                    end
                end
                return false
            end

            if checkIsForTypeCheck(s, "initial value must be a number") then
                local initReg = s.lhs[1]
                initRegSym = getSymbol(initReg)
                forInitExpr = cloneExpr(getVal(initReg)) or Ast.NumberExpression(1)

                for f = i + 1, math.min(#stats, i + 15) do
                    local fs = stats[f]
                    if checkIsForTypeCheck(fs, "limit must be a number") then
                        limitRegSym = getSymbol(fs.lhs[1])
                        forLimitExpr = cloneExpr(getVal(fs.lhs[1])) or Ast.NumberExpression(10)
                    elseif checkIsForTypeCheck(fs, "step must be a number") then
                        stepRegSym = getSymbol(fs.lhs[1])
                        forStepExpr = cloneExpr(getVal(fs.lhs[1])) or Ast.NumberExpression(1)
                    elseif fs.kind == AstKind.WhileStatement then
                        whileIdx = f
                        break
                    elseif fs.kind == AstKind.AssignmentStatement and #fs.lhs == 1 and #fs.rhs == 1 then
                        setVal(fs.lhs[1], fs.rhs[1])
                    end
                end

                if whileIdx and forInitExpr and forLimitExpr then
                    local targetWhile = stats[whileIdx]
                    if targetWhile.body and targetWhile.body.statements and #targetWhile.body.statements >= 2 then
                        local wstats = targetWhile.body.statements
                        if wstats[1].kind == AstKind.AssignmentStatement and wstats[1].lhs and #wstats[1].lhs >= 1 then
                            forLoopVarSym = getSymbol(wstats[1].lhs[1]) or wstats[1].lhs[1]
                            if wstats[1].rhs and #wstats[1].rhs >= 1 then
                                counterSym = getSymbol(wstats[1].rhs[1])
                            end

                            for w = 2, #wstats do
                                local ws = wstats[w]
                                local isCounterUpdate = false
                                if ws.kind == AstKind.AssignmentStatement and ws.lhs then
                                    for _, l in ipairs(ws.lhs) do
                                        local lsym = getSymbol(l)
                                        if lsym and counterSym and lsym == counterSym then
                                            isCounterUpdate = true
                                            break
                                        end
                                    end
                                end
                                if isCounterUpdate then
                                    break
                                else
                                    table.insert(forBodyStats, ws)
                                end
                            end
                            isForPattern = true
                        end
                    end
                end
            end

            if isForPattern then
                local isSetupReg = {}
                if initRegSym then isSetupReg[initRegSym] = true end
                if limitRegSym then isSetupReg[limitRegSym] = true end
                if stepRegSym then isSetupReg[stepRegSym] = true end
                if counterSym then isSetupReg[counterSym] = true end

                while #newStats > 0 do
                    local lastS = newStats[#newStats]
                    if lastS.kind == AstKind.AssignmentStatement and lastS.lhs and #lastS.lhs == 1 then
                        local lsym = getSymbol(lastS.lhs[1])
                        if lsym and isSetupReg[lsym] then
                            if lastS.rhs and lastS.rhs[1] and lastS.rhs[1].kind == AstKind.VariableExpression then
                                local rsym = getSymbol(lastS.rhs[1])
                                if rsym then isSetupReg[rsym] = true end
                            end
                            table.remove(newStats)
                        else
                            break
                        end
                    else
                        break
                    end
                end

                for _, bs in ipairs(forBodyStats) do
                    if bs.kind == AstKind.AssignmentStatement and bs.lhs then
                        for _, l in ipairs(bs.lhs) do
                            local n = getVarName(l)
                            if n then valMap[n] = nil end
                            local sym = getSymbol(l)
                            if sym then valMap[sym] = nil end
                        end
                    end
                end

                local loopVarName = (forLoopVarSym and forLoopVarSym.name) or "i"
                local freshForSymbol = Ast.LocalSymbol(loopVarName)

                local forBlock = Ast.Block(forBodyStats)
                Source.walk(forBlock, function(node)
                    if (node.kind == AstKind.VariableExpression or node.kind == AstKind.AssignmentVariable) and node.symbol == forLoopVarSym then
                        node.symbol = freshForSymbol
                    end
                end)

                cleanBlock(forBlock)

                local forStat = Ast.ForStatement(freshForSymbol, forInitExpr, forLimitExpr, forStepExpr, forBlock)
                table.insert(newStats, forStat)

                i = whileIdx + 1
                s = nil
            end

            if s then
                local isNilCleanup = false
                if s.kind == AstKind.AssignmentStatement and s.rhs and #s.rhs == 1 and s.rhs[1].kind == AstKind.NilExpression then
                    isNilCleanup = true
                end

                local isTypeCheck = false
                if s.kind == AstKind.AssignmentStatement and s.rhs and #s.rhs == 1 then
                    local r = s.rhs[1]
                    if r.kind == AstKind.OrExpression and r.rhs and r.rhs.kind == AstKind.FunctionCallExpression then
                        local callBase = getVarName(r.rhs.base)
                        if callBase == "error" or callBase == "var_3" or (meta.errorVar and r.rhs.base.symbol == meta.errorVar) then
                            isTypeCheck = true
                        end
                    end
                end

                local isDeadPack = false
                if s.kind == AstKind.AssignmentStatement and s.rhs and #s.rhs == 1 then
                    local r = s.rhs[1]
                    if r.kind == AstKind.FunctionCallExpression and isPackFunc(r.base) and (not r.args or #r.args == 0) then
                        isDeadPack = true
                    end
                end

                if s.kind == AstKind.IfStatement then
                    while s.elsebody and s.elsebody.statements and #s.elsebody.statements == 1 and s.elsebody.statements[1].kind == AstKind.IfStatement do
                        local innerIf = s.elsebody.statements[1]
                        s.elseifs = s.elseifs or {}
                        table.insert(s.elseifs, {
                            condition = innerIf.condition,
                            body = innerIf.body,
                        })
                        for _, eif in ipairs(innerIf.elseifs or {}) do
                            table.insert(s.elseifs, eif)
                        end
                        s.elsebody = innerIf.elsebody
                    end

                    if s.condition and s.condition.rhs and s.condition.rhs.kind == AstKind.VariableExpression then
                        local v = getVal(s.condition.rhs)
                        if v and (v.kind == AstKind.NumberExpression or v.kind == AstKind.StringExpression) then
                            s.condition.rhs = cloneExpr(v)
                        end
                    end
                    for _, eif in ipairs(s.elseifs or {}) do
                        if eif.condition and eif.condition.rhs and eif.condition.rhs.kind == AstKind.VariableExpression then
                            local v = getVal(eif.condition.rhs)
                            if v and (v.kind == AstKind.NumberExpression or v.kind == AstKind.StringExpression) then
                                eif.condition.rhs = cloneExpr(v)
                            end
                        end
                    end

                    Source.walk(s, function(node)
                        if node.kind == AstKind.AssignmentStatement and node.lhs then
                            for _, l in ipairs(node.lhs) do
                                local n = getVarName(l)
                                if n then valMap[n] = nil end
                                local sym = getSymbol(l)
                                if sym then valMap[sym] = nil end
                            end
                        end
                    end)
                end

                if s.kind == AstKind.AssignmentStatement and not isNilCleanup and not isTypeCheck and not isDeadPack then
                    for rIdx, r in ipairs(s.rhs) do
                        if r.kind == AstKind.IndexExpression then
                            local isE = isEnv(r.base)
                            if isE then
                                local strVal = nil
                                if r.index.kind == AstKind.StringExpression then
                                    strVal = r.index.value
                                elseif r.index.kind == AstKind.VariableExpression then
                                    local iv = getVal(r.index)
                                    if iv and iv.kind == AstKind.StringExpression then
                                        strVal = iv.value
                                    end
                                end
                                if strVal and strVal:match("^[%a_][%w_]*$") then
                                    s.rhs[rIdx] = Ast.GlobalVariableExpression(strVal)
                                    r = s.rhs[rIdx]
                                end
                            end
                        end

                        if r.kind == AstKind.FunctionCallExpression then
                            local baseVal = getVal(r.base)
                            if baseVal and baseVal.kind == AstKind.GlobalVariableExpression then
                                r.base = cloneExpr(baseVal)
                            end
                            for aIdx, arg in ipairs(r.args or {}) do
                                if arg.kind == AstKind.VariableExpression then
                                    local av = getVal(arg)
                                    if av and (av.kind == AstKind.StringExpression or av.kind == AstKind.NumberExpression) then
                                        r.args[aIdx] = cloneExpr(av)
                                    elseif av and av.kind == AstKind.FunctionCallExpression then
                                        r.args[aIdx] = cloneExpr(av)
                                    end
                                end
                                if isUnpackFunc(arg.base) and arg.args and #arg.args == 1 then
                                    r.args[aIdx] = arg.args[1]
                                end
                            end
                        end

                        local isConcat = r.kind == AstKind.ConcatExpression
                        local isEq = r.kind == AstKind.EqualsExpression or r.kind == AstKind.NotEqualsExpression
                        if r.lhs and r.lhs.kind == AstKind.VariableExpression then
                            local lv = getVal(r.lhs)
                            if lv and lv.kind == AstKind.NumberExpression then
                                r.lhs = cloneExpr(lv)
                            elseif lv and lv.kind == AstKind.StringExpression and (isConcat or isEq) then
                                r.lhs = cloneExpr(lv)
                            end
                        end
                        if r.rhs and r.rhs.kind == AstKind.VariableExpression then
                            local rv = getVal(r.rhs)
                            if rv and rv.kind == AstKind.NumberExpression then
                                r.rhs = cloneExpr(rv)
                            elseif rv and rv.kind == AstKind.StringExpression and (isConcat or isEq) then
                                r.rhs = cloneExpr(rv)
                            end
                        end

                        if #s.lhs >= rIdx then
                            local lhsTarget = s.lhs[rIdx]
                            setVal(lhsTarget, r)
                        end
                    end

                    if #s.lhs == 1 and #s.rhs == 1 and s.rhs[1].kind == AstKind.FunctionCallExpression then
                        local call = s.rhs[1]
                        if call.base.kind == AstKind.GlobalVariableExpression then
                            while #newStats > 0 do
                                local lastS = newStats[#newStats]
                                if lastS.kind == AstKind.AssignmentStatement and lastS.lhs and #lastS.lhs == 1 then
                                    local r = lastS.rhs and lastS.rhs[1]
                                    if r and (r.kind == AstKind.GlobalVariableExpression or (r.kind == AstKind.StringExpression and r.value == "print")) then
                                        table.remove(newStats)
                                    elseif r and r.kind == AstKind.StringExpression then
                                        table.remove(newStats)
                                    else
                                        break
                                    end
                                else
                                    break
                                end
                            end
                            s = Ast.FunctionCallStatement(call.base, call.args)
                        end
                    end
                end

                if s and not isNilCleanup and not isTypeCheck and not isDeadPack then
                    if s.kind == AstKind.WhileStatement and s.body then
                        cleanBlock(s.body)
                    elseif s.kind == AstKind.RepeatStatement and s.body then
                        cleanBlock(s.body)
                        if s.condition and s.condition.rhs and s.condition.rhs.kind == AstKind.VariableExpression and s.body.statements then
                            local condSym = getSymbol(s.condition.rhs)
                            for k = #s.body.statements, 1, -1 do
                                local bs = s.body.statements[k]
                                if bs.kind == AstKind.AssignmentStatement and bs.lhs and #bs.lhs == 1 and bs.rhs and #bs.rhs == 1 then
                                    if getSymbol(bs.lhs[1]) == condSym then
                                        local rv = bs.rhs[1]
                                        if rv.kind == AstKind.NumberExpression or rv.kind == AstKind.StringExpression then
                                            s.condition.rhs = cloneExpr(rv)
                                            break
                                        end
                                    end
                                end
                            end
                        end
                    elseif s.kind == AstKind.IfStatement then
                        if s.body then cleanBlock(s.body) end
                        for _, eif in ipairs(s.elseifs or {}) do
                            if eif.body then cleanBlock(eif.body) end
                        end
                        if s.elsebody then cleanBlock(s.elsebody) end
                    elseif s.kind == AstKind.LocalFunctionDeclaration then
                        cleanFunctionNode(s)
                    elseif s.kind == AstKind.AssignmentStatement and s.rhs then
                        for _, rhs in ipairs(s.rhs) do
                            if rhs.kind == AstKind.FunctionLiteralExpression then
                                cleanFunctionNode(rhs)
                            end
                        end
                    end
                    table.insert(newStats, s)
                end
                i = i + 1
            end
        end

        local collapsed = {}
        local cIdx = 1
        while cIdx <= #newStats do
            local cur = newStats[cIdx]
            local nxt = newStats[cIdx + 1]
            local didCollapse = false
            if cur and nxt and cur.kind == AstKind.AssignmentStatement and #cur.lhs == 1 and #cur.rhs == 1
               and nxt.kind == AstKind.AssignmentStatement and #nxt.lhs == 1 and #nxt.rhs == 1 then
                local curLhs = cur.lhs[1]
                local nxtRhs = nxt.rhs[1]
                if nxtRhs.kind == AstKind.VariableExpression and (getSymbol(curLhs) == getSymbol(nxtRhs) or getVarName(curLhs) == getVarName(nxtRhs)) then
                    nxt.rhs[1] = cur.rhs[1]
                    table.insert(collapsed, nxt)
                    cIdx = cIdx + 2
                    didCollapse = true
                end
            end
            if not didCollapse then
                table.insert(collapsed, cur)
                cIdx = cIdx + 1
            end
        end

        local inlinedCalls = {}
        local icIdx = 1
        while icIdx <= #collapsed do
            local cur = collapsed[icIdx]
            local nxt = collapsed[icIdx + 1]
            local didInline = false
            if cur and nxt and cur.kind == AstKind.AssignmentStatement and #cur.lhs == 1 and #cur.rhs == 1 and cur.rhs[1].kind == AstKind.FunctionCallExpression
               and nxt.kind == AstKind.FunctionCallStatement and nxt.args then
                local curSym = getSymbol(cur.lhs[1])
                local curName = getVarName(cur.lhs[1])
                for aIdx, arg in ipairs(nxt.args) do
                    if arg.kind == AstKind.VariableExpression and (getSymbol(arg) == curSym or getVarName(arg) == curName) then
                        nxt.args[aIdx] = cur.rhs[1]
                        table.insert(inlinedCalls, nxt)
                        icIdx = icIdx + 2
                        didInline = true
                        break
                    end
                end
            end
            if not didInline then
                table.insert(inlinedCalls, cur)
                icIdx = icIdx + 1
            end
        end

        local filtered = {}
        for _, stat in ipairs(inlinedCalls) do
            local isDead = false
            if stat.kind == AstKind.AssignmentStatement and #stat.lhs == 1 and #stat.rhs == 1 then
                local r = stat.rhs[1]
                if r.kind == AstKind.GlobalVariableExpression and r.name == "print" then
                    isDead = true
                elseif r.kind == AstKind.StringExpression and r.value == "print" then
                    isDead = true
                end
            end
            if not isDead then
                table.insert(filtered, stat)
            end
        end

        for _, stat in ipairs(filtered) do
            if stat.kind == AstKind.IfStatement then
                while stat.elsebody and stat.elsebody.statements and #stat.elsebody.statements == 1 and stat.elsebody.statements[1].kind == AstKind.IfStatement do
                    local innerIf = stat.elsebody.statements[1]
                    stat.elseifs = stat.elseifs or {}
                    table.insert(stat.elseifs, {
                        condition = innerIf.condition,
                        body = innerIf.body,
                    })
                    for _, eif in ipairs(innerIf.elseifs or {}) do
                        table.insert(stat.elseifs, eif)
                    end
                    stat.elsebody = innerIf.elsebody
                end
            end
        end

        block.statements = filtered
    end

    cleanBlock(ast.body)

    removeDeadStores(ast.body)

    local fnSymbols = {}
    if ast.body and ast.body.statements then
        local convertedStats = {}
        for _, stat in ipairs(ast.body.statements) do
            if stat.kind == AstKind.AssignmentStatement and #stat.lhs == 1 and #stat.rhs == 1 and stat.rhs[1].kind == AstKind.FunctionLiteralExpression then
                local fnSym = getSymbol(stat.lhs[1])
                local fnLiteral = stat.rhs[1]
                local lfn = Ast.LocalFunctionDeclaration(fnSym, fnLiteral.args, fnLiteral.body)
                table.insert(convertedStats, lfn)
                fnSymbols[fnSym] = true
            elseif stat.kind == AstKind.LocalFunctionDeclaration then
                table.insert(convertedStats, stat)
                if stat.symbol then fnSymbols[stat.symbol] = true end
            else
                table.insert(convertedStats, stat)
            end
        end
        ast.body.statements = convertedStats
    end

    if ast.body and ast.body.statements then
        local live = {}
        local keptStats = {}

        for idx = #ast.body.statements, 1, -1 do
            local s = ast.body.statements[idx]
            local isDead = false

            if s.kind == AstKind.AssignmentStatement and s.lhs and s.rhs then
                local hasSideEffects = false
                for _, r in ipairs(s.rhs) do
                    Source.walk(r, function(n)
                        if n.kind == AstKind.FunctionCallExpression or n.kind == AstKind.PassSelfFunctionCallExpression then
                            hasSideEffects = true
                        end
                    end)
                end

                if not hasSideEffects and #s.lhs == #s.rhs then
                    local keptLhs = {}
                    local keptRhs = {}
                    for lIdx, l in ipairs(s.lhs) do
                        local sym = getSymbol(l)
                        if sym and live[sym] then
                            table.insert(keptLhs, l)
                            table.insert(keptRhs, s.rhs[lIdx])
                        end
                    end
                    if #keptLhs == 0 then
                        isDead = true
                    else
                        s.lhs = keptLhs
                        s.rhs = keptRhs
                    end
                end

                if not isDead then
                    for _, l in ipairs(s.lhs) do
                        local sym = getSymbol(l)
                        if sym then live[sym] = nil end
                    end
                    for _, r in ipairs(s.rhs) do
                        Source.walk(r, function(n)
                            if n.kind == AstKind.VariableExpression and n.symbol then
                                live[n.symbol] = true
                            end
                        end)
                    end
                end
            elseif s.kind == AstKind.LocalFunctionDeclaration then
                if s.symbol then live[s.symbol] = nil end
                Source.walk(s.body, function(n)
                    if n.kind == AstKind.VariableExpression and n.symbol then
                        live[n.symbol] = true
                    end
                end)
            elseif s.kind == AstKind.IfStatement then
                local function getBranchWrites(b)
                    local w = {}
                    if b and b.statements then
                        for _, bs in ipairs(b.statements) do
                            if bs.kind == AstKind.AssignmentStatement and bs.lhs then
                                for _, l in ipairs(bs.lhs) do
                                    local sym = getSymbol(l)
                                    if sym then w[sym] = true end
                                end
                            end
                        end
                    end
                    return w
                end

                local hasElse = s.elsebody and s.elsebody.statements and #s.elsebody.statements > 0
                if hasElse then
                    local allWrites = getBranchWrites(s.body)
                    for _, eif in ipairs(s.elseifs or {}) do
                        local ew = getBranchWrites(eif.body)
                        for sym in pairs(allWrites) do
                            if not ew[sym] then allWrites[sym] = nil end
                        end
                    end
                    local elsew = getBranchWrites(s.elsebody)
                    for sym in pairs(allWrites) do
                        if not elsew[sym] then allWrites[sym] = nil end
                    end
                    for sym in pairs(allWrites) do
                        live[sym] = nil
                    end
                end

                Source.walk(s, function(n)
                    if n.kind == AstKind.VariableExpression and n.symbol then
                        live[n.symbol] = true
                    end
                end)
            elseif s.kind == AstKind.LocalVariableDeclaration then
            else
                Source.walk(s, function(n)
                    if n.kind == AstKind.VariableExpression and n.symbol then
                        live[n.symbol] = true
                    end
                end)
            end

            if not isDead then
                table.insert(keptStats, 1, s)
            end
        end

        ast.body.statements = keptStats
    end

    if ast.body and ast.body.statements and #ast.body.statements > 0 and ast.body.statements[1].kind == AstKind.LocalVariableDeclaration then
        local usedSymbols = {}
        for k = 2, #ast.body.statements do
            Source.walk(ast.body.statements[k], function(node)
                if (node.kind == AstKind.VariableExpression or node.kind == AstKind.AssignmentVariable) and node.symbol then
                    usedSymbols[node.symbol] = true
                end
            end)
        end
        local cleanedSymbols = {}
        for _, sym in ipairs(ast.body.statements[1].symbols or {}) do
            if usedSymbols[sym] and not fnSymbols[sym] then
                table.insert(cleanedSymbols, sym)
            end
        end
        if #cleanedSymbols > 0 then
            ast.body.statements[1].symbols = cleanedSymbols
        else
            table.remove(ast.body.statements, 1)
        end
    end

    return ast
end

return CleanAst
