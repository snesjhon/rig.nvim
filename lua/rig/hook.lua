-- `rig hook`: a Claude Code hook that saves whether Claude is working, waiting
-- on you, or idle, for rig.dash.claude to read. `rig setup` registers it in
-- ~/.claude/settings.json for the events in M.events.
local M = {}

-- Event -> matcher (nil for every tool).
M.events = {
  { "SessionStart" },
  { "UserPromptSubmit" },
  -- Only tools that ask you something.
  { "PreToolUse", "AskUserQuestion|ExitPlanMode" },
  { "PostToolUse" },
  { "Notification" },
  { "Stop" },
  { "SessionEnd" },
}

function M.run()
  local claude = require("rig.dash.claude")

  local ok, input = pcall(vim.json.decode, io.read("*a"))
  if not ok or type(input) ~= "table" then return end
  local project = vim.env.CLAUDE_PROJECT_DIR or input.cwd
  if not project then return end
  local event = input.hook_event_name
  local file = claude.file(project)

  if event == "SessionEnd" then
    os.remove(file)
    return
  end
  local state = ({
    SessionStart = "idle",
    UserPromptSubmit = "working",
    -- A tool ran, so any permission prompt or question before it was answered.
    PostToolUse = "working",
    Stop = "idle",
    -- Registered only for tools that ask you something.
    PreToolUse = "waiting",
  })[event]
  if event == "Notification" then
    -- Claude also notifies after a minute idle, which needs nothing new from you.
    local idle = input.notification_type == "idle_prompt" or (input.message or ""):find("waiting for your input")
    state = idle and "idle" or "waiting"
  end
  if not state then return end

  vim.fn.mkdir(claude.dir(), "p")
  -- Written whole then renamed, so a reader never sees half a file.
  local tmp = file .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(vim.json.encode({ state = state, event = event, message = input.message, time = os.time() }))
  f:close()
  os.rename(tmp, file)
end

return M
