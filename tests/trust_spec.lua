-- xyno-os: linux,macos (the fake cargo-expand is a POSIX shell script)
-- cargo expand is gated by a workspace trust decision; the snippet guard (expression
-- positions, restored from xynovim's configuration); :checkhealth xyno_macros.
-- Hermetic: a fake `cargo-expand` on PATH touches a canary file, which proves whether
-- the build "would have run".
local H = require("xyno_macros_test.helpers")
local mt = require("xyno_macros.tools")
local trust = require("xyno_macros.trust")

local saved = { path = vim.env.PATH, state = vim.env.XDG_STATE_HOME, select = vim.ui.select, notify = vim.notify }

after_each(function()
  vim.env.PATH = saved.path
  vim.env.XDG_STATE_HOME = saved.state
  vim.ui.select = saved.select
  vim.notify = saved.notify
  trust.config.provider = "auto"
  package.loaded["xyno_rust.trust"] = nil
  pcall(mt.lens_close)
  pcall(vim.cmd, "silent! %bwipeout!")
end)

local function setup_crate()
  local base = H.tmpdir()
  vim.env.XDG_STATE_HOME = base .. "/state"
  local dir = base .. "/crate"
  vim.fn.mkdir(dir .. "/src", "p")
  vim.fn.writefile({ '[package]', 'name = "tmpc"', 'version = "0.1.0"', 'edition = "2021"' }, dir .. "/Cargo.toml")
  vim.fn.writefile({ "pub fn f() {}" }, dir .. "/src/lib.rs")
  local bin = base .. "/bin"
  vim.fn.mkdir(bin, "p")
  local canary = base .. "/canary"
  local script = bin .. "/cargo-expand"
  vim.fn.writefile({ "#!/bin/sh", 'echo ran >> "' .. canary .. '"', "echo 'fn lab_extra() {}'" }, script)
  vim.uv.fs_chmod(script, 493)
  vim.env.PATH = bin .. ":" .. saved.path
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/src/lib.rs"))
  vim.bo.filetype = "rust"
  return vim.api.nvim_get_current_buf(), dir, canary
end

local function count(canary)
  return vim.uv.fs_stat(canary) and #vim.fn.readfile(canary) or 0
end

--- answers: list of "trust" | "once" | "no" | "cancel", consumed per prompt
local function answers(list)
  local asked = { n = 0, prompts = {} }
  vim.ui.select = function(items, opts, cb)
    asked.n = asked.n + 1
    asked.prompts[#asked.prompts + 1] = opts.prompt
    local want = table.remove(list, 1)
    local pick
    for _, it in ipairs(items) do
      if it[2] == want then
        pick = it
      end
    end
    vim.schedule(function()
      cb(pick)
    end)
  end
  return asked
end

local function settle(canary, n)
  H.wait_for(function()
    return count(canary) >= n
  end, 60000, "cargo expand ran")
end

describe("cargo expand trust gate (interim check)", function()
  it("an untrusted workspace is asked first and 'no' runs nothing", function()
    local buf, _, canary = setup_crate()
    trust.config.provider = "local"
    local asked = answers({ "no" })
    local cap = H.capture_notify()
    mt.cargo_expand_fallback(buf)
    H.wait_for(function()
      return asked.n == 1
    end, 60000, "the trust prompt")
    H.match(asked.prompts[1], "cargo expand", true)
    H.match(asked.prompts[1], "build.rs", true)
    vim.wait(1500)
    H.eq(0, count(canary), "no build ran")
    H.ok(vim.iter(cap.list):any(function(n)
      return n.msg:find("not a trusted workspace", 1, true)
    end))
  end)

  it("cancelling the prompt runs nothing", function()
    local buf, _, canary = setup_crate()
    trust.config.provider = "local"
    local asked = answers({ "cancel" })
    mt.cargo_expand_fallback(buf)
    H.wait_for(function()
      return asked.n == 1
    end, 60000, "prompt")
    vim.wait(1500)
    H.eq(0, count(canary))
  end)

  it("'run once' runs it and asks again next time; 'trust' remembers", function()
    local buf, dir, canary = setup_crate()
    trust.config.provider = "local"
    local asked = answers({ "once", "trust" })
    mt.cargo_expand_fallback(buf)
    settle(canary, 1)
    H.not_ok(trust.is_trusted(dir), "run once stores nothing")
    mt.cargo_expand_fallback(buf)
    settle(canary, 2)
    H.eq(2, asked.n)
    H.ok(trust.is_trusted(dir), "trust is stored")
    mt.cargo_expand_fallback(buf)
    settle(canary, 3)
    H.eq(2, asked.n, "a trusted workspace is not asked")
    H.ok(trust.revoke(dir))
    answers({ "no" })
    local again = answers({ "no" })
    mt.cargo_expand_fallback(buf)
    H.wait_for(function()
      return again.n == 1
    end, 60000, "asked after the revoke")
  end)

  it("the answer is shared with a second nvim through the state file", function()
    local _, dir = setup_crate()
    trust.trust(dir)
    H.ok(vim.uv.fs_stat(trust.file()))
    local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "--cmd", "set rtp+=" .. H.repo, "-c",
      "lua io.stdout:write(tostring(require('xyno_macros.trust').is_trusted(" .. vim.inspect(dir) .. ")))", "-c", "qa!" },
      { text = true, env = { XDG_STATE_HOME = vim.env.XDG_STATE_HOME } }):wait(20000)
    H.match(r.stdout, "true", true)
  end)
end)

