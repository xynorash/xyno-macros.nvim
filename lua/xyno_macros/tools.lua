-- Macro tools:
--   * macro call help: signature popup for macro_rules! calls (the matcher arms
--     of the definition, found with go-to-definition), format-string and sqlx
--     bind hints, blink snippets for select!/matches!/vec![x; n]
--   * macro lens: :MacroExpand (rust-analyzer/expandMacro in a read-only split,
--     nested stepping, generated items, cargo expand fallback)
--   * proc-macro health: :ProcMacroStatus
--
-- Layout: this file is the facade (setup, commands, keys); the parts live in tools/:
--   lex, format, rules (pure: strings and tables in, tables out), then sig, snip, lens, status (UI).
-- The pure parts take strings and tables and are what tests/tools_spec.lua
-- drives table-wise. Everything that runs a program uses argv lists; crate
-- names that reach a path or a file are validated first.
local M = {}

local parts = { "lex", "format", "rules", "sig", "snip", "lens", "status" }
local P = {}
for _, name in ipairs(parts) do
  P[name] = require("xyno_macros.tools." .. name)
  for k, v in pairs(P[name]) do
    if k:sub(1, 1) ~= "_" then
      M[k] = v
    end
  end
end

local sig = P.sig._sig
local close_popup = P.sig._close_popup
local ra_client = P.sig._ra_client
local schedule_hints = P.format._schedule_hints

--- Buffer-local keys of `keymaps = true`.
M.default_keymaps = { expand = "<leader>rx", status = "<leader>rq", signature = "<C-k>" }

-- ====================================================================== setup

local keymaps = false -- set by setup(): false | table of lhs per action

local function buf_keys(buf)
  if not keymaps then
    return
  end
  local function map(mode, lhs, rhs, desc, force)
    if not lhs then
      return
    end
    local existing = vim.fn.maparg(lhs, mode, false, true)
    if not force and existing and existing.buffer == 1 and existing.desc and existing.desc ~= desc then
      return
    end
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc })
  end
  map("n", keymaps.expand, "<cmd>MacroExpand<cr>", "Expand macro under cursor (lens)")
  map("n", keymaps.status, "<cmd>ProcMacroStatus<cr>", "Proc-macro status")
  -- an LSP config may bind insert-mode <C-k> to vim.lsp.buf.signature_help: the macro
  -- popup first, that one when the cursor is not in a macro call
  map("i", keymaps.signature, function()
    M.signature(buf, { manual = true })
  end, "Macro / signature help", true)
end

function M.commands()
  vim.api.nvim_create_user_command("MacroExpand", function()
    M.expand()
  end, { desc = "Expand the macro under the cursor in a read-only split" })
  vim.api.nvim_create_user_command("MacroFormatFix", function()
    M.format_fix()
  end, { desc = "Add the missing arguments of the format macro at the cursor" })
  vim.api.nvim_create_user_command("MacroSignature", function()
    M.signature(nil, { manual = true })
  end, { desc = "Show the matcher arms of the macro call at the cursor" })
  vim.api.nvim_create_user_command("ProcMacroStatus", function()
    M.proc_macro_status()
  end, { desc = "Proc-macro crates, macros that were not expanded, rebuild / ignore" })
end

--- opts: { commands = true, keymaps = false | true | { expand, status, signature }, snippets_allowed = fn? }
function M.setup(opts)
  opts = opts or {}
  if opts.keymaps == true then
    keymaps = vim.deepcopy(M.default_keymaps)
  elseif type(opts.keymaps) == "table" then
    keymaps = opts.keymaps
  else
    keymaps = false
  end
  M.config.snippets_allowed = opts.snippets_allowed
  if opts.commands ~= false then
    M.commands()
  end
  local group = vim.api.nvim_create_augroup("xyno_macros", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "rust",
    callback = function(ev)
      schedule_hints(ev.buf)
      vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave", "BufWritePost" }, {
        group = group,
        buffer = ev.buf,
        callback = function()
          schedule_hints(ev.buf)
        end,
      })
    end,
  })
  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = group,
    callback = function(ev)
      if vim.bo[ev.buf].filetype ~= "rust" or not ra_client(ev.buf) then
        return
      end
      local ch = vim.v.char
      if ch == "(" or ch == "[" or ch == "{" or ch == "!" then
        vim.schedule(function()
          if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
            M.signature(ev.buf)
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    callback = function(ev)
      if sig.win and vim.api.nvim_win_is_valid(sig.win) and vim.bo[ev.buf].filetype == "rust" then
        M.signature(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    callback = close_popup,
  })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(ev)
      -- any client: LSP configs may set keys (<C-k>) again on every attach,
      -- so the maps follow the same events, after them
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(ev.buf) and #require("xyno_rust.code_actions").clients(ev.buf) > 0 then
          buf_keys(ev.buf)
        end
      end, 120)
    end,
  })
  -- buffers that attached before the setup ran
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].filetype == "rust" then
      schedule_hints(b)
      if #require("xyno_rust.code_actions").clients(b) > 0 then
        buf_keys(b)
      end
    end
  end
end

return M
