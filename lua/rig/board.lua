-- `rig dash`: the worktree sessions on the rig.dash board. Each one shows
-- whose turn it is (yours to approve a plan, review code, or answer Claude;
-- the agent's while it plans or builds), its plan stage, and its PR, and keys
-- run rig commands and skills or open a code review on the selected one.
local cli = require("mux.cli")
local files = require("rig.files")
local claude = require("rig.dash.claude")
local actions = require("rig.actions")
local ago = require("rig.dash").ago
local M = {}

local columns = {
  { id = "none", title = "No plan" },
  { id = "plan", title = "Plan" },
  { id = "build", title = "Building" },
  { id = "check", title = "Self-review" },
  { id = "pr", title = "PR open" },
  { id = "reviewing", title = "Reviewing" },
}

local function column(status)
  if status == "planning" or status == "revise" then return "plan" end
  if status == "approved" or (status or ""):match("^building") then return "build" end
  if status == "review" then return "check" end
  if status == "pr-open" then return "pr" end
  return "none"
end

local function ticket_file(dir, name) return files.path(dir, name) end

local function warn(msg) vim.notify(msg, vim.log.levels.WARN) end

local function read(file)
  local f = io.open(file)
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

-- The Status and PR lines and first heading of the worktree's plan, and when it
-- last changed.
local function read_plan(dir)
  local file = ticket_file(dir, "plan.md")
  local text = read(file)
  if not text then return {} end
  text = "\n" .. text
  local stat = vim.uv.fs_stat(file)
  return {
    file = file,
    status = text:match("\nStatus: ([^\n]*)"),
    pr = text:match("\nPR: (https://%S+)"),
    heading = text:match("\n# ([^\n]+)"),
    time = stat and stat.mtime.sec,
  }
end

-- Seconds since the epoch for a GitHub timestamp (2026-11-10T12:34:56Z).
local function from_iso(s)
  local y, mo, d, h, mi, sec = (s or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
  if not y then return nil end
  local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec })
  -- os.time reads the table as local time.
  return t + (os.time() - os.time(os.date("!*t")))
end

-- PR details from GitHub, fetched in the background at most every 5 minutes
-- per PR: its number, title, author, state, newest commit, draft state, review
-- decision, and the newest review or comment by someone other than you.
local prs, logins = {}, {}

local function pr_info(url, dash)
  local cached = prs[url]
  if cached and (cached.pending or os.time() - cached.at < 300) then return cached end
  prs[url] = vim.tbl_extend("force", cached or {}, { pending = true, at = os.time() })
  local host = url:match("^https://([^/]+)/")
  local function fetch(me)
    vim.system({ "gh", "pr", "view", url, "--json", "number,title,author,state,headRefOid,headRefName,isDraft,reviewDecision,reviews,comments" }, { text = true }, function(r)
      vim.schedule(function()
        local info = { at = os.time() }
        local ok, pr = pcall(vim.json.decode, r.code == 0 and r.stdout or "")
        if ok and type(pr) == "table" then
          info.number, info.draft, info.decision = pr.number, pr.isDraft, pr.reviewDecision
          info.title, info.state, info.head, info.branch = pr.title, pr.state, pr.headRefOid, pr.headRefName
          info.author = type(pr.author) == "table" and pr.author.login or nil
          local function consider(time, author)
            local login = type(author) == "table" and author.login or nil
            -- Without your login, nothing can count as someone else's.
            if not me or not login or login == me or login:match("%[bot%]$") then return end
            local t = from_iso(time)
            if t and t > (info.teammate or 0) then info.teammate = t end
          end
          for _, x in ipairs(pr.reviews or {}) do
            consider(x.submittedAt, x.author)
          end
          for _, x in ipairs(pr.comments or {}) do
            consider(x.createdAt, x.author)
          end
        end
        prs[url] = info
        dash.refresh()
      end)
    end)
  end
  if logins[host] then
    fetch(logins[host])
  else
    vim.system({ "gh", "api", "--hostname", host, "user", "-q", ".login" }, { text = true }, function(r)
      logins[host] = r.code == 0 and vim.trim(r.stdout) or nil
      fetch(logins[host])
    end)
  end
  return prs[url]
