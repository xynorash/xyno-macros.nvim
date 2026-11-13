-- xyno-macros tools: format strings, sqlx binds and the inline hints.
-- Part of xyno_macros.tools (the facade merges every part into one table).
local M = {}

local uv = vim.uv

local Lex = require("xyno_macros.tools.lex")
local is_p = Lex._is_p
local is_str = Lex._is_str
local each_call = Lex._each_call

-- ============================================================ format strings

--- The placeholders of a format string (the content, not the literal):
--- { count, implicit (arguments taken by `{}` / `.*`), explicit = set of
--- indexes, names = set, max_explicit, needs } or nil, reason when the string
--- is malformed (rustc reports those itself).
function M.parse_format(s)
  local info = { count = 0, implicit = 0, explicit = {}, names = {}, max_explicit = -1 }
  local i = 1
  while true do
    local p = s:find("[{}]", i)
    if not p then
      break
    end
    local c = s:sub(p, p)
    if c == "{" and s:sub(p + 1, p + 1) == "{" then
      i = p + 2
    elseif c == "}" then
      if s:sub(p + 1, p + 1) ~= "}" then
        return nil, "unmatched }"
      end
      i = p + 2
    else
      local q = s:find("}", p + 1, true)
      if not q then
        return nil, "unmatched {"
      end
      local inner = s:sub(p + 1, q - 1)
      local arg, spec = inner:match("^([^:]*):?(.*)$")
      arg = vim.trim(arg)
      info.count = info.count + 1
      for ref in spec:gmatch("([%w_]+)%$") do
        if ref:find("^%d+$") then
          local ix = tonumber(ref)
          info.explicit[ix] = true
          info.max_explicit = math.max(info.max_explicit, ix)
        else
          info.names[ref] = true
        end
      end
      if spec:find(".*", 1, true) then
        info.implicit = info.implicit + 1
      end
      if arg == "" then
        info.implicit = info.implicit + 1
      elseif arg:find("^%d+$") then
        local ix = tonumber(arg)
        info.explicit[ix] = true
        info.max_explicit = math.max(info.max_explicit, ix)
      elseif arg:find("^[%a_][%w_]*$") then
        info.names[arg] = true
      end
      i = q + 1
    end
  end
  info.needs = math.max(info.implicit, info.max_explicit + 1)
  return info
end

-- macro -> index of the format string among its top-level arguments
local FORMAT_AT = {
  println = 0,
  print = 0,
  eprintln = 0,
  eprint = 0,
  format = 0,
  format_args = 0,
  panic = 0,
  unreachable = 0,
  todo = 0,
  unimplemented = 0,
  write = 1,
  writeln = 1,
  assert = 1,
  debug_assert = 1,
  assert_eq = 2,
  assert_ne = 2,
  debug_assert_eq = 2,
  debug_assert_ne = 2,
}
-- tracing/log: fields first, the message is the first argument that is only a
-- string literal
local TRACING = { trace = true, debug = true, info = true, warn = true, error = true }
local SQLX_AT = {
  query = 0,
  query_unchecked = 0,
  query_scalar = 0,
  query_scalar_unchecked = 0,
  query_as = 1,
  query_as_unchecked = 1,
}

--- Where the format string of `call` is among its arguments (0-based index),
--- or nil when the macro has none.
local function format_index(call, args)
  if FORMAT_AT[call.name] and (call.path == nil or call.path == "std" or call.path == "core") then
    return FORMAT_AT[call.name]
  end
  if TRACING[call.name] and (call.path == nil or call.path == "tracing" or call.path == "log") then
    for k, a in ipairs(args) do
      if #a == 1 and is_str(a[1]) then
        return k - 1
      end
    end
  end
end

local function range_of(tokens)
  local a, b = tokens[1], tokens[#tokens]
  return { sr = a.sr, sc = a.sc, er = b.er, ec = b.ec }
end

--- Placeholder count against the arguments of a call. Returns nil when the
--- macro has no format string (or it is not a plain literal), else
--- { idx, info, positional = {arg...}, named = {{name, arg}...}, given, needs }.
function M.format_info(call)
  local args = Lex.split_args(call.group.kids)
  local idx = format_index(call, args)
  local fa = idx and args[idx + 1]
  if not fa or #fa ~= 1 or not is_str(fa[1]) or fa[1].s:find("^b") then
    return nil
  end
  local info = M.parse_format(Lex.string_content(fa[1].s))
  if not info then
    return nil
  end
  local positional, named = {}, {}
  for k = idx + 2, #args do
    local a = args[k]
    if #a >= 3 and a[1].t == "id" and is_p(a[2], "=") then
      named[#named + 1] = { name = a[1].s, arg = a }
    else
      positional[#positional + 1] = a
    end
  end
  return {
    idx = idx,
    info = info,
    fmt = fa[1],
    positional = positional,
    named = named,
    given = #positional + #named,
    needs = info.needs,
  }
end

--- Hints for one call: { kind = "missing"|"unused"|"sql", message, needs, given,
--- sr, sc, er, ec, fixable }.
local function call_hints(call)
  local out = {}
  local fi = M.format_info(call)
  if fi then
    local P, Nn = #fi.positional, #fi.named
    if fi.needs > P + Nn then
      local miss = fi.needs - P - Nn
      out[#out + 1] = vim.tbl_extend("force", range_of({ fi.fmt }), {
        kind = "missing",
        needs = fi.needs,
        given = P + Nn,
        add = miss,
        fixable = Nn == 0,
        message = ("format string needs %d argument%s, %d given"):format(fi.needs, fi.needs == 1 and "" or "s", P + Nn),
      })
    else
      for i = 0, P - 1 do
        if i >= fi.info.implicit and not fi.info.explicit[i] then
          out[#out + 1] = vim.tbl_extend("force", range_of(fi.positional[i + 1]), {
            kind = "unused",
            needs = fi.needs,
            given = P + Nn,
            message = "argument is never used by the format string",
          })
        end
      end
      for k, nm in ipairs(fi.named) do
        local pos = P + k - 1
        if not fi.info.names[nm.name] and not (pos < fi.info.implicit or fi.info.explicit[pos]) then
          out[#out + 1] = vim.tbl_extend("force", range_of(nm.arg), {
            kind = "unused",
            needs = fi.needs,
            given = P + Nn,
            message = ("named argument `%s` is never used by the format string"):format(nm.name),
          })
        end
      end
    end
    return out
  end
  -- sqlx::query!("... $1 ... $2", a, b) / query_as!(T, "...", a)
  local sql_at = SQLX_AT[call.name]
  if sql_at and (call.path == nil or call.path == "sqlx") then
    local args = Lex.split_args(call.group.kids)
    local sa = args[sql_at + 1]
    if sa and #sa == 1 and is_str(sa[1]) then
      local binds = M.sql_binds(Lex.string_content(sa[1].s))
      local given = #args - sql_at - 1
      if binds ~= given then
        out[#out + 1] = vim.tbl_extend("force", range_of(sa), {
          kind = "sql",
          needs = binds,
          given = given,
          message = ("SQL binds %d parameter%s, %d argument%s given"):format(
            binds,
            binds == 1 and "" or "s",
            given,
            given == 1 and "" or "s"
          ),
        })
      end
    end
  end
  return out
