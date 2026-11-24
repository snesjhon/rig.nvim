-- The worktree actions, defined once for both the board (lua/rig/board.lua) and
-- the rig command (lua/rig/cli.lua), so each board key has a command of the same
-- name and the two do the same thing. Each action is:
--   verb    the rig command: `rig <verb> [name]`, by default on the worktree
--           this shell is in
--   key     its board key, desc its label there
--   run     function(t, ui) acting on worktree `t` (see M.target), through `ui`,
--           which the board and the command each give (see board_ui in
--           lua/rig/board.lua and cli_ui below)
--   cli     function(args) when the command runs differently from run, such as
--           the actions that create a worktree
--   prompt  for actions that create a worktree: what the board asks for, then
--           passes to `rig <verb>`
--   skill   true when the verb is a skill name from the config (rig revise), so
--           the command runs it as a skill and config may define it
local cli = require("mux.cli")
local files = require("rig.files")
local M = {}

local function git(dir, args)
  return vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
end

local function decode(text)
  local ok, v = pcall(vim.json.decode, text or "")
  return ok and type(v) == "table" and v or nil
end

-- Whether commit `sha` is the one a short or full `at` names.
function M.same_commit(sha, at) return sha and at and sha:sub(1, #at) == at end

-- A rig review worktree's review plan (review-plan skill): its Status, the
-- commit its newest round covers, the time of the newest PR comment it read, the Tests line the test skill writes in
-- test.md ("building", or "ready" with the commit the kit covers), and the
-- commit walkthrough.json covers. Worktrees from before test.md have the
-- Tests line in review.md.
function M.review_plan(dir)
  local file = files.path(dir, "review.md")
  local text = files.read(dir, "review.md")
  if not text then return nil end
  text = "\n" .. text
  local stat = vim.uv.fs_stat(file)
  local test_text = files.read(dir, "test.md")
  local test_stat = test_text and vim.uv.fs_stat(files.path(dir, "test.md"))
  local tests = test_text and "\n" .. test_text or text
  local walk = decode(files.read(dir, "walkthrough.json"))
  return {
    file = file,
    status = text:match("\nStatus: ([^\n]*)"),
    at = text:match("\nRound: %d+ %(at (%x+)%)"),
    comments = text:match("\nComments: (%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ)"),
    tests = tests:match("\nTests: (%a+)"),
    tests_at = tests:match("\nTests: ready %(at (%x+)%)"),
    walk_at = walk and type(walk.head) == "string" and walk.head or nil,
    time = stat and stat.mtime.sec,
    tests_time = test_stat and test_stat.mtime.sec or (stat and stat.mtime.sec),
  }
end

-- What a parked worktree waits on: a new stage, commit, PR push, or teammate
-- comment ends the parking. `t` has plan, review_plan, head, and pr (PR details
-- from GitHub, which only the board has).
function M.signature(t)
  local pr = t.pr or {}
  return {
    stage = t.plan.status,
    review_plan = t.review_plan and t.review_plan.status,
    tests = t.review_plan and t.review_plan.tests,
    head = t.head,
    pr_head = pr.head,
    pr_state = pr.state,
    teammate = pr.teammate,
  }
end

-- Brings a rig review worktree's review/<their branch> up to the PR's newest
-- push, and returns the commit it is at and the PR's newest (nil when the fetch
-- failed). It only moves when it has no changes of its own, so a checkout you
-- were testing in is left alone.
local function catch_up(t, ui)
  local rv = t.review
  -- A review worktree without a branch name on record gets one, saved for next time.
  if not rv.branch and t.pr_info and t.pr_info.branch then
    rv.branch = "review/" .. t.pr_info.branch
    pcall(files.write, t.dir, "review.json", vim.json.encode(rv) .. "\n")
  end
  local done = ui.busy("fetching #" .. rv.number)
  local r = git(t.dir, { "fetch", "-q", rv.remote, ("refs/pull/%d/head"):format(rv.number) })
  done()
  local newest
  if r.code ~= 0 then
    ui.warn("couldn't fetch #" .. rv.number .. ": " .. vim.trim(r.stderr))
  else
    newest = vim.trim(git(t.dir, { "rev-parse", "FETCH_HEAD" }).stdout or "")
  end
  if newest and vim.trim(git(t.dir, { "status", "--porcelain", "-uno" }).stdout or "") == "" then
    git(t.dir, rv.branch and { "checkout", "-q", "-B", rv.branch, "FETCH_HEAD" } or { "checkout", "-q", "--detach", "FETCH_HEAD" })
  end
  return vim.trim(git(t.dir, { "rev-parse", "HEAD" }).stdout or ""), newest
