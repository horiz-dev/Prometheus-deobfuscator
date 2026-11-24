#!/usr/bin/env node

const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const ROOT_DIR = __dirname;
const BIN_DIR = path.join(ROOT_DIR, 'bin');
const DEOBF_SCRIPT = path.join(BIN_DIR, 'deobfuscator.lua');

function findLuaRuntime() {
    const bundledPaths = process.platform === 'win32'
        ? [path.join(BIN_DIR, 'luajit.exe'), path.join(BIN_DIR, 'lua.exe')]
        : [path.join(BIN_DIR, 'luajit'), path.join(BIN_DIR, 'lua')];

    for (const candidate of bundledPaths) {
        if (fs.existsSync(candidate)) {
            return candidate;
        }
    }

    const binaryNames = process.platform === 'win32' ? ['luajit.exe', 'lua.exe', 'luajit', 'lua'] : ['luajit', 'lua'];
    for (const name of binaryNames) {
        try {
            const res = spawnSync(name, ['-v'], { stdio: 'ignore' });
            if (res.status === 0) return name;
        } catch {}
    }

    if (process.platform === 'win32') {
        const localAppData = process.env.LOCALAPPDATA || '';
        const programFiles = process.env.ProgramFiles || '';
        const standardPaths = [
            path.join(localAppData, 'Programs', 'LuaJIT', 'bin', 'luajit.exe'),
            path.join(localAppData, 'Programs', 'Lua', 'bin', 'lua.exe'),
            path.join(programFiles, 'Lua', 'lua.exe'),
            path.join(programFiles, 'LuaJIT', 'luajit.exe'),
            'C:\\LuaJIT\\bin\\luajit.exe',
            'C:\\lua\\bin\\lua.exe',
        ];
        for (const candidate of standardPaths) {
            if (fs.existsSync(candidate)) {
                return candidate;
            }
        }
    }

    return null;
}

function printHelp() {
    console.log(`
\x1b[36mPrometheus Deobfuscator CLI\x1b[0m
Self-contained Lua deobfuscation engine

\x1b[33mUsage:\x1b[0m
  \x1b[32mnode cli.js <input.lua> <output.lua>\x1b[0m
    -> Deobfuscate and output a single clean Lua file to <output.lua>.

  \x1b[32mnode cli.js <input.lua> <output.lua> -full\x1b[0m
    -> Full deobfuscation and dump all artifacts into <output> folder:
       - <output>/<output.lua>      (Clean deobfuscated Lua code)
       - <output>/report.txt        (Detailed deobfuscation metrics)
       - <output>/constants.txt     (Extracted constant table & decrypted strings)
       - <output>/disassembly.txt   (Disassembled bytecode for VM protections)

\x1b[33mOptions:\x1b[0m
  --clean-names / --no-clean-names   Enable/disable semantic variable renaming (default: enabled)
  --no-pretty                        Disable code formatting
  --LuaU                             Target LuaU syntax (default: Lua 5.1 / LuaJIT)
  --help, -h                         Show this help message
`);
}

function main() {
    const rawArgs = process.argv.slice(2);

    if (rawArgs.length === 0 || rawArgs.includes('--help') || rawArgs.includes('-h')) {
        printHelp();
        process.exit(0);
    }

    const luaRuntime = findLuaRuntime();
    if (!luaRuntime) {
        console.error('\x1b[31m[Error] Lua or LuaJIT runtime not found in ./bin/ or system PATH!\x1b[0m');
        process.exit(1);
    }

    let forwardArgs = rawArgs;
    const firstArg = rawArgs[0].toLowerCase();
    if (firstArg === 'deobfuscate' || firstArg === 'deobf') {
        forwardArgs = rawArgs.slice(1);
    }

    const proc = spawnSync(luaRuntime, [DEOBF_SCRIPT, ...forwardArgs], {
        stdio: 'inherit',
        cwd: ROOT_DIR,
    });

    process.exit(proc.status ?? 0);
}

main();
