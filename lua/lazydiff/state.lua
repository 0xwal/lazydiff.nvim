local M = {}

local config = require("lazydiff.config")
local vcs = require("lazydiff.vcs")
local path_util = require("lazydiff.path")
local diff = require("lazydiff.diff")
local render = require("lazydiff.render")
local highlights = require("lazydiff.highlights")

-- per-buffer state:
--   enabled, external, ref, repo, rel, backend, state_dir, baseline (old
--   lines), hunks, saved_modifiable, signcolumn { win, value }, augroup,
--   timer, watcher, watch_timer
local buffers = {}

local function notify(msg, level)
  vim.notify("lazydiff: " .. msg, level or vim.log.levels.INFO)
end

-- Every Neovim API call takes 0 to mean "current buffer", so callers reasonably
-- pass it here too -- but 0 is truthy in Lua, so `bufnr or current()` keeps it
-- and the lookup lands on buffers[0], which is never populated. Normalize once.
local function resolve(bufnr)
  if not bufnr or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function buf_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return vim.fn.fnamemodify(name, ":p")
end

local function buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- Locate the buffer's file inside its repo. Returns { repo, rel, backend } or
-- nil + err.
local function locate(bufnr)
  local path = buf_path(bufnr)
  if not path then
    return nil, "buffer has no file"
  end
  local backend, err, repo = vcs.get(path)
  if not backend then
    return nil, err or "not in a git or jj repository"
  end
  local rel = path_util.relpath(repo, path)
  if not rel then
    return nil, "file is outside the repo root"
  end
  return { repo = repo, rel = rel, backend = backend }
end

-- Fetch the reference blob. One backend call: it fails for paths that are not
-- in `ref`, so a separate tracked-ness probe is unnecessary. Returns the
-- parsed old-lines array, or nil + an error string + a reason.
local function fetch_baseline(loc, ref)
  local blob, err, reason = loc.backend.file_at(loc.repo, loc.rel, ref)
  if not blob then
    return nil, err or "failed to read blob", reason
  end
  if path_util.is_binary(blob) then
    return nil, "binary file", "binary"
  end
  return path_util.split_lines(blob)
end

-- Author label for the hunk header: "Jane Doe · Aug 3 2025 (6 months ago)".
-- Commit text for the hunk header: "[abc1234] - Fix parser" (jj: "[uyknllow] - ...").
-- Each lookup costs a subprocess and refresh runs on every change, so both
-- strings are memoized on the buffer state, keyed by the resolved repo root
-- plus the ref string. A failed lookup is memoized too, so a broken ref does
-- not respawn git or jj on every tick. Returns label, commit (each nil when off).
local function author_for(st, ref)
  if not (config.options.show_author_header or config.options.show_commit_header) then
    return nil
  end
  if not st.backend or not st.repo then
    return nil
  end
  local key = (st.backend.name or "") .. "\0" .. st.repo .. "\0" .. tostring(ref)
  local cached = st.author_cache
  local now = os.time()
  if cached and cached.key == key and now - cached.at < 60 then
    return cached.label, cached.commit
  end
  local label, commit
  if config.options.show_author_header and type(st.backend.author) == "function" then
    local name, when = st.backend.author(st.repo, ref)
    if name then
      if type(when) == "string" and when ~= "" then
        label = name .. " · " .. when
      else
        label = name
      end
    end
  end
  if config.options.show_commit_header and type(st.backend.commit_info) == "function" then
    local ok, short, subject = pcall(st.backend.commit_info, st.repo, ref)
    if ok and short then
      if type(subject) ~= "string" or subject == "" then
        subject = "(no description)"
      end
      commit = "[" .. short .. "] - " .. subject
    end
  end
  st.author_cache = { key = key, label = label, commit = commit, at = now }
  return label, commit
end

local function recompute(bufnr, baseline)
  return diff.compute(baseline, buf_lines(bufnr))
end

local function close_timer(timer)
  if timer then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
  end
end

local function stop_timer(state)
  close_timer(state.timer)
  state.timer = nil
end

local function stop_watcher(state)
  close_timer(state.watch_timer)
  state.watch_timer = nil
  state.watch_key = nil
  if state.watcher then
    pcall(state.watcher.stop, state.watcher)
    pcall(state.watcher.close, state.watcher)
    state.watcher = nil
  end
end

-- Identity of the current watch target. refresh() compares it against the
-- installed watcher's key so a moved repo or a changed `vcs` option restarts
-- the watcher, and a changed watch_names() does too.
local function watch_key(state)
  if not state.state_dir then
    return nil
  end
  local names = state.backend and state.backend.watch_names() or {}
  if #names == 0 then
    return ""
  end
  return state.state_dir .. "\0" .. table.concat(names, ",")
