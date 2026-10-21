local path = require("lazydiff.path")

local M = {}

M.name = "git"

-- Untracked files above this size are listed but not line-counted.
local MAX_COUNT_BYTES = 4 * 1024 * 1024

local function run(cwd, args)
  -- vim.system raises ENOENT rather than returning an error code when cwd does
  -- not exist, which happens for a buffer whose directory was deleted out from
  -- under it. Treat it as a plain git failure so callers can fall through.
  if not cwd or cwd == "" or vim.fn.isdirectory(cwd) == 0 then
    return 1, "", "no such directory: " .. tostring(cwd)
  end
  local ok, result = pcall(function()
    return vim.system({ "git", unpack(args) }, { cwd = cwd, text = true }):wait()
  end)
  if not ok then
    return 1, "", tostring(result)
  end
  return result.code, result.stdout or "", result.stderr or ""
end

local function trim(s)
  return (s:gsub("%s+$", ""))
end

-- Accepts a file path or a directory. The directory case is what lets
-- vcs.get() hand a buffer path straight through: passing a directory used to
-- strip it to its parent via dirname(), so repo_root("/path/to/repo")
-- returned nil.
function M.root(dir)
  if not dir or dir == "" then
    return nil
  end
  local cwd = vim.fn.isdirectory(dir) == 1 and dir or vim.fs.dirname(dir)
  local code, out = run(cwd, { "rev-parse", "--show-toplevel" })
  if code ~= 0 then
    return nil
  end
  out = trim(out)
  if out == "" then
    return nil
  end
  return out
end

