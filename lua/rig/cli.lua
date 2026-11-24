-- The rig command (bin/rig): reads the arguments and runs the command.
local M = {}

local usage = [[
rig new <branch> [base]          create a worktree and switch to its session
rig ticket <id or URL> [-n name | -b branch] [--on <PR URL>] [instructions...]
                                 create a worktree and run the repo's ticket skill in it;
                                 --on builds on that PR and targets its base branch
rig adopt <PR URL> [-n name] [instructions...]
                                 create a worktree for one of your open PRs and run the adopt skill
rig review <PR URL> [-n name]    open the code review of someone else's PR, making its worktree first

On a worktree, by default the git worktree this shell is in (board key in brackets):
rig plan [name]                  [p] open the plan, or the review plan when reviewing
rig update [name]                [u] reviewing: bring the PR's new commits and comments into the review plan
rig review [name]                [r] open the code review
rig mark [name]                  [m] mark the code reviewed
rig pr [name]                    [o] open the PR in the browser
rig revise [name]                [s] send your review to the agent
rig park [name]                  [x] stop the session and hide it until something changes (again to unpark)
rig rm [name]                    [d] stop the session and remove the worktree, keeping the branch

rig dash                         the board of every worktree, in a float inside a mux session

rig <skill> [name] [PR URL]      run a skill from the rig config on a worktree

rig setup                        put rig on PATH, check what it needs, add its Claude hooks
rig hook                         what Claude's hooks run, to record the agent's state

Sessions themselves (attach, switch, restart, kill) are mux's: see mux --help.]]

local function fail(msg)
  io.stderr:write(msg, "\n")
  os.exit(1)
end

local function names(args)
  local list
  if args[1] == "commands" then
    list = vim.tbl_keys(require("rig.config").commands())
    vim.list_extend(list, require("rig.config").builtins)
  else
    list = require("rig.worktree").names()
  end
  table.sort(list)
  io.stdout:write(table.concat(list, "\n"), "\n")
end

local function dispatch(args)
  local cmd = table.remove(args, 1)
  -- First, before loading anything else: Claude runs this on every event.
  if cmd == "hook" then return require("rig.hook").run() end
  if not cmd or cmd == "-h" or cmd == "--help" or cmd == "help" then return io.stderr:write(usage, "\n") end
  if cmd == "setup" then return require("rig.setup").run(args) end
  if not require("rig.paths").use_mux() then
    fail("rig: mux not found; put the mux command on PATH (mux setup), or install mux.nvim next to rig.nvim")
  end
  if cmd == "names" then return names(args) end
  local worktree = require("rig.worktree")
  if cmd == "dash" then return worktree.dash(args) end
  -- The board's actions (lua/rig/actions.lua): new, ticket, adopt, review, plan, update, mark, pr, park, rm.
  local action = require("rig.actions").command(cmd)
  if action then return require("rig.actions").cli(action, args) end
  -- revise and review-plan are always skill names, so a missing one says so.
  if cmd == "revise" or cmd == "review-plan" or require("rig.config").commands()[cmd] then
    return worktree.skill(cmd, args)
  end
  fail(("rig: unknown command %s\n%s"):format(cmd, usage))
end

function M.main(args)
  -- A broken config raises its own message; anything else is a bug worth a trace.
  local ok, err = xpcall(dispatch, function(e)
    if type(e) == "string" and e:match("^rig: ") then return e end
    return debug.traceback(e, 2)
  end, args)
  if not ok then fail(err) end
end

return M
