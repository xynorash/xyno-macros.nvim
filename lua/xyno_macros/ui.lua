-- Look of the windows this plugin draws: the macro popup (layout options) and the highlight groups.
-- Every group is linked to a theme group by default (`default = true`, so a colorscheme or the user
-- can define it themselves) and the links come back after `:colorscheme`.
local M = {}

--- Highlight group -> the theme group it links to until it is defined.
M.groups = {
  XynoMacrosFloat = "NormalFloat", -- popup background
  XynoMacrosBorder = "FloatBorder", -- popup border
  XynoMacrosBest = "PmenuSel", -- the arm that matches the call (whole line)
  XynoMacrosDim = "Comment", -- arms that cannot match
}

--- Layout of the macro popup (setup{ popup = {...} }).
M.popup = {
  max_height = 14, -- lines
  min_width = 20, -- columns
  max_width = nil, -- columns (nil: the screen width minus 6)
  border = nil, -- nil: 'winborder', else "rounded", "single", "double", "solid", "none", "shadow"
  prefer = "below", -- "below" | "above": where it opens when both fit; falls back to the other
}

local BORDERS = { rounded = true, single = true, double = true, solid = true, none = true, shadow = true }

--- Check popup options; returns the problems (nothing is applied).
---@return string[]
function M.validate_popup(p)
  if type(p) ~= "table" then
    return { "popup must be a table" }
  end
  local problems = {}
  for k, v in pairs(p) do
    if k == "max_height" or k == "min_width" or k == "max_width" then
      if type(v) ~= "number" or v ~= math.floor(v) or v < 1 or v > 1000 then
        problems[#problems + 1] = ("popup.%s must be a whole number from 1 to 1000, got %s"):format(k, vim.inspect(v))
      end
    elseif k == "border" then
      if not (type(v) == "string" and BORDERS[v]) then
        problems[#problems + 1] = "popup.border must be one of rounded, single, double, solid, none, shadow, got "
          .. vim.inspect(v)
      end
    elseif k == "prefer" then
      if v ~= "below" and v ~= "above" then
        problems[#problems + 1] = 'popup.prefer must be "below" or "above", got ' .. vim.inspect(v)
      end
    else
      problems[#problems + 1] = ("unknown popup option `%s`"):format(tostring(k))
    end
  end
  if #problems == 0 and p.max_width and p.min_width and p.max_width < p.min_width then
    problems[1] = "popup.max_width is below popup.min_width"
  end
  return problems
end

--- Replace the layout (keys not given return to their defaults).
function M.set_popup(p)
  M.popup = vim.tbl_extend("force", { max_height = 14, min_width = 20, prefer = "below" }, p or {})
end

function M.define_highlights()
  for name, target in pairs(M.groups) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

local group
function M.setup()
  M.define_highlights()
  group = vim.api.nvim_create_augroup("xyno_macros_ui", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = M.define_highlights })
end

return M
