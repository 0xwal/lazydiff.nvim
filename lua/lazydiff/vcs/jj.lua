local M = {}

M.name = "jj"

local function run(cwd, args)
  -- Same guard as the git adapter: vim.system raises ENOENT instead of
  -- returning an error code when cwd has gone away, which happens for a buffer
  -- whose directory was deleted out from under it.
  if not cwd or cwd == "" or vim.fn.isdirectory(cwd) == 0 then
    return 1, "", "no such directory: " .. tostring(cwd)
  end
  local ok, result = pcall(function()
    return vim.system({ "jj", unpack(args) }, { cwd = cwd, text = true }):wait()
  end)
  if not ok then
    return 1, "", tostring(result)
  end
  return result.code, result.stdout or "", result.stderr or ""
end

local function trim(s)
  return (s:gsub("%s+$", ""))
end

local function lines_of(out)
  return vim.split(out, "\n", { plain = true, trimempty = true })
end

-- config.options.ref defaults to "HEAD", which is git's spelling for what jj
-- calls "@". Map it so the default keeps working on a jj repo.
local function resolve_ref(ref)
  if not ref or ref == "" or ref == "HEAD" then
    return "@"
  end
  return ref
end

-- Accepts a file path or a directory, like the git adapter, so vcs.get() can
-- hand a buffer path straight through.
function M.root(dir)
  if not dir or dir == "" then
    return nil
  end
  local cwd = vim.fn.isdirectory(dir) == 1 and dir or vim.fs.dirname(dir)
  local code, out = run(cwd, { "root" })
  if code ~= 0 then
    return nil
  end
  out = trim(out)
  if out == "" then
    return nil
  end
  return out
end

-- `.jj/repo` is where the operation log heads and the commit index live, so it
-- is what the baseline watcher observes. `.jj` may be a file in a repo that
-- was created against an older jj; then there is nothing to watch and the
-- watcher stays off.
function M.state_dir(root)
  if not root or root == "" then
    return nil
  end
  local dir = root .. "/.jj/repo"
  if vim.fn.isdirectory(dir) == 1 then
    return dir
  end
  return nil
end

-- Entries jj rewrites under `.jj/repo` on a commit, checkout or rebase. Any
-- of them changing means the baseline moved.
function M.watch_names()
  return { "op_heads", "index" }
end

