-- Floating file picker for `:LazydiffSearch`. One scratch buffer: line 1 is the
-- editable prompt, rows start at line 2. The filter is a case-insensitive
-- substring match on the path. Nothing here writes to disk.

local M = {}

local MAX_FILES = 500
local MAX_HEIGHT = 25
local MAX_WIDTH = 100
local MAX_DIFF_LINES = 5000
local MAX_DIFF_BYTES = 1024 * 1024
local PROMPT = "> "
local NS = vim.api.nvim_create_namespace("lazydiff_search")
local GROUP = vim.api.nvim_create_augroup("LazydiffSearch", { clear = true })

-- The open picker, or nil when no picker is open.
local state = nil

local function notify(msg, level)
  vim.notify("lazydiff: " .. msg, level or vim.log.levels.WARN)
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
  if cand.kind == "dir" then
    return { path = entry.path, text = entry.path .. "  dir" }
  end

  local old_text = ""
  if not entry.untracked then
    local blob, _, reason = backend.file_at(root, entry.old_path or entry.path, ref)
    if blob then
      old_text = blob
    elseif reason ~= "untracked" then
      return { path = entry.path, text = entry.path .. "  unreadable" }
    end
  end

  local new_text = ""
  if cand.kind == "file" then
    local ok, lines = pcall(vim.fn.readfile, cand.abs)
    if not ok or type(lines) ~= "table" then
      return { path = entry.path, text = entry.path .. "  unreadable" }
    end
    new_text = as_text(table.concat(lines, "\n"))
  end

  local binary = entry.binary or path_util.is_binary(old_text)
  if not binary and cand.kind == "file" then
    binary = sniff_binary(cand.abs)
  end
  if binary then
    return { path = entry.path, text = entry.path .. "  bin" }
  end

  if too_big(old_text) or too_big(new_text) then
    return { path = entry.path, text = entry.path .. "  big" }
  end

  local added, deleted = 0, 0
  for _, h in ipairs(vim.diff(as_text(old_text), new_text, { result_type = "indices" })) do
    deleted = deleted + h[2]
    added = added + h[4]
  end
  return {
    path = entry.path,
    text = ("%s  +%d -%d"):format(entry.path, added, deleted),
  }
end

-- Query is the prompt line without its leading "> ".
local function prompt_query()
  local line = vim.api.nvim_buf_get_lines(state.buf, 0, 1, false)[1] or ""
  return (line:gsub("^>%s?", "", 1))
end