end

-- The time (ISO, UTC) of the newest review, reply, or comment on PR `url` by
-- someone other than you, or nil. A reply on a line comment arrives as a review.
function M.activity(url)
  local host = url:match("^https://([^/]+)/")
  local me = vim.system({ "gh", "api", "--hostname", host, "user", "-q", ".login" }, { text = true }):wait()
  -- Without your login, nothing can count as someone else's.
  if me.code ~= 0 then return nil end
  me = vim.trim(me.stdout)
  local r = vim.system({ "gh", "pr", "view", url, "--json", "reviews,comments" }, { text = true }):wait()
  local pr = r.code == 0 and decode(r.stdout)
  if not pr then return nil end
  local newest
  local function consider(time, author)
    local login = type(author) == "table" and author.login or nil
    if type(time) ~= "string" or not login or login == me or login:match("%[bot%]$") then return end
    if not newest or time > newest then newest = time end
  end
  for _, x in ipairs(pr.reviews or {}) do consider(x.submittedAt, x.author) end
  for _, x in ipairs(pr.comments or {}) do consider(x.createdAt, x.author) end
  return newest
end

-- Whether nobody is on a drafting review plan: the session is down or Claude
-- stopped. Waiting on a question still counts as on it.
local function agent_stopped(t) return not t.running or t.agent == "idle" end

-- Opens the plan, or in a rig review worktree its review plan. A review
-- worktree without one, or with one left half done, has the review-plan skill
-- write it. New pushes wait for update, so the plan and the code you read stay
-- on the same commit.
local function plan(t, ui)
  if t.review then
    local rp = M.review_plan(t.dir)
    if t.agent == "working" then
      ui.warn("the agent is still on it")
    elseif not rp or (rp.status == "drafting" and agent_stopped(t)) then
      -- The first round covers the PR's newest push; later ones wait for update.
      if not rp then catch_up(t, ui) end
      return ui.skill("review-plan", "starting the review plan")
    end
    if not rp then return ui.fail("no review plan yet") end
    return ui.open_file(rp.file)
  end
  -- A review worktree that lost its .rig folder: rig review-plan rebuilds it.
  if (t.branch or ""):match("^review/") then return ui.skill("review-plan", "starting the review plan") end
  if not t.plan.file then return ui.fail("no plan yet in " .. (t.name or t.dir)) end
  ui.open_file(t.plan.file)
end

-- In a rig review worktree: pulls in what is new on the PR since the review
-- plan's last round, new commits or new comments, and has the review-plan skill
-- add the next round (what changed, each reply with options for answering it,
-- new risks).
local function update(t, ui)
  if not t.review then return ui.fail((t.name or t.dir) .. " is not a review worktree (rig review <PR URL>)") end
  if t.agent == "working" then return ui.warn("the agent is still on it") end
  local rp = M.review_plan(t.dir)
  if not rp then return ui.fail("no review plan yet; p writes it") end
  local head, newest = catch_up(t, ui)
  if newest and head ~= newest then
    return ui.fail("the worktree has local changes, so it stays at " .. head:sub(1, 11) .. "; stash or discard them first")
  end
  local done = ui.busy("checking #" .. t.review.number .. " for comments")
  local latest = M.activity(t.review.url)
  done()
  -- ISO times in UTC compare as text.
  local new_comments = latest and latest > (rp.comments or "")
  if M.same_commit(head, rp.at) and not new_comments and rp.status ~= "drafting" then
    return ui.warn("nothing new on #" .. t.review.number .. " since the last round")
  end
  ui.skill("review-plan", "updating the review plan")
end

-- Opens the worktree's code review (see lua/rig/open.lua), at the commit
-- checked out, which update moves.
local function review(t, ui)
  ui.open_review({ name = t.name, dir = t.dir, number = t.review and t.review.number })
end

