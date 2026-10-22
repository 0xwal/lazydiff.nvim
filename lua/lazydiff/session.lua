local M = {}

local GROUP = "LazydiffSession"

M.active = false
-- Buffers this session enabled. M.stop() disables them.
M.enabled_bufs = {}

local function remember(bufnr)
  for _, buf in ipairs(M.enabled_bufs) do
    if buf == bufnr then
      return
    end
  end
  M.enabled_bufs[#M.enabled_bufs + 1] = bufnr
end

-- Enable the overlay on `bufnr` when its file has changes against
-- config.options.ref. Errors are swallowed so navigation never breaks.
function M.check(bufnr)
  if not M.active then
    return
  end
  pcall(function()
    if not bufnr or bufnr == 0 then
      bufnr = vim.api.nvim_get_current_buf()
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if vim.bo[bufnr].buftype ~= "" then
      return
    end
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
      return
    end
    if require("lazydiff.state").is_enabled(bufnr) then
      return
    end

    local path = vim.fn.fnamemodify(name, ":p")
    local vcs = require("lazydiff.vcs")
    local backend, _, root = vcs.get(vim.fs.dirname(path))
    if not backend or not root then
      return
    end

    local config = require("lazydiff.config")
    local ref = M.ref or config.options.ref
    local files = backend.changed_files(root, ref)
    if not files then
      return
    end

    local rel = require("lazydiff.path").relpath(root, path)
    if not rel then
      return
    end
    for _, file in ipairs(files) do
      if file.path == rel then
        if require("lazydiff").enable(bufnr, ref) then
          remember(bufnr)
        end
        return
      end
    end
  end)
end

function M.start(ref)
  M.ref = ref
  M.active = true
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      if vim.bo[args.buf].buftype ~= "" then
        return
      end
      if vim.api.nvim_buf_get_name(args.buf) == "" then
        return
      end
      M.check(args.buf)
    end,
  })
  if ref then
    local state = require("lazydiff.state")
    for _, bufnr in ipairs(M.enabled_bufs) do
      local status = vim.api.nvim_buf_is_valid(bufnr) and state.status(bufnr)
      if status and status.ref ~= ref then
        require("lazydiff").enable(bufnr, ref)
      end
    end
  end
  M.check(vim.api.nvim_get_current_buf())
end

function M.stop()
  M.active = false
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
  for _, bufnr in ipairs(M.enabled_bufs) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(require("lazydiff").disable, bufnr)
    end
  end
  M.enabled_bufs = {}
end

return M