end

local function teardown_autocmds(state)
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
end

local function debounced_refresh(bufnr, state)
  if not config.options.live_refresh then
    return
  end
  stop_timer(state)
  state.timer = vim.uv.new_timer()
  local ms = config.options.debounce_ms or 100
  state.timer:start(
    ms,
    0,
    vim.schedule_wrap(function()
      stop_timer(state)
      M.refresh(bufnr)
    end)
  )
end

-- Watch the backend's state directory so a commit, checkout or reset made
-- behind the editor's back refetches the baseline. Both backends write their
-- bookkeeping files via rename, so the directory (not the files) is what's
-- observed, and each backend says which entry names mean "the baseline moved".
local function start_watcher(bufnr, state)
  stop_watcher(state)
  if not config.options.watch_git or not state.state_dir then
    return
  end
  local names = state.backend and state.backend.watch_names() or {}
  if #names == 0 then
    -- An empty list means nothing in the directory is worth reacting to, so
    -- watching it would only accept every event for no reason.
    state.watch_key = ""
    return
  end
  local watched = {}
  for _, name in ipairs(names) do
    watched[name] = true
  end
  local ok, watcher = pcall(vim.uv.new_fs_event)
  if not ok or not watcher then
    return
  end
  state.watcher = watcher
  local started = pcall(watcher.start, watcher, state.state_dir, {}, function(err, fname)
    if err or not fname or not watched[fname] then
      return
    end
    close_timer(state.watch_timer)
    state.watch_timer = vim.uv.new_timer()
    state.watch_timer:start(
      200,
      0,
      vim.schedule_wrap(function()
        close_timer(state.watch_timer)
        state.watch_timer = nil
        M.refresh(bufnr, { baseline = true })
      end)
    )
  end)
  if not started then
    stop_watcher(state)
    return
  end
  state.watch_key = watch_key(state)
end

local function setup_autocmds(bufnr, state)
  teardown_autocmds(state)
  local group = vim.api.nvim_create_augroup("LazydiffBuf" .. bufnr, { clear = true })
  state.augroup = group

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.disable(bufnr)
    end,
  })

  if not config.options.auto_refresh then
    return
  end

  -- A save or an external reload is also when the baseline is most likely
  -- to have moved (commit from a terminal, then :w), so refetch it here.
  vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost", "BufReadPost" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.refresh(bufnr, { baseline = true })
    end,
  })

  if config.options.live_refresh then
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = group,
      buffer = bufnr,
      callback = function()
        debounced_refresh(bufnr, state)
      end,
    })
  end
end

-- The + markers live in the sign column; with signcolumn=no they are simply
-- invisible. Turn it on for the window showing the buffer and remember what
-- to put back.
local function apply_signcolumn(bufnr, state)
  if not config.options.force_signcolumn or state.signcolumn then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end
  local value = vim.wo[win].signcolumn
  if value == "no" then
    state.signcolumn = { win = win, value = value }
    vim.wo[win].signcolumn = "yes:1"
  end
end

local function restore_signcolumn(state)
  local saved = state.signcolumn
  state.signcolumn = nil
  if saved and vim.api.nvim_win_is_valid(saved.win) and vim.wo[saved.win].signcolumn == "yes:1" then
    vim.wo[saved.win].signcolumn = saved.value
  end
end

function M.is_enabled(bufnr)
  local s = buffers[resolve(bufnr)]
  return s ~= nil and s.enabled == true
end