local function mark(t, ui)
  -- The commit checked out is what you read, even when the PR has moved on.
  local head = t.head or ""
  if head == "" or not pcall(files.write, t.dir, "reviewed", head .. "\n") then
    return ui.fail("couldn't mark " .. (t.name or t.dir) .. " reviewed")
  end
  ui.ok(("marked %s reviewed at %s"):format(t.name or t.dir, head:sub(1, 11)))
end

local function pr(t, ui)
  if not t.pr then return ui.fail("no PR yet") end
  local job, err = vim.ui.open(t.pr)
  if not job then return ui.fail(err or "couldn't open " .. t.pr) end
  job:wait()
end

-- Stops the session and hides it from your turn until something changes; again
-- on a parked worktree whose session is down, unparks it.
local function park(t, ui)
  if not t.name then return ui.fail(t.dir .. " is not a worktree session") end
  if t.parked and not t.running then
    os.remove(files.path(t.dir, "parked"))
    return ui.ok("unparked " .. t.name)
  end
  if t.running then
    local sock = cli.sock(t.name)
    -- Quitting the session this runs in would close it too.
    if cli.current() == sock then return ui.fail("switch to another session to park " .. t.name) end
    if not ui.confirm("Stop session " .. t.name .. " and everything running in it?") then return end
    local done = ui.busy("stopping the session")
    cli.kill_procs({ sock })
    cli.quit_one(sock)
    done()
  end
  local sig = t.signature or M.signature({ plan = t.plan, review_plan = M.review_plan(t.dir), head = t.head })
  if not pcall(files.write, t.dir, "parked", vim.json.encode(sig) .. "\n") then
    return ui.fail("couldn't park " .. t.name)
  end
  ui.ok("parked " .. t.name)
end

local function revise(t, ui)
  if not t.skills.revise then return ui.fail(t.name .. " has no revise skill in the rig config") end
  ui.skill("revise", "sending your review to the agent")
end

local function rm(t, ui)
  if ui.confirm("Remove worktree " .. t.name .. "? Its branch is kept.") then
    ui.rig({ "rm", t.name }, "removing the worktree")
  end
end

local cli_ui

-- `rig review [name]` opens the code review; `rig review <PR URL> [-n name]`
-- first finds that PR's worktree, or makes it.
local function review_cli(args)
  if args[1] and args[1]:match("^https://") then
    local name = require("rig.worktree").review(args)
    -- Without a terminal (the board's v, :Rig) it only makes the worktree.
    if vim.uv.guess_handle(1) ~= "tty" then return end
    args = { name }
  end
  local t = M.target(args[1])
  review(t, cli_ui(t))
end

local function worktree(fn)
  return function(args) return require("rig.worktree")[fn](args) end
end

M.list = {
  { verb = "plan", key = "p", run = plan, desc = "open plan (review plan when reviewing)" },
  { verb = "update", key = "u", run = update, desc = "bring the PR's new commits and comments into the review plan" },
  { verb = "review", key = "r", run = review, cli = review_cli, desc = "review code" },
  { verb = "mark", key = "m", run = mark, desc = "mark code reviewed" },
  { verb = "pr", key = "o", run = pr, desc = "open PR in browser" },
  { verb = "revise", key = "s", run = revise, skill = true, desc = "send your review to the agent (rig revise)" },
  { verb = "ticket", key = "n", prompt = "Ticket (id or URL), then any instructions: ", cli = worktree("ticket"),
    desc = "start a ticket with the agent" },
  { verb = "adopt", key = "a", prompt = "Your PR's URL, then any instructions: ", cli = worktree("adopt"),
    desc = "adopt one of your PRs" },
  -- The same command as r: given a PR URL, rig review finds or makes its worktree.
  { verb = "review", key = "v", prompt = "PR URL to review: ", desc = "review someone else's PR" },
  { verb = "new", key = "w", prompt = "Branch name for a plain worktree: ", cli = worktree("new"),
    desc = "new worktree without an agent" },
  { verb = "park", key = "x", run = park,
    desc = "park: stop the session and hide it from your turn until something changes (again to unpark)" },
  { verb = "rm", key = "d", run = rm, cli = worktree("rm"), desc = "remove worktree" },
}

-- The worktree in `name`'s folder, or without a name the git worktree this shell
-- is in, else this window's session. It has the fields the board's items have
-- that actions use: name (nil for a worktree that is no session), dir, skills,
-- plan { file, status }, review (.rig/review.json), pr (its URL), running,
-- agent (Claude's state), branch, head, and parked.
function M.target(name)
  local function fail(msg) cli.fail("rig: " .. msg) end
  local sessions = require("rig.config").sessions()
  local dir
  if name then
    local def = sessions[name] or fail("no session named " .. name)
    dir = vim.fn.expand(def.path)
  else
    local r = vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true }):wait()
    if r.code == 0 then
      dir = vim.trim(r.stdout)
      -- The shell's path and the config's can name the same folder differently.
      local real = vim.uv.fs_realpath(dir)
      for n, def in pairs(sessions) do
        if vim.uv.fs_realpath(vim.fn.expand(def.path)) == real then name = n end
      end
    else
      local current = cli.current()
      name = current and (vim.fs.basename(current):gsub("%.sock$", ""))
      if not (name and sessions[name]) then fail("not in a git worktree") end
      dir = vim.fn.expand(sessions[name].path)
    end
  end
  local def = name and sessions[name] or {}
  local rv = decode(files.read(dir, "review.json"))
  local plan_file = files.path(dir, "plan.md")
  local status = files.plan_status(dir)
  local plan_pr = files.field(files.read(dir, "plan.md"), "PR")
  local running = name and cli.alive(cli.sock(name)) or false
  local agent = running and require("rig.dash.claude").state(dir) or nil
  return {
    id = name,
    name = name,
    dir = dir,
    skills = def.skills or {},
    plan = { file = vim.uv.fs_stat(plan_file) and plan_file or nil, status = status },
    review = rv,
    pr = rv and rv.url or (plan_pr and plan_pr:match("^https://%S+")),
    running = running,
    agent = agent and agent.state,
    branch = vim.trim(git(dir, { "symbolic-ref", "--short", "-q", "HEAD" }).stdout or ""),
    head = vim.trim(git(dir, { "rev-parse", "HEAD" }).stdout or ""),
    parked = vim.uv.fs_stat(files.path(dir, "parked")) ~= nil,
  }
