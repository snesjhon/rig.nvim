-- Opens a worktree's plan and code review. Inside a session they get tabs of
-- their own, whose nvim gets a call to M.review typed in or on its command
-- line, so everything here comes in as plain values.
local files = require("rig.files")
local M = {}

-- Opens the worktree's code review through the config's review.open, which gets:
--   dir        the worktree's folder
--   pr         the PR number a rig review worktree reviews, else nil (the
--              worktree's own PR, or its branch when there is none)
--   on_submit  function(head) to call once you submit, with the commit reviewed
-- Submitting marks that commit reviewed, and for your own open PR offers to hand
-- the review to the agent with rig revise. opts:
--   name, dir   the worktree session and its folder
--   number      the PR a rig review worktree reviews, else nil
-- hooks (only from a board in this nvim): refresh() and revise() run there.
function M.review(opts, hooks)
  hooks = hooks or {}
  local cli = require("mux.cli")
  local ok, sessions = pcall(require("rig.config").sessions)
  if not ok then return vim.notify(sessions, vim.log.levels.ERROR) end
  local open = (require("rig.config").get().review or {}).open
  if not open then
    return vim.notify("set review.open in the rig config to review code from the board", vim.log.levels.WARN)
  end
  local function refresh()
    if hooks.refresh then hooks.refresh() end
  end
  local skills = (sessions[opts.name] or {}).skills or {}
  open({
    dir = opts.dir,
    pr = opts.number,
    on_submit = function(head)
      pcall(files.write, opts.dir, "reviewed", head .. "\n")
      if opts.number or files.plan_status(opts.dir) ~= "pr-open" or not skills.revise then return refresh() end
      if vim.fn.confirm("Send your review to the agent with rig revise?", "&Yes\n&No", 2) ~= 1 then return refresh() end
      if hooks.revise then return hooks.revise() end
      vim.system({ require("rig.paths").bin(), "revise", opts.name }, { text = true }, function(r)
        vim.schedule(function()
          local msg = vim.trim((r.stderr or "") .. (r.stdout or ""))
          vim.notify(msg ~= "" and msg or "rig revise done", r.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
        end)
      end)
    end,
  })
end

-- The Ex command that opens the code review for `opts` (see M.review), on one
-- line so it can be typed into an nvim.
function M.review_command(opts)
  return ("lua require('rig.open').review(%s)"):format(vim.inspect(opts, { newline = " ", indent = "" }))
end

-- Opens the plan or the code review in the session's `plan` or `review` tab,
-- for a call from inside a session. Returns false outside one, else true and
-- the error, if any.
function M.file_tab(name, file)
  return require("mux.cli").open_tab(name, "plan", { vim.v.progpath, file }, "\27:drop " .. vim.fn.fnameescape(file) .. "\r")
end

function M.review_tab(opts)
  local code = M.review_command(opts)
  return require("mux.cli").open_tab(opts.name, "review", { vim.v.progpath, "-c", code }, "\27:" .. code .. "\r")
end

return M