function M.enable(bufnr, ref)
  highlights.setup()
  bufnr = resolve(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  ref = ref or config.options.ref

  local loc, err = locate(bufnr)
  if not loc then
    notify(err, vim.log.levels.WARN)
    return false
  end

  local baseline, berr, reason = fetch_baseline(loc, ref)
  local untracked = false
  if not baseline then
    if reason == "untracked" then
      baseline = {}
      untracked = true
    else
      notify(berr, vim.log.levels.WARN)
      return false
    end
  end

  local hunks = recompute(bufnr, baseline)

  local state = buffers[bufnr] or {}
  if not state.enabled then
    state.saved_modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr })
  end
  state.enabled = true
  state.external = nil
  state.untracked = untracked
  state.ref = ref
  -- The ref just changed, so the memoized author label no longer applies.
  state.author_cache = nil
  state.path = buf_path(bufnr)
  state.repo = loc.repo
  state.rel = loc.rel
  state.backend = loc.backend
  state.state_dir = loc.backend.state_dir(loc.repo)
  state.baseline = baseline
  state.baseline_lines = baseline
  state.hunks = hunks
  buffers[bufnr] = state

  local author, commit = author_for(state, ref)
  render.render(bufnr, hunks, state.baseline_lines, author, commit)

  if config.options.read_only then
    vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  end

  apply_signcolumn(bufnr, state)
  setup_autocmds(bufnr, state)
  start_watcher(bufnr, state)

  if #hunks == 0 then
    -- Stay enabled: the overlay appears as soon as the buffer diverges.
    notify("no changes against " .. ref .. " yet; overlay is on", vim.log.levels.INFO)
  elseif config.options.jump_on_enable then
    local nav = require("lazydiff.nav")
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if not nav.cursor_in_hunk(hunks[1], row) then
      nav.goto_first(bufnr)
    end
  end
  return true, reason
end

function M.disable(bufnr)
  bufnr = resolve(bufnr)
  local state = buffers[bufnr]
  if not state then
    return
  end

  stop_timer(state)
  stop_watcher(state)
  state.baseline, state.baseline_lines = nil, nil
  state.author_cache = nil

  if vim.api.nvim_buf_is_valid(bufnr) then
    render.clear(bufnr)
    if config.options.read_only and state.saved_modifiable ~= nil then
      vim.api.nvim_set_option_value("modifiable", state.saved_modifiable, { buf = bufnr })
    end
  end
  restore_signcolumn(state)

  teardown_autocmds(state)
  buffers[bufnr] = nil
end

-- Without `ref`: plain on/off. With `ref`: turn on against that ref, or
-- switch to it if already on against a different one.
function M.toggle(bufnr, ref)
  bufnr = resolve(bufnr)
  local state = buffers[bufnr]
  if state and state.enabled and (ref == nil or ref == state.ref) then
    M.disable(bufnr)
  else
    M.enable(bufnr, ref)
  end
end

-- opts.baseline = true refetches the blob from the backend before
-- recomputing, which is what makes a commit or checkout under a live overlay
-- show up.
function M.refresh(bufnr, opts)
  bufnr = resolve(bufnr)
  opts = opts or {}
  local state = buffers[bufnr]
  if not state or not state.enabled then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    M.disable(bufnr)
    return
  end

  if not state.external then
    local path = buf_path(bufnr)
    local wanted = vcs.configured()
    local forced_elsewhere = wanted ~= nil
      and wanted ~= "auto"
      and wanted ~= (state.backend and state.backend.name)
    local loc, moved
    if opts.baseline or path ~= state.path or forced_elsewhere then
      loc = locate(bufnr)
      if loc then
        moved = loc.repo ~= state.repo or loc.rel ~= state.rel or loc.backend ~= state.backend
      end
    end

    -- The old baseline belongs to the old repo, path or backend, so a moved
    -- buffer refetches even when the caller did not ask for it.
    local fetch_failed = false
    if opts.baseline or moved then
      -- locate() can fail after a :saveas out of the repo; the last known
      -- location stays valid enough to refetch from.
      local source = loc or { repo = state.repo, rel = state.rel, backend = state.backend }
      local baseline, _, reason = fetch_baseline(source, state.ref)
      if baseline then
        state.baseline = baseline
        state.baseline_lines = baseline
        state.untracked = false
      elseif reason == "untracked" then
        -- The file vanished from `ref` (e.g. checkout of an older branch):
        -- everything in the buffer is now new.
        state.baseline = {}
        state.baseline_lines = state.baseline
        state.untracked = true
      else
        fetch_failed = true
      end
      if not fetch_failed and loc then
        state.repo = loc.repo
        state.rel = loc.rel
        state.backend = loc.backend
        state.state_dir = loc.backend.state_dir(loc.repo)
        if watch_key(state) ~= state.watch_key then
          start_watcher(bufnr, state)
        end
      end
      if not fetch_failed then
        state.author_cache = nil
      end
      -- Any other failure keeps the last known baseline.
    end
    -- Remember the name even when it left the repo, so a plain refresh does
    -- not re-run detection on every change. A baseline refresh locates anyway.
    if not fetch_failed then
      state.path = path
    end
  end

  local hunks = recompute(bufnr, state.baseline)
  state.hunks = hunks
  local author, commit = author_for(state, state.ref)
  render.render(bufnr, hunks, state.baseline_lines, author, commit)
end

