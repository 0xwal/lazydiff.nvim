-- Backend seam: picks the VCS a buffer belongs to and returns its adapter.
--
-- Resolution is lazy -- it happens on enable, refresh and command completion,
-- never at module load -- so a session that moves between a git and a jj repo
-- keeps working.
--
-- Adapter interface (both lua/lazydiff/vcs/git.lua and .../jj.lua):
--   name                 "git" | "jj"
--   root(dir)            absolute repo root for a file or directory, or nil
--   state_dir(root)      directory the watcher observes, or nil
--   refs(root)           list of ref names, working-copy ref first
--   file_at(root, rel, ref)   content, or nil + message + "untracked"/"error"
--   changed_files(root, ref)  array of { path, status, added, deleted,
--                             binary, untracked, old_path }, or nil + message
--   watch_names()        directory entries under state_dir worth reacting to
local M = {}

local config = require("lazydiff.config")

-- Detection order. `.jj` is tried first: a jj repo may carry a `.git` for
-- git interoperability (colocated repos), and jj is then the source of truth.
local DETECT_ORDER = { "jj", "git" }
local MARKER = { jj = ".jj", git = ".git" }
local VALID = { auto = true, git = true, jj = true }
local MAX_DEPTH = 64

local function load(name)
  return require("lazydiff.vcs." .. name)
end

-- Names for health checks, in the order they should be reported.
function M.backends()
  return { "git", "jj" }
end

local function has_marker(dir, name)
  return vim.uv.fs_stat(dir .. "/" .. MARKER[name]) ~= nil
end

-- Walk `dir` and its parents. A `.jj` at any level wins over a `.git` at any
-- level; otherwise the deepest `.git` wins, which is the repo the file is
-- actually inside of. Returns the backend name, or nil.
local function detect(dir)
  local found_git = false
  local level = dir
  local depth = 0
  while level and level ~= "" and depth < MAX_DEPTH do
    for _, name in ipairs(DETECT_ORDER) do
      if has_marker(level, name) then
        if name == "jj" then
          return "jj"
        end
        found_git = true
      end
    end
    local parent = vim.fs.dirname(level)
    if not parent or parent == level then
      break
    end
    level = parent
    depth = depth + 1
  end
  return found_git and "git" or nil
end

-- Validated value of `config.options.vcs`: "auto", "git" or "jj", or nil +
-- a message. Callers must not index the adapter modules with an unchecked
-- option value.
function M.configured()
  local wanted = config.options.vcs or "auto"
  if not VALID[wanted] then
    return nil, ("unknown vcs: %s"):format(tostring(wanted))
  end
  return wanted
end

-- Adapter for the repo containing `dir` (a directory or a file path), or
-- nil + message. The third return value is the resolved root, so callers do
-- not have to ask the backend twice.
function M.get(dir)
  if not dir or dir == "" then
    return nil, "no directory to resolve from"
  end

  local wanted, verr = M.configured()
  if not wanted then
    return nil, verr
  end

  local name
  if wanted == "auto" then
    name = detect(dir)
    if not name then
      return nil, "not in a git or jj repository"
    end
  else
    name = wanted
  end

  local backend = load(name)
  local root = backend.root(dir)
  if not root then
    return nil, ("not in a %s repository"):format(name)
  end
  return backend, nil, root
end

-- Directory to resolve the repo from. The current buffer's name is only
-- trusted when its parent directory actually exists: plugin buffers name
-- themselves with things shaped like paths -- oil://, term://, fugitive:// --
-- and dirname() on those yields a directory that isn't there.
function M.anchor_dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" then
    local dir = vim.fs.dirname(name)
    if dir and vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  return vim.fn.getcwd()
end

return M
