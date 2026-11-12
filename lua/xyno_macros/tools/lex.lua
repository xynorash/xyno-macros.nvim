-- xyno-macros tools: the lexer and the token helpers every other part uses.
-- Part of xyno_macros.tools (the facade merges every part into one table).
local M = {}

-- ===================================================================== lexer
-- A Rust token lexer that is only as exact as macro help needs: strings (raw,
-- byte, c), chars vs lifetimes, comments, numbers, groups. Groups nest; a
-- group that is not closed (the text ends while typing) has open = true.
--
-- token = { t = "id"|"lit"|"str"|"life"|"p"|"group", s = text, sr, sc, er, ec }
-- (0-based row, byte col, end exclusive); a group adds d = "(" | "[" | "{",
-- kids, open, and cr, cc = the position of its closing delimiter.

local PUNCT3 = { ["..="] = true, ["..."] = true, ["<<="] = true, [">>="] = true }
local PUNCT2 = {}
for _, p in ipairs({
  "=>",
  "::",
  "->",
  "..",
  "==",
  "!=",
  "<=",
  ">=",
  "&&",
  "||",
  "+=",
  "-=",
  "*=",
  "/=",
  "%=",
  "^=",
  "&=",
  "|=",
  "<<",
  ">>",
}) do
  PUNCT2[p] = true
end
local CLOSER = { ["("] = ")", ["["] = "]", ["{"] = "}" }

