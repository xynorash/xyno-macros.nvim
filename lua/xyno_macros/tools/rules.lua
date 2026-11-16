-- xyno-macros tools: macro_rules! definitions: parsing the matcher and matching a call against the arms.
-- Part of xyno_macros.tools (the facade merges every part into one table).
local M = {}

local Lex = require("xyno_macros.tools.lex")
local is_p = Lex._is_p
local CLOSER = Lex._CLOSER

-- ============================================================== macro_rules!
-- Matcher arms parsed with treesitter, matched against the typed arguments.

local FRAGMENT_DOC = {
  expr = "an expression",
  ty = "a type",
  ident = "an identifier",
  path = "a path (a::b)",
  pat = "a pattern",
  pat_param = "a pattern without a top-level |",
  stmt = "a statement",
  block = "a { block }",
  item = "an item (fn, struct, impl, ...)",
  meta = "the inside of an attribute",
  tt = "one token tree (a token or a delimited group)",
  lifetime = "a lifetime ('a)",
  literal = "a literal",
  vis = "a visibility (pub, may be empty)",
}
M.fragment_doc = FRAGMENT_DOC

-- Definitions of std macros for when the definition cannot be found (no
-- rust-src component): the arms only, enough for the popup.
local FALLBACK = {
  vec = "macro_rules! vec { () => (); ($elem:expr; $n:expr) => (); ($($x:expr),+ $(,)?) => (); }",
  matches = "macro_rules! matches { ($expression:expr, $pattern:pat $(if $guard:expr)? $(,)?) => {}; }",
  dbg = "macro_rules! dbg { () => {}; ($val:expr $(,)?) => {}; ($($val:expr),+ $(,)?) => {}; }",
}

local function same_tok(a, b)
  return a.t == b.t and a.s == b.s
end