end

--- Bind parameters of an SQL text: the highest `$n` (postgres), else the
--- number of `?` (mysql, sqlite). Quoted text and `--` comments are ignored.
function M.sql_binds(sql)
  sql = sql:gsub("%-%-[^\n]*", ""):gsub("'[^']*'", "''")
  local max = 0
  for d in sql:gmatch("%$(%d+)") do
    max = math.max(max, tonumber(d))
  end
  if max > 0 then
    return max
  end
  local _, q = sql:gsub("%?", "")
  return q
end

--- All hints of a Rust text (a whole buffer): see call_hints. Each hint also
--- has the closing position of its call (cr, cc) and `trailing` (the call
--- ends in a comma), which the fix needs.
function M.hints(text)
  local out = {}
  each_call(Lex.lex(text), function(call)
    for _, h in ipairs(call_hints(call)) do
      h.macro = call.name
      h.cr, h.cc = call.group.cr, call.group.cc
      local last = call.group.kids[#call.group.kids]
      h.trailing = is_p(last, ",")
      -- where an added argument goes: right after the last token, not before
      -- a closing delimiter that sits on a line of its own
      h.lr, h.lc = last and last.er or h.cr, last and last.ec or h.cc
      out[#out + 1] = h
    end
  end)
  return out
end

-- ================================================================ diagnostics

local ns = vim.api.nvim_create_namespace("xyno_macros_hints")
M.ns = ns
local MAX_SCAN_BYTES = 400000

--- Run the scan of `bufnr` now and publish the hint diagnostics.
function M.refresh_hints(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "rust" then
    return
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  if #text > MAX_SCAN_BYTES then
    return vim.diagnostic.reset(ns, bufnr)
  end
  local ds = {}
  for _, h in ipairs(M.hints(text)) do
    ds[#ds + 1] = {
      lnum = h.sr,
      col = h.sc,
      end_lnum = h.er,
      end_col = h.ec,
      severity = vim.diagnostic.severity.HINT,
      source = "xyno-macros",
      code = h.kind,
      message = h.message .. (h.fixable and " (:MacroFormatFix adds it)" or ""),
      user_data = { hint = h },
    }
  end
  vim.diagnostic.set(ns, bufnr, ds)
end

local timers = {}
local function schedule_hints(bufnr)
  local t = timers[bufnr]
  if not t then
    t = uv.new_timer()
    timers[bufnr] = t
  end
  t:stop()
  t:start(
    300,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.refresh_hints(bufnr)
      end
    end)
  )
end

--- :MacroFormatFix - append the missing arguments (`todo!()`) of the format
--- macro call around the cursor. Returns the number of arguments added.
function M.format_fix(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  M.refresh_hints(bufnr)
  local cur = vim.api.nvim_win_get_cursor(0)
  local row = cur[1] - 1
  local best
  for _, d in ipairs(vim.diagnostic.get(bufnr, { namespace = ns })) do
    local h = d.user_data and d.user_data.hint
    if h and h.kind == "missing" and h.fixable and h.cr then
      -- the call spans from the format string's line to its closing delimiter
      if row >= h.sr and row <= h.cr then
        if not best or h.sr >= best.sr then
          best = h
        end
      end
    end
  end
  if not best then
    vim.notify("no missing format argument at the cursor", vim.log.levels.INFO)
    return 0
  end
  local fill = {}
  for _ = 1, best.add do
    fill[#fill + 1] = "todo!()"
  end
  local text = table.concat(fill, ", ")
  text = best.trailing and (" " .. text .. ",") or (", " .. text)
  vim.api.nvim_buf_set_text(bufnr, best.lr, best.lc, best.lr, best.lc, { text })
  M.refresh_hints(bufnr)
  return best.add
end

M._ns = ns
M._schedule_hints = schedule_hints

return M
