-- The .rig folder of a worktree, where rig and the skills keep notes, plans, and
-- review state (see docs/contract.md). It is kept out of git through the repo's
-- info/exclude, not .gitignore: that covers every worktree without changing a
-- tracked file.
local M = {}

M.name = ".rig"

-- Folders made by wt, before rig, which move to .rig the first time rig looks.
local old = ".ticket"

local function git_common(dir)
  local r = vim.system({ "git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir" }, { text = true }):wait()
  return r.code == 0 and vim.trim(r.stdout) or nil
end

-- Adds /.rig/ to the info/exclude of the repo `dir` is in. Returns false when
-- `dir` isn't in a git repo.
function M.exclude(dir)
  local common = git_common(dir)
  if not common then return false end
  local exclude = common .. "/info/exclude"
  local f = io.open(exclude)
  local text = f and f:read("*a") or ""
  if f then f:close() end
  local line = "/" .. M.name .. "/"
  if not ("\n" .. text .. "\n"):find("\n" .. line .. "\n", 1, true) then
    vim.fn.mkdir(vim.fs.dirname(exclude), "p")
    f = assert(io.open(exclude, "a"))
    f:write((text ~= "" and not text:match("\n$")) and "\n" or "", line, "\n")
    f:close()
  end
  return true
end

-- The .rig folder of worktree `dir`, moving an older .ticket folder there first.
function M.dir(dir)
  local path = vim.fs.joinpath(dir, M.name)
  if not vim.uv.fs_stat(path) then
    local from = vim.fs.joinpath(dir, old)
    if vim.uv.fs_stat(from) and os.rename(from, path) then M.exclude(dir) end
  end
  return path
end

-- File `name` in worktree `dir`'s .rig folder.
function M.path(dir, name) return vim.fs.joinpath(M.dir(dir), name) end

function M.read(dir, name)
  local f = io.open(M.path(dir, name))
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

-- Writes `text` to file `name`, making the folder and its exclude line first.
function M.write(dir, name, text)
  M.exclude(dir)
  vim.fn.mkdir(M.dir(dir), "p")
  local f = assert(io.open(M.path(dir, name), "w"))
  f:write(text)
  f:close()
end

-- The value of the first "Key: value" line of `text`.
function M.field(text, key)
  return text and ("\n" .. text):match("\n" .. key .. ": ([^\n]*)") or nil
end

-- The Status line of the worktree's plan, or nil without a plan.
function M.plan_status(dir) return M.field(M.read(dir, "plan.md"), "Status") end

return M
