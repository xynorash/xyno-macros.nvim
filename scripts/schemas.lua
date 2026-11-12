-- Maintenance of the attribute schemas in data/macro_attrs/*.json.
--
--   nvim -l scripts/schemas.lua check [file ...]   strict validation (exit 1 on any error)
--   nvim -l scripts/schemas.lua fmt FILE ...       rewrite in the canonical layout (key order, 2 spaces)
--   nvim -l scripts/schemas.lua drift              compare with crates.io and the docs URLs (needs network + curl)
--   nvim -l scripts/schemas.lua new CRATE          print an empty schema for CRATE
--
-- `check` is stricter than the loader in lua/xyno_macros/attrs.lua, which only refuses what it cannot
-- use: unknown fields (typos), enum without values, conflicts/requires naming a key that does not
-- exist, bad `applies_to` words, unreadable version ranges, snippets with unbalanced placeholders,
-- non-https links. tests/schemas_spec.lua runs it, so a schema cannot drift into a broken state.
local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local repo = vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(here, ":p")))
vim.opt.rtp:prepend(repo)
local rust = vim.env.XYNO_RUST_DIR
if not rust or rust == "" then
  rust = vim.fs.dirname(repo) .. "/xyno-rust.nvim"
end
vim.opt.rtp:append(rust)

local S = {}

local KINDS =
  { flag = true, string = true, ident = true, path = true, int = true, bool = true, enum = true, expr = true }
local TARGETS = {
  container = true,
  ["container:struct"] = true,
  ["container:enum"] = true,
  field = true,
  variant = true,
  fn = true,
  param = true,
}
local FILE_FIELDS = { crate = true, versions = true, docs_url = true, attributes = true, verified = true }
local ATTR_FIELDS =
  { name = true, derives = true, applies_to = true, needs_attr = true, docs_url = true, doc = true, args = true }
local ARG_FIELDS = {
  key = true,
  kind = true,
  doc = true,
  applies_to = true,
  derives = true,
  values = true,
  quoted = true,
  conflicts = true,
  requires = true,
  repeatable = true,
  since = true,
  nested = true,
  positional = true,
  doc_url = true,
  snippet = true,
  alt = true,
}
local ALT_FIELDS = { label = true, snippet = true, doc = true }

local ORDER = {
  file = { "crate", "versions", "docs_url", "verified", "attributes" },
  attr = { "name", "derives", "applies_to", "needs_attr", "docs_url", "doc", "args" },
  arg = {
    "key",
    "kind",
    "doc",
    "applies_to",
    "derives",
    "values",
    "quoted",
    "conflicts",
    "requires",
    "repeatable",
    "since",
    "nested",
    "positional",
    "doc_url",
    "snippet",
    "alt",
  },
  value = { "value", "doc" },
  alt = { "label", "snippet", "doc" },
}

local function is_list(t)
  return type(t) == "table" and (next(t) == nil or vim.islist(t))
end

--- Placeholders of an LSP snippet must be `$n`, `${n}` or `${n:text}` with balanced braces.
local function snippet_ok(s)
  local depth = 0
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" then
      i = i + 1
    elseif c == "$" and s:sub(i + 1, i + 1) == "{" then
      if not s:match("^%${%d+[:}]", i) and not s:match("^%${%d+|", i) then
        return false
      end
      depth = depth + 1
      i = i + 1
    elseif c == "}" and depth > 0 then
      depth = depth - 1
    end
    i = i + 1
  end
  return depth == 0
end

local function https(u)
  return type(u) == "string" and u:match("^https://[%w.-]+/") ~= nil
end

local function check_range(r)
  if r == "*" then
    return true
  end
  for comp in r:gmatch("[^,]+") do
    if not comp:match("^%s*[<>=~^]*%s*%d+%.?%d*%.?%d*%s*$") then
      return false
    end
  end
  return true
end

---@return string[] errors, string[] warnings
function S.validate(data, source)
  local errs, warns = {}, {}
  local function bad(path, msg)
    errs[#errs + 1] = ("%s: %s: %s"):format(source, path, msg)
  end
  local cm = require("xyno_rust.crate_meta")
  if type(data) ~= "table" then
    return { source .. ": not an object" }, warns
  end
  for k in pairs(data) do
    if not FILE_FIELDS[k] then
      bad("file", "unknown field `" .. tostring(k) .. "`")
    end
  end
  if type(data.crate) ~= "string" or not cm.valid_name(data.crate) then
    bad("crate", "must be a crate name")
  elseif source:match("%.json$") then
    local base = vim.fs.basename(source):gsub("%.json$", "")
    if base:gsub("-", "_") ~= data.crate:gsub("-", "_") then
      bad("crate", ("file name `%s` does not match crate `%s`"):format(base, data.crate))
    end
  end
  if type(data.versions) ~= "string" or not check_range(data.versions) then
    bad("versions", 'must be a cargo-style range such as ">=1.0.0, <2.0.0"')
  end
  if not https(data.docs_url) then
    bad("docs_url", "must be an https link")
  end
  if data.verified == nil then
    warns[#warns + 1] = source .. ": no `verified` note (date and crate version the schema was checked against)"
  elseif type(data.verified) ~= "string" then
    bad("verified", "must be a string")
  end
  if not is_list(data.attributes) or #data.attributes == 0 then
    bad("attributes", "must be a non-empty list")
    return errs, warns
  end
  for i, a in ipairs(data.attributes) do
    local ap = ("attributes[%d]"):format(i)
    if type(a) ~= "table" or type(a.name) ~= "string" or not a.name:match("^[%w_]+[%w_:]*$") then
      bad(ap, "needs a `name` (path of identifiers)")
    else
      ap = a.name .. (a.derives and "" or "")
      for k in pairs(a) do
        if not ATTR_FIELDS[k] then
          bad(ap, "unknown field `" .. tostring(k) .. "`")
        end
      end
      for _, f in ipairs({ "derives", "applies_to", "needs_attr" }) do
        if a[f] ~= nil and not is_list(a[f]) then
          bad(ap, f .. " must be a list")
        end
      end
      for _, t in ipairs(a.applies_to or {}) do
        if not TARGETS[t] then
          bad(ap, "applies_to: unknown target `" .. tostring(t) .. "`")
        end
      end
      for _, d in ipairs(a.derives or {}) do
        if type(d) ~= "string" or not d:match("^[%w_]+$") then
          bad(ap, "derives: `" .. tostring(d) .. "` is not a derive name")
        end
      end
      if a.docs_url ~= nil and not https(a.docs_url) then
        bad(ap, "docs_url must be an https link")
      end
      if not is_list(a.args) then
        bad(ap, "args must be a list (empty for an attribute without keys)")
      else
        local keys, seen = {}, {}
        for _, arg in ipairs(a.args) do
          if type(arg) == "table" and type(arg.key) == "string" then
            keys[arg.key] = true
            keys[arg.key:match("^[^(]+") or arg.key] = true -- `not(source)` is written, and so conflicted with, as `not`
          end
        end
        for j, arg in ipairs(a.args) do
          local gp = ("%s.args[%d]"):format(ap, j)
          if type(arg) ~= "table" or type(arg.key) ~= "string" or arg.key == "" then
            bad(gp, "needs a `key`")
          else
            gp = ap .. "." .. arg.key
            for k in pairs(arg) do
              if not ARG_FIELDS[k] then
                bad(gp, "unknown field `" .. tostring(k) .. "`")
              end
            end
            local kind = arg.kind or "flag"
            if not KINDS[kind] then
              bad(gp, "unknown kind `" .. tostring(kind) .. "`")
            end
            if kind == "enum" and not (is_list(arg.values) and #arg.values > 0) then
              bad(gp, "an enum needs `values`")
            end
            if kind ~= "enum" and (arg.values ~= nil or arg.quoted ~= nil) then
              bad(gp, "`values` and `quoted` belong to enum keys")
            end
            for _, v in ipairs(arg.values or {}) do
              if type(v) == "table" then
                for k in pairs(v) do
                  if not (k == "value" or k == "doc") then
                    bad(gp, "values: unknown field `" .. tostring(k) .. "`")
                  end
                end
              end
              if not (type(v) == "string" or (type(v) == "table" and type(v.value) == "string")) then
                bad(gp, "values: entries are strings or { value, doc }")
              end
            end
            for _, f in ipairs({ "applies_to", "derives", "conflicts", "requires", "nested" }) do
              if arg[f] ~= nil and not is_list(arg[f]) then
                bad(gp, f .. " must be a list")
              end
            end
            for _, t in ipairs(arg.applies_to or {}) do
              if not TARGETS[t] then
                bad(gp, "applies_to: unknown target `" .. tostring(t) .. "`")
              end
            end
            for _, f in ipairs({ "conflicts", "requires" }) do
              for _, other in ipairs(arg[f] or {}) do
                if not keys[other] then
                  bad(gp, ("%s names `%s`, which is not a key of this attribute"):format(f, tostring(other)))
                elseif other == arg.key then
                  bad(gp, f .. " names itself")
                end
              end
            end
            if arg.since ~= nil and not (type(arg.since) == "string" and cm.valid_version(arg.since)) then
              bad(gp, "since must be a version such as 1.0.60")
            end
            if arg.doc == nil or arg.doc == "" then
              warns[#warns + 1] = ("%s: %s: no `doc`"):format(source, gp)
            end
            if arg.snippet ~= nil and not (type(arg.snippet) == "string" and snippet_ok(arg.snippet)) then
              bad(gp, "snippet has an unbalanced or malformed placeholder")
            end
            if arg.doc_url ~= nil and not https(arg.doc_url) then
              bad(gp, "doc_url must be an https link")
            end
            for _, alt in ipairs(arg.alt or {}) do
              for k in pairs(type(alt) == "table" and alt or {}) do
                if not ALT_FIELDS[k] then
                  bad(gp, "alt: unknown field `" .. tostring(k) .. "`")
                end
              end
              if
                type(alt) ~= "table"
                or type(alt.label) ~= "string"
                or (alt.snippet ~= nil and not snippet_ok(alt.snippet))
              then
                bad(gp, "alt entries need a label and a well-formed snippet")
              end
            end
            -- the same key twice is fine for different targets or derives, a plain duplicate is not
            local sig = arg.key
              .. "|"
              .. table.concat(arg.applies_to or {}, ",")
              .. "|"
              .. table.concat(arg.derives or {}, ",")
            if seen[sig] then
              bad(gp, "listed twice for the same targets and derives")
            end
            seen[sig] = true
          end
        end
      end
    end
  end
  return errs, warns
end

-- ------------------------------------------------------------- canonical layout

local function enc(v, order_name, indent)
  local pad = ("  "):rep(indent)
  local pad1 = ("  "):rep(indent + 1)
  if type(v) ~= "table" then
    return vim.json.encode(v)
  end
  if is_list(v) then
    if #v == 0 then
      return "[]"
    end
    local child = ({ attributes = "attr", args = "arg", alt = "alt" })[order_name]
    local parts = {}
    for _, x in ipairs(v) do
      local name = child
      if order_name == "values" and type(x) == "table" then
        name = "value"
      end
      parts[#parts + 1] = pad1 .. enc(x, name, indent + 1)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
  end
  local order = ORDER[order_name] or {}
  local keys, done = {}, {}
  for _, k in ipairs(order) do
    if v[k] ~= nil then
      keys[#keys + 1] = k
      done[k] = true
    end
  end
  local rest = {}
  for k in pairs(v) do
    if not done[k] then
      rest[#rest + 1] = k
    end
  end
  table.sort(rest)
  vim.list_extend(keys, rest)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = pad1 .. vim.json.encode(k) .. ": " .. enc(v[k], k, indent + 1)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
end

function S.format(data)
  return enc(data, "file", 0) .. "\n"
end

local function read_json(path)
  local f = io.open(path, "rb")
  if not f then
    return nil, path .. ": cannot read"
  end
  local text = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok then
    return nil, path .. ": invalid JSON"
  end
  return data
end

local function files(args)
  if #args > 0 then
    return args
  end
  local out = vim.fn.glob(repo .. "/data/macro_attrs/*.json", true, true)
  table.sort(out)
  return out
end

-- ------------------------------------------------------------------ drift

local function curl(url)
  local r = vim
    .system({
      "curl",
      "-sS",
      "-L",
      "--max-time",
      "20",
      "-A",
      "xyno-macros-schema-check",
      "-o",
      "/dev/null",
      "-w",
      "%{http_code}",
      url,
    }, { text = true })
    :wait(30000)
  return r.stdout
end

local function newest(crate)
  local r = vim
    .system({
      "curl",
      "-sS",
      "--max-time",
      "20",
      "-A",
      "xyno-macros-schema-check",
      "https://crates.io/api/v1/crates/" .. crate,
    }, { text = true })
    :wait(30000)
  local ok, d = pcall(vim.json.decode, r.stdout or "")
  return ok and type(d) == "table" and d.crate and d.crate.max_stable_version or nil
end

local function run(argv)
  local cmd = argv[1]
  if cmd == "check" then
    local bad = 0
    for _, path in ipairs(files(vim.list_slice(argv, 2))) do
      local data, err = read_json(path)
      local errs, warns
      if data then
        errs, warns = S.validate(data, vim.fs.basename(path))
      else
        errs, warns = { err }, {}
      end
      for _, e in ipairs(errs) do
        io.stdout:write("error: ", e, "\n")
      end
      for _, w in ipairs(warns) do
        io.stdout:write("warning: ", w, "\n")
      end
      bad = bad + #errs
    end
    io.stdout:write(bad == 0 and "schemas ok\n" or ("%d error(s)\n"):format(bad))
    return bad == 0 and 0 or 1
  elseif cmd == "fmt" then
    local list = vim.list_slice(argv, 2)
    if #list == 0 then
      io.stderr:write("usage: schemas.lua fmt FILE ...\n")
      return 2
    end
    for _, path in ipairs(list) do
      local data, err = read_json(path)
      if not data then
        io.stderr:write(err, "\n")
        return 1
      end
      local f = assert(io.open(path, "wb"))
      f:write(S.format(data))
      f:close()
    end
    return 0
  elseif cmd == "drift" then
    local rc = 0
    for _, path in ipairs(files(vim.list_slice(argv, 2))) do
      local data = read_json(path)
      if data then
        local latest = newest(data.crate)
        local cm = require("xyno_rust.crate_meta")
        local am = require("xyno_macros.attrs")
        if not latest then
          io.stdout:write(("%s: crates.io did not answer\n"):format(data.crate))
        elseif not am.satisfies(latest, data.versions) then
          io.stdout:write(
            ("DRIFT %s: newest release %s is outside `%s`; re-read the docs\n"):format(
              data.crate,
              latest,
              data.versions
            )
          )
          rc = 1
        else
          io.stdout:write(
            ("ok    %s: newest release %s inside `%s` (%s)\n"):format(
              data.crate,
              latest,
              data.versions,
              data.verified or "not verified"
            )
          )
        end
        local _ = cm
        local urls = { data.docs_url }
        for _, a in ipairs(data.attributes or {}) do
          urls[#urls + 1] = a.docs_url
        end
        local seen = {}
        for _, u in ipairs(urls) do
          if not seen[u] then
            seen[u] = true
            local code = curl(u)
            if code ~= "200" then
              io.stdout:write(("DRIFT %s: %s answers %s\n"):format(data.crate, u, tostring(code)))
              rc = 1
            end
          end
        end
      end
    end
    return rc
  elseif cmd == "new" and argv[2] then
    io.stdout:write(S.format({
      crate = argv[2],
      versions = ">=1.0.0, <2.0.0",
      docs_url = "https://docs.rs/" .. argv[2] .. "/latest/" .. argv[2]:gsub("-", "_") .. "/",
      verified = os.date("%Y-%m-%d") .. " against " .. argv[2] .. " X.Y.Z",
      attributes = {
        {
          name = "attr",
          applies_to = { "container" },
          args = { { key = "key", kind = "flag", doc = "What it does." } },
        },
      },
    }))
    return 0
  end
  io.stderr:write("usage: nvim -l scripts/schemas.lua check [file ...] | fmt FILE ... | drift | new CRATE\n")
  return 2
end

if arg and arg[0] and arg[0]:match("schemas%.lua$") then
  os.exit(run(arg))
end
return S
