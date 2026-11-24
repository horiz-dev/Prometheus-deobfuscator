local function script_path()
    local str = debug.getinfo(2, "S").source:sub(2)
    return str:match("(.*[/%\\])") or ""
end
local root = script_path() .. "../"
package.path = root .. "src/?.lua;" .. root .. "src/?/init.lua;" .. root .. "?.lua;" .. package.path

package.preload["logger"] = function()
    return {
        error = function(self, msg) error(tostring(msg), 0) end,
        warn = function(self, msg) io.stderr:write("[WARN] " .. tostring(msg) .. "\n") end,
        info = function(self, msg) end,
        debug = function(self, msg) end,
    }
end

package.preload["config"] = function()
    return {
        IdentPrefix = "__",
        SPACE = " ",
        TAB = "\t",
    }
end

package.preload["prometheus.sourcemapwriter"] = function()
    return {
        render = function() return "" end
    }
end

local Deobfuscator = require("deobfuscator.init")
local Enums = require("prometheus.enums")

local function print_help()
    print("Prometheus Deobfuscator CLI")
    print("Usage: luajit bin/deobfuscator.lua <input.lua> <output.lua> [options]")
    print("")
    print("Options:")
    print("  -full, --full          Export all artifacts into a folder named <output_without_.lua>")
    print("  --dump-dir <dir>       Specify custom directory to dump all artifacts")
    print("  --no-clean-names       Disable variable beautification")
    print("  --no-pretty            Disable pretty-printing")
    print("  --LuaU                 Target LuaU syntax (default: Lua 5.1)")
    print("  --help, -h             Show this help message")
    print("")
    print("Examples:")
    print("  luajit bin/deobfuscator.lua input.lua output.lua")
    print("  luajit bin/deobfuscator.lua input.lua output.lua -full")
end

local input_file = nil
local output_file = nil
local clean_names = true
local pretty_print = true
local is_full = false
local dump_dir = nil
local lua_version = Enums.LuaVersion.Lua51

local positional = {}
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--out" or a == "-o" then
        i = i + 1
        output_file = arg[i]
    elseif a == "-full" or a == "--full" then
        is_full = true
    elseif a == "--dump-dir" then
        i = i + 1
        dump_dir = arg[i]
        is_full = true
    elseif a == "--no-clean-names" then
        clean_names = false
    elseif a == "--clean-names" then
        clean_names = true
    elseif a == "--no-pretty" then
        pretty_print = false
    elseif a == "--LuaU" then
        lua_version = Enums.LuaVersion.LuaU
    elseif a == "--help" or a == "-h" then
        print_help()
        os.exit(0)
    elseif not a:find("^-") then
        table.insert(positional, a)
    end
    i = i + 1
end

if #positional >= 1 and not input_file then
    input_file = positional[1]
end
if #positional >= 2 and not output_file then
    output_file = positional[2]
end

if not input_file then
    print_help()
    os.exit(1)
end

if not output_file then
    output_file = input_file:gsub("%.lua$", "") .. ".clean.lua"
    if output_file == input_file then
        output_file = input_file .. ".clean.lua"
    end
end

local f = io.open(input_file, "r")
if not f then
    io.stderr:write("Error: Could not open input file: " .. tostring(input_file) .. "\n")
    os.exit(1)
end
local content = f:read("*a")
f:close()

local deobf = Deobfuscator:new({
    LuaVersion = lua_version,
    PrettyPrint = pretty_print,
    CleanNames = clean_names,
})

local result, report = deobf:deobfuscate(content, input_file)

local function getBaseFilename(filePath)
    return filePath:match("([^/\\]+)$") or filePath
end