end

-- Whose turn it is, a few words on why, and since when.
local function turn(t)
  local s, a = t.plan.status, t.agent
  if a and a.state == "waiting" then return "you", a.message or "asking", a.time end
  if a and a.state == "working" then return "agent", s or "working", a.time end
  if s == "planning" then return "you", "plan ready", t.plan.time end
  if s == "revise" then return "agent", "revising plan", t.plan.time end
  if s == "approved" or s == "review" or (s or ""):match("^building") then
    -- Claude stops on its own only between stages, so a stop here needs a look.
    return "you", (t.running and "stopped: " or "session down: ") .. s, a and a.time or t.plan.time
  end
  if s == "pr-open" then
    if t.head and t.head ~= t.reviewed then return "you", "review code", t.commit_time end
    if t.pr and t.pr.teammate and t.pr.teammate > (t.commit_time or 0) then
      return "you", "new comments", t.pr.teammate
    end
    if t.pr and t.pr.decision == "APPROVED" then return nil, "approved", nil end
    return nil, "in review", nil
  end
  return nil, t.running and "no plan" or "stopped", nil
end

local read_review_plan = actions.review_plan
local same_commit = actions.same_commit

-- The same for a worktree reviewing someone else's PR (rig review). A review
-- goes: to review (p), writing plan, read plan (p, then r to walk the code),
-- building tests (t), test, then you submit and it waits on the author until
-- new commits or comments, which u brings into the plan as its next round. The reason names the step, so it says what to do.
local function review_turn(t)
  local info, a, plan = t.pr or {}, t.agent, t.review_plan
  if info.state and info.state ~= "OPEN" then return nil, info.state:lower(), nil end
  if a and a.state == "waiting" then return "you", a.message or "asking", a.time end
  local busy = plan and (plan.status == "drafting" or plan.status == "ask")
  local building = plan and plan.tests == "building"
  local doing = busy and (plan.status == "ask" and "answering" or "writing plan")
    or building and "building tests" or "writing plan"
  if a and a.state == "working" then return "agent", doing, a.time end
  if busy or building then
    -- Without the Claude hook there is no agent state, so drafting counts as
    -- working until the session goes down or the hook says Claude stopped.
    if not t.running or (a and a.state == "idle") then
      if busy then return "you", "plan stopped: " .. plan.status, plan.time end
      return "you", "tests stopped", plan.tests_time
    end
    return "agent", doing, busy and plan.time or plan.tests_time
  end
  -- Comments newer than the plan's last round, or than your mark for a plan
  -- that doesn't record them.
  local seen = plan and plan.comments and from_iso(plan.comments) or t.reviewed_time or 0
  if plan and plan.status == "ready" and info.teammate and info.teammate > seen then
    return "you", "new replies", info.teammate
  end
  local head = info.head or t.head
  if t.reviewed == "" or not same_commit(head, t.reviewed) then
    if plan and plan.status == "ready" and same_commit(head, plan.at) then
      if same_commit(head, plan.tests_at) then return "you", "test", plan.tests_time end
      return "you", "read plan", plan.time
    end
    if t.reviewed == "" then return "you", "to review", t.created end
    return "you", "new commits", nil
  end
  return nil, "waiting on author", nil
end

local signature = actions.signature

-- Whether the worktree is parked (x) and nothing has changed since, which
-- ends the parking. A field missing on either side, like PR details still
-- loading, counts as unchanged. One the parked file lacks, as rig park leaves
-- the PR's, is saved the first time the board knows it, so later changes count.
local function still_parked(dir, sig)
  local file = ticket_file(dir, "parked")
  local ok, parked = pcall(vim.json.decode, read(file) or "")
  if not (ok and type(parked) == "table") then return false end
  local filled = false
  for k, v in pairs(sig) do
    if parked[k] == nil then
      parked[k], filled = v, true
    elseif v ~= parked[k] then
      os.remove(file)
      return false
    end
  end
  if filled then pcall(files.write, dir, "parked", vim.json.encode(parked) .. "\n") end
  return true
