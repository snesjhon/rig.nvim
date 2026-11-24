-- rig's config: $RIG_CONFIG, else $XDG_CONFIG_HOME/rig/config.lua (default
-- ~/.config/rig/config.lua), a Lua file returning:
--   agent   the agent command skills run in (default "claude --permission-mode auto")
--   review  { open = function(opts) }, how the board opens a code review
--           (see lua/rig/open.lua); optional
--   repos   mux session name -> repo, for sessions whose folder is a git repo:
--     worktrees  a folder: rig makes the repo's worktrees there, and mux gets one
--                session per worktree through rig's session source (lua/rig/source.lua),
--                with the repo session's tabs
--     copy       paths relative to the repo that git ignores but a new worktree
--                needs, such as build output or local data; copied into each worktree
--     skills     name -> skill, the agent skills rig runs for this repo (see below)
-- A config.local.lua next to it, when there is one, is merged in, repos by name,
-- so private repos can live outside a shared config (it can be a link to another repo).
--
-- A skill is the command typed into the agent, or a table with it first:
--   { "/my-ticket revise", needs = "pr-open", key = "r", desc = "...", url = true }
--   needs  the plan status the worktree must be at, so a busy agent isn't interrupted
--   url    takes an optional PR URL; with one it also starts where there is no plan yet
--   key    a key for it on the board, desc its label there
-- These names have a set use: ticket (rig ticket, with the ticket id), adopt (rig
-- adopt, with the PR URL), review-plan (rig review worktrees, writes .rig/review.md; p
-- runs it for the first round, update for each next one),
-- and revise (sends your review of the worktree's PR to the agent). Any other name
-- is a command of its own: `rig <name> [worktree] [url]`.
local M = {}

-- Commands rig has itself, which skills can't be named after: the board's
-- actions (lua/rig/actions.lua) and these.
M.builtins = vim.list_extend({ "dash", "setup", "hook", "names", "help" }, require("rig.actions").verbs())

-- Board keys rig uses itself: the actions' and the board's own (lua/rig/dash).
M.board_keys = vim.list_extend({ "<CR>", "q", "?", "h", "j", "k", "l", "<Tab>" }, require("rig.actions").keys())

function M.file()
  if vim.env.RIG_CONFIG and vim.env.RIG_CONFIG ~= "" then return vim.env.RIG_CONFIG end
  local home = vim.env.XDG_CONFIG_HOME or vim.fs.joinpath(vim.env.HOME, ".config")
  return vim.fs.joinpath(home, "rig", "config.lua")
end

local function load(file)
  if not vim.uv.fs_stat(file) then return {} end
  local ok, res = pcall(dofile, file)
  if not ok then error("rig: " .. file .. ": " .. res, 0) end
  return type(res) == "table" and res or {}
end

-- `spec` in its table form: { cmd, needs, key, desc, url }.
local function skill(spec)
  if type(spec) == "string" then return { cmd = spec } end
  return { cmd = spec[1], needs = spec.needs, key = spec.key, desc = spec.desc, url = spec.url }
end

local function check(cfg)
  local reserved = {}
  for _, b in ipairs(M.builtins) do reserved[b] = true end
  local keys = {}
  for _, k in ipairs(M.board_keys) do keys[k] = true end
  for name, repo in pairs(cfg.repos) do
    for sname, spec in pairs(repo.skills) do
      if reserved[sname] and sname ~= "ticket" and sname ~= "adopt" then
        error(("rig: skill %s in repo %s has the name of a rig command"):format(sname, name), 0)
      end
      if not spec.cmd or spec.cmd == "" then error(("rig: skill %s in repo %s has no command"):format(sname, name), 0) end
      if spec.key and keys[spec.key] then
        error(("rig: skill %s in repo %s uses board key %s, which rig uses"):format(sname, name, spec.key), 0)
      end
    end
  end
end

-- The config, read fresh each time: repos can come and go while a session
-- runs. Errors from a broken config are raised with a message for the user.
function M.get()
  local file = M.file()
  local cfg = load(file)
  local extra = load(vim.fs.joinpath(vim.fs.dirname(file), "config.local.lua"))
  cfg.repos = vim.tbl_extend("force", cfg.repos or {}, extra.repos or {})
  for k, v in pairs(extra) do
    if k ~= "repos" then cfg[k] = v end
  end
  cfg.agent = cfg.agent or "claude --permission-mode auto"
  for _, repo in pairs(cfg.repos) do
    local skills = {}
    for sname, spec in pairs(repo.skills or {}) do
      skills[sname] = skill(spec)
    end
    repo.skills = skills
  end
  check(cfg)
  return cfg
end

-- mux's sessions, with each repo session's worktrees, copy, and skills from the
-- rig config, and each worktree session's skills from its repo. Stops with a
-- message when mux doesn't list rig's session source, since without it mux
-- can't start a worktree's session.
function M.sessions()
  local cfg = M.get()
  local mux_cfg = require("mux.config").get()
  if next(cfg.repos) and not mux_cfg.sources["rig.source"] then
    error(('rig: add ["rig.source"] = "<rig.nvim folder>" to sources in %s'):format(require("mux.config").file()), 0)
  end
  local all = require("mux.cli").sessions()
  for name in pairs(cfg.repos) do
    if not all[name] then error(("rig: repo %s in the rig config is not a session in the mux config"):format(name), 0) end
  end
  for name, def in pairs(all) do
    local repo = cfg.repos[def.parent or name]
    def.skills = repo and repo.skills or {}
    if repo and not def.parent then def.worktrees, def.copy = repo.worktrees, repo.copy end
  end
  return all
end

-- Every skill name across the repos that isn't one of the set ones, for
-- dispatch and tab completion.
function M.commands(cfg)
  local names = {}
  for _, repo in pairs((cfg or M.get()).repos) do
    for sname in pairs(repo.skills) do
      if sname ~= "ticket" and sname ~= "adopt" then names[sname] = true end
    end
  end
  return names
end

return M
