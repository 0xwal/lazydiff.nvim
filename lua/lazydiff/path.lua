-- Pure helpers shared by every VCS backend. Nothing here touches the
-- filesystem or a subprocess, so it is safe to require from anywhere.
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