end

local function mtime(file)
  local stat = vim.uv.fs_stat(file)
  return stat and stat.mtime.sec
end

local function items(dash)
  local list = {}
  -- Every worktree's git runs at once, so a refresh waits for the slowest
  -- one instead of all of them in turn.
  local ok_cfg, sessions = pcall(require("rig.config").sessions)
  if not ok_cfg then
    warn(sessions)
    return list
  end
  -- The session this board runs in, or else the worktree nvim was opened in,
  -- so it can sit at the top.
  local here = cli.current() or vim.v.servername
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local jobs = {}
  for name, def in pairs(sessions) do
    if def.parent then
      local dir = vim.fn.expand(def.path)
      jobs[name] = {
        log = vim.system({ "git", "-C", dir, "log", "-1", "--format=%H %ct" }, { text = true }),
        branch = vim.system({ "git", "-C", dir, "symbolic-ref", "--short", "-q", "HEAD" }, { text = true }),
      }
    end
  end
  for name, def in pairs(sessions) do
    if jobs[name] then
      local dir = vim.fn.expand(def.path)
      local plan = read_plan(dir)
      local running = cli.alive(cli.sock(name))
      -- A state file outlives a session that was killed, so only a running one counts.
      local agent = running and claude.state(dir) or nil
      local log = jobs[name].log:wait().stdout or ""
      local head, commit_time = log:match("^(%x+) (%d+)")
      local branch = vim.trim(jobs[name].branch:wait().stdout or "")
      local ok, rv = pcall(vim.json.decode, read(ticket_file(dir, "review.json")) or "")
      rv = ok and type(rv) == "table" and rv or nil
      local t = {
        plan = plan,
        agent = agent,
        running = running,
        head = head,
        commit_time = tonumber(commit_time),
        reviewed = vim.trim(read(ticket_file(dir, "reviewed")) or ""),
        reviewed_time = mtime(ticket_file(dir, "reviewed")),
        created = rv and mtime(ticket_file(dir, "review.json")),
        review_plan = rv and read_review_plan(dir),
      }
      local url = rv and rv.url or (plan.status == "pr-open" and plan.pr)
      t.pr = url and pr_info(url, dash) or nil
      -- The PR title is kept in .rig so it shows at once, and saved again only
      -- when GitHub reports a new one. Before there is a PR, the plan's heading
      -- says what the ticket is.
      local saved = vim.trim(read(ticket_file(dir, "title")) or "")
      if saved == "" then saved = rv and rv.title or "" end
      local fresh = t.pr and t.pr.title
      -- review.json is left alone, since its time is when the review started.
      if fresh and fresh ~= saved then
        files.write(dir, "title", fresh .. "\n")
        saved = fresh
      end
      local title = saved ~= "" and saved or plan.heading
      local whose, reason, since
      if rv then
        whose, reason, since = review_turn(t)
      else
        whose, reason, since = turn(t)
      end
      local sig = signature(t)
      local parked = still_parked(dir, sig)
      if parked and whose == "you" then whose, reason = nil, "parked: " .. reason end
      table.insert(list, {
        id = name,
        name = name,
        dir = dir,
        parent = def.parent,
        skills = def.skills,
        running = running,
        agent = agent and agent.state,
        agent_info = agent,
        plan = plan,
        stage = plan.status,
        pr = rv and rv.url or plan.pr,
        pr_info = t.pr,
        title = title,
        review = rv,
        branch = branch,
        head = head,
        review_plan = t.review_plan,
        turn = whose,
        reason = reason,
        since = since,
        column = rv and "reviewing" or column(plan.status),
        signature = sig,
        parked = parked,
        current = vim.fs.normalize(here) == vim.fs.normalize(cli.sock(name))
          or cwd == vim.fs.normalize(dir) or vim.startswith(cwd, vim.fs.normalize(dir) .. "/"),
      })
    end
  end
  return list
end

