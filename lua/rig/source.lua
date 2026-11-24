-- A mux session source (see mux's README): one session per git worktree of
-- each repo in the rig config, named after the worktree's folder, with its
-- repo session's tabs, the plan status for the picker, and `parent` set to the
-- repo's session. List it in the mux config's sources as "rig.source".
local M = {}

-- The status text a worktree's plan gives in the session picker.
local function plan_status(dir)
  local status = require("rig.files").plan_status(dir)
  return status and "plan: " .. status
end

function M.sessions(configured)
  local trees = {}
  for parent, repo in pairs(require("rig.config").get().repos) do
    local s = configured[parent]
    if s and repo.worktrees then
      local out = vim.system({ "git", "-C", vim.fn.expand(s.path), "worktree", "list", "--porcelain" }):wait().stdout
      local first = true
      for path in (out or ""):gmatch("worktree ([^\n]+)") do
        -- The first entry is the repo itself, which is already its session.
        -- A worktree whose folder was deleted by hand stays listed until pruned.
        if not first and vim.uv.fs_stat(path) then
          trees[vim.fs.basename(path)] = { path = path, tabs = s.tabs, status = plan_status, parent = parent }
        end
        first = false
      end
    end
  end
  return trees
end

return M
