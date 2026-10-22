local M = {}

local function complete_refs(arglead)
  local vcs = require("lazydiff.vcs")
  local dir = vcs.anchor_dir()
  local backend, _, repo = vcs.get(dir)
  if not backend then
    return {}
  end
  return vim.tbl_filter(function(ref)
    return ref:sub(1, #arglead) == arglead
  end, backend.refs(repo))
end

local function ref_arg(cmd)
  local ref = vim.trim(cmd.args or "")
  return ref ~= "" and ref or nil
end

function M.setup()
  local function cmd(name, fn, opts)
    vim.api.nvim_create_user_command(name, fn, opts)
  end

  cmd("Lazydiff", function(c)
    require("lazydiff").toggle(nil, ref_arg(c))
  end, {
    nargs = "?",
    complete = complete_refs,
    desc = "Toggle lazydiff overlay on the current buffer (optionally against a ref)",
  })

  cmd("LazydiffOff", function()
    require("lazydiff").disable()
  end, { desc = "Disable lazydiff overlay on the current buffer" })

  cmd("LazydiffRefresh", function()
    require("lazydiff").refresh(nil, { baseline = true })
  end, { desc = "Refetch the baseline and re-render the lazydiff overlay" })

  cmd("LazydiffNext", function(c)
    local mode = vim.trim(c.args or "")
    if mode == "" or mode == "buffer" then
      require("lazydiff").goto_next()
    elseif mode == "all" then
      require("lazydiff").goto_next_all()
    else
      vim.notify("lazydiff: LazydiffNext mode must be buffer or all", vim.log.levels.WARN)
    end
  end, {
    nargs = "?",
    complete = function(arglead)
      return vim.tbl_filter(function(mode)
        return mode:sub(1, #arglead) == arglead
      end, { "buffer", "all" })
    end,
    desc = "Jump to the next lazydiff hunk (mode: buffer or all)",
  })

  cmd("LazydiffPrev", function()
    require("lazydiff").goto_prev()
  end, { desc = "Jump to the previous lazydiff hunk" })

  cmd("LazydiffFirst", function()
    require("lazydiff").goto_first()
  end, { desc = "Jump to the first lazydiff hunk" })

  cmd("LazydiffReset", function()
    require("lazydiff").reset_hunk()
  end, { desc = "Revert the hunk under the cursor to the baseline" })

  cmd("LazydiffYank", function(c)
    local reg = vim.trim(c.args or "")
    require("lazydiff").yank_hunk(nil, reg ~= "" and reg or nil)
  end, { nargs = "?", desc = "Yank the deleted lines of the hunk under the cursor" })

  cmd("LazydiffFloat", function(c)
    require("lazydiff").toggle_float({ ref = ref_arg(c) })
  end, {
    nargs = "?",
    complete = complete_refs,
    desc = "Toggle the lazydiff float over all uncommitted files (optionally against a ref)",
  })

  cmd("LazydiffFloatOff", function()
    require("lazydiff").close_float()
  end, { desc = "Close the lazydiff float" })

  cmd("LazydiffStart", function(c)
    require("lazydiff.session").start(ref_arg(c))
  end, {
    nargs = "?",
    complete = complete_refs,
    desc = "Start a lazydiff session: overlay changed files on enter (optionally against a ref)",
  })

  cmd("LazydiffStop", function()
    require("lazydiff.session").stop()
  end, { desc = "Stop the lazydiff session and disable the overlays it enabled" })

  cmd("LazydiffQf", function(c)
    require("lazydiff").quickfix(ref_arg(c))
  end, {
    nargs = "?",
    complete = complete_refs,
    desc = "Fill the quickfix list with one entry per lazydiff hunk (optionally against a ref)",
  })

  cmd("LazydiffOpen", function(c)
    require("lazydiff.open").open(c.args)
  end, {
    nargs = "*",
    complete = function(arglead)
      local out = vim.tbl_filter(function(pos)
        return pos:sub(1, #arglead) == arglead
      end, { "left", "right", "bottom", "float" })
      vim.list_extend(out, complete_refs(arglead))
      return out
    end,
    desc = "List changed files in a read-only buffer (optionally a ref and left|right|bottom|float)",
  })
end

return M