--- Matcher tokens -> elements { k = "frag"|"lit"|"group"|"rep" }.
local function compile(toks)
  local out, i = {}, 1
  while i <= #toks do
    local t = toks[i]
    local nx = toks[i + 1]
    if is_p(t, "$") and nx and nx.t == "id" and is_p(toks[i + 2], ":") and toks[i + 3] and toks[i + 3].t == "id" then
      out[#out + 1] = { k = "frag", name = nx.s, spec = toks[i + 3].s }
      i = i + 4
    elseif is_p(t, "$") and nx and nx.t == "group" and nx.d == "(" then
      local j = i + 2
      local a, b = toks[j], toks[j + 1]
      local function op(x)
        return x and x.t == "p" and (x.s == "*" or x.s == "+" or x.s == "?") and x.s or nil
      end
      local sep, o
      if op(a) then
        o, j = op(a), j + 1
      elseif a and op(b) then
        sep, o, j = a, op(b), j + 2
      end
      if o then
        out[#out + 1] = { k = "rep", inner = compile(nx.kids), sep = sep, op = o }
        i = j
      else
        out[#out + 1] = { k = "lit", tok = t }
        i = i + 1
      end
    elseif t.t == "group" then
      out[#out + 1] = { k = "group", d = t.d, kids = compile(t.kids) }
      i = i + 1
    else
      out[#out + 1] = { k = "lit", tok = t }
      i = i + 1
    end
  end
  return out
end
M.compile_matcher = function(text)
  return compile(Lex.lex(text))
end

local function nullable(e)
  if e.k == "rep" then
    if e.op ~= "+" then
      return true
    end
    for _, x in ipairs(e.inner) do
      if not nullable(x) then
        return false
      end
    end
    return true
  end
  return e.k == "frag" and e.spec == "vis"
end

local function rest_nullable(elems, ei)
  for k = ei, #elems do
    if not nullable(elems[k]) then
      return false
    end
  end
  return true
end

local function is_literal_tok(t)
  return t.t == "lit" or t.t == "str" or (t.t == "id" and (t.s == "true" or t.s == "false"))
end

-- run-length fragments: the tokens one may contain, per fragment kind
local TYPE_PUNCT = {
  ["::"] = true,
  ["<"] = true,
  [">"] = true,
  [">>"] = true,
  ["&"] = true,
  ["*"] = true,
  ["!"] = true,
  [","] = true,
  ["->"] = true,
  ["?"] = true,
  ["+"] = true,
  ["="] = true,
  ["dyn"] = true,
}
local function run_ok(spec, t, depth)
  if
    (spec == "ty" or spec == "path")
    and (t.t == "str" or (t.t == "group" and t.d == "{") or (t.t == "p" and not TYPE_PUNCT[t.s]))
  then
    return false
  end
  if t.t == "p" then
    if spec ~= "item" then
      if t.s == ";" or t.s == "=>" then
        return false
      end
      if t.s == "," and depth <= 0 then
        return false
      end
    end
  end
  return true
end

local match_seq

--- 2 complete, 1 viable (more input may complete it), 0 no.
local function match_elem_group(e, tok, budget)
  if tok.t ~= "group" or tok.d ~= e.d then
    return 0
  end
  local r = match_seq(e.kids, 1, tok.kids, 1, function(ti)
    return ti == #tok.kids + 1 and 2 or 0
  end, budget)
  if tok.open then
    return r > 0 and 1 or 0
  end
  return r == 2 and 2 or 0
end

local RUN = { expr = true, ty = true, pat = true, pat_param = true, path = true, stmt = true, item = true, meta = true }

match_seq = function(elems, ei, toks, ti, cont, budget)
  budget.n = budget.n - 1
  if budget.n < 0 then
    return 1
  end
  if ei > #elems then
    return cont(ti)
  end
  if ti > #toks then
    if rest_nullable(elems, ei) then
      return cont(ti)
    end
    return 1
  end
  local e, t = elems[ei], toks[ti]
  if e.k == "lit" then
    if same_tok(e.tok, t) then
      return match_seq(elems, ei + 1, toks, ti + 1, cont, budget)
    end
    return 0
  elseif e.k == "group" then
    local r = match_elem_group(e, t, budget)
    if r == 0 then
      return 0
    elseif r == 1 then
      return 1
    end
    return match_seq(elems, ei + 1, toks, ti + 1, cont, budget)
  elseif e.k == "frag" then
    local spec = e.spec
    local single
    if spec == "tt" then
      single = true
    elseif spec == "ident" then
      single = t.t == "id"
    elseif spec == "lifetime" then
      single = t.t == "life"
    elseif spec == "block" then
      single = t.t == "group" and t.d == "{"
    elseif spec == "literal" then
      if is_p(t, "-") and toks[ti + 1] then
        if is_literal_tok(toks[ti + 1]) then
          return match_seq(elems, ei + 1, toks, ti + 2, cont, budget)
        end
        return 0
      end
      single = is_literal_tok(t)
    elseif spec == "vis" then
      local best = match_seq(elems, ei + 1, toks, ti, cont, budget)
      if best < 2 and t.t == "id" and t.s == "pub" then
        local used = (toks[ti + 1] and toks[ti + 1].t == "group" and toks[ti + 1].d == "(") and 2 or 1
        best = math.max(best, match_seq(elems, ei + 1, toks, ti + used, cont, budget))
      end
      return best
    end
    if single ~= nil then
      if single then
        return match_seq(elems, ei + 1, toks, ti + 1, cont, budget)
      end
      return 0
    end
    if RUN[spec] then
      local best, depth = 0, 0
      for len = 1, #toks - ti + 1 do
        local tk = toks[ti + len - 1]
        if spec == "ty" or spec == "path" then
          if is_p(tk, "<") then
            depth = depth + 1
          elseif is_p(tk, ">") then
            depth = depth - 1
          elseif is_p(tk, ">>") then
            depth = depth - 2
          end
        end
        if not run_ok(spec, tk, depth) then
          break
        end
        local r = match_seq(elems, ei + 1, toks, ti + len, cont, budget)
        if r > best then
          best = r
          if best == 2 then
            break
          end
        end
      end
      return best
    end
    -- an unknown fragment kind: take one token
    return match_seq(elems, ei + 1, toks, ti + 1, cont, budget)
  else -- rep
    local best = 0
    if e.op ~= "+" then
      best = match_seq(elems, ei + 1, toks, ti, cont, budget)
      if best == 2 then
        return 2
      end
    end
    local function iter(tj)
      return match_seq(e.inner, 1, toks, tj, function(tk)
        local r = match_seq(elems, ei + 1, toks, tk, cont, budget)
        if r == 2 or e.op == "?" or tk > #toks then
          return r
        end
        local nxt = tk
        if e.sep then
          if toks[tk] and same_tok(toks[tk], e.sep) then
            nxt = tk + 1
          else
            return r
          end
        end
        if nxt == tj then
          return r
        end
        return math.max(r, iter(nxt))
      end, budget)
    end
    return math.max(best, iter(ti))
  end
end

--- How the typed argument tokens fit one compiled arm: 2, 1 or 0.
function M.match_arm(elems, toks)
  return match_seq(elems, 1, toks, 1, function(ti)
    return ti == #toks + 1 and 2 or 0
  end, { n = 20000 })
end

--- Which arms fit `toks`: { results = {0|1|2 per arm}, best = index|nil }.
--- best is the first complete arm, else the first viable one.
function M.match_arms(def, toks)
  local results, best, viable = {}, nil, nil
  for i, arm in ipairs(def.arms) do
    local r = M.match_arm(arm.elems, toks)
    results[i] = r
    if r == 2 and not best then
      best = i
    end
    if r >= 1 and not viable then
      viable = i
    end
  end
  return { results = results, best = best or viable }
end

local function macro_def_at(root, src, row, col)
  local node = root:named_descendant_for_range(row, col, row, col)
  while node and node:type() ~= "macro_definition" do
    node = node:parent()
  end
  return node
end

local function def_of_node(node, src)
  local name_node = node:field("name")[1]
  local def =
    { name = name_node and vim.treesitter.get_node_text(name_node, src) or "?", arms = {}, row = node:range() }
  for child in node:iter_children() do
    if child:type() == "macro_rule" then
      local left = child:field("left")[1]
      if left then
        local text = vim.treesitter.get_node_text(left, src)
        local open, inner = text:sub(1, 1), text:sub(2, -2)
        def.arms[#def.arms + 1] = {
          delim = CLOSER[open] and open or "(",
          matcher = vim.trim((inner:gsub("%s+", " "))),
          elems = compile(Lex.lex(inner)),
        }
      end
    end
  end
  return def
end

--- The macro_rules! definition whose name is at row, col (0-based) of the
--- Rust text `src`; with row nil, the first definition named `name`. Returns
--- { name, arms = { {delim, matcher, elems} }, row } or nil.
function M.parse_macro_def(src, row, col, name)
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, "rust")
  if not ok then
    return nil
  end
  local root = parser:parse()[1]:root()
  if row then
    local node = macro_def_at(root, src, row, col or 0)
    return node and def_of_node(node, src) or nil
  end
  local function find(n)
    if n:type() == "macro_definition" then
      local nn = n:field("name")[1]
      if nn and vim.treesitter.get_node_text(nn, src) == name then
        return n
      end
    end
    for c in n:iter_children() do
      local f = find(c)
      if f then
        return f
      end
    end
  end
  local node = find(root)
  return node and def_of_node(node, src) or nil
end

--- Fragments `$name:kind` of an arm matcher: { {name, spec}... } (unique by
--- name, in order).
function M.fragments(matcher)
  local out, seen = {}, {}
  for name, spec in matcher:gmatch("%$([%w_]+)%s*:%s*([%w_]+)") do
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = { name = name, spec = spec }
    end
  end
  return out
end

M._FALLBACK = FALLBACK

return M
