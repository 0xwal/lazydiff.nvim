-- Read-only buffer listing changed files for `:LazydiffOpen`. Line N maps to
-- entry N through `views[bufnr].entries`. Nothing here writes to disk.

local M = {}

local MAX_FILES = 500
local MAX_DIFF_LINES = 5000
local MAX_DIFF_BYTES = 1024 * 1024
local SIDE_WIDTH = 40
local BOTTOM_HEIGHT = 12
local MAX_FLOAT_HEIGHT = 25
local POSITIONS = { left = true, right = true, bottom = true, float = true }
local NOT_OPENABLE = { dir = true, deleted = true, bin = true }

-- bufnr -> { ref, root, origin, entries }
local views = {}

local function warn(msg)
  vim.notify("lazydiff: " .. msg, vim.log.levels.WARN)
end

-- Text with one trailing newline, so baseline and working text compare alike.
local function as_text(s)
  if not s or s == "" then
    return ""
  end
  if s:sub(-1) ~= "\n" then
    s = s .. "\n"
  end
  return s
end

local function sniff_binary(abs)
  local f = io.open(abs, "rb")
  if not f then
    return false
  end
  local head = f:read(8000) or ""
  f:close()
  return require("lazydiff.path").is_binary(head)
end

-- Keep entries that have a working-tree side, plus deleted entries and
-- directories. Other paths (sockets, FIFOs, vanished paths) are skipped.
local function candidates(root, files)
  local path_util = require("lazydiff.path")
  local out = {}
  for _, entry in ipairs(files) do
    local abs = root .. "/" .. entry.path
    if entry.status == "D" then
      out[#out + 1] = { entry = entry, abs = abs, kind = "deleted" }
    elseif path_util.is_regular_file(abs) then
      out[#out + 1] = { entry = entry, abs = abs, kind = "file" }
    else
      local ok, stat = pcall(vim.uv.fs_stat, abs)
      if ok and stat and stat.type == "directory" then
        out[#out + 1] = { entry = entry, abs = abs, kind = "dir" }
      end
    end
  end
  return out
end

-- True when text is too large to diff within the size cap.
local function too_big(s)
  if #s > MAX_DIFF_BYTES then
    return true
  end
  local _, newlines = s:gsub("\n", "")
  return newlines > MAX_DIFF_LINES
end

-- Row for one candidate. Counts come from vim.diff with result_type
-- "indices": count_old sums into deleted, count_new into added.
local function describe(backend, root, ref, cand)
  local path_util = require("lazydiff.path")
  local entry = cand.entry
  local function make(kind, text)
    return { path = entry.path, abs = cand.abs, kind = kind, text = text }
  end
  if cand.kind == "dir" then
    return make("dir", entry.path .. "  dir")
  end

  local old_text = ""
  if not entry.untracked then
    local blob, _, reason = backend.file_at(root, entry.old_path or entry.path, ref)
    if blob then
      old_text = blob
    elseif reason ~= "untracked" then
      return make("unreadable", entry.path .. "  unreadable")
    end
  end

  local new_text = ""
  if cand.kind == "file" then
    local ok, lines = pcall(vim.fn.readfile, cand.abs)
    if not ok or type(lines) ~= "table" then
      return make("unreadable", entry.path .. "  unreadable")
    end
    new_text = as_text(table.concat(lines, "\n"))
  end

  local binary = entry.binary or path_util.is_binary(old_text)
  if not binary and cand.kind == "file" then
    binary = sniff_binary(cand.abs)
  end
  if binary then
    return make("bin", entry.path .. "  bin")
  end

  if too_big(old_text) or too_big(new_text) then
    return make("big", entry.path .. "  big")
  end

  local added, deleted = 0, 0
  for _, h in ipairs(vim.diff(as_text(old_text), new_text, { result_type = "indices" })) do
    deleted = deleted + h[2]
    added = added + h[4]
  end
  return make(cand.kind, ("%s  +%d -%d"):format(entry.path, added, deleted))
end

-- Splits args into ref and position. A token that is not a position word is
-- the ref. A second ref or a second position makes the args invalid.
local function parse(args)
  local ref, position
  for token in (args or ""):gmatch("%S+") do
    if POSITIONS[token] and not position then
      position = token
    elseif not POSITIONS[token] and not ref then
      ref = token
    else
      return nil, nil, false
    end
  end
  return ref, position or "bottom", true
end

-- Buffer and window of an open list for `ref` in the current tab, if any.
local function find_view(ref)
  for buf, view in pairs(views) do
    if view.ref == ref and vim.api.nvim_buf_is_valid(buf) then
      local win = vim.fn.bufwinid(buf)
      if win ~= -1 then
        return buf, win
      end
    end
  end
end

-- Give `buf` the name `base`, or `base #N` when that name is taken.
local function name_buf(buf, base)
  for i = 1, 100 do
    local name = i == 1 and base or ("%s #%d"):format(base, i)
    if pcall(vim.api.nvim_buf_set_name, buf, name) then
      return
    end
  end
end

-- Replace buffer lines and return the entry map, line count and widest line.
local function fill(buf, rows, more)
  local lines, entries, width = {}, {}, 0
  for i, row in ipairs(rows) do
    lines[i] = row.text
    entries[i] = row
  end
  if #rows == 0 then
    lines[1] = "(no changed files)"
  end
  if more > 0 then
    lines[#lines + 1] = ("... %d more"):format(more)
  end
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  return entries, #lines, width
end

-- Show `buf` in a new window at `position` and return that window.
local function show(buf, position, nlines, width)
  if position == "float" then
    local w = math.max(1, math.min(width + 4, vim.o.columns - 4))
    local h = math.max(1, math.min(nlines, MAX_FLOAT_HEIGHT))
    return vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      style = "minimal",
      border = "rounded",
      width = w,
      height = h,
      row = math.max(0, math.floor((vim.o.lines - h) / 2)),
      col = math.max(0, math.floor((vim.o.columns - w) / 2)),
    })
  end

  if position == "bottom" then
    vim.cmd("botright split")
  elseif position == "left" then
    vim.cmd("topleft vsplit")
  else
    vim.cmd("botright vsplit")
  end
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  if position == "bottom" then
    vim.api.nvim_win_set_height(win, BOTTOM_HEIGHT)
  else
    vim.api.nvim_win_set_width(win, SIDE_WIDTH)
  end
  return win
end

local function first_normal_win(except)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= except and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
end

local function open_entry()
  local buf = vim.api.nvim_get_current_buf()
  local view = views[buf]
  if not view then
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local row = view.entries[line]
  if not row then
    return
  end
  if NOT_OPENABLE[row.kind] or not require("lazydiff.path").is_regular_file(row.abs) then
    warn("skip, not a regular file: " .. row.path)
    return
  end

  local target = view.origin
  if not (target and vim.api.nvim_win_is_valid(target)) then
    target = first_normal_win(vim.api.nvim_get_current_win())
  end
  if not target then
    vim.cmd("aboveleft new")
    target = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(target)
  vim.cmd.edit(vim.fn.fnameescape(row.abs))
  require("lazydiff").enable(vim.api.nvim_get_current_buf(), view.ref)
end

local function close_view()
  local buf = vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function create_buf(ref)
  local buf = vim.api.nvim_create_buf(false, true)
  name_buf(buf, "lazydiff://open/" .. ref)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "lazydiff-open"
  vim.keymap.set("n", "<CR>", open_entry, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "lazydiff open: open file",
  })
  vim.keymap.set("n", "q", close_view, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "lazydiff open: close",
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      views[buf] = nil
    end,
  })
  return buf
