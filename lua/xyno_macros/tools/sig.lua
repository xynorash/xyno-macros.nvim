-- xyno-macros tools: call context, popup text and the signature popup.
-- Part of xyno_macros.tools (the facade merges every part into one table).
local M = {}

local uv = vim.uv

local Lex = require("xyno_macros.tools.lex")
local Rules = require("xyno_macros.tools.rules")
local Format = require("xyno_macros.tools.format")
local FRAGMENT_DOC = Rules.fragment_doc
local is_p = Lex._is_p
local FALLBACK = Rules._FALLBACK
local ns = Format._ns

-- ================================================================ call context

--- The macro call the text ends in (the text is everything before the
--- cursor): { name, path, id, group (open) | nil when only `name!` was typed,
--- innermost (the macro's group is the innermost open group), pending }.
function M.context_before(text, opts)
  local toks = Lex.lex(text, opts)
  local chain = {} -- open groups, outermost first, with the token list they sit in
  local list = toks
  while true do
    local last = list[#list]
    if last and last.t == "group" and last.open then
      chain[#chain + 1] = { group = last, list = list, index = #list }
      list = last.kids
    else
      break
    end
  end
  -- `name!` typed, nothing after it yet
  local last = list[#list]
  if is_p(last, "!") and list[#list - 1] and list[#list - 1].t == "id" then
    local id = list[#list - 1]
    return { name = id.s, id = id, pending = true, innermost = true }
  end
  for depth = #chain, 1, -1 do
    local link = chain[depth]
    local k = link.index
    local sib = link.list
    if is_p(sib[k - 1], "!") and sib[k - 2] and sib[k - 2].t == "id" then
      local id = sib[k - 2]
      local path
      if is_p(sib[k - 3], "::") and sib[k - 4] and sib[k - 4].t == "id" then
        local j = k - 4
        while is_p(sib[j - 1], "::") and sib[j - 2] and sib[j - 2].t == "id" do
          j = j - 2
        end
        path = sib[j].s
      end
      return { name = id.s, path = path, id = id, group = link.group, innermost = depth == #chain }
    end
  end
  return nil
end

-- ================================================================ popup text

--- Popup lines for a macro definition and the typed tokens: { lines, active
--- (line index of the best arm, 1-based) | nil, arms = lines of arms }.
function M.popup(name, def, toks, extra)
  local m = Rules.match_arms(def, toks or {})
  local lines, marks = {}, {}
  local any = false
  for i, arm in ipairs(def.arms) do
    local close = ({ ["("] = ")", ["["] = "]", ["{"] = "}" })[arm.delim]
    local body = arm.matcher == "" and "" or (" " .. arm.matcher .. " ")
    local viable = m.results[i] >= 1
    any = any or viable
    lines[#lines + 1] = (i == m.best and "> " or "  ") .. name .. "!" .. arm.delim .. body .. close
    marks[#marks + 1] = { line = #lines, best = i == m.best, viable = viable }
  end
  local arms_n = #lines
  -- fragment legend: the best arm's; every viable arm when that one has no
  -- fragments (the empty arm of vec!) or nothing fits yet
  local best_has = m.best and #Rules.fragments(def.arms[m.best].matcher) > 0
  local seen, legend = {}, {}
  for i, arm in ipairs(def.arms) do
    if (best_has and i == m.best) or (not best_has and (m.results[i] >= 1 or not m.best)) then
      for _, f in ipairs(Rules.fragments(arm.matcher)) do
        local key = f.name .. ":" .. f.spec
        if not seen[key] then
          seen[key] = true
          legend[#legend + 1] = ("$%s: %s - %s"):format(f.name, f.spec, FRAGMENT_DOC[f.spec] or "fragment")
        end
      end
    end
  end
  if #legend > 0 then
    lines[#lines + 1] = ""
    vim.list_extend(lines, legend)
  end
  if extra then
    lines[#lines + 1] = ""
    vim.list_extend(lines, extra)
  end
  if not m.best and #toks > 0 and not any then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "no arm fits the arguments typed so far"
  end
  return { lines = lines, marks = marks, best = m.best, arms = arms_n }
end

-- ============================================================= signature help

local LSP_DEF_TIMEOUT = 5000
local sig = { win = nil, buf = nil, seq = 0, key = nil, def = nil, label = nil }

local function close_popup()
  if sig.win and vim.api.nvim_win_is_valid(sig.win) then
    pcall(vim.api.nvim_win_close, sig.win, true)
  end
  sig.win = nil
  sig.key = nil
  sig.def = nil
end
M.close_popup = close_popup

--- The popup window while it is open (specs read it).
function M.popup_win()
  return sig.win and vim.api.nvim_win_is_valid(sig.win) and sig.win or nil
end

local function lsp_character(bufnr, row, col, enc)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local ok, ch = pcall(vim.str_utfindex, line, enc, math.min(col, #line), false)
  return ok and ch or col
end

local function ra_client(bufnr)
  return require("xyno_rust.code_actions").clients(bufnr)[1]
end

--- Lines of a file (an open buffer wins over the disk), nil when unreadable or huge.
local function file_text(fname)
  local b = vim.fn.bufnr(fname)
  if b > 0 and vim.api.nvim_buf_is_loaded(b) then
    return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  end
  local st = uv.fs_stat(fname)
  if not st or st.type ~= "file" or st.size > 3000000 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, fname)
  return ok and table.concat(lines, "\n") or nil
end

--- Resolve the macro_rules! definition behind the name at (row, col) of
--- `bufnr` through textDocument/definition. cb(def, where) or cb(nil, reason).
function M.find_definition(bufnr, row, col, name, cb)
  local client = ra_client(bufnr)
  local function fallback(reason)
    if FALLBACK[name] then
      return cb(Rules.parse_macro_def(FALLBACK[name], nil, nil, name), "built-in table")
    end
    cb(nil, reason)
  end
  if not client then
    return fallback("no rust-analyzer client")
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = row, character = lsp_character(bufnr, row, col, client.offset_encoding or "utf-16") },
  }
  client:request("textDocument/definition", params, function(err, result)
    if err or not result or (vim.islist(result) and #result == 0) then
      return fallback("no definition found")
    end
    local loc = vim.islist(result) and result[1] or result
    local uri = loc.targetUri or loc.uri
    local range = loc.targetSelectionRange or loc.range
    if not uri or not range then
      return fallback("no definition found")
    end
    local fname = vim.uri_to_fname(uri)
    local src = file_text(fname)
    if not src then
      return fallback("cannot read " .. fname)
    end
    local def = Rules.parse_macro_def(src, range.start.line, range.start.character)
    if not def or #def.arms == 0 then
      return fallback("not a macro_rules! macro (a proc macro has no matcher arms)")
    end
    local home = vim.fs.normalize(vim.uv.os_homedir() or "")
    local short = vim.fs.normalize(fname):gsub("^" .. vim.pesc(home), "~"):gsub("^.*/library/", "")
    -- a file inside the working directory is shown relative to it (the absolute path of a project under /tmp or
    -- a deep checkout filled the popup's first line and was cut at the window edge)
    local rel = vim.fn.fnamemodify(fname, ":.")
    if rel:sub(1, 1) ~= "/" and rel:sub(1, 1) ~= "~" then
      short = rel
    end
    cb(def, ("%s:%d"):format(short, def.row + 1))
  end, bufnr)
end

local function open_popup(lines, marks)
  if not (sig.buf and vim.api.nvim_buf_is_valid(sig.buf)) then
    sig.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[sig.buf].bufhidden = "wipe"
  end
  vim.bo[sig.buf].modifiable = true
  vim.api.nvim_buf_set_lines(sig.buf, 0, -1, false, lines)
  vim.bo[sig.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(sig.buf, ns, 0, -1)
  for _, mk in ipairs(marks or {}) do
    vim.api.nvim_buf_set_extmark(sig.buf, ns, mk.line - 1, 0, {
      line_hl_group = mk.best and "XynoMacrosBest" or nil,
      end_row = mk.line - 1,
      hl_group = (not mk.best and not mk.viable) and "XynoMacrosDim" or nil,
      end_col = (not mk.best and not mk.viable) and #lines[mk.line] or nil,
    })
  end
  local lay = require("xyno_macros.ui").popup
  local width = lay.min_width
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width, lay.max_width or math.max(30, vim.o.columns - 6))
  local height = math.min(#lines, lay.max_height)
  local fits_below = vim.fn.winline() + height + 3 < vim.o.lines
  local fits_above = vim.fn.winline() - 1 >= height + 2
  local below = fits_below
  if lay.prefer == "above" and fits_above then
    below = false
  elseif not fits_below and not fits_above then
    below = vim.fn.winline() <= vim.o.lines / 2
  end
  local cfg = {
    relative = "cursor",
    row = below and 1 or 0,
    col = 0,
    width = width,
    height = height,
    anchor = below and "NW" or "SW",
    style = "minimal",
    focusable = false,
    noautocmd = true,
    border = lay.border or (vim.o.winborder ~= "" and vim.o.winborder or "rounded"),
  }
  if sig.win and vim.api.nvim_win_is_valid(sig.win) then
    vim.api.nvim_win_set_config(sig.win, cfg)
    vim.api.nvim_win_set_buf(sig.win, sig.buf)
  else
    sig.win = vim.api.nvim_open_win(sig.buf, false, cfg)
    vim.wo[sig.win].wrap = false
    vim.wo[sig.win].winhighlight = "NormalFloat:XynoMacrosFloat,FloatBorder:XynoMacrosBorder"
  end
end

local function extra_lines(ctx, toks)
  -- a format/sql macro also tells how its placeholders and arguments line up
  local g = ctx.group
  if not g then
    return nil
  end
  local call = { name = ctx.name, path = ctx.path, group = g }
  local fi = Format.format_info(call)
  if fi then
    return {
      ("format: %d placeholder%s, %d argument%s given"):format(
        fi.needs,
        fi.needs == 1 and "" or "s",
        fi.given,
        fi.given == 1 and "" or "s"
      ),
    }
  end
end

--- Show (or refresh) the macro popup for the call before the cursor.
--- opts.manual: <C-k> / :MacroSignature (also reports why nothing shows).
function M.signature(bufnr, opts)
  opts = opts or {}
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1] - 1, cur[2]
  local first = math.max(0, row - 300)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first, row + 1, false)
  if #lines == 0 then
    return
  end
  lines[#lines] = lines[#lines]:sub(1, col)
  local ctx = M.context_before(table.concat(lines, "\n"), { row0 = first })
  if not ctx or not (ctx.innermost or opts.manual) then
    if opts.manual and not ctx then
      return vim.lsp.buf.signature_help()
    end
    return close_popup()
  end
  local toks = ctx.group and ctx.group.kids or {}
  local key = ("%d:%d:%d:%s"):format(bufnr, ctx.id.sr, ctx.id.sc, ctx.name)
  local function render(def, where)
    if sig.key ~= key then
      return
    end
    local view = M.popup(ctx.name, def, toks, extra_lines(ctx, toks))
    local head = ctx.name .. "!" .. (where and ("  " .. where) or "")
    table.insert(view.lines, 1, head)
    for _, mk in ipairs(view.marks) do
      mk.line = mk.line + 1
    end
    open_popup(view.lines, view.marks)
  end
  if sig.key == key and sig.def then
    return render(sig.def, sig.where)
  end
  sig.key, sig.def = key, nil
  sig.seq = sig.seq + 1
  local seq = sig.seq
  local function request()
    if seq ~= sig.seq or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    M.find_definition(bufnr, ctx.id.sr, math.max(ctx.id.ec - 1, ctx.id.sc), ctx.name, function(def, where)
      if seq ~= sig.seq then
        return
      end
      if not def then
        if opts.manual then
          vim.notify(ctx.name .. "!: " .. tostring(where), vim.log.levels.INFO)
        end
        return close_popup()
      end
      sig.def, sig.where = def, where
      render(def, where)
    end)
  end
  -- rust-analyzer must have seen the typed `name!` before it can resolve it
  if opts.manual then
    request()
  else
    vim.defer_fn(request, 200)
  end
end

M._lsp_character = lsp_character
M._ra_client = ra_client
M._close_popup = close_popup
M._sig = sig

return M