-- Branch, distance from the default branch, and changes, from one shell so
-- it stays a single async job.
local git_script = [[
git status --porcelain=v2 --branch -uno
base=$(git rev-parse -q --abbrev-ref upstream/HEAD 2>/dev/null || git rev-parse -q --abbrev-ref origin/HEAD 2>/dev/null)
[ -n "$base" ] && echo "# base $base $(git rev-list --left-right --count "$base...HEAD")"
]]

-- The last git state per worktree, shown while git runs again, so a refresh
-- doesn't blank it.
local branches = {}

-- A Details line: a dim label column, then the value chunks. Empty chunks drop out.
local function row(label, ...)
  local line = { { ("  %-9s"):format(label), "RigDashLabel" } }
  for _, chunk in ipairs({ ... }) do
    if chunk and chunk[1] ~= "" then table.insert(line, chunk) end
  end
  return line
end

local function heading(text) return { { text, "RigDashHeading" } } end

local decisions = {
  APPROVED = { "approved", "RigDashOk" },
  CHANGES_REQUESTED = { "changes requested", "RigDashBad" },
  REVIEW_REQUIRED = { "needs review", "RigDashDim" },
}

local agent_hl = { working = "RigDashAge", waiting = "RigDashHeading", idle = "RigDashDim" }

local function details(item, done)
  local function lines(git)
    local out = {
      { { item.name, "RigDashHeading" }, { "  " .. item.parent, "RigDashDim" } },
      { { vim.fn.fnamemodify(item.dir, ":~"), "RigDashDim" } },
      "",
      heading("Status"),
    }
    local whose = ({ you = { "your turn", "RigDashHeading" }, agent = { "agent's turn", "RigDashAge" } })[item.turn]
      or { "nobody's turn", "RigDashDim" }
    table.insert(out, row("turn", whose))
    table.insert(out, row("now", { item.reason or "", "Normal" }, item.since and { "  " .. ago(item.since), "RigDashAge" }))

    table.insert(out, "")
    table.insert(out, heading("Git"))
    if not git then
      table.insert(out, row("branch", { item.branch ~= "" and item.branch or "…", "RigDashOk" }))
    else
      table.insert(out, row("branch", { git.head, "RigDashOk" }))
      if git.base then
        table.insert(out, row("vs base", { "↑" .. git.ahead, git.ahead == "0" and "RigDashDim" or "RigDashOk" },
          { " ↓" .. git.behind, git.behind == "0" and "RigDashDim" or "RigDashBad" }, { "  " .. git.base, "RigDashDim" }))
      end
      table.insert(out, row("changes", { git.changed == 0 and "clean" or git.changed .. " files", git.changed == 0 and "RigDashDim" or "RigDashChanged" }))
    end

    local info = item.pr_info
    table.insert(out, "")
    if item.review then
      table.insert(out, heading("Review"))
      table.insert(out, row("PR", { "#" .. item.review.number, "RigDashNumber" }, { " " .. (item.review.title or ""), "Normal" }))
      if info and info.author then table.insert(out, row("author", { info.author, "Normal" })) end
      -- Each piece is current when it covers the PR's newest commit.
      local rp = item.review_plan or {}
      local head = info and info.head or item.head
      local function piece(name, at, missing)
        if at and same_commit(head, at) then
          return row(name, { "✓", "RigDashOk" }, { "  at " .. at, "RigDashDim" })
        end
        return row(name, { "✗ ", "RigDashBad" }, { at and ("at " .. at .. ", older; " .. missing) or missing, "RigDashDim" })
      end
      if rp.status and rp.status ~= "ready" then
        table.insert(out, row("plan", { rp.status, "Normal" }))
      else
        table.insert(out, piece("plan", rp.at, rp.at and "u updates it" or "p writes it"))
      end
      table.insert(out, piece("walkthrough", rp.walk_at, rp.at and "u updates it" or "p writes it"))
      local seen = rp.comments and from_iso(rp.comments)
      if seen and info and info.teammate and info.teammate > seen then
        table.insert(out, row("comments", { "new", "RigDashChanged" }, { "  u brings them in", "RigDashDim" }))
      end
      if rp.tests == "building" then
        table.insert(out, row("tests", { "building", "Normal" }))
      else
        table.insert(out, piece("tests", rp.tests_at, "t builds them"))
      end
    else
      table.insert(out, heading("Plan"))
      table.insert(out, row("stage", item.stage and { item.stage, "Normal" } or { "none", "RigDashDim" }))
      table.insert(out, "")
      table.insert(out, heading("PR"))
      if not item.pr then
        table.insert(out, row("PR", { "none", "RigDashDim" }))
      elseif info and info.number then
        table.insert(out, row("PR", { "#" .. info.number, "RigDashNumber" }, info.draft and { " draft", "RigDashDim" }))
      end
    end
    if info and info.decision and info.decision ~= "" then
      local d = decisions[info.decision] or { info.decision:lower():gsub("_", " "), "Normal" }
      table.insert(out, row("decision", d))
    end
    if item.pr then table.insert(out, row("url", { item.pr, "RigDashDim" })) end

    table.insert(out, "")
    table.insert(out, heading("Claude"))
    local a = item.agent_info
    if not item.running then
      table.insert(out, row("state", { "session not running", "RigDashDim" }))
    elseif a then
      table.insert(out, row("state", { a.state, agent_hl[a.state] or "Normal" }, { "  " .. ago(a.time) .. " ago", "RigDashDim" }))
      if a.message then table.insert(out, row("says", { a.message, "Normal" })) end
    else
      table.insert(out, row("state", { "no state yet", "RigDashDim" }))
    end
    return out
  end
  done(lines(branches[item.id]))
  vim.system({ "sh", "-c", git_script }, { cwd = item.dir, text = true }, function(r)
    local git = { head = "?", changed = 0 }
    for line in (r.stdout or ""):gmatch("[^\n]+") do
      local h = line:match("^# branch%.head (.+)")
      local b, behind, ahead = line:match("^# base (%S+) (%d+)%s+(%d+)")
      if h then
        git.head = h
      elseif b then
        git.base, git.ahead, git.behind = b, ahead, behind
      elseif not line:match("^#") then
        git.changed = git.changed + 1
      end
    end
    branches[item.id] = git
    done(lines(git))
  end)