local function visible(st)
  local q = st.query:lower()
  local out = {}
  for _, row in ipairs(st.rows) do
    if q == "" or row.path:lower():find(q, 1, true) then
      out[#out + 1] = row
    end
  end
  return out
end

local function highlight(st)
  vim.api.nvim_buf_clear_namespace(st.buf, NS, 0, -1)
  if #st.matches > 0 then
    -- Row i (1-based) is buffer line i + 1, which is extmark row i (0-based).
    vim.api.nvim_buf_set_extmark(st.buf, NS, st.sel, 0, { line_hl_group = "PmenuSel" })
  end
end

local function render(st)
  st.matches = visible(st)
  st.sel = math.max(1, math.min(st.sel, #st.matches))
  local lines = {}
  for i, row in ipairs(st.matches) do
    lines[i] = row.text
  end
  if #st.matches == 0 then
    lines[1] = "(no matches)"
  end
  if st.more > 0 then
    lines[#lines + 1] = ("... %d more"):format(st.more)
  end
  vim.api.nvim_buf_set_lines(st.buf, 1, -1, false, lines)
  highlight(st)
end

local function close(restore)
  local st = state
  if not st then
    return
  end
  if vim.api.nvim_win_is_valid(st.win) then
    pcall(vim.api.nvim_win_close, st.win, true)
  end
  state = nil
  if restore and st.origin and vim.api.nvim_win_is_valid(st.origin) then
    vim.api.nvim_set_current_win(st.origin)
  end
end

local function on_change()
  local st = state
  if not st then
    return
  end
  local line = vim.api.nvim_buf_get_lines(st.buf, 0, 1, false)[1] or ""
  if line:sub(1, #PROMPT) ~= PROMPT then
    -- Mouse or <C-o> jump altered the prompt. Restore it from the stored query.
    vim.api.nvim_buf_set_lines(st.buf, 0, 1, false, { PROMPT .. st.query })
    vim.api.nvim_win_set_cursor(st.win, { 1, #PROMPT + #st.query })
    return
  end
  local q = prompt_query()
  -- Re-rendering changes the buffer, which fires TextChanged again. Stop when
  -- the query is unchanged, or the autocmd loops forever.
  if q == st.query then
    return
  end
  st.query = q
  render(st)
end

local function move(delta)
  local st = state
  if not st then
    return
  end
  st.sel = math.max(1, math.min(st.sel + delta, #st.matches))
  highlight(st)
end

local function open_selected()
  local st = state
  if not st then
    return
  end
  -- Line 1 is the prompt. Lines 2+ are rows: match rows, then the footer.
  local line = vim.api.nvim_win_get_cursor(st.win)[1]
  if line > 1 and (#st.matches == 0 or line - 1 > #st.matches) then
    vim.cmd.startinsert()
    return
  end
  local row = st.matches[st.sel]
  if not row then
    vim.cmd.startinsert()
    return
  end
  local abs = st.root .. "/" .. row.path
  if not require("lazydiff.path").is_regular_file(abs) then
    notify("skip, not a regular file: " .. row.path)
    vim.cmd.startinsert()
    return
  end
  vim.cmd.stopinsert()
  close(true)
  vim.cmd.edit(vim.fn.fnameescape(abs))
end

local function map(buf, lhs, fn, desc)
  vim.keymap.set({ "n", "i" }, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
end

function M.open(ref)
  local vcs = require("lazydiff.vcs")
  ref = require("lazydiff").resolve_ref(ref)

  vim.api.nvim_clear_autocmds({ group = GROUP })
  close(true)

  local backend, err, root = vcs.get(vcs.anchor_dir())
  if not backend then
    notify(err or "not in a git or jj repository")
    return
  end

  local files, ferr = backend.changed_files(root, ref)
  if not files then
    notify(ferr or "failed to list changed files")
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

  local rows, path_width = {}, 0
  for _, cand in ipairs(cands) do
    local row = describe(backend, root, ref, cand)
    rows[#rows + 1] = row
    path_width = math.max(path_width, vim.fn.strdisplaywidth(row.path))
  end

  local data_rows = math.max(#rows, 1) + (more > 0 and 1 or 0)
  local width = math.min(path_width + 16, MAX_WIDTH)
  local height = math.min(data_rows + 2, MAX_HEIGHT)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { PROMPT })

  local origin = vim.api.nvim_get_current_win()
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })

  state = {
    win = win,
    buf = buf,
    origin = origin,
    root = root,
    ref = ref,
    rows = rows,
    more = more,
    matches = {},
    query = "",
    sel = 1,
  }
  render(state)
  vim.api.nvim_win_set_cursor(win, { 1, #PROMPT })

  map(buf, "<CR>", open_selected, "lazydiff search: open file")
  map(buf, "<C-n>", function()
    move(1)
  end, "lazydiff search: next row")
  map(buf, "<Down>", function()
    move(1)
  end, "lazydiff search: next row")
  map(buf, "<C-p>", function()
    move(-1)
  end, "lazydiff search: previous row")
  map(buf, "<Up>", function()
    move(-1)
  end, "lazydiff search: previous row")
  map(buf, "<Esc>", function()
    vim.cmd.stopinsert()
    close(true)
  end, "lazydiff search: close")

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = GROUP,
    buffer = buf,
    callback = on_change,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = GROUP,
    buffer = buf,
    callback = function()
      if state and vim.api.nvim_get_current_win() == state.win then
        close(false)
      end
    end,
  })

  vim.cmd.startinsert({ bang = true })
end

return M
