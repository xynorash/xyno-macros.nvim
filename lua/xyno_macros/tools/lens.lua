-- xyno-macros tools: the macro lens (:MacroExpand): expandMacro in a read-only split, nested stepping, cargo expand fallback.
-- Part of xyno_macros.tools (the facade merges every part into one table).
local M = {}

local Lex = require("xyno_macros.tools.lex")
local Rules = require("xyno_macros.tools.rules")
local Sig = require("xyno_macros.tools.sig")
local each_call = Lex._each_call
local FALLBACK = Rules._FALLBACK
local lsp_character = Sig._lsp_character
local ra_client = Sig._ra_client

-- ====================================================================== lens
-- :MacroExpand - rust-analyzer/expandMacro in a read-only split.

local lens = { win = nil, buf = nil, stack = {}, origin = nil }

--- Top-level items of an expansion: { {label, row (0-based), kind} ... }.
function M.items_of(text)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, "rust")
  if not ok then
    return {}
  end
  local root = parser:parse()[1]:root()
  local out = {}
  local KINDS = {
    function_item = "fn",
    impl_item = "impl",
    struct_item = "struct",
    enum_item = "enum",
    trait_item = "trait",
    const_item = "const",
    static_item = "static",
    type_item = "type",
    mod_item = "mod",
  }
  local function label(node, src)
    local t = node:type()
    if t == "impl_item" then
      local body = node:field("body")[1]
      local srow, scol = node:range()
      local erow, ecol = (body or node):range()
      local head = vim.split(src, "\n", { plain = true })
      local parts = {}
      for r = srow, erow do
        local l = head[r + 1] or ""
        if r == erow then
          l = l:sub(1, ecol)
        end
        if r == srow then
          l = l:sub(scol + 1)
        end
        parts[#parts + 1] = l
      end
      return vim.trim((table.concat(parts, " "):gsub("%s+", " ")))
    end
    local nm = node:field("name")[1]
    return KINDS[t] .. " " .. (nm and vim.treesitter.get_node_text(nm, src) or "_")
  end
  local function walk(node, depth)
    for c in node:iter_children() do
      if KINDS[c:type()] then
        out[#out + 1] = { label = label(c, text), row = (c:range()), kind = KINDS[c:type()], depth = depth }
        local t = c:type()
        if t == "impl_item" or t == "mod_item" or t == "trait_item" then
          walk(c, depth + 1)
        elseif t == "const_item" then
          walk(c, depth) -- `const _: () = { ... };` (serde) wraps the items
        end
      elseif c:named_child_count() > 0 and c:type() ~= "function_item" then
        walk(c, depth)
      end
    end
  end
  walk(root, 0)
  -- a `const _: () = { ... };` wrapper (serde) is not an item worth listing
  return vim.tbl_filter(function(it)
    return not it.label:find("^const _")
  end, out)
end

--- The first generated item whose name is `word` (fn name, impl for/of it).
function M.find_symbol(items, word)
  if not word or word == "" then
    return nil
  end
  local pat = "%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]"
  for _, it in ipairs(items) do
    if it.kind == "fn" and it.label == "fn " .. word then
      return it
    end
  end
  for _, it in ipairs(items) do
    if it.label:find(pat) then
      return it
    end
  end
end

--- Normalised text of a call's group, for matching the same call elsewhere.
local function call_key(call, lines)
  local g = call.group
  local parts = {}
  for r = g.sr, g.er do
    local l = lines[r + 1] or ""
    local a = r == g.sr and g.sc + 1 or 1
    local b = r == g.er and g.ec or #l
    parts[#parts + 1] = l:sub(a, b)
  end
  return call.name .. "!" .. table.concat(parts, "\n"):gsub("%s+", "")
end

--- The innermost macro call of `text` that contains (row, col) (0-based).
function M.call_at(text, row, col)
  local lines = vim.split(text, "\n", { plain = true })
  local best
  each_call(Lex.lex(text), function(call)
    local a, b = call.id, call.group
    local before = row > a.sr or (row == a.sr and col >= a.sc)
    local after = row < b.er or (row == b.er and col < b.ec)
    if before and after then
      best = { name = call.name, id = a, group = b, key = call_key(call, lines) } -- inner calls come last
    end
  end)
  return best
end

--- A source call (any call of `text`) with the same name and arguments as
--- `key`, nearest to `near_row`.
function M.find_same_call(text, key, near_row)
  local lines = vim.split(text, "\n", { plain = true })
  local best, dist
  each_call(Lex.lex(text), function(call)
    if call_key(call, lines) == key then
      local d = math.abs(call.id.sr - near_row)
      if not dist or d < dist then
        best, dist = call, d
      end
    end
  end)
  return best
end

local function winbar_text(parts)
  return table.concat(
    vim.tbl_map(function(p)
      return (p:gsub("%%", "%%%%"))
    end, parts),
    "  |  "
  )
end

local function lens_items()
  return lens.buf
      and vim.api.nvim_buf_is_valid(lens.buf)
      and M.items_of(table.concat(vim.api.nvim_buf_get_lines(lens.buf, 0, -1, false), "\n"))
    or {}
end

local function lens_render()
  local lvl = lens.stack[#lens.stack]
  if not lvl then
    return
  end
  if not (lens.buf and vim.api.nvim_buf_is_valid(lens.buf)) then
    lens.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[lens.buf].buftype = "nofile"
    vim.bo[lens.buf].bufhidden = "wipe"
    vim.bo[lens.buf].swapfile = false
    local saved = vim.o.eventignore
    vim.o.eventignore = "FileType" -- no rustaceanvim attach on a scratch buffer
    vim.bo[lens.buf].filetype = "rust"
    vim.o.eventignore = saved
    pcall(vim.treesitter.start, lens.buf, "rust")
    M.lens_keys(lens.buf)
  end
  if not (lens.win and vim.api.nvim_win_is_valid(lens.win)) then
    vim.cmd("botright vsplit")
    lens.win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_win_set_buf(lens.win, lens.buf)
  vim.bo[lens.buf].modifiable = true
  vim.api.nvim_buf_set_lines(lens.buf, 0, -1, false, lvl.lines)
  vim.bo[lens.buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, lens.buf, "macro-expansion://" .. lvl.label)
  vim.wo[lens.win].number = false
  vim.wo[lens.win].wrap = false
  vim.wo[lens.win].foldenable = false
  local crumbs = {}
  for _, l in ipairs(lens.stack) do
    crumbs[#crumbs + 1] = l.label
  end
  local items = M.items_of(table.concat(lvl.lines, "\n"))
  local gen = {}
  for i = 1, math.min(3, #items) do
    gen[#gen + 1] = items[i].label
  end
  local parts =
    { table.concat(crumbs, " > "), ("expanded to %d line%s"):format(#lvl.lines, #lvl.lines == 1 and "" or "s") }
  if lvl.note then
    parts[#parts + 1] = lvl.note
  end
  if #gen > 0 then
    parts[#parts + 1] = "items: " .. table.concat(gen, ", ") .. (#items > 3 and (", +" .. (#items - 3)) or "")
  end
  parts[#parts + 1] = "<CR> step in  <BS> back  gi items  q close"
  vim.wo[lens.win].winbar = winbar_text(parts)
  if lvl.cursor_row then
    pcall(vim.api.nvim_win_set_cursor, lens.win, { math.min(lvl.cursor_row + 1, #lvl.lines), 0 })
  else
    pcall(vim.api.nvim_win_set_cursor, lens.win, { 1, 0 })
  end
end

local function lens_push(level)
  lens.stack[#lens.stack + 1] = level
  lens_render()
  vim.notify(("%s: expanded to %d lines"):format(level.label, #level.lines), vim.log.levels.INFO)
end

function M.lens_back()
  if #lens.stack <= 1 then
    return vim.notify("already at the outermost expansion", vim.log.levels.INFO)
  end
  table.remove(lens.stack)
  lens_render()
end

function M.lens_close()
  if lens.win and vim.api.nvim_win_is_valid(lens.win) then
    pcall(vim.api.nvim_win_close, lens.win, true)
  end
  lens.win, lens.stack = nil, {}
end

function M.lens_items()
  local items = lens_items()
  if #items == 0 then
    return vim.notify("no generated items in this expansion", vim.log.levels.INFO)
  end
  vim.ui.select(items, {
    prompt = "Generated items",
    format_item = function(it)
      return ("%s%s  (line %d)"):format(("  "):rep(it.depth or 0), it.label, it.row + 1)
    end,
  }, function(it)
    if it and lens.win and vim.api.nvim_win_is_valid(lens.win) then
      vim.api.nvim_set_current_win(lens.win)
      vim.api.nvim_win_set_cursor(lens.win, { it.row + 1, 0 })
      vim.cmd("normal! zz")
    end
  end)
end

--- <CR> in the lens: expand the macro call under the cursor of the expansion
--- by finding the same call in the source (rust-analyzer expands from source
--- positions only).
function M.lens_step()
  local origin = lens.origin
  if not (origin and vim.api.nvim_buf_is_valid(origin.bufnr)) then
    return vim.notify("the source buffer is gone", vim.log.levels.WARN)
  end
  local cur = vim.api.nvim_win_get_cursor(0)
  local text = table.concat(vim.api.nvim_buf_get_lines(lens.buf, 0, -1, false), "\n")
  local call = M.call_at(text, cur[1] - 1, cur[2])
  if not call then
    return vim.notify("no macro call under the cursor in the expansion", vim.log.levels.INFO)
  end
  local src = table.concat(vim.api.nvim_buf_get_lines(origin.bufnr, 0, -1, false), "\n")
  local found = M.find_same_call(src, call.key, origin.row)
  if not found then
    return vim.notify(
      ("%s! was generated by the expansion: rust-analyzer only expands macro calls written in the source"):format(
        call.name
      ),
      vim.log.levels.INFO
    )
  end
  M.expand({
    bufnr = origin.bufnr,
    row = found.id.sr,
    col = found.id.sc + 1,
    push = true,
    step = true,
  })
end

function M.lens_keys(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  map("q", M.lens_close, "Close macro expansion")
  map("<BS>", M.lens_back, "Back to the outer expansion")
  map("<CR>", M.lens_step, "Step into the macro call under the cursor")
  map("gi", M.lens_items, "Generated items")
end

--- Result of rust-analyzer/expandMacro at a position: cb(name, text) or cb(nil, err).
local function request_expand(bufnr, row, col, cb, retry_nil)
  local client = ra_client(bufnr)
  if not client then
    return cb(nil, "no rust-analyzer client attached")
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = row, character = lsp_character(bufnr, row, col, client.offset_encoding or "utf-16") },
  }
  local ask
  local function handle(err, result)
    if err then
      return cb(nil, err.message or "expandMacro failed")
    end
    if not result or not result.expansion or result.expansion == "" then
      -- right after a reload rust-analyzer may answer null for a call it
      -- expands a moment later
      if (retry_nil or 0) > 0 then
        retry_nil = retry_nil - 1
        return vim.defer_fn(ask, 300)
      end
      return cb(nil, nil)
    end
    -- rust-analyzer answers with this text when a proc macro cannot run
    if result.expansion:find("^Expansion had errors") then
      return cb(
        nil,
        "rust-analyzer could not expand it: "
          .. vim.trim((result.expansion:gsub("^Expansion had errors:%s*", "")))
          .. " (see :ProcMacroStatus)"
      )
    end
    cb(result.name or "macro", result.expansion)
  end
  -- rust-analyzer answers "content modified" while it reloads after an edit
  local tries = 0
  ask = function()
    client:request("rust-analyzer/expandMacro", params, function(err, result)
      if err and (err.code == -32801 or err.code == -32802) and tries < 8 then
        tries = tries + 1
        return vim.defer_fn(ask, 250)
      end
      handle(err, result)
    end, bufnr)
  end
  ask()
end
M.request_expand = request_expand

--- Positions of the attribute macros / derives of the item at the cursor:
--- { {row, col, label} ... } (the cursor is on the item itself, not on a call).
function M.item_macro_positions(bufnr, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "rust")
  if not ok or not parser then
    return {}
  end
  parser:parse()
  local node = vim.treesitter.get_node({ bufnr = bufnr, pos = { row, col } })
  local ITEM = {
    struct_item = true,
    enum_item = true,
    union_item = true,
    function_item = true,
    impl_item = true,
    trait_item = true,
    mod_item = true,
  }
  while node and not ITEM[node:type()] do
    if node:type() == "attribute_item" then
      local nxt = node:next_named_sibling()
      while nxt and nxt:type() == "attribute_item" do
        nxt = nxt:next_named_sibling()
      end
      node = nxt
      break
    end
    node = node:parent()
  end
  if not node then
    return {}
  end
  local out = {}
  local prev = node:prev_named_sibling()
  local attrs = {}
  while prev and (prev:type() == "attribute_item" or prev:type() == "line_comment" or prev:type() == "block_comment") do
    if prev:type() == "attribute_item" then
      table.insert(attrs, 1, prev)
    end
    prev = prev:prev_named_sibling()
  end
  local BUILTIN = {
    allow = true,
    warn = true,
    deny = true,
    forbid = true,
    cfg = true,
    cfg_attr = true,
    doc = true,
    test = true,
    inline = true,
    must_use = true,
    repr = true,
    derive = false,
    deprecated = true,
    expect = true,
    non_exhaustive = true,
    ["automatically_derived"] = true,
    no_mangle = true,
    export_name = true,
    cold = true,
    track_caller = true,
  }
  for _, a in ipairs(attrs) do
    local attr = a:named_child(0)
    local path = attr and attr:named_child(0)
    local pname = path and vim.treesitter.get_node_text(path, bufnr) or ""
    if pname == "derive" then
      local tt = attr:named_child(1)
      for c in (tt and tt:iter_children()) or function() end do
        if c:type() == "identifier" or c:type() == "scoped_identifier" then
          local r, cc = c:end_()
          -- end of the name: its last segment is where rust-analyzer finds the derive
          out[#out + 1] =
            { row = r, col = math.max(cc - 1, 0), label = "derive(" .. vim.treesitter.get_node_text(c, bufnr) .. ")" }
        end
      end
    elseif pname ~= "" and not BUILTIN[pname] then
      local r, cc = path:end_()
      out[#out + 1] = { row = r, col = math.max(cc - 1, 0), label = "#[" .. pname .. "]" }
    end
  end
  return out
end

--- `cargo expand` arguments for a file of a workspace member (nil, reason when
--- the file is no target of the member): { argv, scope }.
function M.expand_argv(member, file)
  local lib, bin
  for _, t in ipairs(member.targets or {}) do
    for _, k in ipairs(t.kind or {}) do
      if k == "lib" or k == "proc-macro" then
        lib = lib or t
      elseif k == "bin" then
        if t.src_path == file then
          bin = t
        end
      end
    end
  end
  local manifest = member.manifest_path
  local base = { "cargo", "expand", "--color", "never", "--manifest-path", manifest }
  local srcdir = lib and vim.fs.dirname(lib.src_path)
  if lib and file == lib.src_path then
    vim.list_extend(base, { "--lib" })
    return base, "the whole library crate"
  end
  if bin then
    vim.list_extend(base, { "--bin", bin.name })
    return base, "the whole binary crate"
  end
  if lib and srcdir and vim.startswith(file, srcdir .. "/") then
    local rel = file:sub(#srcdir + 2):gsub("%.rs$", ""):gsub("/mod$", "")
    local mod = rel:gsub("/", "::")
    if mod:find("^[%w_:]+$") then
      vim.list_extend(base, { "--lib", mod })
      return base, "module " .. mod
    end
  end
  return nil, "the file is not a target of the package"
end

local function cargo_expand_fallback(bufnr, push)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if vim.fn.executable("cargo-expand") ~= 1 then
    return vim.notify(
      "rust-analyzer expanded nothing here and cargo-expand is not installed (cargo install cargo-expand)",
      vim.log.levels.WARN
    )
  end
  local cm = require("xyno_rust.crate_meta")
  cm.metadata_async(file, function(meta, err)
    if not meta then
      return vim.notify("cargo expand fallback: " .. tostring(err), vim.log.levels.WARN)
    end
    local member = cm.member_of(meta, file)
    if not member then
      return vim.notify("cargo expand fallback: the file is not in a workspace member", vim.log.levels.WARN)
    end
    local argv, scope = M.expand_argv(member, file)
    if not argv then
      return vim.notify("cargo expand fallback: " .. scope, vim.log.levels.WARN)
    end
    -- cargo expand BUILDS the crate: build.rs and proc macros of the project and its
    -- dependencies run. Never without a trust decision for the workspace.
    require("xyno_macros.trust").require(meta.root, "cargo expand (" .. scope .. ")", function(trusted)
      if not trusted then
        return
      end
      vim.notify("rust-analyzer expanded nothing: running cargo expand for " .. scope .. " ...", vim.log.levels.INFO)
      M._run_cargo_expand(argv, meta.root, bufnr, scope, push)
    end)
  end)
end

function M._run_cargo_expand(argv, cwd, bufnr, scope, push)
  vim.system(
    argv,
    { text = true, cwd = cwd, timeout = 180000 },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then
        local msg = vim.trim(r.stderr or "")
        if msg:find("nightly", 1, true) or msg:find("-Z", 1, true) then
          msg = "cargo expand needs a nightly toolchain for this (rustup toolchain install nightly): "
            .. msg:sub(1, 200)
        end
        return vim.notify("cargo expand failed: " .. msg:sub(1, 400), vim.log.levels.WARN)
      end
      local lines = vim.split(r.stdout, "\n", { plain = true })
      lens.origin = lens.origin or { bufnr = bufnr, row = 0 }
      lens.origin.bufnr = bufnr
      local level = { label = "cargo expand", lines = lines, note = "FALLBACK (cargo expand, " .. scope .. ")" }
      if not push then
        lens.stack = {}
      end
      lens_push(level)
    end)
  )
end

M.cargo_expand_fallback = cargo_expand_fallback

--- :MacroExpand - expand the macro under the cursor. opts: bufnr, row, col
--- (0-based), push (keep the stack: stepping), step.
function M.expand(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local row, col = opts.row, opts.col
  local word
  if not row then
    local cur = vim.api.nvim_win_get_cursor(0)
    row, col = cur[1] - 1, cur[2]
    word = vim.fn.expand("<cword>")
  end
  if not ra_client(bufnr) then
    return vim.notify("MacroExpand: no rust-analyzer attached to this buffer", vim.log.levels.WARN)
  end
  if not opts.push then
    lens.origin = { bufnr = bufnr, row = row }
    lens.stack = {}
  end
  -- on a literal or identifier inside the arguments rust-analyzer finds no call at the cursor
  -- token's own macro-name position: ask at the start of the enclosing call (nearest ancestor)
  local ask_row, ask_col = row, col
  do
    local okp, parser = pcall(vim.treesitter.get_parser, bufnr, "rust")
    if okp and parser then
      pcall(function()
        parser:parse()
        local n = vim.treesitter.get_node({ bufnr = bufnr, pos = { row, col } })
        while n and n:type() ~= "macro_invocation" do
          n = n:parent()
        end
        if n then
          ask_row, ask_col = n:start()
        end
      end)
    end
  end
  local function show(name, text, note)
    local lines = vim.split((text:gsub("\n+$", "")), "\n", { plain = true })
    local level = { label = name:find("!$") and name or name .. "!", lines = lines, note = note }
    local sym = M.find_symbol(M.items_of(text), word)
    level.cursor_row = sym and sym.row or nil
    lens_push(level)
  end
  -- the cursor's own position first (a nested call inside println!'s arguments is no
  -- macro_invocation node: the ancestor would be the outer call), then the enclosing call
  local function request(cb)
    request_expand(bufnr, row, col, function(name, text)
      if name or (ask_row == row and ask_col == col) or opts.step then
        return cb(name, text)
      end
      request_expand(bufnr, ask_row, ask_col, function(n2, t2)
        if n2 then
          return cb(n2, t2)
        end
        cb(name, text or t2)
      end, 2)
    end, 2)
  end
  request(function(name, text)
    if name then
      return show(name, text)
    end
    if text then
      vim.notify("MacroExpand: " .. text, vim.log.levels.WARN)
    end
    if opts.step then
      return vim.notify("rust-analyzer returned no expansion for that call", vim.log.levels.INFO)
    end
    -- not on a call: the item's own derives and attribute macros
    local cands = M.item_macro_positions(bufnr, row, col)
    if #cands == 0 then
      -- cargo expand builds the crate: only for a cursor that is on a macro
      local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      local node = vim.treesitter.get_node({ bufnr = bufnr, pos = { row, col } })
      local on_macro = M.call_at(text, row, col) ~= nil
      while node and not on_macro do
        on_macro = node:type() == "attribute_item"
          or node:type() == "macro_definition"
          or node:type() == "macro_invocation"
        node = node:parent()
      end
      if not on_macro then
        return vim.notify("MacroExpand: no macro call, derive or attribute under the cursor", vim.log.levels.INFO)
      end
      return cargo_expand_fallback(bufnr, opts.push)
    end
    local parts, left = {}, #cands
    for i, c in ipairs(cands) do
      request_expand(bufnr, c.row, c.col, function(n, t)
        parts[i] = n and ("// ---- " .. c.label .. "\n" .. t) or false
        left = left - 1
        if left == 0 then
          local got = vim.tbl_filter(function(p)
            return p
          end, parts)
          if #got == 0 then
            return cargo_expand_fallback(bufnr, opts.push)
          end
          show("item", table.concat(got, "\n\n"), ("%d macro%s on this item"):format(#got, #got == 1 and "" or "s"))
        end
      end)
    end
  end)
end

return M
