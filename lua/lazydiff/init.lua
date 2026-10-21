local M = {}

function M.setup(opts)
  require("lazydiff.config").setup(opts)
  require("lazydiff.highlights").setup()
end

local function state()
  return require("lazydiff.state")
end

-- All bufnr arguments default to the current buffer (nil or 0).

function M.toggle(bufnr, ref)
  return state().toggle(bufnr, ref)
end

function M.enable(bufnr, ref)
  return state().enable(bufnr, ref)
end

function M.disable(bufnr)
  return state().disable(bufnr)
end

-- opts.baseline = true refetches the blob from git first.
function M.refresh(bufnr, opts)
  return state().refresh(bufnr, opts)
end

function M.is_enabled(bufnr)
  return state().is_enabled(bufnr)
end

function M.reset_hunk(bufnr)
  return state().reset_hunk(bufnr)
end

function M.yank_hunk(bufnr, register)
  return state().yank_hunk(bufnr, register)
end

function M.status(bufnr)
  return state().status(bufnr)
end

function M.statusline(bufnr)
  return state().statusline(bufnr)
end

function M.goto_first(bufnr)
  return require("lazydiff.nav").goto_first(bufnr or vim.api.nvim_get_current_buf())
end

function M.goto_next(bufnr)
  return require("lazydiff.nav").goto_next(bufnr or vim.api.nvim_get_current_buf())
end

function M.goto_prev(bufnr)
  return require("lazydiff.nav").goto_prev(bufnr or vim.api.nvim_get_current_buf())
end

-- Next hunk in the current file, else first hunk of the next changed file.
function M.goto_next_all()
  local config = require("lazydiff.config")
  local vcs = require("lazydiff.vcs")
  local ref = require("lazydiff.session").ref or config.options.ref

  local backend, err, root = vcs.get(vcs.anchor_dir())
  if not backend then
    vim.notify("lazydiff: " .. (err or "not in a git or jj repository"), vim.log.levels.WARN)
    return
  end

  local files, ferr = backend.changed_files(root, ref)
  if not files then
    vim.notify("lazydiff: " .. (ferr or "failed to list changed files"), vim.log.levels.WARN)
    return
  end

  local path_util = require("lazydiff.path")
  local paths = {}
  for _, entry in ipairs(files) do
    if not entry.untracked and entry.status ~= "D" then
      local abs = root .. "/" .. entry.path
      if path_util.is_regular_file(abs) then
        paths[#paths + 1] = abs
      end
    end
  end

  local st = state()
  local cur_buf = vim.api.nvim_get_current_buf()
  local hunks = st.get_hunks(cur_buf)
  if hunks and #hunks > 0 then
    local nav = require("lazydiff.nav")
    local row = vim.api.nvim_win_get_cursor(0)[1]
    for _, h in ipairs(hunks) do
      if nav.target_line(h) > row then
        M.goto_next(cur_buf)
        return
      end
    end
  end

  local cur_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(cur_buf), ":p")
  local idx = 0
  for i, p in ipairs(paths) do
    if p == cur_path then
      idx = i
      break
    end
  end

  local target = paths[idx + 1]
  if not target and config.options.nav and config.options.nav.wrap then
    target = paths[1]
  end
  if not target then
    vim.notify("lazydiff: no more changed files", vim.log.levels.INFO)
    return
  end

  vim.cmd.edit(vim.fn.fnameescape(target))
  local buf = vim.api.nvim_get_current_buf()
  if not M.is_enabled(buf) and not M.enable(buf, ref) then
    return
  end
  M.goto_first(buf)
end

-- One quickfix entry per hunk across all changed files of `ref`.
function M.quickfix(ref)
  local config = require("lazydiff.config")
  local vcs = require("lazydiff.vcs")
  local diff_mod = require("lazydiff.diff")
  local path_util = require("lazydiff.path")
  ref = ref or require("lazydiff.session").ref or config.options.ref

  local backend, err, root = vcs.get(vcs.anchor_dir())
  if not backend then
    vim.notify("lazydiff: " .. (err or "not in a git or jj repository"), vim.log.levels.WARN)
    return
  end

  local files, ferr = backend.changed_files(root, ref)
  if not files then
    vim.notify("lazydiff: " .. (ferr or "failed to list changed files"), vim.log.levels.WARN)
    return
  end

  local items = {}
  local no_baseline = 0
  for _, entry in ipairs(files) do
    if not entry.untracked and entry.status ~= "D" then
      local abs = root .. "/" .. entry.path
      -- Directories, sockets, FIFOs and vanished paths have no readable
      -- working-tree side, so keep them visible as contentless entries.
      if not path_util.is_regular_file(abs) then
        local stat_ok, stat = pcall(vim.uv.fs_stat, abs)
        local is_dir = stat_ok and stat and stat.type == "directory"
        items[#items + 1] = {
          filename = abs,
          lnum = 1,
          col = 1,
          valid = 0,
          text = is_dir and "directory or submodule change" or "unreadable path",
        }
      else
        local blob = backend.file_at(root, entry.path, ref)
        if blob and not path_util.is_binary(blob) then
          local old_lines = path_util.split_lines(blob)
          -- The path can vanish between the stat above and this read. A
          -- failed read must not diff as a full deletion, so skip the path.
          local read_ok, read = pcall(vim.fn.readfile, abs)
          if read_ok and type(read) == "table" then
            for _, hunk in ipairs(diff_mod.compute(old_lines, read)) do
              items[#items + 1] = {
                filename = abs,
                lnum = hunk.new_start > 0 and hunk.new_start or 1,
                col = 1,
                text = diff_mod.format_hunk_header(hunk),
              }
            end
          else
            no_baseline = no_baseline + 1
            items[#items + 1] = {
              filename = abs,
              lnum = 1,
              col = 1,
              valid = 0,
              text = "unreadable path",
            }
          end
        elseif not blob then
          no_baseline = no_baseline + 1
        end
      end
    end
  end

  vim.fn.setqflist({}, " ", { title = "lazydiff " .. ref, items = items })
  if #items > 0 then
    vim.cmd("copen")
  else
    vim.notify("lazydiff: no changed hunks", vim.log.levels.INFO)
  end
  if no_baseline > 0 then
    vim.notify("lazydiff: skipped " .. no_baseline .. " changed path(s) with no baseline", vim.log.levels.WARN)
  end
end

function M.open_float(opts)
  return require("lazydiff.float").open(opts)
end

function M.close_float()
  return require("lazydiff.float").close()
end

function M.toggle_float(opts)
  return require("lazydiff.float").toggle(opts)
end

return M