-- Register hunks computed elsewhere (the float's scratch pane) so nav.lua can
-- navigate the buffer. Deliberately skips what enable() does around it: no
-- autocmds and no timers, because the float refreshes manually, and no
-- baseline fetch, because locate() derives the blob from the buffer's
-- filename and a scratch buffer has none. (Naming the scratch buffer after
-- the real file isn't an option -- duplicate buffer names raise E95.)
function M.attach(bufnr, opts)
  bufnr = resolve(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local previous = buffers[bufnr]
  if previous and previous.enabled then
    stop_timer(previous)
    stop_watcher(previous)
    teardown_autocmds(previous)
  end
  highlights.setup()
  buffers[bufnr] = {
    enabled = true,
    external = true,
    ref = opts.ref,
    baseline = opts.baseline,
    hunks = opts.hunks,
  }
end

function M.get_hunks(bufnr)
  bufnr = resolve(bufnr)
  local state = buffers[bufnr]
  if not state or not state.enabled then
    return nil
  end
  return state.hunks
end

-- Hunk under the cursor of the current window, when it shows `bufnr`.
local function hunk_under_cursor(bufnr)
  local state = buffers[bufnr]
  if not state or not state.enabled then
    return nil, "overlay is not enabled"
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return nil, "buffer is not in the current window"
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local index, hunk = require("lazydiff.nav").hunk_at(state.hunks, row)
  if not hunk then
    return nil, "no hunk under cursor"
  end
  return hunk, nil, index, state
end

-- Put the baseline's lines back in place of the hunk under the cursor: the
-- "reject this change" action when reviewing a patch.
function M.reset_hunk(bufnr)
  bufnr = resolve(bufnr)
  local state = buffers[bufnr]
  if not state or not state.enabled then
    vim.notify("lazydiff: not enabled in this buffer", vim.log.levels.WARN)
    return false
  end
  if state.external then
    notify("review pane is read-only; open the file with <CR> to edit", vim.log.levels.WARN)
    return false
  end
  if state.baseline_lines == nil then
    vim.notify("lazydiff: no baseline for this file", vim.log.levels.WARN)
    return false
  end
  if state.untracked then
    vim.notify("lazydiff: untracked file, nothing to revert to", vim.log.levels.WARN)
    return false
  end
  if vim.bo[bufnr].modifiable == false then
    vim.notify("lazydiff: buffer is not modifiable", vim.log.levels.WARN)
    return false
  end
  local hunk, err = hunk_under_cursor(bufnr)
  if not hunk then
    notify(err, vim.log.levels.WARN)
    return false
  end

  -- 0-based, end-exclusive range of the new-side lines. A pure delete has
  -- no new lines; its old lines are inserted after line new_start.
  local first = hunk.new_count > 0 and hunk.new_start - 1 or hunk.new_start
  local last = first + hunk.new_count

  vim.api.nvim_buf_set_lines(bufnr, first, last, false, hunk.old_lines)

  M.refresh(bufnr)
  return true
end

-- Yank the hunk's deleted lines (the red virtual lines, which `y` can't
-- reach) into `register`, linewise. Defaults to the unnamed register.
function M.yank_hunk(bufnr, register)
  bufnr = resolve(bufnr)
  local hunk, err = hunk_under_cursor(bufnr)
  if not hunk then
    notify(err, vim.log.levels.WARN)
    return false
  end
  if #hunk.old_lines == 0 then
    notify("hunk has no deleted lines to yank", vim.log.levels.INFO)
    return false
  end
  register = register or '"'
  vim.fn.setreg(register, hunk.old_lines, "l")
  notify(("yanked %d deleted line%s"):format(#hunk.old_lines, #hunk.old_lines == 1 and "" or "s"))
  return true
end

-- For statuslines: { ref, hunks = n, current = i or nil } or nil when off.
function M.status(bufnr)
  bufnr = resolve(bufnr)
  local state = buffers[bufnr]
  if not state or not state.enabled then
    return nil
  end
  local current
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local row = vim.api.nvim_win_get_cursor(win)[1]
    current = require("lazydiff.nav").hunk_at(state.hunks, row)
    if current then
      break
    end
  end
  return { ref = state.ref, hunks = #state.hunks, current = current }
end

function M.statusline(bufnr)
  local s = M.status(bufnr)
  if not s then
    return ""
  end
  if s.hunks == 0 then
    return "lazydiff: no changes"
  end
  if s.current then
    return ("lazydiff: hunk %d/%d"):format(s.current, s.hunks)
  end
  return ("lazydiff: %d hunk%s"):format(s.hunks, s.hunks == 1 and "" or "s")
end

return M
