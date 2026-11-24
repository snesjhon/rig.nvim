-- Claude Code's state in each project folder: working, waiting on you, or idle.
-- `rig hook` writes it from Claude Code's hooks, one file per folder.
local M = {}

function M.dir() return vim.fs.joinpath(vim.fn.stdpath("state"), "rig", "claude") end

-- The state file of `project`, named after its real path so a symlinked path
-- finds the same file.
function M.file(project)
  local real = vim.uv.fs_realpath(project) or project
  return vim.fs.joinpath(M.dir(), (real:gsub("/", "%%")) .. ".json")
end

-- { state, event, message, time } for `project`, or nil when no Claude session
-- has run there since its last one ended.
function M.state(project)
  local f = io.open(M.file(project))
  if not f then return nil end
  local ok, state = pcall(vim.json.decode, f:read("*a"))
  f:close()
  return ok and type(state) == "table" and state or nil
end

return M
