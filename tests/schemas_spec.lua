-- The shipped attribute schemas pass the strict validator of scripts/schemas.lua, load through the
-- plugin's own loader, and the validator catches the mistakes it is there for.
local H = require("xyno_macros_test.helpers")
local S = dofile(H.repo .. "/scripts/schemas.lua")

local function read(path)
  local f = assert(io.open(path, "rb"))
  local t = f:read("*a")
  f:close()
  return vim.json.decode(t, { luanil = { object = true, array = true } })
end

local files = vim.fn.glob(H.repo .. "/data/macro_attrs/*.json", true, true)

describe("shipped schemas", function()
  it("there are at least the fourteen documented crates", function()
    H.ok(#files >= 14, tostring(#files))
    local shipped = require("xyno_macros.attrs").shipped()
    for _, c in ipairs({ "serde", "clap", "tokio", "thiserror", "sqlx", "derive_more", "strum", "bon", "schemars", "utoipa", "tracing", "diesel", "axum", "bevy" }) do
      H.ok(shipped[c], c .. " is not shipped")
    end
    H.eq({}, require("xyno_macros.attrs").load_errors)
  end)

  it("every file passes the strict validator", function()
    for _, path in ipairs(files) do
      local errs = S.validate(read(path), vim.fs.basename(path))
      H.eq({}, errs, path)
    end
  end)

  it("the files added with their docs check carry a `verified` note", function()
    for _, c in ipairs({ "tracing", "diesel", "axum", "bevy" }) do
      local d = read(H.repo .. "/data/macro_attrs/" .. c .. ".json")
      H.match(d.verified, "^%d%d%d%d%-%d%d%-%d%d against ")
      H.eq(d.verified, d.verified)
    end
  end)

  it("fmt is idempotent on the files in canonical layout", function()
    for _, c in ipairs({ "tracing", "diesel", "axum", "bevy" }) do
      local path = H.repo .. "/data/macro_attrs/" .. c .. ".json"
      local f = assert(io.open(path, "rb"))
      local text = f:read("*a")
      f:close()
      H.eq(text, S.format(vim.json.decode(text)), c)
    end
  end)
end)

describe("validator", function()
  local function good()
    return {
      crate = "demo",
      versions = ">=1.0.0, <2.0.0",
      docs_url = "https://docs.rs/demo/",
      verified = "2026-01-01 against demo 1.0.0",
      attributes = { { name = "demo", applies_to = { "field" }, args = { { key = "a", kind = "flag", doc = "x" }, { key = "b", kind = "flag", doc = "y", conflicts = { "a" } } } } },
    }
  end
  local function errors(mut)
    local d = good()
    mut(d)
    return table.concat((S.validate(d, "demo.json")), "\n")
  end

  it("accepts a good file", function()
    H.eq({}, (S.validate(good(), "demo.json")))
  end)

  it("catches typos, dangling references and bad values", function()
    H.match(errors(function(d) d.attributes[1].args[1].knd = "flag" end), "unknown field `knd`", true)
    H.match(errors(function(d) d.attributes[1].args[2].conflicts = { "zz" } end), "not a key of this attribute", true)
    H.match(errors(function(d) d.attributes[1].args[1].kind = "enum" end), "enum needs `values`", true)
    H.match(errors(function(d) d.attributes[1].applies_to = { "fields" } end), "unknown target `fields`", true)
    H.match(errors(function(d) d.attributes[1].args[1].snippet = "a = ${1:x" end), "unbalanced", true)
    H.match(errors(function(d) d.attributes[1].args[1].since = "one" end), "since must be a version", true)
    H.match(errors(function(d) d.docs_url = "http://docs.rs/demo" end), "https", true)
    H.match(errors(function(d) d.versions = "latest" end), "cargo-style range", true)
    H.match(errors(function(d) d.attributes[1].args[2].key = "a" end), "listed twice", true)
    H.match(errors(function(d) d.crate = "other" end), "does not match crate", true)
  end)

  it("a key written as `not(source)` is conflicted with as `not`", function()
    local d = good()
    d.attributes[1].args = { { key = "source", doc = "x", conflicts = { "not" } }, { key = "not(source)", doc = "y" } }
    H.eq({}, (S.validate(d, "demo.json")))
  end)
end)

describe("the added schemas complete in a real buffer", function()
  local dir
  local function items_at(src)
    if not dir then
      dir = H.tmpdir() .. "/added"
      vim.fn.mkdir(dir .. "/src", "p")
      local function put(p, t)
        local f = assert(io.open(p, "wb"))
        f:write(t)
        f:close()
      end
      put(dir .. "/Cargo.toml", '[package]\nname = "added"\nversion = "0.1.0"\nedition = "2024"\n\n[dependencies]\ntracing = "0.1"\ndiesel = "2"\naxum = "0.8"\nbevy = "0.20"\n')
      put(dir .. "/src/main.rs", "fn main() {}\n")
    end
    local lines = vim.split(src, "\n", { plain = true })
    local row, col
    for i, l in ipairs(lines) do
      local c = l:find("|", 1, true)
      if c then
        row, col, lines[i] = i, c - 1, l:gsub("|", "", 1)
        break
      end
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, dir .. "/src/lib.rs")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local items = require("xyno_macros.attrs").items(buf, row, col)
    vim.api.nvim_buf_delete(buf, { force = true })
    local labels = {}
    for _, it in ipairs(items) do
      labels[it.label] = true
    end
    return labels
  end

  it("tracing::instrument", function()
    local l = items_at("#[tracing::instrument(|)]\nfn f() {}")
    for _, k in ipairs({ "skip_all", "level", "fields", "err", "ret" }) do
      H.ok(l[k], k)
    end
  end)

  it("diesel keys depend on the derive and the target", function()
    local l = items_at("#[derive(Insertable)]\n#[diesel(|)]\nstruct New { a: i32 }")
    H.ok(l.table_name and l.treat_none_as_default_value, "container keys of Insertable")
    H.not_ok(l.belongs_to or l.primary_key or l.skip_update, "keys of other derives")
    local f = items_at("#[derive(AsChangeset)]\nstruct U {\n    #[diesel(|)]\n    a: i32,\n}")
    H.ok(f.skip_update and f.column_name and f.embed, "field keys of AsChangeset")
    H.not_ok(f.skip_insertion or f.table_name, "no insert or container keys on an AsChangeset field")
  end)

  it("axum debug_handler and FromRequest", function()
    H.ok(items_at("#[axum::debug_handler(|)]\nasync fn h() {}").state)
    local l = items_at("#[derive(FromRequest)]\n#[from_request(|)]\nstruct S { a: u8 }")
    H.ok(l.via and l.rejection and l.state)
  end)

  it("bevy component", function()
    local l = items_at("#[derive(Component)]\n#[component(|)]\nstruct C;")
    H.ok(l.storage and l.on_add and l.immutable)
  end)
end)
