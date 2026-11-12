-- xyno-macros tools: blink.cmp snippet source for select!/matches!/vec![x; n].
-- Part of xyno_macros.tools (the facade merges every part into one table).
local M = {}

M.config = {
  snippets_allowed = nil, -- optional function(ctx) -> boolean, see M.snippets_allowed
}


-- ================================================================== snippets
-- A blink.cmp source (provider "macro_tools") for macro arms that rust-analyzer
-- does not complete: tokio::select!, matches!, vec![x; n].

local SNIPPETS = {
  {
    label = "select!",
    filter = "select",
    detail = "tokio::select! with two branches",
    text = "tokio::select! {\n\t${1:res} = ${2:future} => ${3:handler},\n\t${4:other} = ${5:future2} => ${0:handler2},\n}",
  },
  {
    label = "select! (shutdown loop)",
    filter = "select",
    detail = "tokio::select! { cancelled => break, recv => ... }",
    text = "tokio::select! {\n\t_ = ${1:token}.cancelled() => break,\n\t${2:msg} = ${3:rx}.recv() => {\n\t\t${0:todo!()}\n\t}\n}",
  },
  {
    label = "select! (biased)",
    filter = "select",
    detail = "tokio::select! with biased; order",
    text = "tokio::select! {\n\tbiased;\n\t${1:res} = ${2:future} => ${3:handler},\n\t${4:other} = ${5:future2} => ${0:handler2},\n}",
  },
  {
    label = "matches!",
    filter = "matches",
    detail = "matches!(expr, Pattern)",
    text = "matches!(${1:expr}, ${2:Pattern})",
  },
  {
    label = "matches! (guard)",
    filter = "matches",
    detail = "matches!(expr, Pattern if guard)",
    text = "matches!(${1:expr}, ${2:Pattern} if ${3:cond})",
  },
  {
    label = "vec![x; n]",
    filter = "vec",
    detail = "vec![value; len]",
    text = "vec![${1:value}; ${2:len}]",
  },
}
M.snippets = SNIPPETS

local Source = {}
Source.__index = Source

--- blink.cmp calls module.new(opts) for a provider with module = "xyno_macros.tools".
--- Are the snippets (select!, matches!, vec![x; n]) offered at ctx's position? Not after a
--- `.`, not inside a string or comment, and not in an expression position (call
--- arguments, struct literal fields, macro token trees; a block inside them is a
--- statement position again). The same guard xynovim used before the extraction. Replace it (setup() option `snippets_allowed`)
--- to decide differently; it gets blink's context (line, cursor, bufnr).
--- Whether the innermost bracket still open between the start of the (error) node and the
--- cursor is a `(` or `[`: `call(a, be` while typing has no `arguments` node yet.
local function unclosed_paren(node, ctx)
  local srow, scol = node:start()
  if srow ~= ctx.cursor[1] - 1 then
    return false
  end
  local stack = {}
  for ch in ctx.line:sub(scol + 1, ctx.cursor[2]):gmatch("[%(%)%[%]{}]") do
    if ch == "(" or ch == "[" or ch == "{" then
      stack[#stack + 1] = ch
    else
      stack[#stack] = nil
    end
  end
  return stack[#stack] == "(" or stack[#stack] == "["
end

local EXPRESSION_NODES = { arguments = true, field_initializer_list = true, token_tree = true }

function M.snippets_allowed(ctx)
  if type(M.config.snippets_allowed) == "function" then
    return M.config.snippets_allowed(ctx)
  end
  local before = ctx.line:sub(1, ctx.cursor[2])
  if before:match("[^%.]%.[%w_]*$") then
    return false
  end
  local ok, node = pcall(vim.treesitter.get_node, {
    bufnr = ctx.bufnr,
    pos = { ctx.cursor[1] - 1, math.max(ctx.cursor[2] - 1, 0) },
  })
  while ok and node do
    local t = node:type()
    local _, _, erow, ecol = node:range()
    -- a literal ends at its closing quote: the cursor behind it is outside
    local behind = t:find("literal$") and erow == ctx.cursor[1] - 1 and ecol <= ctx.cursor[2]
    if (t:find("string") or t:find("comment")) and not behind then
      return false
    end
    if t == "block" then
      break -- statement position (a closure body inside call arguments)
    end
    if EXPRESSION_NODES[t] then
      return false -- call arguments, struct literal fields, macro token trees
    end
    if t == "ERROR" and unclosed_paren(node, ctx) then
      return false
    end
    node = node:parent()
  end
  return true
end

function M.new(opts)
  return setmetatable({ opts = opts or {} }, Source)
end

function Source:enabled()
  return vim.bo.filetype == "rust"
end

function Source:get_completions(ctx, callback)
  if not M.snippets_allowed(ctx) then
    return callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
  end
  local kinds = vim.lsp.protocol.CompletionItemKind
  local items = {}
  for _, s in ipairs(SNIPPETS) do
    items[#items + 1] = {
      label = s.label,
      filterText = s.filter,
      kind = kinds.Snippet,
      insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet,
      insertText = s.text,
      detail = s.detail,
      documentation = { kind = "markdown", value = "```rust\n" .. s.text:gsub("%${%d:([^}]*)}", "%1"):gsub("%${0}", "") .. "\n```" },
    }
  end
  callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
  return function() end
end

--- blink.cmp opts: the provider registered and listed as a default source.
function M.blink_opts(_, opts)
  opts.sources = opts.sources or {}
  opts.sources.providers = opts.sources.providers or {}
  opts.sources.providers.macro_tools = {
    name = "Macro",
    module = "xyno_macros.tools",
    score_offset = -1,
  }
  if type(opts.sources.default) == "table" and not vim.tbl_contains(opts.sources.default, "macro_tools") then
    table.insert(opts.sources.default, "macro_tools")
  end
  return opts
end

return M
