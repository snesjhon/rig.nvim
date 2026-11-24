-- Worktree commands: git worktrees, each shown as its own mux session, with the
-- repo's agent skills run in them. A repo's `worktrees` in the rig config says
-- where they go, and its `skills` what runs in them (see lua/rig/config.lua).
-- Notes and plans live in each worktree's .rig folder (see lua/rig/files.lua).
--
-- Needs git, the agent CLI (claude), and gh for anything with a PR.
local cli = require("mux.cli")
local files = require("rig.files")
local M = {}

local function fail(msg) cli.fail("rig: " .. msg) end

local function say(msg) cli.say("rig: " .. msg) end

-- Runs `cmd` and returns its trimmed stdout, or nil and its error output.
local function run(cmd)
  local r = vim.system(cmd, { text = true }):wait()
  if r.code ~= 0 then return nil, vim.trim(r.stderr ~= "" and r.stderr or r.stdout) end
  return vim.trim(r.stdout)
end

-- Like run, but stops rig with the command's error when it fails.
local function must(cmd)
  local out, err = run(cmd)
  if not out then fail(err ~= "" and err or table.concat(cmd, " ") .. " failed") end
  return out
end

-- Session names and arguments get typed into a shell, so they must be plain.
local function plain(s) return s:match("^[%w._-]+$") ~= nil end

local function git_root(dir)
  return vim.fs.dirname(must({ "git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir" }))
end

