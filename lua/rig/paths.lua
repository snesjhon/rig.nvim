-- Where rig and mux are. rig runs on mux's sessions, so the rig command and
-- the board's own nvim put mux on the runtimepath next to rig.
local M = {}

-- The rig.nvim folder.
function M.root()
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
end

-- The rig command, called by path so it works before `rig setup` puts it on PATH.
function M.bin() return vim.fs.joinpath(M.root(), "bin", "rig") end

-- The mux.nvim folder: wherever the mux command on PATH links to, so rig runs
-- the same mux as the command (`mux setup` sets the link), else next to
-- rig.nvim, as vim.pack puts them. Nil when neither is there.
function M.mux()
  local exe = vim.fn.exepath("mux")
  local real = exe ~= "" and vim.uv.fs_realpath(exe)
  if real then return vim.fs.dirname(vim.fs.dirname(real)) end
  local sibling = vim.fs.joinpath(vim.fs.dirname(M.root()), "mux.nvim")
  if vim.uv.fs_stat(vim.fs.joinpath(sibling, "lua", "mux", "cli.lua")) then return sibling end
end

-- Puts mux on the runtimepath unless it can already be loaded. Returns false
-- when mux can't be found.
function M.use_mux()
  if pcall(require, "mux.cli") then return true end
  local dir = M.mux()
  if not dir then return false end
  vim.opt.rtp:prepend(dir)
  return true
end

return M