-- Bookmark names plus the two revisions every jj user types by hand. `@` (the
-- working copy) comes first so the list is ordered like git's HEAD-first one.
function M.refs(root)
  local list, seen = {}, {}
  local function add(name)
    if name ~= "" and not seen[name] then
      seen[name] = true
      list[#list + 1] = name
    end
  end
  add("@")
  add("@-")

  local code, out = run(root, { "bookmark", "list", "--all-remotes", "--template", 'name ++ "\n"' })
  if code ~= 0 then
    return list
  end
  for _, line in ipairs(lines_of(out)) do
    add(trim(line))
  end
  return list
end

-- Tracked-path sets, keyed by root and ref. A failed `file show` asks whether
-- the path is tracked at all; without a cache that is a full `jj file list`
-- scan each time. Entries expire after a few seconds, and an op change makes
-- them stale immediately.
local TRACKED_TTL_MS = 3000
local tracked_cache = {}

-- Current operation heads, read from the files jj keeps on disk, so the
-- freshness check costs no subprocess. nil when the layout is unexpected.
local function read_dir_names(dir)
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return nil
  end
  local names = {}
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    names[#names + 1] = name
  end
  table.sort(names)
  return table.concat(names, ",")
end

local function current_op(root)
  local base = root .. "/.jj/repo/op_heads"
  -- Newer jj keeps the head files in `op_heads/heads`; older jj puts them
  -- directly in `op_heads`.
  return read_dir_names(base .. "/heads") or read_dir_names(base)
end

-- Set of paths tracked at `ref`, or nil when `jj file list` failed.
local function tracked_paths(root, ref)
  ref = resolve_ref(ref)
  local key = root .. "\0" .. ref
  local cached = tracked_cache[key]
  local now = vim.uv.now()
  if cached then
    local op = current_op(root)
    if now - cached.time < TRACKED_TTL_MS and (op == nil or op == cached.op) then
      return cached.paths
    end
    tracked_cache[key] = nil
  end

  local code, out = run(root, { "file", "list", "-r", ref })
  if code ~= 0 then
    return nil
  end
  local paths = {}
  for _, line in ipairs(lines_of(out)) do
    paths[line] = true
  end
  tracked_cache[key] = { paths = paths, time = now, op = current_op(root) }
  return paths
end

-- Same contract as the git adapter: content, or nil + message + reason, with
-- reason "untracked" when the path simply does not exist at `ref`.
function M.file_at(root, relpath, ref)
  ref = resolve_ref(ref)
  local code, out, err = run(root, { "file", "show", "-r", ref, relpath })
  if code == 0 then
    return out, nil
  end
  local paths = tracked_paths(root, ref)
  if paths and not paths[relpath] then
    return nil, "file is not tracked at " .. ref, "untracked"
  end
  local msg = trim(err)
  return nil, msg ~= "" and msg or ("jj file show failed for " .. relpath), "error"
end

-- jj prints a rename as `old => new`, and folds the common prefix or suffix
-- away as `{old => new}` with text around the braces. The arrow separator is
-- " => " in both forms; splitting on it keeps spaces inside paths intact --
-- trimming the segments would corrupt legal names.
local function split_arrow(text)
  local at = text:find(" => ", 1, true)
  if at then
    return text:sub(1, at - 1), text:sub(at + 4)
  end
  at = text:find("=>", 1, true)
  if at then
    return text:sub(1, at - 1), text:sub(at + 2)
  end
  return nil, text
end

-- Returns old, new. `new` is always the remaining text when no arrow exists.
local function split_rename(text)
  local open = text:find("{", 1, true)
  local close = open and text:find("}", open, true)
  if open and close then
    local old, new = split_arrow(text:sub(open + 1, close - 1))
    if old then
      local prefix = text:sub(1, open - 1)
      local suffix = text:sub(close + 1)
      return prefix .. old .. suffix, prefix .. new .. suffix
    end
  end
  local old, new = split_arrow(text)
  if old and old ~= "" then
    return old, new
  end
  return nil, text
end

-- `jj diff -r <ref> --summary` emits one `STATUS path` line per file; STATUS is
-- the same letter git uses. jj always tracks whatever is in the working copy,
-- so there is no untracked class and no line counts to report.
function M.changed_files(root, ref)
  ref = resolve_ref(ref)
  local code, out, err = run(root, { "diff", "-r", ref, "--summary" })
  if code ~= 0 then
    local msg = trim(err)
    return nil, msg ~= "" and msg or ("jj diff failed against " .. ref)
  end

  local list = {}
  for _, line in ipairs(lines_of(out)) do
    local letter = line:sub(1, 1)
    -- jj separates the status letter from the path with one space; strip only
    -- that separator, because spaces inside a path are legal.
    local rest = (line:sub(2):gsub("^%s+", ""))
    if rest ~= "" and letter:match("%u") then
      local old_path, new_path = nil, rest
      if letter == "R" or letter == "C" then
        old_path, new_path = split_rename(rest)
        if not old_path and letter == "R" then
          -- An unparseable rename is still a rename: report the whole text
          -- rather than dropping old_path.
          old_path, new_path = rest, rest
        end
      end
      if new_path ~= "" then
        list[#list + 1] = {
          path = new_path,
          status = letter,
          binary = false,
          untracked = false,
          old_path = old_path,
        }
      end
    end
  end

  table.sort(list, function(a, b)
    return a.path < b.path
  end)
  return list
end

return M
