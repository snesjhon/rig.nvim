-- `rig setup`: checks what rig needs, links bin/rig onto PATH, and adds rig's
-- Claude hooks to Claude's settings.json after asking. Running it again
-- changes nothing.
local paths = require("rig.paths")
local M = {}

local function say(msg) io.stderr:write(msg, "\n") end

local function ask(question)
  io.stderr:write(question, " [y/N] ")
  local answer = io.read("*l") or ""
  return answer:lower():match("^y") ~= nil
end

local function check_deps()
  local ok = true
  local v = vim.version()
  if vim.version.lt(v, { 0, 12, 0 }) then
    say(("✗ nvim %s; rig needs 0.12 or later"):format(tostring(v)))
    ok = false
  else
    say(("✓ nvim %s"):format(tostring(v)))
  end
  for _, dep in ipairs({
    { "git", "worktrees" },
    { "gh", "PRs, rig adopt, rig review, and the board's PR status" },
    { "claude", "the agent skills run in" },
  }) do
    if vim.fn.executable(dep[1]) == 1 then
      say("✓ " .. dep[1])
    else
      say(("✗ %s not found; needed for %s"):format(dep[1], dep[2]))
      ok = false
    end
  end
  return ok
end

-- mux runs the sessions, and needs rig's session source to start worktree sessions.
local function check_mux()
  if not paths.use_mux() then
    return say("✗ mux not found; install mux.nvim next to rig.nvim, or put the mux command on PATH")
  end
  say("✓ mux " .. (paths.mux() or "on the runtimepath"))
  local ok, cfg = pcall(require("mux.config").get)
  if not ok then return say("✗ " .. cfg) end
  if cfg.sources["rig.source"] then return say("✓ the mux config lists rig.source") end
  say(("✗ add this to sources in %s, so mux lists and starts worktree sessions:"):format(require("mux.config").file()))
  say(('    ["rig.source"] = %q,'):format(vim.fn.fnamemodify(paths.root(), ":~")))
end

-- Links ~/.local/bin/rig to this checkout's bin/rig, asking before replacing
-- anything else there.
local function link()
  local bin = vim.fs.joinpath(vim.env.HOME, ".local", "bin")
  local dest = vim.fs.joinpath(bin, "rig")
  local target = paths.bin()
  local current = vim.uv.fs_readlink(dest)
  if current == target then return say("✓ " .. dest .. " links to " .. target) end
  if vim.uv.fs_lstat(dest) then
    if not ask(("%s is %s. Replace it with a link to %s?"):format(dest, current and "a link to " .. current or "a file", target)) then
      return say("· left " .. dest .. " as it is")
    end
    os.remove(dest)
  end
  vim.fn.mkdir(bin, "p")
  assert(vim.uv.fs_symlink(target, dest))
  say("✓ linked " .. dest .. " to " .. target)
  if not vim.tbl_contains(vim.split(vim.env.PATH or "", ":"), bin) then say("! add " .. bin .. " to PATH") end
end

local function settings_file()
  local dir = vim.env.CLAUDE_CONFIG_DIR
  if not dir or dir == "" then dir = vim.fs.joinpath(vim.env.HOME, ".claude") end
  return vim.fs.joinpath(dir, "settings.json")
end

-- A jq program that drops old entries for rig's hook (and dash.nvim's, which it
-- replaces) from every event, then adds rig's. jq keeps the file's key order and
-- formatting, which a decode and encode in Lua would lose.
local function jq_program(command)
  local adds = {}
  for _, e in ipairs(require("rig.hook").events) do
    -- Built by hand so matcher comes first, as Claude writes it.
    local hook = ('{"type":"command","command":%s}'):format(vim.json.encode(command))
    local entry = (e[2] and ("{\"matcher\":%s,"):format(vim.json.encode(e[2])) or "{") .. ("\"hooks\":[%s]}"):format(hook)
    table.insert(adds, ("| .hooks[%s] = ((.hooks[%s] // []) + [%s])"):format(
      vim.json.encode(e[1]), vim.json.encode(e[1]), entry))
  end
  return [[
.hooks = ((.hooks // {}) | with_entries(.value |= (
  map(.hooks |= map(select((.command // "") | test("dash-claude-hook|/rig hook$") | not)))
  | map(select((.hooks | length) > 0))
)) | with_entries(select((.value | length) > 0)))
]] .. table.concat(adds, "\n")
end

local function hooks()
  if vim.fn.executable("jq") ~= 1 then
    say("✗ jq not found; add these hooks to " .. settings_file() .. " by hand, each running `rig hook`:")
    for _, e in ipairs(require("rig.hook").events) do
      say("  " .. e[1] .. (e[2] and " (matcher " .. e[2] .. ")" or ""))
    end
    return
  end
  local file = settings_file()
  local f = io.open(file)
  local before = f and f:read("*a") or "{}"
  if f then f:close() end
  if vim.trim(before) == "" then before = "{}" end
  -- The link, not the checkout, so moving the checkout needs no change here.
  -- A full path, since hooks don't always run with ~/.local/bin on PATH.
  local command = vim.fs.joinpath("~", ".local", "bin", "rig") .. " hook"
  local r = vim.system({ "jq", jq_program(command) }, { stdin = before, text = true }):wait()
  if r.code ~= 0 then return say("✗ couldn't read " .. file .. ": " .. vim.trim(r.stderr)) end
  local after = r.stdout
  local normal = vim.system({ "jq", "." }, { stdin = before, text = true }):wait().stdout
  if after == normal then return say("✓ Claude hooks are set up in " .. file) end

  local events = {}
  for _, e in ipairs(require("rig.hook").events) do
    table.insert(events, e[1])
  end
  local old = before:find("dash-claude-hook", 1, true) and " It replaces the dash-claude-hook entries." or ""
  say(("rig records whether Claude is working or waiting on you through a hook on %s.%s")
    :format(table.concat(events, ", "), old))
  if not ask("Add rig's hooks to " .. file .. "?") then
    return say("· left " .. file .. " as it is; run rig setup again to add them")
  end
  if f then
    local backup = file .. ".bak-" .. os.date("%Y%m%d%H%M%S")
    local b = assert(io.open(backup, "w"))
    b:write(before)
    b:close()
    say("✓ backed up " .. file .. " to " .. backup)
  end
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  -- Written whole then renamed, so Claude never reads half a file.
  local tmp = file .. ".tmp"
  local w = assert(io.open(tmp, "w"))
  w:write(after)
  w:close()
  assert(os.rename(tmp, file))
  say("✓ added rig's hooks to " .. file)
end

function M.run()
  check_deps()
  check_mux()
  link()
  hooks()
end

return M
