# Prometheus Deobfuscator

A standalone, self-contained deobfuscation engine for Lua 5.1, LuaJIT, and Luau scripts protected by Prometheus and similar Lua obfuscators. Bundles portable LuaJIT runtime binaries in `./bin/` so no external Lua installation is required on Windows.

---

## Project Structure

- `cli.js`: Main Node.js CLI runner located in the project root. Automatically detects and uses the bundled `./bin/luajit.exe` binary.
- `bin/`:
  - `bin/deobfuscator.lua`: Lua entrypoint for the deobfuscation engine.
  - `bin/luajit.exe`: Pre-built portable LuaJIT runtime (Windows x64).
  - `bin/lua51.dll`: Lua 5.1 shared library required by LuaJIT.
  - `bin/lua/jit/`: Bundled LuaJIT standard library and bytecode modules.
- `src/`:
  - `src/deobfuscator/`: Multi-pass deobfuscation pipeline and pass implementations.
  - `src/prometheus/`: Abstract Syntax Tree (AST), tokenizer, parser, and unparser engines.
- `package.json`: Node.js package metadata.
- `LICENSE`: GNU General Public License v3.0.

---

## Requirements

- **Node.js**: v14.0 or higher (to run `cli.js`).
- **Lua / LuaJIT**: Portable binaries are bundled in `./bin/`. On Linux/macOS, `luajit` or `lua` in system `PATH` is used automatically.

---

## Usage

### 1. Basic Deobfuscation (Clean Single File)

Outputs a clean, fully deobfuscated Lua script directly to `<output.lua>`:

```bash
node cli.js input.lua output.lua
```

### 2. Full Artifacts Mode (`-full`)

Deobfuscates the input script and exports all analysis artifacts into a dedicated folder named `<output>` (derived from `<output.lua>`):

```bash
node cli.js input.lua output.lua -full
```

The resulting folder `<output>/` contains:
- `<output>/<output.lua>`: Clean deobfuscated Lua source code with recovered control flow.
- `<output>/report.txt`: Detailed statistics of all transformation passes applied.
- `<output>/constants.txt`: Extracted constant arrays and decrypted string pools (if present).
- `<output>/disassembly.txt`: Disassembled instructions if a Register VM is detected.

### 3. Optional Flags

```bash
# Disable variable renaming / beautification
node cli.js input.lua output.lua --no-clean-names

# Disable pretty-printing
node cli.js input.lua output.lua --no-pretty

# Target Luau syntax
node cli.js input.lua output.lua --LuaU

# Display help message
node cli.js --help
```

### 4. Direct Execution via LuaJIT

You can also run the deobfuscator directly using the bundled LuaJIT binary without Node.js:

```bash
# Windows (PowerShell / CMD)
.\bin\luajit.exe bin/deobfuscator.lua input.lua output.lua
.\bin\luajit.exe bin/deobfuscator.lua input.lua output.lua -full

# Linux / macOS (using system luajit)
luajit bin/deobfuscator.lua input.lua output.lua -full
```

---

## Deobfuscation Passes

1. **Top-Level Unwrap (`Unwrap`)**: Strips root wrapping functions (`WrapInFunction`) and unpacks enclosed statements.
2. **Anti-Tamper Removal (`AntiTamper`)**: Detects and eliminates infinite loops (`while true do end`), integrity assertions, and debugger traps.
3. **Constant Array Inlining (`ConstantArray`)**: Resolves encrypted/rotated constant tables (Base64/Base85 encoding, shift indices) and inlines table lookups into their AST call sites.
4. **String Decryption (`EncryptStrings`)**: Identifies PRNG decryptor routines, evaluates cipher states, and replaces decryptor calls with literal strings.
5. **Constant Folding & Propagation (`ConstantFolding`)**: Evaluates compile-time arithmetic operations (`NumbersToExpressions`) and concatenates sliced strings (`SplitStrings`).
6. **Control Flow De-flattening (`CffDeflatten`)**: Restructures flattened state-machine dispatchers back into high-level control structures (`if/else`, `while`, `repeat-until`).
7. **AST Cleanup (`CleanAst`)**: Eliminates dead state-variable assignments, dead branches, unpack wrappers, and proxy closures.
8. **Semantic Variable Beautification (`CleanNames`)**: Renames obfuscated identifier sequences (`_IlI11l`, `a_1`, etc.) into readable, contextual variable names.
9. **Register VM Disassembler (`VmDisassembler`)**: Extracts prototype graphs and bytecode shards, determines opcode mappings, and produces readable instruction disassembly.

---

## License

This project is licensed under the [GNU General Public License v3.0](file:///C:/Users/dkhanhh/Downloads/Prometheus/LICENSE).
