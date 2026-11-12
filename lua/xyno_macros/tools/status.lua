-- xyno-macros tools: proc-macro health (:ProcMacroStatus).
-- Part of xyno_macros.tools (the facade merges every part into one table).
local M = {}

local uv = vim.uv or vim.loop

local Sig = require("xyno_macros.tools.sig")
local ra_client = Sig._ra_client

-- ============================================================ proc-macro status

local MACRO_CODES = {
  ["macro-error"] = true,
  ["proc-macro-disabled"] = true,
  ["unresolved-proc-macro"] = true,
  ["unresolved-macro-call"] = true,
  ["macro-def-error"] = true,
}

--- Diagnostics (vim.Diagnostic list) about macros that were not expanded.
function M.macro_diagnostics(diags)
  local out = {}
  for _, d in ipairs(diags) do
    local code = d.code ~= nil and tostring(d.code) or ""
    local msg = (d.message or ""):lower()
    if
      MACRO_CODES[code]
      or msg:find("proc.macro")
      or msg:find("macro expansion")
      or msg:find("not expanded", 1, true)
    then
      out[#out + 1] = d
    end
  end
  return out
end

--- Crates of an analyzerStatus text: { { name, proc_macro = bool } ... } plus
--- settings found in the config dump.
function M.parse_analyzer_status(text)
  local crates, cur = {}, nil
  for line in (text or ""):gmatch("[^\n]+") do
    local name = line:match("^Crate: ([%w_%-]+)")
    if name then
      cur = { name = name, proc_macro = false }
      crates[#crates + 1] = cur
    end
    local pm = line:match("Is a proc macro crate: (%a+)")
    if pm and cur then
      cur.proc_macro = pm == "true"
    end
  end
  return {
    crates = crates,
    enabled = text and text:match("procMacro_enable: (%a+)"),
    attributes = text and text:match("procMacro_attributes_enable: (%a+)"),
  }
end

local function dylib_built(target_dir, crate)
  if not target_dir then
    return false
  end
  local lib = crate:gsub("%-", "_")
  -- target/ is cargo's own; target/rust-analyzer is where rust-analyzer builds
  -- (cargo.targetDir = true in the rust-analyzer settings)
  for _, sub in ipairs({ "", "/rust-analyzer" }) do
    for _, profile in ipairs({ "debug", "release" }) do
      for _, ext in ipairs({ "so", "dylib", "dll" }) do
        if #vim.fn.glob(("%s%s/%s/deps/lib%s-*.%s"):format(target_dir, sub, profile, lib, ext), true, true) > 0 then
          return true
        end
      end
    end
  end
  return false
end

--- Proc-macro crates of the metadata: { { name, version, member, dir, built } }.
function M.proc_macro_crates(meta, target_dir)
  local cm = require("xyno_rust.crate_meta")
  local out = {}
  for _, p in ipairs(meta.packages) do
    local toml = p.dir and cm.read_manifest(p.dir)
    if
      toml and (toml:match("%[lib%].-\nproc[-_]macro%s*=%s*true") or toml:match("%[lib%]\nproc[-_]macro%s*=%s*true"))
    then
      out[#out + 1] = {
        name = p.name,
        version = p.version,
        member = p.is_member,
        dir = p.dir,
        built = dylib_built(target_dir, p.name),
      }
    end
  end
  table.sort(out, function(a, b)
    if a.member ~= b.member then
      return a.member
    end
    return a.name < b.name
  end)
  return out
end

--- Names a proc-macro crate exports (derives, attributes, function-like), read
--- from its source text.
function M.proc_macro_names(text)
  local names, seen = {}, {}
  local function add(n)
    if n and not seen[n] and n:find("^[%w_]+$") then
      seen[n] = true
      names[#names + 1] = n
    end
  end
  for n in text:gmatch("#%[%s*proc_macro_derive%s*%(%s*([%w_]+)") do
    add(n)
  end
  for n in text:gmatch("#%[%s*proc_macro_attribute%s*%]%s*[^\n]-fn%s+([%w_]+)") do
    add(n)
  end
  for n in text:gmatch("#%[%s*proc_macro%s*%]%s*[^\n]-fn%s+([%w_]+)") do
    add(n)
  end
  for n in text:gmatch("#%[%s*proc_macro_attribute%s*%]%s*\n%s*pub%s+fn%s+([%w_]+)") do
    add(n)
  end
  return names
end

--- The report: lines + a map line -> { kind, ... } for <CR>.
--- data = { root, crates = {...}, status = parse_analyzer_status | nil,
---          diags = vim.Diagnostic[], ignored = {name=...}, server = string|nil }
function M.report_lines(data)
  local lines, targets = {}, {}
  local function add(l, target)
    lines[#lines + 1] = l
    if target then
      targets[#lines] = target
    end
  end
  add("Proc macros  " .. (data.root or "(no workspace)"))
  add("")
  if data.status then
    if data.status.enabled == "false" then
      add("! rust-analyzer.procMacro.enable is false: no proc macro is expanded")
    end
    if data.status.attributes == "false" then
      add("! procMacro.attributes.enable is false: attribute macros (tokio::main, ...) are not expanded")
    end
  end
  if data.server then
    add("server: " .. data.server)
  end
  add("")
  add("Proc-macro crates (" .. #data.crates .. ")")
  if #data.crates == 0 then
    add("  none in this workspace's dependency graph")
  end
  local problems = {}
  for _, d in ipairs(data.diags) do
    local c = (d.message or ""):match("`([%w_%-]+)`")
    if c then
      problems[c] = (problems[c] or 0) + 1
    end
  end
  for _, c in ipairs(data.crates) do
    local ign = data.ignored and data.ignored[c.name]
    local state = ign and "ignored" or (c.built and "built" or "NOT BUILT")
    local note = problems[c.name] and ("  " .. problems[c.name] .. " problem(s)") or ""
    add(
      ("  %-28s %-9s %s%s%s"):format(c.name, c.version or "", state, c.member and "  (workspace)" or "", note),
      { kind = "crate", name = c.name }
    )
  end
  add("")
  add("Macros not expanded (" .. #data.diags .. " in open buffers)")
  if #data.diags == 0 then
    add("  none")
  end
  for _, d in ipairs(data.diags) do
    local file =
      vim.fn.fnamemodify(vim.api.nvim_buf_is_valid(d.bufnr) and vim.api.nvim_buf_get_name(d.bufnr) or "?", ":t")
    add(
      ("  %s:%d  [%s] %s"):format(file, d.lnum + 1, tostring(d.code or "?"), (d.message or ""):gsub("\n.*", "")),
      { kind = "diag", diag = d }
    )
  end
  add("")
  add("r rebuild proc macros   i ignore a slow proc macro   <CR> jump / ignore   R refresh   q close")
  return lines, targets
end

--- A rust-analyzer.toml text with `crate` added to [procMacro.ignored]:
--- returns the new text, or nil + why when the file declares the setting in a
--- form that is not edited blindly (dotted keys, inline tables).
function M.toml_ignore(text, crate, names)
  local items = {}
  for _, n in ipairs(names or {}) do
    if n:find("^[%w_]+$") then
      items[#items + 1] = '"' .. n .. '"'
    end
  end
  if #items == 0 then
    items = { '"*"' } -- every macro of the crate
  end
  local entry = ('"%s" = [%s]'):format(crate, table.concat(items, ", "))
  local lines = vim.split(text, "\n", { plain = true })
  local header, header_i, key_i, key_j, last_i
  for i, l in ipairs(lines) do
    local h = l:match('^%s*%[%s*([%w_.%s"-]-)%s*%]%s*$') or l:match('^%s*%[%s*([%w_.%s"-]-)%s*%]%s*#.*$')
    if h then
      header = h:gsub("%s", "")
      if header == "procMacro.ignored" then
        header_i = i
        last_i = i
      end
    elseif header == "procMacro.ignored" then
      if l:match("^%s*[\"']?" .. vim.pesc(crate) .. "[\"']?%s*=") then
        key_i = i
        key_j = i
        -- a multi-line array: the entry replaces every line up to the closing bracket
        local v = l:gsub("#.*$", "")
        if v:find("[", 1, true) and not v:find("]", 1, true) then
          key_j = nil
          for j = i + 1, #lines do
            if (lines[j]:gsub("#.*$", "")):find("]", 1, true) then
              key_j = j
              break
            end
          end
          if not key_j then
            return nil, "rust-analyzer.toml has an array for this crate that is not closed: fix it by hand"
          end
        end
      end
      if l:match("%S") then
        last_i = i
      end
    elseif l:match("^%s*procMacro%.ignored") or (header == "procMacro" and l:match("^%s*ignored%s*=")) then
      return nil,
        "rust-analyzer.toml sets procMacro.ignored in a form that is not edited automatically: add the crate by hand"
    end
  end
  if key_i then
    lines[key_i] = entry
    for _ = key_i + 1, key_j do
      table.remove(lines, key_i + 1)
    end
  elseif header_i then
    table.insert(lines, last_i + 1, entry)
  else
    if #lines > 0 and lines[#lines] == "" then
      table.remove(lines)
    end
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "[procMacro.ignored]"
    lines[#lines + 1] = entry
  end
  local out = table.concat(lines, "\n")
  -- cheap sanity check in place of a TOML parser: the table must still be declared once
  local heads = 0
  for _, l in ipairs(lines) do
    local h = l:match('^%s*%[%s*([%w_.%s"-]-)%s*%]')
    if h and h:gsub("%s", "") == "procMacro.ignored" then
      heads = heads + 1
    end
  end
  if heads ~= 1 then
    return nil, "rust-analyzer.toml has an unusual [procMacro.ignored] layout: add the crate by hand"
  end
  return out:sub(-1) == "\n" and out or (out .. "\n")
end

--- Add `crate` to procMacro.ignored in <root>/rust-analyzer.toml, the
--- project-level settings file rust-analyzer reads itself (.rust-analyzer.toml
--- when that is the one that exists). Returns the path, or nil + error.
function M.ignore_proc_macro(root, crate, names)
  if not crate:find("^[%w_.%-]+$") then
    return nil, "refusing an odd crate name"
  end
  local path = root .. "/rust-analyzer.toml"
  if not uv.fs_stat(path) and uv.fs_stat(root .. "/.rust-analyzer.toml") then
    path = root .. "/.rust-analyzer.toml"
  end
  local text = ""
  local fh = io.open(path, "rb") -- binary: text mode would turn LF into CRLF on Windows
  if fh then
    text = fh:read("*a")
    fh:close()
  end
  local crlf = text:find("\r\n", 1, true) ~= nil
  local new, why = M.toml_ignore(crlf and text:gsub("\r\n", "\n") or text, crate, names)
  if not new then
    return nil, why
  end
  if crlf then
    new = new:gsub("\r?\n", "\r\n")
  end
  -- atomic (tmp + rename) onto the real file, so a symlinked settings file stays one
  local real = uv.fs_realpath(path) or path
  local tmp = ("%s.%d.tmp"):format(real, uv.os_getpid())
  local out, err = io.open(tmp, "wb")
  if not out then
    return nil, err
  end
  out:write(new)
  out:close()
  local st = uv.fs_stat(real)
  if st then
    pcall(uv.fs_chmod, tmp, st.mode % 4096)
  end
  local okr, rerr = require("xyno_rust.fsutil").rename(tmp, real)
  if not okr then
    uv.fs_unlink(tmp)
    return nil, rerr
  end
  return path
end

--- Crate names under [procMacro.ignored] of the project's rust-analyzer.toml.
local function ignored_of(root)
  local out = {}
  for _, name in ipairs({ "rust-analyzer.toml", ".rust-analyzer.toml" }) do
    local fh = io.open(root .. "/" .. name, "r")
    if fh then
      local header
      for l in fh:lines() do
        local h = l:match('^%s*%[%s*([%w_.%s"-]-)%s*%]%s*$') or l:match('^%s*%[%s*([%w_.%s"-]-)%s*%]%s*#.*$')
        if h then
          header = h:gsub("%s", "")
        elseif header == "procMacro.ignored" then
          local k = l:match("^%s*[\"']?([%w_.%-]+)[\"']?%s*=")
          if k then
            out[k] = true
          end
        end
      end
      fh:close()
    end
  end
  return out
end

local report = { buf = nil, win = nil, targets = {}, data = nil, src = nil }

local function reload_settings()
  -- rust-analyzer watches the toml itself; this also covers a client that
  -- was started with a stale copy of the settings
  pcall(vim.cmd, "RustAnalyzer reloadSettings")
end

local function ignore_crate(root, crate, crates)
  local names
  for _, c in ipairs(crates or {}) do
    if c.name == crate and c.dir then
      names = {}
      for _, rel in ipairs(vim.fn.glob(c.dir .. "/src/**/*.rs", true, true)) do
        local f = io.open(rel, "r")
        if f then
          local t = f:read("*a")
          f:close()
          vim.list_extend(names, M.proc_macro_names(t))
        end
      end
    end
  end
  local path, err = M.ignore_proc_macro(root, crate, names)
  if not path then
    return vim.notify("ProcMacroStatus: " .. tostring(err), vim.log.levels.ERROR)
  end
  reload_settings()
  vim.notify(("proc macros of `%s` are ignored (%s); settings reloaded"):format(crate, path), vim.log.levels.INFO)
end

local function report_draw()
  local lines, targets = M.report_lines(report.data)
  report.targets = targets
  vim.bo[report.buf].modifiable = true
  vim.api.nvim_buf_set_lines(report.buf, 0, -1, false, lines)
  vim.bo[report.buf].modifiable = false
end

local function report_keys(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  map("q", function()
    if report.win and vim.api.nvim_win_is_valid(report.win) then
      vim.api.nvim_win_close(report.win, true)
    end
  end, "Close")
  map("r", function()
    if vim.fn.exists(":RustLsp") ~= 2 then
      return vim.notify("ProcMacroStatus: rebuilding proc macros needs rustaceanvim (:RustLsp)", vim.log.levels.WARN)
    end
    vim.cmd("RustLsp rebuildProcMacros")
  end, "Rebuild proc macros")
  map("R", function()
    M.proc_macro_status({ reuse = true })
  end, "Refresh")
  local function pick_ignore()
    local names = vim.tbl_map(function(c)
      return c.name
    end, report.data.crates)
    vim.ui.select(names, { prompt = "Ignore the proc macros of" }, function(n)
      if n then
        ignore_crate(report.data.root, n, report.data.crates)
        M.proc_macro_status({ reuse = true })
      end
    end)
  end
  map("i", pick_ignore, "Ignore a slow proc macro")
  map("<CR>", function()
    local t = report.targets[vim.api.nvim_win_get_cursor(0)[1]]
    if not t then
      return
    end
    if t.kind == "crate" then
      ignore_crate(report.data.root, t.name, report.data.crates)
      M.proc_macro_status({ reuse = true })
    elseif t.kind == "diag" and vim.api.nvim_buf_is_valid(t.diag.bufnr) then
      vim.cmd("wincmd p")
      vim.api.nvim_set_current_buf(t.diag.bufnr)
      vim.api.nvim_win_set_cursor(0, { t.diag.lnum + 1, t.diag.col })
    end
  end, "Ignore the crate / jump to the diagnostic")
end

--- :ProcMacroStatus
function M.proc_macro_status(opts)
  opts = opts or {}
  local src = opts.reuse and report.src or vim.api.nvim_get_current_buf()
  report.src = src
  local cm = require("xyno_rust.crate_meta")
  local file = vim.api.nvim_buf_get_name(src)
  local root = cm.root(file)
  if not root then
    return vim.notify("ProcMacroStatus: not in a cargo workspace", vim.log.levels.WARN)
  end
  cm.metadata_async(root, function(meta, err)
    if not meta then
      return vim.notify("ProcMacroStatus: " .. tostring(err), vim.log.levels.WARN)
    end
    local target = vim.env.CARGO_TARGET_DIR or ((meta.workspace_root or root) .. "/target")
    local data = {
      root = root,
      crates = M.proc_macro_crates(meta, target),
      diags = M.macro_diagnostics(vim.diagnostic.get(nil)),
      ignored = ignored_of(root),
    }
    local function finish()
      if not (report.buf and vim.api.nvim_buf_is_valid(report.buf)) then
        report.buf = vim.api.nvim_create_buf(false, true)
        vim.bo[report.buf].buftype = "nofile"
        vim.bo[report.buf].bufhidden = "wipe"
        vim.bo[report.buf].swapfile = false
        report_keys(report.buf)
      end
      report.data = data
      if not (report.win and vim.api.nvim_win_is_valid(report.win)) then
        vim.cmd("botright 18split")
        report.win = vim.api.nvim_get_current_win()
      end
      vim.api.nvim_win_set_buf(report.win, report.buf)
      -- the first line carries the project path: wrap it at words instead of cutting it at the window edge
      vim.wo[report.win].wrap = true
      vim.wo[report.win].linebreak = true
      vim.wo[report.win].breakindent = true
      pcall(vim.api.nvim_buf_set_name, report.buf, "proc-macro-status")
      report_draw()
    end
    local client = vim.api.nvim_buf_is_valid(src) and ra_client(src)
    if not client then
      data.server = "no rust-analyzer client attached to " .. (file ~= "" and vim.fs.basename(file) or "this buffer")
      return finish()
    end
    client:request(
      "rust-analyzer/analyzerStatus",
      { textDocument = { uri = vim.uri_from_bufnr(src) } },
      function(e, text)
        if not e and type(text) == "string" then
          data.status = M.parse_analyzer_status(text)
          local pmc = vim.tbl_filter(function(c)
            return c.proc_macro
          end, data.status.crates)
          -- a count of 0 would contradict the list below when the status text has no crate graph
          data.server = #pmc == 0 and ("rust-analyzer " .. client.name)
            or ("rust-analyzer %s; %d proc-macro crate%s in this file's crates"):format(
              client.name,
              #pmc,
              #pmc == 1 and "" or "s"
            )
        else
          data.server = "analyzerStatus failed: " .. tostring(e and e.message)
        end
        finish()
      end,
      src
    )
  end)
end

return M
