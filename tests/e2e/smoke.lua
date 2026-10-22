-- End-to-end smoke test (see tests/e2e/init.lua): the plugin is loaded by lazy.nvim,
-- setup() ran, every documented command exists, :help xyno-macros resolves, the shipped
-- schemas load, no global key is set, and the missing-dependency message is one line.
local failures = {}
local function check(name, ok, detail)
  io.stdout:write(("%s %s%s\n"):format(ok and "ok  " or "FAIL", name, (not ok and detail) and (": " .. tostring(detail)) or ""))
  if not ok then
    failures[#failures + 1] = name
  end
end

check("lazy.nvim loaded xyno_macros", package.loaded["xyno_macros"] ~= nil)
for _, c in ipairs({ "MacroAttrs", "MacroExpand", "MacroFormatFix", "MacroSignature", "ProcMacroStatus" }) do
  check("command :" .. c, vim.fn.exists(":" .. c) == 2)
end
check("autocmd group xyno_macros", #vim.api.nvim_get_autocmds({ group = "xyno_macros" }) >= 4)
for _, lhs in ipairs({ "<leader>rx", "<leader>rq" }) do
  check("no global " .. lhs .. " by default", vim.fn.maparg(lhs, "n") == "")
end
for _, m in ipairs({ "attrs", "tools" }) do
  check("require xyno_macros." .. m, (pcall(require, "xyno_macros." .. m)))
end

local schemas = require("xyno_macros.attrs").shipped()
check("shipped schemas load from the plugin directory", schemas.serde ~= nil and schemas.clap ~= nil and schemas.tokio ~= nil)
check("no schema problems", #require("xyno_macros.attrs").load_errors == 0, vim.inspect(require("xyno_macros.attrs").load_errors))

local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
vim.cmd("helptags " .. vim.fn.fnameescape(repo .. "/doc"))
for _, tag in ipairs({ "xyno-macros", "xyno-macros-api", "xyno-macros-setup", ":MacroExpand", ":MacroFormatFix", ":MacroSignature", ":ProcMacroStatus", ":MacroAttrs" }) do
  local ok, err = pcall(vim.cmd, "help " .. tag)
  check(":help " .. tag, ok, err)
end
vim.cmd("only")

-- the pure lexer works without a server
local toks = require("xyno_macros.tools").lex('println!("{}", x)')
check("lex() returns tokens", #toks >= 3)

-- blink_opts registers both sources
local o = require("xyno_macros").blink_opts({ sources = { default = { "lsp" } } })
check("blink_opts() registers the providers", o.sources.providers.macro_attrs and o.sources.providers.macro_tools and o.sources.default[2] == "macro_tools")

-- a missing dependency gives one notification line and no Lua error
local function without(mods, fn)
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg)
    notes[#notes + 1] = msg
  end
  local saved = {}
  for _, k in ipairs(mods) do
    saved[k] = package.loaded[k]
    package.loaded[k] = nil
  end
  local saved_path, saved_loaders, rtp = package.path, package.loaders, vim.o.runtimepath
  package.loaders = { function() return nil end }
  package.path = ""
  vim.o.runtimepath = ""
  local ok = pcall(fn)
  vim.o.runtimepath = rtp
  package.path = saved_path
  package.loaders = saved_loaders
  for k, v in pairs(saved) do
    package.loaded[k] = v
  end
  vim.notify = orig
  return ok, notes
end
local ok, notes = without({ "xyno_rust.crate_meta", "xyno_rust.code_actions", "xyno_rust.fsutil", "xyno_rust.rust_context" }, require("xyno_macros").setup)
check("setup() without xyno-rust: no error", ok)
check("setup() without xyno-rust: one line", #notes == 1 and not notes[1]:find("\n"), vim.inspect(notes))
ok, notes = without({ "xyno_imports.engine" }, require("xyno_macros").setup)
check("setup() without xyno-imports: no error", ok)
check("setup() without xyno-imports: one line", #notes == 1 and not notes[1]:find("\n") and notes[1]:find("xyno-imports", 1, true), vim.inspect(notes))

if #failures > 0 then
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
