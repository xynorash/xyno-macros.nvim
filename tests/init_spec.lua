-- xyno_macros.setup(): options, opt-in keymaps, commands switch, snippet guard and the
-- one-line message when a dependency is missing.
local H = require("xyno_macros_test.helpers")
local M = require("xyno_macros")
local mt = require("xyno_macros.tools")

local ALL = { "MacroAttrs", "MacroExpand", "MacroFormatFix", "MacroSignature", "ProcMacroStatus" }

after_each(function()
  pcall(vim.cmd, "silent! %bwipeout!")
  for _, c in ipairs(ALL) do
    pcall(vim.api.nvim_del_user_command, c)
  end
  mt.config.snippets_allowed = nil
end)

describe("setup", function()
  it("registers the five commands and sets no keymap by default", function()
    M.setup({})
    for _, c in ipairs(ALL) do
      H.eq(2, vim.fn.exists(":" .. c), c)
    end
    H.eq("", vim.fn.maparg("<leader>rx", "n"))
    H.eq("", vim.fn.maparg("<leader>rq", "n"))
  end)

  it("commands = false registers none", function()
    M.setup({ commands = false })
    for _, c in ipairs(ALL) do
      H.eq(0, vim.fn.exists(":" .. c), c)
    end
  end)

  it("keymaps = true maps buffer-local keys when a client is attached, a table maps only what it lists", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "rust"
    local ca = require("xyno_rust.code_actions")
    local orig = ca.clients
    ca.clients = function()
      return { {} }
    end
    local function keys_after(opts)
      M.setup(opts)
      vim.api.nvim_exec_autocmds("LspAttach", { buffer = buf, data = { client_id = 1 } })
      H.wait_for(function()
        return vim.fn.maparg("<leader>rx", "n", false, true).buffer == 1 or vim.fn.maparg("<C-s>", "i", false, true).buffer == 1
      end, 3000, "the buffer-local key")
    end
    local ok, err = pcall(function()
      keys_after({ keymaps = true })
      H.eq("Expand macro under cursor (lens)", vim.fn.maparg("<leader>rx", "n", false, true).desc)
      H.eq("Proc-macro status", vim.fn.maparg("<leader>rq", "n", false, true).desc)
      H.eq("Macro / signature help", vim.fn.maparg("<C-k>", "i", false, true).desc)
      H.eq(1, vim.fn.maparg("<leader>rx", "n", false, true).buffer, "buffer-local")
      vim.keymap.del("n", "<leader>rx", { buffer = buf })
      vim.keymap.del("n", "<leader>rq", { buffer = buf })
      vim.keymap.del("i", "<C-k>", { buffer = buf })
      keys_after({ keymaps = { signature = "<C-s>", expand = false } })
      H.eq("Macro / signature help", vim.fn.maparg("<C-s>", "i", false, true).desc)
      H.eq("", vim.fn.maparg("<leader>rx", "n"))
      H.eq("", vim.fn.maparg("<leader>rq", "n"), "an action that is not listed is not mapped")
    end)
    ca.clients = orig
    if not ok then
      error(err, 0)
    end
  end)

  it("snippets_allowed: the default refuses after a dot, the option replaces it", function()
    M.setup({})
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    H.eq(false, mt.snippets_allowed({ line = "    x.sel", cursor = { 1, 9 }, bufnr = buf }))
    M.setup({ snippets_allowed = function()
      return false
    end })
    H.eq(false, mt.snippets_allowed({ line = "    sel", cursor = { 1, 7 }, bufnr = buf }))
  end)

  it("the shipped schemas are read from the plugin directory", function()
    local shipped = require("xyno_macros.attrs").shipped()
    H.ok(shipped.serde and shipped.clap and shipped.tokio and shipped.sqlx, "serde, clap, tokio, sqlx")
    H.eq(H.repo .. "/data/macro_attrs/serde.json", shipped.serde.source)
  end)
end)

describe("xyno-rust.nvim API pin", function()
  local rust = require("xyno_rust")
  local saved = rust.api_version
  after_each(function()
    rust.api_version = saved
  end)

  local function setup_with(version)
    rust.api_version = version
    local notes, orig = {}, vim.notify
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    local ok, err = pcall(require("xyno_macros").setup, {})
    vim.notify = orig
    H.ok(ok, tostring(err))
    return notes
  end

  it("states the API it needs and accepts it", function()
    local want = require("xyno_macros").requires_rust_api
    H.match(want, "^%d+%.%d+$")
    H.eq(true, (rust.compatible(want)))
  end)

  it("a newer major of xyno-rust.nvim: one clear error line, nothing started", function()
    local notes = setup_with("2.0")
    H.eq(1, #notes)
    H.match(notes[1].msg, "xyno-macros: xyno-rust api 2.0 is installed", true)
    H.eq(vim.log.levels.ERROR, notes[1].level)
  end)

  it("an older minor of xyno-rust.nvim says to update it", function()
    local notes = setup_with("1.0")
    H.eq(1, #notes)
    H.match(notes[1].msg, "update xyno-rust.nvim", true)
  end)
end)
