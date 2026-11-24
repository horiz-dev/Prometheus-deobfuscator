local Parser = require("prometheus.parser")
local Unparser = require("prometheus.unparser")
local Source = require("prometheus.source")
local Enums = require("prometheus.enums")

local Unwrap = require("deobfuscator.passes.unwrap")
local ConstantFolding = require("deobfuscator.passes.constant_folding")
local ConstantArray = require("deobfuscator.passes.constant_array")
local EncryptStrings = require("deobfuscator.passes.encrypt_strings")
local AntiTamper = require("deobfuscator.passes.anti_tamper")
local CleanNames = require("deobfuscator.passes.clean_names")
local VmDisassembler = require("deobfuscator.passes.vm_disassembler")
local CffDeflatten = require("deobfuscator.passes.cff_deflatten")
local CleanAst = require("deobfuscator.passes.clean_ast")

local Deobfuscator = {}

function Deobfuscator:new(options)
    options = options or {}
    local luaVersion = options.LuaVersion or Enums.LuaVersion.Lua51
    local prettyPrint = options.PrettyPrint ~= false
    local cleanNames = options.CleanNames ~= false

    local obj = {
        luaVersion = luaVersion,
        prettyPrint = prettyPrint,
        cleanNames = cleanNames,
        parser = Parser:new({ LuaVersion = luaVersion }),
        unparser = Unparser:new({ LuaVersion = luaVersion, PrettyPrint = prettyPrint }),
    }
    setmetatable(obj, { __index = self })
    return obj
end

function Deobfuscator:deobfuscate(content, filename)
    filename = filename or "input.lua"
    local report = {
        isVm = false,
        unwrapped = 0,
        constantsInlined = 0,
        stringsDecrypted = 0,
        tamperChecksRemoved = 0,
        expressionsFolded = 0,
        namesCleaned = 0,
        cffRecovered = { total = 0, ifs = 0, whiles = 0, repeats = 0 },
    }

    if VmDisassembler:detect(content) then
        report.isVm = true
        local disassembly, err = VmDisassembler:disassemble(content)
        if disassembly then
            report.vmDisassembly = disassembly
            return disassembly, report
        end
    end

    local source = Source.new(filename, content)
    local ast = self.parser:parse(content, source)

    ast, report.unwrapped = Unwrap:apply(ast)
    ast, report.tamperChecksRemoved = AntiTamper:apply(ast)

    local inlinedArrCount, constTable
    ast, inlinedArrCount, constTable = ConstantArray:apply(ast, self.unparser)
    report.constantsInlined = inlinedArrCount
    report.constantsTable = constTable

    local decStringsCount, decList
    ast, decStringsCount, decList = EncryptStrings:apply(ast, self.unparser)
    report.stringsDecrypted = decStringsCount
    report.decryptedStrings = decList

    ast, report.expressionsFolded = ConstantFolding:apply(ast)

    local _, cffCount, details, meta = CffDeflatten:apply(ast)
    report.cffRecovered = {
        total = cffCount,
        ifs = details and details.ifs or 0,
        whiles = details and details.whiles or 0,
        repeats = details and details.repeats or 0,
    }

    ast = CleanAst:apply(ast, meta)
    ast, _ = ConstantFolding:apply(ast)

    if self.cleanNames then
        ast, report.namesCleaned = CleanNames:apply(ast)
    end

    ast = CleanAst:apply(ast, meta)

    local result = self.unparser:unparse(ast)
    return result, report
end

return Deobfuscator