--- Tokens of `text`. opts.row0 / opts.col0 shift the reported positions (the
--- text starts there in its buffer).
function M.lex(text, opts)
  opts = opts or {}
  local n = #text
  local starts = { 1 }
  for i in text:gmatch("()\n") do
    starts[#starts + 1] = i + 1
  end
  local row0, col0 = opts.row0 or 0, opts.col0 or 0
  --- byte index (1-based) -> row, col (0-based)
  local function rc(i)
    local lo, hi = 1, #starts
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if starts[mid] <= i then
        lo = mid
      else
        hi = mid - 1
      end
    end
    local col = i - starts[lo]
    if lo == 1 then
      col = col + col0
    end
    return lo - 1 + row0, col
  end

  local function tok(t, i, j, extra) -- j exclusive
    local sr, sc = rc(i)
    local er, ec = rc(j)
    local o = { t = t, s = text:sub(i, j - 1), sr = sr, sc = sc, er = er, ec = ec }
    if extra then
      for k, v in pairs(extra) do
        o[k] = v
      end
    end
    return o
  end

  --- index after the string starting at i (a `"`), honouring `\`
  local function skip_string(i)
    local j = i + 1
    while true do
      local p = text:find('[\\"]', j)
      if not p then
        return n + 1
      end
      if text:sub(p, p) == "\\" then
        j = p + 2
      else
        return p + 1
      end
    end
  end

  local run
  run = function(i, close)
    local kids = {}
    while i <= n do
      local c = text:sub(i, i)
      if c:find("%s") then
        i = text:find("[^%s]", i) or (n + 1)
      elseif text:sub(i, i + 1) == "//" then
        i = (text:find("\n", i, true) or n) + 1
      elseif text:sub(i, i + 1) == "/*" then
        local depth, j = 1, i + 2
        while depth > 0 do
          local a, b = text:find("[/*]", j)
          if not a then
            j = n + 1
            break
          end
          local two = text:sub(a, a + 1)
          if two == "/*" then
            depth, j = depth + 1, a + 2
          elseif two == "*/" then
            depth, j = depth - 1, a + 2
          else
            j = b + 1
          end
        end
        i = j
      elseif c == '"' then
        local j = skip_string(i)
        kids[#kids + 1] = tok("str", i, j)
        i = j
      elseif c:find("[%a_\128-\255]") then
        local id = text:match("^[%w_\128-\255]+", i)
        local j = i + #id
        local nx = text:sub(j, j)
        if (id == "b" or id == "c") and nx == '"' then
          j = skip_string(j)
          kids[#kids + 1] = tok("str", i, j)
        elseif (id == "r" or id == "br" or id == "cr") and (nx == '"' or (nx == "#" and text:find('^#*"', j))) then
          local hashes = text:match("^#*", j)
          local body = j + #hashes + 1
          local a, b = text:find('"' .. hashes, body, true)
          j = a and (b + 1) or (n + 1)
          kids[#kids + 1] = tok("str", i, j)
        elseif id == "b" and nx == "'" then
          local a = text:find("'", j + 2 + (text:sub(j + 1, j + 1) == "\\" and 1 or 0), true)
          j = a and (a + 1) or (n + 1)
          kids[#kids + 1] = tok("lit", i, j)
        elseif id == "r" and nx == "#" and text:find("^#[%a_]", j) then
          j = j + #text:match("^#[%w_]+", j)
          kids[#kids + 1] = tok("id", i, j)
        else
          kids[#kids + 1] = tok("id", i, j)
        end
        i = j
      elseif c == "'" then
        local j
        if text:sub(i + 1, i + 1) == "\\" then
          local a = text:find("'", i + 3, true)
          j = a and (a + 1) or (n + 1)
          kids[#kids + 1] = tok("lit", i, j)
        elseif text:find("^'[%z\1-\127]'", i) then
          j = i + 3
          kids[#kids + 1] = tok("lit", i, j)
        elseif text:find("^'[\194-\244][\128-\191]*'", i) then
          j = i + #text:match("^'[\194-\244][\128-\191]*'", i)
          kids[#kids + 1] = tok("lit", i, j)
        elseif text:find("^'[%a_]", i) then
          j = i + #text:match("^'[%w_]+", i)
          kids[#kids + 1] = tok("life", i, j)
        else
          j = i + 1
          kids[#kids + 1] = tok("p", i, j)
        end
        i = j
      elseif c:find("%d") then
        local j = i + #text:match("^%d[%w_]*", i)
        while text:find("^%.%d", j) do
          j = j + #text:match("^%.%d[%w_]*", j)
        end
        kids[#kids + 1] = tok("lit", i, j)
        i = j
      elseif CLOSER[c] then
        local inner, j, closed = run(i + 1, CLOSER[c])
        local g = tok("group", i, closed and j or (n + 1), { d = c, kids = inner, open = not closed })
        if closed then
          g.cr, g.cc = rc(j - 1)
        end
        kids[#kids + 1] = g
        i = j
      elseif c == ")" or c == "]" or c == "}" then
        if c == close then
          return kids, i + 1, true
        end
        kids[#kids + 1] = tok("p", i, i + 1)
        i = i + 1
      else
        local w = 1
        if PUNCT3[text:sub(i, i + 2)] then
          w = 3
        elseif PUNCT2[text:sub(i, i + 1)] then
          w = 2
        end
        kids[#kids + 1] = tok("p", i, i + w)
        i = i + w
      end
    end
    return kids, n + 1, false
  end
  return (run(1, nil))
end

local function is_p(t, s)
  return t ~= nil and t.t == "p" and t.s == s
end

local function is_str(t)
  return t ~= nil and t.t == "str" and t.s:find('^[bcr]*#*"') ~= nil
end

--- The text of a string literal token without quotes and, for non-raw strings,
--- without `\u{...}` escapes (their braces are not placeholders).
function M.string_content(s)
  local prefix, hashes = s:match('^([bcr]*)(#*)"')
  if not prefix then
    return nil
  end
  local body = s:sub(#prefix + #hashes + 2)
  local tail = '"' .. hashes
  if body:sub(-#tail) == tail then
    body = body:sub(1, -#tail - 1)
  end
  if not prefix:find("r", 1, true) then
    body = body:gsub("\\u%b{}", "")
  end
  return body
end

--- Split the tokens of a group at top-level commas: { {tok, ...}, ... }. A
--- trailing comma adds no empty argument.
function M.split_args(kids)
  local args, cur = {}, {}
  for _, t in ipairs(kids) do
    if is_p(t, ",") then
      args[#args + 1] = cur
      cur = {}
    else
      cur[#cur + 1] = t
    end
  end
  if #cur > 0 then
    args[#args + 1] = cur
  end
  return args
end

--- Every `name!(...)` call of a token list, nested ones included:
--- cb({ name, path (first segment of `a::b::name!` or nil), id = token, group = token })
local function each_call(tokens, cb)
  for k, t in ipairs(tokens) do
    if t.t == "id" and is_p(tokens[k + 1], "!") and tokens[k + 2] and tokens[k + 2].t == "group" then
      local path
      if is_p(tokens[k - 1], "::") and tokens[k - 2] and tokens[k - 2].t == "id" then
        local j = k - 2
        while is_p(tokens[j - 1], "::") and tokens[j - 2] and tokens[j - 2].t == "id" do
          j = j - 2
        end
        path = tokens[j].s
      end
      cb({ name = t.s, path = path, id = t, group = tokens[k + 2] })
    end
    if t.t == "group" then
      each_call(t.kids, cb)
    end
  end
end
M.each_call = each_call

M._is_p = is_p
M._is_str = is_str
M._each_call = each_call
M._CLOSER = CLOSER

return M