end

function M.open(args)
  local ref_arg, position, ok = parse(args)
  if not ok then
    warn("position must be left, right, bottom or float")
    return
  end

  local vcs = require("lazydiff.vcs")
  local ref = require("lazydiff").resolve_ref(ref_arg)

  local backend, err, root = vcs.get(vcs.anchor_dir())
  if not backend then
    warn(err or "not in a git or jj repository")
    return
  end

  local files, ferr = backend.changed_files(root, ref)
  if not files then
    warn(ferr or "failed to list changed files")
    return
  end

  local cands = candidates(root, files)
  local more = 0
  if #cands > MAX_FILES then
    more = #cands - MAX_FILES
    for i = #cands, MAX_FILES + 1, -1 do
      cands[i] = nil
    end
  end

  local rows = {}
  for _, cand in ipairs(cands) do
    rows[#rows + 1] = describe(backend, root, ref, cand)
  end

  local origin = vim.api.nvim_get_current_win()
  local buf, win = find_view(ref)
  if buf then
    local view = views[buf]
    if win ~= origin then
      view.origin = origin
    end
    view.root = root
    view.entries = fill(buf, rows, more)
    vim.api.nvim_set_current_win(win)
  else
    buf = create_buf(ref)
    local entries, nlines, width = fill(buf, rows, more)
    views[buf] = { ref = ref, root = root, origin = origin, entries = entries }
    win = show(buf, position, nlines, width)
  end
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

return M