describe("cargo expand trust provider", function()
  it("auto uses xyno_rust.trust when it exists, 'local' ignores it", function()
    local buf, dir, canary = setup_crate()
    local seen
    package.loaded["xyno_rust.trust"] = {
      require = function(root, what, cb)
        seen = { root = root, what = what }
        cb(false)
      end,
    }
    H.eq("xyno-rust", trust.provider())
    mt.cargo_expand_fallback(buf)
    H.wait_for(function()
      return seen
    end, 60000, "the xyno-rust trust call")
    H.match(seen.what, "cargo expand", true)
    H.eq(vim.fs.normalize(vim.uv.fs_realpath(dir)), vim.fs.normalize(vim.uv.fs_realpath(seen.root)))
    vim.wait(1000)
    H.eq(0, count(canary), "a refusal there runs nothing")
    trust.config.provider = "local"
    H.eq("local", trust.provider())
  end)

  it("a custom provider decides; without xyno_rust.trust the interim check is used", function()
    package.loaded["xyno_rust.trust"] = nil
    local real = package.preload["xyno_rust.trust"]
    package.preload["xyno_rust.trust"] = function()
      error("absent")
    end
    local p = trust.provider()
    package.preload["xyno_rust.trust"] = real
    H.ok(p == "local" or p == "xyno-rust")
    local got
    trust.config.provider = function(root, what, cb)
      got = { root, what }
      cb(true)
    end
    H.eq("custom", trust.provider())
    local ok
    trust.require("/x", "w", function(v)
      ok = v
    end)
    H.eq(true, ok)
    H.eq({ "/x", "w" }, got)
  end)
end)

describe("default snippet guard", function()
  local function allowed(text)
    local col = assert(text:find("|", 1, true)) - 1
    local line = text:gsub("|", "", 1)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    vim.bo[buf].filetype = "rust"
    vim.treesitter.get_parser(buf, "rust"):parse()
    return mt.snippets_allowed({ line = line, cursor = { 1, col }, bufnr = buf })
  end

  it("is false in expression positions, true in a block inside them", function()
    H.need_parser("rust")
    H.eq(false, allowed("fn f() { call(a, be|"), "unfinished call arguments")
    H.eq(false, allowed("fn f() { call(a, be|) }"), "call arguments")
    H.eq(false, allowed("fn f() { S { a: be| } }"), "struct literal")
    H.eq(false, allowed("fn f() { vec![1, be|] }"), "macro token tree")
    H.eq(true, allowed("fn f() { call(unsafe { be| }) }"), "statement position in a block inside the arguments")
    H.eq(true, allowed("fn f() { call(a); be| }"), "after the call")
    H.eq(true, allowed("fn f() { le| }"), "plain code in a body")
  end)
end)

describe("health", function()
  it("reports without error", function()
    local lines = {}
    local orig = vim.health
    local function rec(m)
      lines[#lines + 1] = m
    end
    vim.health = { start = rec, ok = rec, info = rec, warn = rec, error = rec }
    local ok, err = pcall(require("xyno_macros.health").check)
    vim.health = orig
    H.ok(ok, err)
    H.ok(vim.iter(lines):any(function(l)
      return l:find("trust", 1, true)
    end), "mentions trust")
  end)
end)