if is_full then
    if not dump_dir then
        dump_dir = output_file:gsub("%.lua$", "")
        if dump_dir == output_file then
            dump_dir = output_file .. "_dump"
        end
    end

    local isWindows = package.config:sub(1, 1) == "\\"
    if isWindows then
        os.execute(string.format('mkdir "%s" >nul 2>&1', dump_dir:gsub("/", "\\")))
    else
        os.execute(string.format('mkdir -p "%s" >/dev/null 2>&1', dump_dir))
    end

    print(string.format("[+] Running full deobfuscation with artifact dump into: %s/", dump_dir))

    local baseName = getBaseFilename(output_file)
    local targetScriptPath = dump_dir .. "/" .. baseName
    local fClean = io.open(targetScriptPath, "w")
    if fClean then
        fClean:write(result)
        fClean:close()
        print("    [>] Clean Lua script:        " .. targetScriptPath)
    else
        io.stderr:write("Error: Could not write clean script to: " .. targetScriptPath .. "\n")
    end

    local reportPath = dump_dir .. "/report.txt"
    local fRep = io.open(reportPath, "w")
    if fRep then
        fRep:write("=== Prometheus Deobfuscation Report ===\n")
        fRep:write("Input File:  " .. input_file .. "\n")
        fRep:write("Output File: " .. targetScriptPath .. "\n\n")
        fRep:write(string.format("- Outer functions unwrapped:   %d\n", report.unwrapped or 0))
        fRep:write(string.format("- Anti-tamper checks removed:  %d\n", report.tamperChecksRemoved or 0))
        fRep:write(string.format("- Constant array inlined:      %d\n", report.constantsInlined or 0))
        fRep:write(string.format("- Strings decrypted:           %d\n", report.stringsDecrypted or 0))
        fRep:write(string.format("- Expressions folded:          %d\n", report.expressionsFolded or 0))
        if report.cffRecovered then
            fRep:write(string.format("- Control flow restructured:   %d (if: %d, while: %d, repeat: %d)\n",
                report.cffRecovered.total or 0,
                report.cffRecovered.ifs or 0,
                report.cffRecovered.whiles or 0,
                report.cffRecovered.repeats or 0))
        end
        if clean_names then
            fRep:write(string.format("- Variables beautified:        %d\n", report.namesCleaned or 0))
        end
        if report.isVm then
            fRep:write("- Register VM:                 Detected and disassembled\n")
        end
        fRep:close()
        print("    [>] Deobfuscation report:    " .. reportPath)
    end

    if (report.constantsTable and #report.constantsTable > 0) or (report.decryptedStrings and #report.decryptedStrings > 0) then
        local constPath = dump_dir .. "/constants.txt"
        local fConst = io.open(constPath, "w")
        if fConst then
            fConst:write("=== Extracted Literals & Constants ===\n\n")
            if report.constantsTable and #report.constantsTable > 0 then
                fConst:write(string.format("-- ConstantArray Table (%d entries):\n", #report.constantsTable))
                for idx, val in ipairs(report.constantsTable) do
                    fConst:write(string.format("  [%d] = %s\n", idx, type(val) == "string" and string.format("%q", val) or tostring(val)))
                end
                fConst:write("\n")
            end
            if report.decryptedStrings and #report.decryptedStrings > 0 then
                fConst:write(string.format("-- Decrypted Strings (%d entries):\n", #report.decryptedStrings))
                for idx, str in ipairs(report.decryptedStrings) do
                    fConst:write(string.format("  [%d] %q\n", idx, str))
                end
            end
            fConst:close()
            print("    [>] Extracted constants:     " .. constPath)
        end
    end

    if report.vmDisassembly then
        local disasmPath = dump_dir .. "/disassembly.txt"
        local fDisasm = io.open(disasmPath, "w")
        if fDisasm then
            fDisasm:write(report.vmDisassembly)
            fDisasm:close()
            print("    [>] VM Bytecode Disassembly: " .. disasmPath)
        end
    end

    print(string.format("[+] Full artifacts successfully saved in folder: %s/", dump_dir))
else
    local out = io.open(output_file, "w")
    if not out then
        io.stderr:write("Error: Could not open output file for writing: " .. tostring(output_file) .. "\n")
        os.exit(1)
    end
    out:write(result)
    out:close()
    print(string.format("[+] Deobfuscated: %s -> %s", input_file, output_file))
end
