local M = {}

local function version_of(exe)
  local out = vim.fn.systemlist({ exe, "--version" })
  return out[1] or (exe .. " found on $PATH")
end

local function neovim_version()
  local v = vim.version()
  return ("%d.%d.%d"):format(v.major, v.minor, v.patch)
end

function M.check()
  vim.health.start("lazydiff")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim " .. neovim_version())
  else
    vim.health.error("Neovim 0.10 or newer is required (vim.system, vim.diff indices)")
  end

  local vcs = require("lazydiff.vcs")
  local backends = vcs.backends()
  for _, name in ipairs(backends) do
    if vim.fn.executable(name) == 1 then
      vim.health.ok(version_of(name))
    else
      vim.health.warn(("%s not found on $PATH"):format(name))
    end
  end

  -- Validate a copy: running setup() here would install the options as a side
  -- effect of a health check.
  local cfg = require("lazydiff.config")
  local ok, err = pcall(cfg.validate, vim.deepcopy(cfg.options))
  if ok then
    vim.health.ok("configuration is valid")
  else
    vim.health.error("configuration error: " .. tostring(err))
  end

  local configured, verr = vcs.configured()
  if configured then
    vim.health.info(("vcs = %s"):format(configured))
  else
    vim.health.error("configuration error: " .. tostring(verr))
  end

  local dir = vcs.anchor_dir()
  local backend, rerr, root = vcs.get(dir)
  if backend then
    vim.health.ok(("%s repository at %s (resolved from %s)"):format(backend.name, root, dir))
    if vim.fn.executable(backend.name) ~= 1 then
      vim.health.error(("%s is missing, so this buffer cannot be read"):format(backend.name))
    end
  else
    vim.health.info(("current buffer resolves to no backend: %s"):format(tostring(rerr)))
  end
end

return M
