local M = {}

local config = require("lazydiff.config")

-- Colour values reach the blend maths as numbers. Accept an integer, a
-- "#rrggbb" string, or "NONE" (which means "unset").
local function to_color(value)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    local hex = value:match("^#(%x%x%x%x%x%x)$")
    if hex then
      return tonumber(hex, 16)
    end
  end
  return nil
end

local function normalize(attrs)
  attrs.fg = to_color(attrs.fg)
  attrs.bg = to_color(attrs.bg)
  return attrs
end

local function source_hl(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and hl then
    return normalize(hl)
  end
  return {}
end

-- Walk an unresolved link chain up to 8 hops and return the final attributes
-- table with the `link` key removed.
local function follow_link(attrs)
  for _ = 1, 8 do
    if not attrs or not attrs.link then
      break
    end
    local ok, next_hl = pcall(vim.api.nvim_get_hl, 0, { name = attrs.link, link = false })
    if not ok or not next_hl then
      break
    end
    attrs = next_hl
  end
  if not attrs then
    return {}
  end
  attrs.link = nil
  return normalize(attrs)
end

-- Default group per slot; only the add/delete pair exists as a distinction.
local DEFAULT_SLOT_GROUP = {
  add = "DiffAdd",
  add_word = "DiffAdd",
  add_sign = "DiffAdd",
  delete = "DiffDelete",
  delete_word = "DiffDelete",
  delete_sign = "DiffDelete",
}

-- Attributes for one overlay slot, from the configured source or the default.
local function source(slot)
  local spec = (config.options.highlights or {})[slot]
  if type(spec) == "table" then
    local copy = vim.deepcopy(spec)
    copy.fg = to_color(copy.fg)
    copy.bg = to_color(copy.bg)
    return copy
  end
  if type(spec) ~= "string" then
    spec = DEFAULT_SLOT_GROUP[slot]
  end
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = spec, link = false })
  if not ok or not hl then
    return {}
  end
  return follow_link(normalize(hl))
end

-- First non-nil fg across `names`, else nil. The diff-oriented groups
-- (DiffAdd etc.) are frequently bg-only, so the float's status letters and
-- counts -- which are fg-only text -- source from Added/Removed/Changed first.
local function first_fg(names)
  for _, name in ipairs(names) do
    local hl = source_hl(name)
    if hl.fg then
      return hl.fg
    end
  end
  return nil
end

-- First non-nil bg across `names`, else nil.
local function first_bg(names)
  for _, name in ipairs(names) do
    local hl = source_hl(name)
    if hl.bg then
      return hl.bg
    end
  end
  return nil
end

-- Mix `color` toward `target` by `amount` (0..1). Used to derive the word
-- emphasis bands from the line bands, so they read as "more of the same".
local function blend(color, target, amount)
  local function channel(shift)
    local a = bit.band(bit.rshift(color, shift), 0xff)
    local b = bit.band(bit.rshift(target, shift), 0xff)
    return math.floor(a + (b - a) * amount + 0.5)
  end
  return bit.bor(bit.lshift(channel(16), 16), bit.lshift(channel(8), 8), channel(0))
end

-- Word-level groups link to the colourscheme's intra-line group when it exists,
-- else to the line-band group of the same side.
local function word_target(preferred, fallback)
  if vim.fn.hlexists(preferred) == 1 then
    return preferred
  end
  return fallback
end

local function apply()
  local da = source("add")
  local dd = source("delete")
  local dw = source("add_word")
  local ddw = source("delete_word")
  local ds = source("add_sign")
  local dds = source("delete_sign")
  local fn = source_hl("Function")
  local nm = source_hl("Normal")
  local toward = nm.fg or 0xffffff

  -- LazydiffAdd paints the in-buffer added line via hl_group + hl_eol; it is
  -- bg-only so it doesn't fight treesitter syntax fg.
  -- LazydiffDelete paints virtual deleted lines (no syntax to preserve), so it
  -- carries fg + bg.
  --
  -- Sign groups (+/- prefix) explicitly carry bg = Normal.bg so the prefix
  -- always sits on the buffer's natural background, regardless of how the
  -- surrounding line band is painted. Without this, some Neovim builds /
  -- colorschemes paint the line bg over the virt_text region too, swallowing
  -- the marker.
  --
  -- The *Word groups mark the changed spans inside a change hunk.
  local groups = {
    LazydiffAdd = { bg = da.bg, default = true },
    LazydiffDelete = { bg = dd.bg, default = true },
    LazydiffAddSign = { fg = ds.fg or da.fg, bg = nm.bg, bold = true, default = true },
    LazydiffDeleteSign = { fg = dds.fg or dd.fg, bg = nm.bg, bold = true, default = true },
    LazydiffHunkHeader = { fg = fn.fg, default = true },
    LazydiffAddWord = type(config.options.highlights and config.options.highlights.add_word) == "table"
        and vim.tbl_extend("force", dw, { default = true })
      or {
        link = type(config.options.highlights and config.options.highlights.add_word) == "string"
            and config.options.highlights.add_word
          or word_target("DiffAddText", "DiffAdd"),
        default = true,
      },
    LazydiffDeleteWord = type(config.options.highlights and config.options.highlights.delete_word) == "table"
        and vim.tbl_extend("force", ddw, { default = true })
      or {
        link = type(config.options.highlights and config.options.highlights.delete_word) == "string"
            and config.options.highlights.delete_word
          or word_target("DiffDeleteText", "DiffDelete"),
        default = true,
      },
  }

  -- Float mode. Status letters and counts are fg-only text in the sidebar, so
  -- they source from the fg-carrying groups first (see first_fg).
  local add_fg = first_fg({ "Added", "GitSignsAdd", "DiffAdd" })
  local del_fg = first_fg({ "Removed", "GitSignsDelete", "DiffDelete" })
  local chg_fg = first_fg({ "Changed", "GitSignsChange", "DiffChange" })
  local dim_fg = first_fg({ "Comment", "NonText" })

  groups.LazydiffStatusModified = { fg = chg_fg, default = true }
  groups.LazydiffStatusAdded = { fg = add_fg, default = true }
  groups.LazydiffStatusDeleted = { fg = del_fg, default = true }
  groups.LazydiffStatusRenamed = { fg = fn.fg, default = true }
  groups.LazydiffStatusUntracked = { fg = dim_fg, default = true }
  groups.LazydiffCountAdd = { fg = add_fg, default = true }
  groups.LazydiffCountDelete = { fg = del_fg, default = true }
  groups.LazydiffFloatPath = { fg = nm.fg, default = true }
  groups.LazydiffFloatDim = { fg = dim_fg, default = true }
  groups.LazydiffFloatTitle = { fg = fn.fg, bold = true, default = true }
  groups.LazydiffFloatSelected = {
    bg = first_bg({ "CursorLine", "Visual" }),
    bold = true,
    default = true,
  }
  groups.LazydiffFold = { fg = dim_fg, default = true }

  for name, spec in pairs(groups) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

local installed = false

-- Idempotent: setup() is called from init.setup() and again lazily on the
-- first enable(), whichever comes first.
function M.setup()
  if installed then
    return
  end
  installed = true
  apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("LazydiffHighlights", { clear = true }),
    callback = apply,
  })
end

return M
