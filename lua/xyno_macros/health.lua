-- :checkhealth xyno_macros
local M = {}

function M.check()
  local h = vim.health
  h.start("xyno-macros")
  if vim.fn.has("nvim-0.12") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.12 or newer is required")
  end
  for _, mod in ipairs({
    "xyno_rust.crate_meta",
    "xyno_rust.code_actions",
    "xyno_rust.fsutil",
    "xyno_rust.rust_context",
  }) do
    if pcall(require, mod) then
      h.ok(mod .. " (xyno-rust.nvim)")
    else
      h.error(mod .. " not found", { "install xynorash/xyno-rust.nvim" })
    end
  end
  if pcall(require, "xyno_imports.engine") then
    h.ok("xyno_imports.engine (xyno-imports.nvim, accepting a derive imports it)")
  else
    h.warn(
      "xyno-imports.nvim not found: accepting a derive will not import it",
      { "install xynorash/xyno-imports.nvim" }
    )
  end
  if pcall(vim.treesitter.language.add, "rust") then
    h.ok("tree-sitter parser for rust")
  else
    h.warn("no tree-sitter parser for rust: attribute context and the snippet guard degrade", { ":TSInstall rust" })
  end
  if pcall(require, "blink.cmp") then
    h.ok("blink.cmp found (attribute completion and snippets are blink sources)")
    local ok, cfg = pcall(function()
      return require("blink.cmp.config").sources
    end)
    if ok and cfg and cfg.providers then
      h.info(
        ("providers registered: macro_attrs=%s macro_tools=%s"):format(
          tostring(cfg.providers.macro_attrs ~= nil),
          tostring(cfg.providers.macro_tools ~= nil)
        )
      )
    end
  else
    h.warn(
      "blink.cmp not found: no completion sources (commands still work)",
      { "see `require('xyno_macros').blink_opts` in the README" }
    )
  end
  local clients = vim.lsp.get_clients({ name = "rust-analyzer" })
  if #clients > 0 then
    h.ok("rust-analyzer attached (:MacroExpand, :ProcMacroStatus)")
  else
    h.info("rust-analyzer is not attached in this session (open a Rust file)")
  end

  h.start("xyno-macros: cargo expand and trust")
  if vim.fn.executable("cargo-expand") == 1 then
    h.ok("cargo-expand found (fallback of :MacroExpand)")
  else
    h.info("cargo-expand not installed: :MacroExpand uses rust-analyzer only", { "cargo install cargo-expand" })
  end
  local trust = require("xyno_macros.trust")
  local which = trust.provider()
  if which == "xyno-rust" then
    h.ok("trust: xyno-rust.nvim's workspace trust (:RustTrust) decides before cargo expand builds a crate")
  elseif which == "custom" then
    h.warn("trust: a custom provider decides before cargo expand builds a crate (its answer is not checked here)")
  else
    h.warn(
      "trust: the installed xyno-rust.nvim has no xyno_rust.trust; the INTERIM check of this plugin is used",
      { "update xyno-rust.nvim; the interim list is " .. trust.file() }
    )
    local list = trust.list()
    h.info(("interim trust list: %d workspace%s"):format(#list, #list == 1 and "" or "s"))
    for _, e in ipairs(list) do
      h.info("  trusted: " .. e.root)
    end
  end
  h.info(
    "cargo expand builds the crate (build.rs and proc macros run), so it asks first in a workspace that is not trusted"
  )
end

return M