end

-- What actions do through, for the rig command: errors stop it, files and the
-- code review open in an nvim in this terminal, and skills run directly.
function cli_ui(t)
  local function say(msg) cli.say("rig: " .. msg) end
  local function fail(msg) cli.fail("rig: " .. msg) end
  -- An nvim needs the terminal, which :Rig and other callers don't give.
  local function exec(cmd)
    if vim.uv.guess_handle(1) ~= "tty" then fail("this opens nvim, so run it in a terminal (or use rig dash)") end
    cli.exec(cmd)
  end
  return {
    fail = fail,
    warn = say,
    ok = say,
    busy = function(label)
      say(label .. "...")
      return function() end
    end,
    confirm = function() return true end,
    -- Inside a session they open in its plan or review tab, else in nvim here.
    open_file = function(file)
      local inside, err = require("rig.open").file_tab(t.name, file)
      if err then fail(err) end
      if not inside then exec({ vim.v.progpath, file }) end
    end,
    open_review = function(opts)
      if not (require("rig.config").get().review or {}).open then fail("set review.open in the rig config to review code") end
      local inside, err = require("rig.open").review_tab(opts)
      if err then fail(err) end
      if not inside then exec({ vim.v.progpath, "-c", require("rig.open").review_command(opts) }) end
    end,
    skill = function(name)
      if not t.name then fail(t.dir .. " is not a worktree session") end
      require("rig.worktree").skill(name, { t.name })
    end,
  }
end

-- Runs `action` for the rig command with its arguments.
function M.cli(action, args)
  if action.cli then return action.cli(args) end
  local t = M.target(args[1])
  action.run(t, cli_ui(t))
end

-- The action for rig command `verb`, or nil. Verbs that are skill names run as skills.
function M.command(verb)
  for _, a in ipairs(M.list) do
    if a.verb == verb and (a.run or a.cli) and not a.skill then return a end
  end
end

-- The verbs and board keys rig uses itself, which the config can't reuse.
function M.verbs()
  local list = {}
  for _, a in ipairs(M.list) do
    if not a.skill and not vim.tbl_contains(list, a.verb) then table.insert(list, a.verb) end
  end
  return list
end

function M.keys()
  return vim.tbl_map(function(a) return a.key end, M.list)
end

return M
