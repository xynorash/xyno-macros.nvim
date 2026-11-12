-- xyno-macros.nvim: macro help for Rust. setup() checks the dependencies, then starts
-- the attribute completion (xyno_macros.attrs) and the macro tools (xyno_macros.tools).
-- The two blink.cmp sources are registered by the user's blink config: M.blink_opts().
local M = {}

M.defaults = {
  commands = true, -- :MacroAttrs :MacroExpand :MacroFormatFix :MacroSignature :ProcMacroStatus
  keymaps = false, -- false | true | { expand = lhs|false, status = lhs|false, signature = lhs|false } (buffer-local in Rust buffers with rust-analyzer)
  snippets_allowed = nil, -- optional function(ctx) -> boolean: where select!/matches!/vec! snippets may appear
  trust = "auto", -- who decides before `cargo expand` builds the crate: "auto" | "local" | function(root, what, cb)
  popup = {}, -- layout of the macro popup: max_height, min_width, max_width, border, prefer (xyno_macros.ui.popup)
  attrs = {}, -- overrides of the attribute completion's tuning values (xyno_macros.attrs.config)
}

--- Default keys of `keymaps = true`.
M.default_keymaps = { expand = "<leader>rx", status = "<leader>rq", signature = "<C-k>" }

local REQUIRED = {
  { "xyno_rust.crate_meta", "xyno-rust.nvim (xynorash/xyno-rust.nvim)" },
  { "xyno_rust.code_actions", "xyno-rust.nvim (xynorash/xyno-rust.nvim)" },
  { "xyno_rust.fsutil", "xyno-rust.nvim (xynorash/xyno-rust.nvim)" },
  { "xyno_rust.rust_context", "xyno-rust.nvim (xynorash/xyno-rust.nvim)" },
  { "xyno_imports.engine", "xyno-imports.nvim (xynorash/xyno-imports.nvim)" },
}

--- The xyno-rust.nvim API this plugin was written against (see xyno_rust.compatible).
M.requires_rust_api = "1.1"

--- Fails with one clear line when xyno-rust.nvim is too old or too new for this plugin.
local function rust_api_ok(name)
  local ok, rust = pcall(require, "xyno_rust")
  if not ok or type(rust.compatible) ~= "function" then
    vim.notify(name .. ": the installed xyno-rust.nvim is too old to say which API it has (needs API " .. M.requires_rust_api .. "): update xyno-rust.nvim", vim.log.levels.ERROR)
    return false
  end
  local good, why = rust.compatible(M.requires_rust_api)
  if not good then
    vim.notify(name .. ": " .. why, vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Configure and start the plugin. Safe to call again (autocmd groups are cleared and redefined).
---@param opts? { commands?: boolean, keymaps?: boolean|table<string, string|false>, snippets_allowed?: fun(ctx: table): boolean, trust?: "auto"|"local"|fun(root: string, what: string, cb: fun(ok: boolean)), popup?: table, attrs?: table }
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if vim.fn.has("nvim-0.12") ~= 1 then
    vim.notify("xyno-macros: Neovim 0.12 or newer is required", vim.log.levels.ERROR)
    return
  end
  for _, req in ipairs(REQUIRED) do
    if not pcall(require, req[1]) then
      vim.notify("xyno-macros: needs " .. req[2] .. ", which is not installed", vim.log.levels.ERROR)
      return
    end
  end
  if not rust_api_ok("xyno-macros") then
    return
  end
  if opts.trust == "auto" or opts.trust == "local" or type(opts.trust) == "function" then
    require("xyno_macros.trust").config.provider = opts.trust
  else
    vim.notify("xyno-macros: option trust must be \"auto\", \"local\" or a function; using \"auto\"", vim.log.levels.WARN)
    require("xyno_macros.trust").config.provider = "auto"
  end
  local problems = {}
  local ui = require("xyno_macros.ui")
  local pp = ui.validate_popup(opts.popup)
  if #pp == 0 then
    ui.set_popup(opts.popup)
  else
    vim.list_extend(problems, pp)
    ui.set_popup({}) -- the defaults stay
  end
  ui.setup()
  local attrs = require("xyno_macros.attrs")
  if type(opts.attrs) ~= "table" then
    problems[#problems + 1] = "attrs must be a table"
  else
    for k, v in pairs(opts.attrs) do
      local cur = attrs.config[k]
      if cur == nil then
        problems[#problems + 1] = ("unknown attrs option `%s`"):format(tostring(k))
      elseif type(v) ~= type(cur) then
        problems[#problems + 1] = ("attrs.%s must be a %s, got %s"):format(k, type(cur), vim.inspect(v))
      elseif type(v) == "number" and (v ~= v or v < 0 or v == math.huge) then
        problems[#problems + 1] = ("attrs.%s must be a finite number, got %s"):format(k, vim.inspect(v))
      else
        attrs.config[k] = v
      end
    end
  end
  if #problems > 0 then
    vim.notify("xyno-macros: invalid options ignored:\n  " .. table.concat(problems, "\n  "), vim.log.levels.WARN)
  end
  attrs.setup({ commands = opts.commands })
  require("xyno_macros.tools").setup({
    commands = opts.commands,
    keymaps = opts.keymaps,
    snippets_allowed = opts.snippets_allowed,
  })
end

--- For blink.cmp: registers both sources (attribute / derive completion with priority over
--- rust-analyzer's path items inside attributes, and the macro snippets). Use it as a lazy.nvim
--- `opts` function of blink.cmp: `opts = function(_, o) return require("xyno_macros").blink_opts(o) end`
--- (also accepts the (_, opts) call shape).
function M.blink_opts(a, b)
  local opts = b or a
  opts.sources = opts.sources or {}
  opts.sources.providers = opts.sources.providers or {}
  opts.sources.providers.macro_attrs = {
    name = "MacroAttrs",
    module = "xyno_macros.attrs",
    -- above rust-analyzer's generic path items (core::, std::, ...) inside attributes
    score_offset = 100,
  }
  opts.sources.per_filetype = opts.sources.per_filetype or {}
  opts.sources.per_filetype.rust = { "macro_attrs", inherit_defaults = true }
  return require("xyno_macros.tools").blink_opts(nil, opts)
end

return M
