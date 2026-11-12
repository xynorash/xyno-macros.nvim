# xyno-macros.nvim

Rust macro help in Neovim: completion inside helper attributes and derives (serde, clap, tokio, sqlx and more, from schemas), `macro_rules!` signature help, `:MacroExpand` and proc-macro status.

I use this in my own Rust setup, [xynovim](https://github.com/xynorash/xynovim), and pulled it out as a standalone plugin.

The macro expansion view and the macro-aware completion are inspired by what the JetBrains Rust tooling does with macros. I still use JetBrains tools; this plugin is my own independent project and is not affiliated with JetBrains.

## Why

rust-analyzer returns nothing inside `#[serde(...)]` or `#[arg(...)]`, so the keys and the enumerated values (`rename_all = "camelCase"`) were typed from memory. A proc-macro that is slow or broken shows up only as a missing expansion. This plugin completes those attributes from small JSON schemas per crate, shows the arms of a `macro_rules!` while you write a call, expands the macro under the cursor, and lists the proc-macro crates and the macros rust-analyzer could not expand.

## Requirements

- Neovim 0.12+
- [xyno-rust.nvim](https://github.com/xynorash/xyno-rust.nvim) (modules `crate_meta`, `code_actions`, `fsutil`, `rust_context`) `setup()` also checks the API version (`require("xyno_rust").compatible(require("xyno_macros").requires_rust_api)`, now `1.1`): a xyno-rust.nvim with another major or an older minor gives one error line naming the fix, and nothing starts. The CI workflow fetches the dependencies by tag (`XYNO_RUST_REF`, `XYNO_IMPORTS_REF`), never `main`; pin your own plugin manager the same way (`tag = "v0.2.0"` or a commit) so a breaking major cannot arrive unannounced.
- [xyno-imports.nvim](https://github.com/xynorash/xyno-imports.nvim) (the import of an accepted derive goes through its engine)
- rust-analyzer started through `vim.lsp` (I use [rustaceanvim](https://github.com/mrcjkb/rustaceanvim)); the proc-macro rebuild key of the status window uses its `:RustLsp`
- `cargo` in `$PATH` (workspace and dependency metadata); `cargo-expand` is the fallback of `:MacroExpand` where rust-analyzer expands nothing
- the tree-sitter `rust` parser
- optional: [blink.cmp](https://github.com/Saghen/blink.cmp) for the completion sources (attributes, derives, snippets)

`setup()` checks the two plugins and shows one error line, not a Lua error, if one is missing.

## Install (lazy.nvim)

```lua
{
  "xynorash/xyno-macros.nvim",
  dependencies = { "xynorash/xyno-rust.nvim", "xynorash/xyno-imports.nvim" },
  ft = "rust",
  cmd = { "MacroExpand", "MacroFormatFix", "MacroSignature", "ProcMacroStatus", "MacroAttrs" },
  opts = {},
  keys = {
    { "<leader>rx", "<cmd>MacroExpand<cr>", ft = "rust", desc = "Expand macro under cursor" },
    { "<leader>rq", "<cmd>ProcMacroStatus<cr>", ft = "rust", desc = "Proc-macro status" },
  },
},
{
  "saghen/blink.cmp",
  version = "1.*", -- blink.cmp 2.x needs saghen/blink.lib too; the sources are written against 1.x
  opts = function(_, opts)
    return require("xyno_macros").blink_opts(opts)
  end,
},
```

The blink.cmp spec calls `require("xyno_macros")` when blink.cmp starts, which loads this plugin (and its dependencies) at startup and registers the commands before a Rust file is open; the `ft` and `cmd` lines only matter if you leave the blink.cmp spec out. blink.cmp is pinned to `1.*` because 2.x refuses to load without saghen/blink.lib, and I only tried the sources against 1.x.

Load the plugin with `ft = "rust"` (as above) or `event = "VeryLazy"`: the signature popup and the hints start with `setup()`.

## Options

`require("xyno_macros").setup(opts)`; the defaults:

```lua
{
  commands = true,         -- :MacroAttrs :MacroExpand :MacroFormatFix :MacroSignature :ProcMacroStatus
  keymaps = false,         -- false | true | { expand = lhs|false, status = lhs|false, signature = lhs|false }
  snippets_allowed = nil,  -- function(ctx) -> boolean: where the select!/matches!/vec! snippets may appear
  trust = "auto",           -- who decides before `cargo expand` builds the crate: "auto" | "local" | function(root, what, cb)
  attrs = {},              -- tuning of the attribute completion, see below
}
```

No global keymap is set by default. `keymaps = true` maps `<leader>rx` (expand), `<leader>rq` (status) and insert-mode `<C-k>` (the macro popup first, `vim.lsp.buf.signature_help` when the cursor is not in a macro call), buffer-local in Rust buffers that have a rust-analyzer client attached. A table maps only what you list, to the keys you choose.

`snippets_allowed(ctx)` gets blink's context (`line`, `cursor`, `bufnr`). The default offers the snippets neither after a `.`, nor inside a string or comment, nor in an expression position (call arguments, struct literal fields, macro token trees, an unfinished `call(a, be`); a block inside those is a statement position again. That is the guard of the original configuration, restored; set `snippets_allowed` to decide differently.

`attrs` overrides values of `require("xyno_macros.attrs").config`: `context_lines = 15` (how far above the cursor an attribute may start), `window_min = 1500` and `window_lines = 300` (longer files are parsed around the cursor only), `learn_ttl = 120`, `learn_max_files = 300`, `learn_max_bytes`, `derive_max_files = 80`, `derive_max_bytes`, `import_attempts = 10`, `import_interval = 500`, and `user_dir = ".xyno-macros/attrs"` (the project schema directory).

### blink.cmp

```lua
opts = function(_, opts) return require("xyno_macros").blink_opts(opts) end
```

registers the provider `macro_attrs` (module `xyno_macros.attrs`, `score_offset = 100`, for Rust buffers, next to the default sources) and the provider `macro_tools` (module `xyno_macros.tools`, the snippets, added to `sources.default`).

## Trust before `cargo expand`

`cargo expand` compiles the crate, which runs the project's `build.rs` and proc macros (and those of its dependencies). The `:MacroExpand` fallback therefore does nothing until the workspace is trusted: you are asked (trust this workspace, run once, do not run) and a refusal or a cancelled prompt runs nothing. `trust = "auto"` uses `xyno_rust.trust` (`:RustTrust`) when the installed xyno-rust.nvim has it, so one trust list serves all xyno plugins; otherwise an interim check of this plugin (`lua/xyno_macros/trust.lua`, list in `stdpath("state")/xyno-macros/trust.json`, shared between nvim instances) answers; `trust = "local"` always uses the interim check; a function `(root, what, cb)` replaces both (`cb(true)` to allow, so `function(_, _, cb) cb(true) end` opts out). `:checkhealth xyno_macros` says which one is in use. Limits: rust-analyzer's own expansion (`expandMacro`) runs proc macros inside rust-analyzer and is not gated by this plugin (xyno-rust's `ra_overrides` is the place for that), and "trusted" is a per-directory answer, not a sandbox.

## Commands

| Command | What it does |
| --- | --- |
| `:MacroExpand` | Expand the macro under the cursor (rust-analyzer's `expandMacro`) in a read-only split. `<CR>` steps into the macro call under the cursor, `<BS>` goes back, `gi` lists the generated items, `q` closes. Falls back to `cargo expand` where rust-analyzer expands nothing; that fallback builds the crate (`build.rs`, proc macros), so it asks for workspace trust first (see below). |
| `:MacroFormatFix` | Append the missing arguments (`todo!()`) of the format macro call at the cursor. |
| `:MacroSignature` | Show the matcher arms of the `macro_rules!` call at the cursor (found with go-to-definition), plus format-string and sqlx bind hints. The popup also opens by itself after `(`, `[`, `{` or `!` in insert mode. |
| `:ProcMacroStatus` | List the proc-macro crates of the workspace, the macros that were not expanded, and rust-analyzer's view. In the window: `r` rebuilds proc macros, `R` refreshes, `i` or `<CR>` on a crate writes it to `procMacro.ignored` in `rust-analyzer.toml`, `<CR>` on a diagnostic jumps to it, `q` closes. |
| `:MacroAttrs` | Show what the attribute completion sees at the cursor (attribute, target, schemas, where the dependencies came from), for finding out why a completion is missing. |

## Completion data

One JSON file per crate in `data/macro_attrs/` (serde, clap, tokio, sqlx, thiserror, derive_more, strum, bon, schemars, utoipa), format in [data/macro_attrs/README.md](data/macro_attrs/README.md). A schema is used only when the workspace member depends on the crate, within the version range of the file, and when the helper attribute is in scope (a derive that brings it is on the item, or the attribute macro is named or imported). A project overrides or adds schemas with `.xyno-macros/attrs/*.json` in the workspace root. For dependency crates without a schema, keys that the workspace and the crate's own sources already write inside that attribute are offered, by frequency. `#[derive(` completes the built-in derives and the derive macros found in the dependencies' proc-macro sources; accepting one that is not imported asks the xyno-imports engine for the `use`.

## How it works

A small lexer reads the attribute from its `#[` to the cursor (strings, nesting, `key = value` entries) and says which key or value is being typed. The buffer is then parsed with the attribute repaired (closing quote and brackets appended) so tree-sitter can say what it is attached to. Dependencies come from cargo metadata once cached, from a scan of `Cargo.toml` until then, and never block. The macro tools use a lexer for Rust tokens, find the `macro_rules!` definition through the language server, and match the call against its arms.

## Platforms

- Linux: tested by the specs in this repository (`nvim -l tests/run.lua`): the lexer, schema, matcher and report logic table-wise, plus cases against a real rust-analyzer on a small fixture crate where rust-analyzer, cargo and the registry crates are available (they skip with a printed reason otherwise). The completion-menu specs need blink.cmp and skip without it.
- Windows: the guards of the original code are kept, but I have no evidence for them from this repository. In xynovim's CI the Windows job passed overall (run 39673715062) while the live rust-analyzer flows, including the live part of the macro tool specs, failed or hung there as a known issue; I do not claim the live part works on Windows.
- macOS: nothing tested here. In xynovim's CI the live part of the macro tool specs hung on macOS in one run (39668277143, passed in earlier ones) and the rust-analyzer import spec of the attribute completion timed out; the macOS runs were not stable, so I do not claim it works.

## Extracted from xynovim

This module comes from [xynovim](https://github.com/xynorash/xynovim), my Neovim configuration for Rust. The code is the same apart from the namespace (`config.macro_attrs` and `config.macro_tools` became `xyno_macros.attrs` and `xyno_macros.tools`, the helpers `xyno_rust.*` and `xyno_imports.engine`), `setup()` taking options, the keys being opt-in (the original bound them itself), the blink.cmp sources registered through `blink_opts()`, the schema directory read from the plugin directory and the project one renamed to `.xyno-macros/attrs`, a built-in snippet guard (the same checks as my configuration's), a trust gate before `cargo expand`, and a notice instead of an error when `:RustLsp` does not exist.

## Tests

```sh
nvim -l tests/run.lua    # specs, each file in its own headless nvim; needs xyno-rust.nvim and xyno-imports.nvim as siblings or in XYNO_RUST_DIR / XYNO_IMPORTS_DIR
XYNO_BLINK_DIR=/path/to/blink.cmp nvim -l tests/run.lua    # with the completion-menu specs
XYNO_LAZY=/path/to/lazy.nvim nvim --headless -u tests/e2e/init.lua -c "luafile tests/e2e/smoke.lua"
```

## License

MIT, Copyright (c) 2026 Xynorash.