end

-- Runs rig with `args` in the background and shows what it says. Until it
-- ends, opts.item's row (or the title, without one) shows a spinner and
-- opts.label. opts.cwd is the folder to run in, and opts.on_done runs once it
-- succeeds.
local function rig(dash, args, opts)
  opts = opts or {}
  local done = dash.busy(opts.item and opts.item.id, opts.label or "rig " .. args[1])
  vim.system(vim.list_extend({ require("rig.paths").bin() }, args), { text = true, cwd = opts.cwd }, function(r)
    vim.schedule(function()
      done()
      local msg = vim.trim((r.stderr or "") .. (r.stdout or ""))
      vim.notify(msg ~= "" and msg or "rig " .. args[1] .. " done", r.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
      dash.refresh()
      if r.code == 0 and opts.on_done then opts.on_done() end
    end)
  end)
end

-- The selected worktree's repo folder, so new worktrees go in the same repo.
local function repo_dir(item)
  local def = item and require("rig.config").sessions()[item.parent]
  return def and vim.fn.expand(def.path) or nil
end

-- Whether the board runs in a session's float (rig dash --float), where plans and
-- reviews open in the session's plan or review tab instead of in this nvim.
local float = false

-- In the float: opens through `open` (file_tab or review_tab in
-- lua/rig/open.lua), which hides the float and moves this window to the
-- worktree's session. Returns false outside the float.
local function open_in(open, ...)
  if not float then return false end
  local inside, err = open(...)
  if err then warn(err) end
  return inside
end

local function open_file(item, file)
  if open_in(require("rig.open").file_tab, item.name, file) then return end
  vim.cmd.tabedit(vim.fn.fnameescape(file))
end

-- What actions (lua/rig/actions.lua) do through on the board, for `item`:
-- problems show as warnings, files and the code review open in the session's
-- plan or review tab from the float, else in this nvim, and rig commands run in the background with a
-- spinner on the item's row.
local function board_ui(item, dash)
  return {
    fail = warn,
    warn = warn,
    ok = function() dash.refresh() end,
    busy = function(label)
      local done = dash.busy(item.id, label)
      -- What follows blocks, so draw the spinner's first frame before it starts.
      vim.cmd.redraw()
      return done
    end,
    confirm = function(msg) return vim.fn.confirm(msg, "&Yes\n&No", 2) == 1 end,
    open_file = function(file) open_file(item, file) end,
    open_review = function(opts)
      if open_in(require("rig.open").review_tab, opts) then return end
      require("rig.open").review(opts, {
        refresh = dash.refresh,
        revise = function() rig(dash, { "revise", item.name }, { item = item, label = "sending your review to the agent" }) end,
      })
    end,
    skill = function(name, label) rig(dash, { name, item.name }, { item = item, label = label }) end,
    rig = function(args, label) rig(dash, args, { item = item, label = label }) end,
  }
end

-- An action that makes a worktree: asks for its argument, then runs it in the
-- background from the selected worktree's repo, so the new one goes there too.
-- rig review with a PR URL then opens the code review, as from a terminal.
local function start(action)
  return function(item, dash)
    vim.ui.input({ prompt = action.prompt }, function(text)
      if not (text and vim.trim(text) ~= "") then return end
      local args = vim.split(vim.trim(text), "%s+")
      local cwd = repo_dir(item)
      rig(dash, { action.verb, unpack(args) }, {
        cwd = cwd,
        label = "rig " .. action.verb .. " " .. text,
        on_done = action.verb == "review" and function()
          local name = require("rig.worktree").reviewing(args[1])
          if name then
            local t = actions.target(name)
            actions.command("review").run(t, board_ui(t, dash))
          end
        end or nil,
      })
    end)
  end
end

local keys = {
  { "<CR>", function(item)
    if not item then return end
    local current = cli.current()
    if not current then return warn("rig dash: not in a mux session") end
    -- The float stays behind in this session, hidden.
    if float then cli.call(current, "return require('mux.session').hide_overlay()") end
    local ok, err = cli.switch(current, item.name)
    if not ok then warn(err) end
  end, desc = "jump to session" },
}
for _, a in ipairs(actions.list) do
  if a.prompt then
    table.insert(keys, { a.key, start(a), desc = a.desc })
  else
    table.insert(keys, { a.key, function(item, dash)
      if item then a.run(item, board_ui(item, dash)) end
    end, desc = a.desc })
  end
end

-- Keys for the skills in the config that name one, each running that skill on
-- the selected worktree when its repo has it. A skill that takes a PR URL asks
-- for one first.
local function skill_keys()
  local found = {}
  for _, def in pairs(require("rig.config").sessions()) do
    for name, s in pairs(def.skills) do
      if s.key and not found[s.key] then found[s.key] = { name = name, desc = s.desc, url = s.url } end
    end
  end
  local list = {}
  for key, k in pairs(found) do
    table.insert(list, { key, function(item, dash)
      if not item then return end
      local name
      for n, s in pairs(item.skills) do
        if s.key == key then name = n end
      end
      if not name then return warn(item.name .. " has no skill on " .. key .. " in the rig config") end
      local function go(url)
        rig(dash, { name, item.name, url }, { item = item, label = "starting rig " .. name })
      end
      if not item.skills[name].url then return go() end
      vim.ui.input({ prompt = "PR URL (blank for the worktree's own): " }, function(url)
        if url then go(url ~= "" and url or nil) end
      end)
    end, desc = k.desc or ("rig " .. k.name) })
  end
  table.sort(list, function(a, b) return a[1] < b[1] end)
  return list
end

-- opts.float: it runs in a session's float (rig dash --float).
function M.open(opts)
  float = opts and opts.float or false
  -- rig dash runs in an nvim of its own, where a tabline from your config
  -- would only show the dashboard's buffer.
  if vim.g.rig_dash == 1 then vim.o.showtabline = 0 end
  local all = vim.list_extend(vim.list_extend({}, keys), skill_keys())
  require("rig.dash").open({ columns = columns, items = items, details = details, keys = all })
end

return M