-- Absolute path of the repository's git directory. A linked worktree keeps its
-- own `.git/worktrees/<n>` directory, but the refs live in the common
-- directory, so that is what the watcher has to observe to see branch moves.
function M.state_dir(root)
  local code, out = run(root, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
  if code == 0 then
    local common = trim(out)
    if common ~= "" then
      if common:sub(1, 1) == "/" then
        return common
      end
      return root .. "/" .. common
    end
  end
  code, out = run(root, { "rev-parse", "--absolute-git-dir" })
  if code ~= 0 then
    return nil
  end
  out = trim(out)
  return out ~= "" and out or nil
end

-- Branch and tag names plus HEAD, for command completion.
function M.refs(root)
  local list = { "HEAD" }
  local code, out = run(root, { "for-each-ref", "--format=%(refname:short)" })
  if code ~= 0 then
    return list
  end
  for _, ref in ipairs(vim.split(out, "\n", { plain = true, trimempty = true })) do
    list[#list + 1] = ref
  end
  return list
end

-- Author name of the commit at `ref`, or nil on failure.
function M.author(root, ref)
  local code, out = run(root, { "log", "-1", "--format=%an", ref or "HEAD" })
  if code ~= 0 then
    return nil
  end
  local name = trim(out)
  return name ~= "" and name or nil
end

-- Directory entries the watcher treats as "the baseline may have moved". HEAD
-- and the index are written via rename, so observing the directory is enough.
function M.watch_names()
  return { "HEAD", "index", "ORIG_HEAD", "packed-refs" }
end

function M.is_tracked(root, relpath, ref)
  ref = ref or "HEAD"
  local code = run(root, { "cat-file", "-e", ref .. ":" .. relpath })
  return code == 0
end

-- A bad ref makes every cat-file probe fail, so a missing path can only be
-- called untracked once the ref itself is known to resolve.
local function ref_exists(root, ref)
  return run(root, { "rev-parse", "--verify", "--quiet", ref .. "^{commit}" }) == 0
end

-- Returns the blob content, or nil + a message + a reason. `reason` is
-- "untracked" when the path simply doesn't exist at `ref`, so callers can
-- treat that as "everything is new" rather than as an error. The decision is
-- a probe, not a match on git's English stderr.
function M.file_at(root, relpath, ref)
  ref = ref or "HEAD"
  local code, out, err = run(root, { "show", ref .. ":" .. relpath })
  if code == 0 then
    return out, nil
  end
  if ref_exists(root, ref) and not M.is_tracked(root, relpath, ref) then
    return nil, "file is not tracked at " .. ref, "untracked"
  end
  return nil, trim(err), "error"
end

-- Split git's -z output into records. -z is used throughout changed_files so
-- that paths containing spaces, quotes or UTF-8 arrive verbatim; without it
-- git backslash-escapes and quotes such paths and they no longer round-trip.
local function nul_tokens(out)
  local toks = vim.split(out, "\0", { plain = true })
  if toks[#toks] == "" then
    toks[#toks] = nil
  end
  return toks
end

-- git diff --name-status -z emits: STATUS \0 PATH \0
-- except for renames/copies, which emit: R100 \0 OLD \0 NEW \0
local function parse_name_status(out, upsert)
  local toks = nul_tokens(out)
  local i = 1
  while i <= #toks do
    local status = toks[i] or ""
    local letter = status:sub(1, 1)
    if letter == "R" or letter == "C" then
      local newpath = toks[i + 2]
      if newpath then
        local entry = upsert(newpath)
        entry.status = letter
        entry.old_path = toks[i + 1]
      end
      i = i + 3
    else
      local path_at = toks[i + 1]
      if path_at then
        upsert(path_at).status = letter
      end
      i = i + 2
    end
  end
end

-- git diff --numstat -z emits: "ADDED\tDELETED\tPATH" \0
-- except for renames, where the path field is empty and the old and new paths
-- follow as their own records: "ADDED\tDELETED\t" \0 OLD \0 NEW \0
-- Binary files report "-" for both counts.
local function parse_numstat(out, files)
  local toks = nul_tokens(out)
  local i = 1
  while i <= #toks do
    local added, deleted, path_at = (toks[i] or ""):match("^(%S+)\t(%S+)\t(.*)$")
    if not added then
      i = i + 1
    else
      if path_at == "" then
        path_at = toks[i + 2]
        i = i + 3
      else
        i = i + 1
      end
      local entry = path_at and files[path_at]
      if entry then
        entry.binary = added == "-"
        entry.added = tonumber(added) or 0
        entry.deleted = tonumber(deleted) or 0
      end
    end
  end
end

-- Untracked files have no blob to diff against, so numstat never sees them.
-- Read the file once: detect binaries by the same NUL rule git uses, and
-- count lines ourselves so the sidebar isn't blank. Returns (lines, binary).
local function inspect_untracked(abspath)
  local stat = vim.uv.fs_stat(abspath)
  if not stat or stat.type ~= "file" then
    return 0, false
  end
  local f = io.open(abspath, "rb")
  if not f then
    return 0, false
  end
  local head = f:read(8000) or ""
  if path.is_binary(head) then
    f:close()
    return 0, true
  end
  if stat.size > MAX_COUNT_BYTES then
    f:close()
    return 0, false
  end
  local content = head .. (f:read("*a") or "")
  f:close()
  if content == "" then
    return 0, false
  end
  local _, newlines = content:gsub("\n", "")
  if content:sub(-1) ~= "\n" then
    newlines = newlines + 1
  end
  return newlines, false
end

-- Every file differing from `ref` in the working tree, plus untracked files.
-- Returns an array sorted by path:
--   { path, status, added, deleted, binary, untracked, old_path }
-- `status` is git's letter: M A D R C, or "?" for untracked.
function M.changed_files(root, ref)
  ref = ref or "HEAD"
  local files, order = {}, {}

  local function upsert(file_path)
    local entry = files[file_path]
    if not entry then
      -- added/deleted stay nil until numstat reports them, so a failed numstat
      -- leaves the sidebar blank instead of claiming +0 -0.
      entry = { path = file_path, status = "M", binary = false }
      files[file_path] = entry
      order[#order + 1] = file_path
    end
    return entry
  end

  local code, out, err = run(root, { "diff", ref, "--name-status", "-z", "--" })
  if code ~= 0 then
    return nil, err ~= "" and trim(err) or ("git diff failed against " .. ref)
  end
  parse_name_status(out, upsert)

  local ncode, nout = run(root, { "diff", ref, "--numstat", "-z", "--" })
  if ncode == 0 then
    parse_numstat(nout, files)
  end

  local ucode, uout = run(root, { "ls-files", "--others", "--exclude-standard", "-z" })
  if ucode == 0 then
    for _, file_path in ipairs(nul_tokens(uout)) do
      if file_path ~= "" and not files[file_path] then
        local entry = upsert(file_path)
        entry.status = "?"
        entry.untracked = true
        entry.added, entry.binary = inspect_untracked(root .. "/" .. file_path)
        entry.deleted = 0
      end
    end
  end

  local list = {}
  for _, file_path in ipairs(order) do
    list[#list + 1] = files[file_path]
  end
  table.sort(list, function(a, b)
    return a.path < b.path
  end)
  return list
end

-- The names below predate the VCS seam. vcs.get() returns this module as the
-- git adapter, and these aliases keep the old call sites (and the spec) on the
-- same function names.
M.repo_root = M.root
M.git_dir = M.state_dir
M.head_blob = M.file_at
M.is_binary = path.is_binary
M.split_lines = path.split_lines
M.relpath = path.relpath

return M
