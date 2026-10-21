-- Helpers shared by every VCS backend. Nothing here spawns a subprocess, and
-- only is_regular_file() touches the filesystem, so it is safe to require from
-- anywhere.
local M = {}

function M.relpath(root, abspath)
  if not root or not abspath then
    return nil
  end
  local prefix = root:gsub("/+$", "") .. "/"
  if abspath:sub(1, #prefix) ~= prefix then
    return nil
  end
  return abspath:sub(#prefix + 1)
end

-- True only for a path that resolves to a regular file. fs_stat follows
-- symlinks, so a link to a regular file counts. Directories, sockets, FIFOs and
-- vanished paths are all false.
function M.is_regular_file(abs)
  if not abs or abs == "" then
    return false
  end
  local ok, stat = pcall(vim.uv.fs_stat, abs)
  if not ok or not stat then
    return false
  end
  return stat.type == "file"
end

function M.is_binary(content)
  if not content or content == "" then
    return false
  end
  return content:sub(1, 8000):find("\0", 1, true) ~= nil
end

function M.split_lines(content)
  if not content or content == "" then
    return {}
  end
  local trailing_newline = content:sub(-1) == "\n"
  local lines = vim.split(content, "\n", { plain = true })
  if trailing_newline then
    lines[#lines] = nil
  end
  return lines
end

return M
