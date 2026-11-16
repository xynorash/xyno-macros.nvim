-- Workspace trust for the one thing this plugin runs that executes project code:
-- `cargo expand` (a full build: build.rs, proc macros). rust-analyzer's own
-- expansion is not gated here (that is rust-analyzer's configuration, see
-- xyno_rust.trust.ra_overrides).
--
-- Provider (setup{ trust = ... }):
--   "auto" (default)  xyno_rust.trust when the installed xyno-rust.nvim has it
--                     (require(root, what, cb); one trust list for all xyno plugins),
--                     else the interim check below
--   "local"           always the interim check below
--   function(root, what, cb)  your own; cb(true|false)
--
-- Interim check (used only without xyno_rust.trust, easy to delete): the answer
-- "trust this workspace" is remembered per real path in
-- stdpath("state")/xyno-macros/trust.json; "run once" and "no" are not stored.
-- It is swapped for xyno_rust.trust by nothing but its presence: M.provider().
local M = {}

M.config = { provider = "auto" }

local function file()
  return vim.fn.stdpath("state") .. "/xyno-macros/trust.json"
end
M.file = file

local function norm(root)
  if type(root) ~= "string" or root == "" then
    return nil
  end
  return (vim.uv.fs_realpath(root) or root):gsub("[/\\]+$", "")
end

local function read()
  local f = io.open(file(), "rb")
  if not f then
    return {}
  end
  local txt = f:read("*a")
  f:close()
  local ok, t = pcall(vim.json.decode, txt)
  return ok and type(t) == "table" and t or {}
end

local function write(t)
  local path = file()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then
    return false, err
  end
  f:write(vim.json.encode(t))
  f:close()
  return os.rename(tmp, path)
end

--- Interim check: is `root` trusted?
function M.is_trusted(root)
  local p = norm(root)
  return p ~= nil and read()[p] ~= nil
end

function M.trust(root)
  local p = norm(root)
  assert(p, "a directory is required")
  local t = read()
  t[p] = { at = os.time() }
  return write(t)
end

function M.revoke(root)
  local p = norm(root)
  local t = read()
  local had = p ~= nil and t[p] ~= nil
  if had then
    t[p] = nil
    write(t)
  end
  return had
end

function M.list()
  local out = {}
  for root, e in pairs(read()) do
    out[#out + 1] = { root = root, at = type(e) == "table" and e.at or 0 }
  end
  table.sort(out, function(a, b)
    return a.root < b.root
  end)
  return out
end

--- Interim ask: cb(true|false).
local function ask(root, what, cb)
  local p = norm(root)
  if not p then
    return cb(false)
  end
  local choices = { { "Trust this workspace", "trust" }, { "Run this once", "once" }, { "Do not run", "no" } }
  vim.ui.select(choices, {
    prompt = ("Trust %s?\n%s runs code from it (build.rs, proc macros)."):format(p, what),
    format_item = function(c)
      return c[1]
    end,
  }, function(choice)
    local kind = choice and choice[2]
    if kind == "trust" then
      local ok, err = pcall(M.trust, p)
      if not ok or err == false then
        vim.notify("xyno-macros: could not remember the choice: " .. tostring(err), vim.log.levels.WARN)
      end
    end
    cb(kind == "trust" or kind == "once")
  end)
end

--- Which provider is in use: "xyno-rust" | "local" | "custom".
function M.provider()
  local p = M.config.provider
  if type(p) == "function" then
    return "custom"
  end
  if p ~= "local" then
    local ok, t = pcall(require, "xyno_rust.trust")
    if ok and type(t) == "table" and type(t.require) == "function" then
      return "xyno-rust"
    end
  end
  return "local"
end

--- cb(true) when `root` is trusted or the user agrees, cb(false) otherwise (a refusal is notified).
function M.require(root, what, cb)
  local which = M.provider()
  if which == "custom" then
    return M.config.provider(root, what, cb)
  end
  if which == "xyno-rust" then
    return require("xyno_rust.trust").require(root, what, cb)
  end
  if M.is_trusted(root) then
    return cb(true)
  end
  ask(root, what, function(ok)
    if not ok then
      vim.notify(
        ("xyno-macros: %s not run: %s is not a trusted workspace"):format(what, tostring(root)),
        vim.log.levels.WARN
      )
    end
    cb(ok)
  end)
end

return M