-- The repo this shell is in, or the only repo with a worktree folder in the
-- rig config when the shell is in none. Returns its folder, its worktree folder,
-- and its session.
local function repo()
  local repos = {} -- repo folder -> { worktree folder, session }
  for _, def in pairs(require("rig.config").sessions()) do
    if def.worktrees then repos[vim.fn.expand(def.path)] = { vim.fn.expand(def.worktrees), def } end
  end
  local common = run({ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" })
  local here = common and vim.fs.dirname(common)
  if here and repos[here] then return here, unpack(repos[here]) end
  local roots = vim.tbl_keys(repos)
  if #roots ~= 1 then
    fail("run inside a repo with worktrees set in the rig config: " .. table.concat(roots, ", "))
  end
  return roots[1], unpack(repos[roots[1]])
end

-- Worktree session `name` (default: the one this shell is in, see
-- actions.target). Returns the name, its folder, its parent session, and its definition.
local function session(name)
  name = name or require("rig.actions").target().name
  local def = name and require("rig.config").sessions()[name]
  if not def or not def.parent then fail((name or "this window") .. " is not a worktree session") end
  return name, vim.fn.expand(def.path), def.parent, def
end

-- Skill `name` of session `def`, or a stop naming what's missing.
local function skill_of(def, name, where)
  local s = def.skills[name]
  if not s then fail(("%s has no %s skill in the rig config"):format(where, name)) end
  return s
end

-- Copies the paths in session `def`'s `copy` list, relative to the repo, from
-- the repo at `root` into new worktree `dir`. They are files git ignores, such as
-- local build output, that a worktree needs to run but git won't check out.
-- -c clones on APFS, so large files take no extra space; plain cp is the fallback.
local function copy_ignored(def, root, dir)
  for _, rel in ipairs(def.copy or {}) do
    local from, to = vim.fs.joinpath(root, rel), vim.fs.joinpath(dir, rel)
    local stat = vim.uv.fs_stat(from)
    if stat then
      local src = from
      if stat.type == "directory" then
        vim.fn.mkdir(to, "p")
        src = from .. "/."
      else
        vim.fn.mkdir(vim.fs.dirname(to), "p")
      end
      if not run({ "cp", "-Rc", src, to }) then must({ "cp", "-R", src, to }) end
      -- Files git tracks come from the worktree's own branch, so the repo's copies
      -- are put back or removed. They would otherwise show as changes and block `rig rm`.
      local repo_tracked = run({ "git", "-C", root, "ls-files", "-z", "--", rel }) or ""
      local own = {}
      for f in (run({ "git", "-C", dir, "ls-files", "-z", "--", rel }) or ""):gmatch("[^%z]+") do own[f] = true end
      for f in repo_tracked:gmatch("[^%z]+") do
        if not own[f] then os.remove(vim.fs.joinpath(dir, f)) end
      end
      if next(own) then must({ "git", "-C", dir, "checkout", "--", rel }) end
    else
      say("copy: " .. rel .. " is not in " .. root .. ", skipped")
    end
  end
end

-- Creates a worktree for `branch` in the worktree folder of the repo from
-- repo(). An existing branch (local or on origin) is checked out; a new one
-- starts from `base` on `remote`, by default upstream (or origin when there is
-- no upstream) and that remote's default branch. The folder and session are
-- `name`, default the branch's last part. Returns the session's name and its
-- folder.
local function worktree(branch, base, name, remote)
  local root, dir, def = repo()
  name = name or vim.fs.basename(branch)
  local path = vim.fs.joinpath(dir, name)
  if vim.uv.fs_stat(path) then fail(path .. " already exists") end
  local function has(ref) return run({ "git", "-C", root, "show-ref", "-q", "--verify", ref }) ~= nil end
  if has("refs/heads/" .. branch) or has("refs/remotes/origin/" .. branch) then
    must({ "git", "-C", root, "worktree", "add", path, branch })
  else
    -- In a fork setup origin is the fork, whose base branch can be behind.
    remote = remote or (run({ "git", "-C", root, "remote", "get-url", "upstream" }) and "upstream" or "origin")
    if not base then
      base = must({ "git", "-C", root, "symbolic-ref", "--short", "refs/remotes/" .. remote .. "/HEAD" })
      base = base:sub(#remote + 2)
    end
    must({ "git", "-C", root, "fetch", "-q", remote, base })
    -- --no-track: the branch is pushed under its own name, not to base.
    must({ "git", "-C", root, "worktree", "add", "--no-track", "-b", branch, path, remote .. "/" .. base })
  end
  copy_ignored(def, root, path)
  return name, path
end

-- Lowercase words joined by hyphens, at most 30 characters, for branch names.
local function slug(s)
  s = s:lower():gsub("[^%w]+", "-"):sub(1, 30)
  return (s:gsub("^%-+", ""):gsub("%-+$", ""))
end

-- The first ticket id (ABC-123) in `s`, uppercased, or nil.
local function ticket_id(s)
  return (s or ""):upper():match("%f[%w]([A-Z][A-Z0-9]*%-%d+)%f[^%w]")
end

-- A name made from `-n name`, else a short slug Haiku makes from `notes`,
-- prefixed with ticket `id` when there is one. Nil when there is nothing to
-- name it from.
local function label(id, name, notes)
  if not name and notes ~= "" then
    say("naming the branch...")
    name = run({ "claude", "-p", "--model", "haiku",
      "Reply with only a 1 to 3 word name for a git branch doing this work, nothing else: " .. notes })
  end
  name = name and slug(name)
  -- Haiku or -n may repeat the id, which is added back in its uppercase form.
  if name and id then name = name:gsub("^" .. vim.pesc(id:lower()) .. "%-?", "") end
  if not name or name == "" then return id end
  return id and id .. "-" .. name or name
end

-- Reads PR `url` with gh, asking for `fields`. Returns the PR's URL without
-- any trailing path and the fields. Stops rig with `use` if `url` isn't a PR URL.
-- PR `url` without any trailing path. Stops rig with `use` if it isn't a PR URL.
local function pr_url_of(url, use)
  url = url or ""
  local pr_url = url:match("^(https://[^/]+/[^/]+/[^/]+/pull/%d+)/") or url:match("^(https://[^/]+/[^/]+/[^/]+/pull/%d+)$")
  -- The URL is typed into a shell, so it must be plain.
  if not pr_url or not url:match("^https://[%w./_-]+$") then fail(use) end
  return pr_url
end

local function pr_view(url, fields, use)
  local pr_url = pr_url_of(url, use)
  return pr_url, vim.json.decode(must({ "gh", "pr", "view", pr_url, "--json", fields }))
end

-- Fetches the head branch of `pr` (read with headRefName,headRepositoryOwner)
-- from origin, and stops rig if the branch is on another repo.
local function fetch_head(root, pr_url, pr)
  local owner = pr.headRepositoryOwner.login
  local origin = must({ "git", "-C", root, "remote", "get-url", "origin" })
  if not origin:find("[/:]" .. vim.pesc(owner) .. "/") then
    fail(pr_url .. "'s branch is on " .. owner .. "'s repo, not origin (" .. origin .. ")")
  end
  must({ "git", "-C", root, "fetch", "-q", "origin", pr.headRefName })
end

-- Starts session `name` for worktree `dir` without switching to it, saves
-- `notes` to .rig/notes.md, and runs skill command `cmd` with the agent in its
-- first tab.
local function start(name, dir, cmd, notes)
  if not plain(name) then fail("session name " .. name .. " has characters rig can't pass on") end
  files.exclude(dir)
  if notes ~= "" then files.write(dir, "notes.md", notes .. "\n") end
  local ok, err = cli.ensure(name)
  if not ok then fail(err) end
  local agent = require("rig.config").get().agent
  local res
  res, err = cli.call(cli.sock(name), "return require('mux.session').send(...)",
    ("%s -n %s \"%s\""):format(agent, name, cmd))
  err = err or (res ~= "" and res) or nil
  if err then fail(name .. ": " .. err) end
  say("started " .. cmd .. " in session " .. name)
end

-- `rig new <branch> [base]`: creates a worktree and switches to its session.
function M.new(args)
  if not args[1] then fail("usage: rig new <branch> [base]") end
  cli.open((worktree(args[1], args[2])))
end

-- `rig ticket`: creates a worktree for a ticket, starts its session without
-- switching to it, and runs the repo's ticket skill with the id in the session's
-- first tab. The window stays put, so several tickets, or several ideas for one
-- ticket, can start in a row.
-- The ticket is an id (ABC-123) or a URL containing one. Any words after it are
-- instructions for the agent, saved to .rig/notes.md in the worktree, where the
-- skill reads them. The branch and session are <id>-<name>, with the name from
-- -n, else a short slug Haiku makes from the instructions, else just <id>. -b
-- sets the whole branch name instead.
-- --on <PR URL> stacks the work on that PR: the branch starts from the PR's
-- branch while it is open, or from its base once merged, and .rig/base names
-- that base for the skill to open its PR against.
function M.ticket(args)
  local use = "usage: rig ticket <id or URL> [-n name | -b branch] [--on <PR URL>] [instructions...]"
  local id = ticket_id(args[1])
  if not id then fail(use) end
  local root, _, def = repo()
  local cmd = skill_of(def, "ticket", "this repo").cmd
  local i, branch, name, on = 2, nil, nil, nil
  while args[i] == "-b" or args[i] == "-n" or args[i] == "--on" do
    if not args[i + 1] then fail(use) end
    if args[i] == "-b" then
      branch = args[i + 1]
    elseif args[i] == "-n" then
      name = args[i + 1]
    else
      on = args[i + 1]
    end
    i = i + 2
  end
  local notes = table.concat(args, " ", i)
  local from, remote, parent
  if on then
    local pr_url, pr = pr_view(on, "headRefName,headRepositoryOwner,baseRefName,state", use)
    if pr.state == "OPEN" then
      fetch_head(root, pr_url, pr)
      from, remote = pr.headRefName, "origin"
      parent = ("This builds on %s, which is still open. The branch starts from its branch %s, "
        .. "so plan only this ticket's work on top of it."):format(pr_url, pr.headRefName)
    elseif pr.state == "MERGED" then
      from = pr.baseRefName
      parent = ("This builds on %s, already merged into %s, where the branch starts. "
        .. "Plan only this ticket's work on top of it."):format(pr_url, pr.baseRefName)
    else
      fail(pr_url .. " is closed without merging")
    end
    on = { url = pr_url, base = pr.baseRefName }
  end
  branch = branch or label(id, name, notes)
  local dir
  name, dir = worktree(branch, from, nil, remote)
  if on then
    files.write(dir, "base", on.base .. "\n")
    notes = notes ~= "" and notes .. "\n\n" .. parent or parent
  end
  start(name, dir, cmd .. " " .. id, notes)
end

-- `rig adopt`: creates a worktree for the branch of one of your open PRs,
-- starts its session without switching to it, and runs the repo's adopt skill
-- with the PR URL there. Words after the URL are instructions, saved like rig
-- ticket's. The session and folder are named like rig ticket's branch, with the
-- ticket id from the instructions or the branch; with neither -n nor
-- instructions, after the branch. The branch itself keeps its name, since the PR
-- is tied to it. It must be on origin, where the agent pushes.
function M.adopt(args)
  local use = "usage: rig adopt <PR URL> [-n name] [instructions...]"
  local i, name = 2, nil
  if args[i] == "-n" then
    if not args[i + 1] then fail(use) end
    name, i = args[i + 1], i + 2
  end
  local notes = table.concat(args, " ", i)
  local root, _, def = repo()
  local cmd = skill_of(def, "adopt", "this repo").cmd
  local pr_url, pr = pr_view(args[1], "headRefName,headRepositoryOwner,state,author,title", use)
  local host = pr_url:match("^https://([^/]+)/")
  if pr.state ~= "OPEN" then fail(pr_url .. " is " .. pr.state:lower()) end
  local login = must({ "gh", "api", "--hostname", host, "user", "-q", ".login" })
  if pr.author.login ~= login then fail(pr_url .. " is " .. pr.author.login .. "'s PR, not yours") end
  fetch_head(root, pr_url, pr)
  local dir
  name = label(ticket_id(notes) or ticket_id(pr.headRefName), name, notes)
  name, dir = worktree(pr.headRefName, nil, name)
  -- The board shows the title from here, without waiting on GitHub.
  files.write(dir, "title", pr.title .. "\n")
  start(name, dir, cmd .. " " .. pr_url, notes)
end

-- The remote of the repo in `root` that PR `pr_url` belongs to, found by its URL.
local function pr_remote(root, pr_url)
  local path = pr_url:match("^https://[^/]+/([^/]+/[^/]+)/pull/")
  for remote in must({ "git", "-C", root, "remote" }):gmatch("%S+") do
    local url = (run({ "git", "-C", root, "remote", "get-url", remote }) or ""):gsub("%.git$", "")
    if url:match("[/:]" .. vim.pesc(path) .. "$") then return remote end
  end
  fail("no remote of " .. root .. " points at " .. path)
end

-- The worktree session already reviewing the PR at `url` (rig review), or nil.
function M.reviewing(url)
  local pr_url = (url or ""):match("^(https://[^/]+/[^/]+/[^/]+/pull/%d+)")
  if not pr_url then return nil end
  for name, def in pairs(require("rig.config").sessions()) do
    if def.parent then
      local ok, rv = pcall(vim.json.decode, files.read(vim.fn.expand(def.path), "review.json") or "")
      if ok and type(rv) == "table" and rv.url == pr_url then return name end
    end
  end
end

-- `rig review <PR URL>`: finds the worktree reviewing someone else's open PR,
-- or creates one on a branch review/<their branch> at the PR's newest commit
-- and starts its session without switching to it or starting the agent.
-- Returns the session's name, so the caller can open the review.
-- .rig/review.json records the PR, so the board can list it and fetch new pushes
-- before each round. The session and folder are review-<number>, or -n's name.
function M.review(args)
  local use = "usage: rig review [name | <PR URL> [-n name]]"
  local name
  if args[2] == "-n" then
    name = args[3] and slug(args[3]) or fail(use)
  end
  local found = M.reviewing(pr_url_of(args[1], use))
  if found then
    say("reviewing in " .. found)
    return found
  end
  local root, trees, def = repo()
  local pr_url, pr = pr_view(args[1], "number,title,state,headRefName", use)
  if pr.state ~= "OPEN" then fail(pr_url .. " is " .. pr.state:lower()) end
  name = name or ("review-" .. pr.number)
  if not plain(name) then fail("session name " .. name .. " has characters rig can't pass on") end
  local dir = vim.fs.joinpath(trees, name)
  if vim.uv.fs_stat(dir) then fail(dir .. " already exists") end
  local remote = pr_remote(root, pr_url)
  -- GitHub keeps every PR's commits at refs/pull/<n>/head, forks included.
  must({ "git", "-C", root, "fetch", "-q", remote, ("refs/pull/%d/head"):format(pr.number) })
  local sha = must({ "git", "-C", root, "rev-parse", "FETCH_HEAD" })
  -- The prefix keeps it apart from any branch of yours with the same name. -B
  -- resets one left by an earlier review of the same PR.
  local branch = "review/" .. pr.headRefName
  must({ "git", "-C", root, "worktree", "add", "-q", "-B", branch, dir, sha })
  copy_ignored(def, root, dir)
  local info = { url = pr_url, number = pr.number, title = pr.title, remote = remote, branch = branch }
  files.write(dir, "review.json", vim.json.encode(info) .. "\n")
  local ok, err = cli.ensure(name)
  if not ok then fail(err) end
  say(("created %s for #%d %s"):format(name, pr.number, pr.title))
  return name
end

-- Runs skill command `cmd` with the agent in the first tab of session `name`,
-- where rig ticket starts it. An agent still open there is cleared first, so
-- the run works from the files and the PR, not the old conversation. The window
-- stays put.
local function run_skill(name, cmd)
  local ok, err = cli.ensure(name)
  if not ok then fail(err) end
  local sock = cli.sock(name)
  local comms = vim.split(cli.call(sock, "return require('mux.session').first_fg()") or "", "\n", { trimempty = true })
  local fg = vim.tbl_contains(comms, "claude") and "claude" or (comms[1] or "")
  local texts
  if fg == "claude" then
    texts = { "/clear", cmd }
  elseif fg == "zsh" or fg == "bash" or fg == "sh" or fg == "fish" then
    texts = { ("%s -n %s \"%s\""):format(require("rig.config").get().agent, name, cmd) }
  else
    fail(name .. ": the first tab runs " .. (fg ~= "" and fg or "nothing") .. ", not claude or a shell")
  end
  for _, text in ipairs(texts) do
    -- /clear has to finish before claude takes the next prompt.
    if text == cmd then vim.wait(1000) end
    local res
    res, err = cli.call(sock, "return require('mux.session').send(...)", text)
    err = err or (res ~= "" and res) or nil
    if err then fail(name .. ": " .. err) end
  end
  say("started " .. cmd .. " in session " .. name)
end

-- Makes sure the rig review worktree in `dir` has its .rig/review.json, and
-- rebuilds the file when it is gone, from the PR number in the folder name
-- (review-<number>), else the open PR whose branch its review/ branch copies.
-- Returns false when `dir` is not a review worktree.
local function ensure_review_json(dir)
  if vim.uv.fs_stat(files.path(dir, "review.json")) then return true end
  local branch = run({ "git", "-C", dir, "symbolic-ref", "--short", "-q", "HEAD" }) or ""
  local head = branch:match("^review/(.+)")
  if not head then return false end
  -- gh finds the repo from the remotes of the folder it runs in.
  local function gh(args)
    local r = vim.system(vim.list_extend({ "gh" }, args), { text = true, cwd = dir }):wait()
    if r.code ~= 0 then fail(vim.trim(r.stderr)) end
    return vim.json.decode(r.stdout)
  end
  local number = vim.fs.basename(dir):match("^review%-(%d+)$")
  local pr = number and gh({ "pr", "view", number, "--json", "number,title,url" })
    or gh({ "pr", "list", "--head", head, "--json", "number,title,url" })[1]
  if not pr then fail("no open PR has the branch " .. head) end
  local info = { url = pr.url, number = pr.number, title = pr.title, remote = pr_remote(git_root(dir), pr.url), branch = branch }
  files.write(dir, "review.json", vim.json.encode(info) .. "\n")
  say("rebuilt " .. files.path(dir, "review.json") .. " for #" .. pr.number)
  return true
end

-- `rig <skill> [session] [url]`: runs skill `name` from the rig config in
-- worktree session `session` (default: the one this shell is in), through run_skill.
-- review-plan runs only in rig review worktrees. A skill with `needs` runs only
-- at that plan status, since typing into an agent that is still working would
-- interrupt it; revise always needs pr-open. In a rig review worktree, which has
-- no plan, it runs unless the review plan is drafting or answering questions. One with `url` takes a PR URL, and
-- with one it can also start in a worktree with no plan yet, which is idle.
function M.skill(name, args)
  local target, url = args[1], args[2]
  if target and target:match("^https://") then
    url, target = target, nil
  end
  local sname, dir, _, def = session(target)
  local s = skill_of(def, name, sname)
  if not plain(sname) then fail("session name " .. sname .. " has characters rig " .. name .. " can't pass on") end
  if url and not s.url then fail(name .. " takes no PR URL") end
  if url and not url:match("^https://[%w./_-]+$") then fail(url .. " has characters rig " .. name .. " can't pass on") end
  if name == "review-plan" then
    if not ensure_review_json(dir) then fail(sname .. " is not a rig review worktree") end
  elseif s.needs and name ~= "revise" and vim.uv.fs_stat(files.path(dir, "review.json")) then
    -- A review worktree has no plan, so its review plan's Status tells whether the agent is busy.
    local status = files.field(files.read(dir, "review.md"), "Status")
    if status == "drafting" or status == "ask" then
      fail(("%s is still working on its review plan (Status: %s)"):format(sname, status))
    end
  else
    local needs = name == "revise" and "pr-open" or s.needs
    local status = files.plan_status(dir)
    if needs and status ~= needs and not (s.url and url and not status) then
      fail(("%s isn't at %s yet (%s)"):format(sname, needs, status and "Status: " .. status or "no plan"))
    end
  end
  run_skill(sname, s.cmd .. (url and " " .. url or ""))
end

-- `rig rm [name]`: stops worktree session `name` (default: the one this shell is in) and
-- everything running in it, then removes the worktree. The branch is kept. Run
-- inside that session, the window moves to the repo's session first.
function M.rm(args)
  local name, dir, parent = session(args[1])
  -- Real paths, read while the folder still exists, since the shell's $PWD and
  -- git's worktree path can name the same folder differently.
  local cwd = vim.uv.fs_realpath(vim.env.PWD or ".") or ""
  dir = vim.uv.fs_realpath(dir) or dir
  -- git refuses to remove a worktree with changes, so check before stopping anything.
  if must({ "git", "-C", dir, "status", "--porcelain" }) ~= "" then fail(name .. " has uncommitted changes") end
  local root = git_root(dir)
  local branch = run({ "git", "-C", dir, "symbolic-ref", "--short", "-q", "HEAD" }) or ""
  local sock = cli.sock(name)
  cli.kill_procs({ sock })
  vim.uv.chdir(root)
  must({ "git", "-C", root, "worktree", "remove", dir })
  -- A review/ branch is only a copy of someone else's PR (rig review), so it goes too.
  if branch:match("^review/") then
    must({ "git", "-C", root, "branch", "-D", branch })
    say("removed " .. name .. " and its branch " .. branch)
  else
    say("removed " .. name .. "; its branch is kept")
  end
  if cli.current() == sock then
    -- Quitting the server a window is attached to closes the window, so move it
    -- to the repo's session and wait until no window is left on this one.
    local ok, err = cli.switch(sock, parent)
    if not ok then fail(err) end
    vim.wait(10000, function() return (cli.call(sock, "return #vim.api.nvim_list_uis()") or 0) == 0 end, 50)
  end
  -- A command can't change its shell's folder, so say where to go.
  if cwd == dir or vim.startswith(cwd, dir .. "/") then say("this shell's folder is gone; cd " .. root) end
  -- Run inside that session, this ends the calling shell.
  cli.quit_one(sock)
end

-- `rig dash`: inside a session, shows the board in mux's float over the tab.
-- Elsewhere, and in that float (--float), hands this terminal to an nvim
-- showing it (lua/rig/board.lua), with rig and mux on its runtimepath.
function M.dash(args)
  local float = args[1] == "--float"
  local current = cli.current()
  local paths = require("rig.paths")
  if current and not float then
    local _, err = cli.call(current, "return require('mux.session').show_overlay(...)", { paths.bin(), "dash", "--float" })
    if err then fail(err) end
    return
  end
  local open = ("+lua require('rig.board').open({ float = %s })"):format(tostring(float))
  local rtp = ("lua vim.opt.rtp:prepend(%q); vim.opt.rtp:prepend(%q)"):format(paths.root(), paths.mux())
  cli.exec({ vim.v.progpath, "--cmd", rtp, "--cmd", "let g:rig_dash = 1", open })
end

-- The worktree sessions, for tab completion.
function M.names()
  local names = {}
  for name, def in pairs(require("rig.config").sessions()) do
    if def.parent then table.insert(names, name) end
  end
  return names
end

return M
