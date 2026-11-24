-- A dashboard for overseeing agents, laid out in bordered panels. Two views of
-- the same items: an inbox of what is waiting on you, one panel per whose turn
-- it is, and a board with one column per stage. A Details panel shows the
-- selected item, and keys act on it. The caller says what the items are and what each key does (see
-- M.open), so the dashboard works with any setup.
local M = {}

local ns = vim.api.nvim_create_namespace("rig.dash")

local function scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "rig-dash"
  vim.bo[buf].modifiable = false
  return buf
end

local function set_lines(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  -- Refreshes mostly bring the same text, which needs no redraw.
  if vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function width(s) return vim.fn.strdisplaywidth(s) end

local function pad(s, w) return s .. string.rep(" ", math.max(w - width(s), 0)) end

-- `s` cut to `w` columns, ending in … when it had to be cut.
local function fit(s, w)
  if width(s) <= w then return pad(s, w) end
  local out = ""
  for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
    if width(out .. ch) > w - 1 then break end
    out = out .. ch
  end
  return pad(out .. "…", w)
end

function M.ago(time)
  if not time then return "" end
  local s = os.time() - time
  if s < 60 then return "now" end
  if s < 3600 then return math.floor(s / 60) .. "m" end
  if s < 86400 then return math.floor(s / 3600) .. "h" end
  return math.floor(s / 86400) .. "d"
end

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function spinner() return frames[math.floor(vim.uv.now() / 100) % #frames + 1] end

-- The age column, or a spinner while an action runs on the item.
local function age(item)
  if item.busy then return spinner(), "RigDashBusy" end
  return M.ago(item.since), "RigDashAge"
end

local function name_hl() return "RigDashName" end

-- Groups link to common ones by default, so any colorscheme can restyle them.
-- The colors follow lazygit: purple-gray borders, teal for the active panel
-- and ages.
local function set_highlights()
  local function fg(group) return vim.api.nvim_get_hl(0, { name = group, link = false }).fg end
  vim.api.nvim_set_hl(0, "RigDashActive", { fg = fg("Special"), bold = true, default = true })
  -- Comment's color without its italic, which many themes add and which reads
  -- poorly in lists.
  for _, name in ipairs({ "RigDashBorder", "RigDashDim", "RigDashLabel" }) do
    vim.api.nvim_set_hl(0, name, { fg = fg("Comment"), default = true })
  end
  for name, link in pairs({
    RigDashAge = "Special",
    RigDashBusy = "DiagnosticInfo",
    RigDashName = "Normal",
    RigDashHeading = "Title",
    RigDashOk = "DiagnosticOk",
    RigDashBad = "DiagnosticError",
    RigDashNumber = "Identifier",
    RigDashChanged = "Changed",
  }) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

local sections = {
  { current = true, title = "This worktree" },
  { turn = "you", title = "Your turn" },
  { turn = "agent", title = "Agents working" },
  { title = "Nothing to do" },
}

-- Most recently active first. Items without a time go last, by name.
local function newest(a, b)
  local x, y = a.since or -math.huge, b.since or -math.huge
  if x ~= y then return x > y end
  return a.name < b.name
end

-- The inbox: one panel per section. Returns per section its title, lines,
-- highlights as { row, start col, end col, group }, and item ids in row order,
-- plus the section and row of each item.
local function inbox(items, inner_w)
  -- Row: age(3) " " name, padded to the section's longest, then the PR title.
  -- The reason stays out, since the section already says whose turn it is.
  local out, pos = {}, {}
  for s, sec in ipairs(sections) do
    local list = vim.tbl_filter(function(item)
      if sec.current or item.current then return sec.current == item.current end
      local turn = (item.turn == "you" or item.turn == "agent") and item.turn or nil
      return turn == sec.turn
    end, items)
    table.sort(list, newest)
    local namew = 0
    for _, item in ipairs(list) do
      namew = math.max(namew, width(item.name))
    end
    local lines, marks, ids = {}, {}, {}
    for i, item in ipairs(list) do
      local a, a_hl = age(item)
      local head = pad(a, 3) .. " "
      local room = inner_w - width(head)
      local name = item.name
      if width(name) > room then name = vim.trim(fit(name, room)) end
      local detail = item.busy or item.title or ""
      local rest = room - math.min(namew, room) - 2
      detail = rest > 3 and detail ~= "" and vim.trim(fit(detail, rest)) or ""
      local line = head .. name
      if detail ~= "" then line = pad(line, width(head) + namew) .. "  " .. detail end
      table.insert(lines, line)
      local row = i - 1
      table.insert(marks, { row, 0, #a, a_hl })
      table.insert(marks, { row, #head, #head + #name, name_hl(item) })
      if detail ~= "" then table.insert(marks, { row, #line - #detail, #line, item.busy and "RigDashBusy" or "RigDashDim" }) end
      table.insert(ids, item.id)
      pos[item.id] = { section = s, row = i }
    end
    out[s] = { title = ("[%d]─%s"):format(s, sec.title), lines = lines, marks = marks, ids = ids }
  end
  return out, { sections = vim.tbl_map(function(sec) return sec.ids end, out), pos = pos }
end

-- The sidebar's inner width that fits every row without cutting.
local function inbox_width(items)
  local w = 0
  for _, item in ipairs(items) do
    w = math.max(w, width(item.name) + width(item.busy or item.title or "") + 10)
  end
  return w
end

-- The board returns its lines, highlights, and where each item is:
-- pos[id] = { line, col }, plus the ids per column.
local function board(items, columns, sel, win_width)
  local colw = math.max(math.floor((win_width - 1) / #columns), 18)
  local cardw = colw - 2
  local inner = cardw - 4
  local grid = {}
  for c, column in ipairs(columns) do
    local list = vim.tbl_filter(function(item) return item.column == column.id end, items)
    table.sort(list, function(a, b)
      if (a.turn == "you") ~= (b.turn == "you") then return a.turn == "you" end
      return a.name < b.name
    end)
    grid[c] = list
  end

  local header = " "
  for c, column in ipairs(columns) do
    header = header .. fit(("%s (%d)"):format(column.title, #grid[c]), cardw) .. "  "
  end
  local lines, marks, pos = { header, "" }, { { 0, 0, #header, "Title" } }, {}
  local rows = 0
  for _, list in ipairs(grid) do
    rows = math.max(rows, #list)
  end
  for r = 1, rows do
    local parts = { " ", " ", " ", " " }
    for c = 1, #columns do
      local item = grid[c][r]
      for k = 1, 4 do
        local start, row = #parts[k], #lines + k - 1
        if not item then
          parts[k] = parts[k] .. string.rep(" ", colw)
        else
          local border = item.id == sel and "RigDashActive" or "RigDashBorder"
          local text
          if k == 1 or k == 4 then
            text = (k == 1 and "╭" or "╰") .. string.rep("─", cardw - 2) .. (k == 1 and "╮" or "╯")
            table.insert(marks, { row, start, start + #text, border })
          else
            -- The age leads the name line, as in the inbox.
            local a, a_hl = age(item)
            local lead = a ~= "" and a .. " " or ""
            local body = k == 2 and lead .. item.name or item.busy or item.reason or ""
            text = "│ " .. fit(body, inner) .. " │"
            local left = start + #"│ "
            local right = start + #text - #" │"
            table.insert(marks, { row, start, start + #"│", border })
            table.insert(marks, { row, start + #text - #"│", start + #text, border })
            if k == 2 then
              if a ~= "" then table.insert(marks, { row, left, left + #a, a_hl }) end
              table.insert(marks, { row, left + #lead, right, name_hl(item) })
            else
              table.insert(marks, { row, left, right, item.busy and "RigDashBusy" or "RigDashDim" })
            end
            if k == 2 then pos[item.id] = { row + 1, start } end
          end
          parts[k] = parts[k] .. text .. "  "
        end
      end
    end
    vim.list_extend(lines, parts)
  end
  local ids = vim.tbl_map(function(list) return vim.tbl_map(function(item) return item.id end, list) end, grid)
  return lines, marks, { grid = ids, pos = pos }
end

-- Opens the dashboard in its own tab. opts:
--   columns  the board's columns, a list of { id, title }
--   items    function(dash) returning the items, each with
--              id, name     unique id and the name shown
--              turn         "you" when it waits on you, "agent" when an agent
--                           is on it, nil when neither
--              reason       a few words on where it is ("plan ready")
--              title        the PR's title, shown beside the name in the inbox
--              since        when it got there, in seconds since the epoch
--              column       the id of its board column
--              agent        "working", "waiting", or "idle"
--              running      whether its session is up
--              current      whether it is the worktree you are in, which the
--                           inbox lists first on its own and both views select
--                           when they open
--            dash.refresh() redraws, for data that arrives later
--   details  function(item, done) that calls done(lines) with the text of the
--            Details panel, as many times as it has more to show. A line is
--            a string, or a list of { text, highlight group } chunks
--   keys     list of { lhs, function(item, dash), desc = "..." }, where item
--            can be nil and dash has refresh(), close(), and busy(id, label),
--            which shows a spinner and `label` on item `id` (or only in the
--            title when id is nil) until the function it returns is called
--   view     "inbox" (default) or "board"
--   interval ms between refreshes (default 3000)
function M.open(opts)
  local api = vim.api
  local interval = opts.interval or 3000
  local keys = opts.keys or {}
  local columns = opts.columns or { { id = nil, title = "All" } }
  local view = opts.view or "inbox"

  set_highlights()

  -- Use the window nvim started with when it shows nothing, else a new tab.
  local start = api.nvim_get_current_buf()
  if api.nvim_buf_get_name(start) ~= "" or vim.bo[start].modified or vim.fn.winnr("$") > 1 then
    vim.cmd.tabnew()
    start = api.nvim_get_current_buf()
  end
  local tab = api.nvim_get_current_tabpage()
  -- The window under the panels only gives the space they share.
  local base = api.nvim_get_current_win()
  local base_buf = scratch()
  api.nvim_win_set_buf(base, base_buf)
  if start ~= base_buf then pcall(api.nvim_buf_delete, start, {}) end
  do
    local wo = vim.wo[base]
    wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, "no", "0"
    wo.statuscolumn, wo.cursorline, wo.list = "", false, false
    wo.fillchars = "eob: "
    wo.winbar, wo.statusline = "", " "
  end

  local function show(p, lines, marks)
    set_lines(p.buf, lines)
    api.nvim_buf_clear_namespace(p.buf, ns, 0, -1)
    for _, m in ipairs(marks or {}) do
      pcall(api.nvim_buf_set_extmark, p.buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
    end
  end

  -- Panels are bordered floats: one per inbox section, the board, and details.
  -- Those the view doesn't use stay hidden.
  local panels = {}
  local function panel(name)
    local buf = scratch()
    local win = api.nvim_open_win(buf, false, {
      relative = "editor", row = 0, col = 0, width = 1, height = 1,
      style = "minimal", border = "rounded", zindex = 10, hide = true,
    })
    vim.wo[win].wrap = name == "details"
    -- Keeps the details text off the border.
    if name == "details" then vim.wo[win].statuscolumn = " " end
    vim.wo[win].winhighlight = "NormalFloat:Normal"
    panels[name] = { buf = buf, win = win }
    return panels[name]
  end
  for s = 1, #sections do
    panel(s)
  end
  panel("board")
  panel("details")
  local section_wins = {}
  for s = 1, #sections do
    section_wins[s] = panels[s].win
  end

  -- The full key list is too long for a status line, so it waits behind ?.
  -- They get their own row, since 'laststatus' may hide every status line.
  local first = keys[1] and (keys[1][1]:gsub("<CR>", "⏎")) .. " " .. keys[1].desc .. "  " or ""
  local hints = " " .. first .. "1-" .. #sections .. " jump  ⇥ inbox/board  ? keys  q quit"
  local hint_bar = panel("hints")
  api.nvim_win_set_config(hint_bar.win, { border = "none", focusable = false })

  local help = {}
  for _, k in ipairs(keys) do
    table.insert(help, "  " .. pad((k[1]:gsub("<CR>", "⏎")), 6) .. " " .. k.desc)
  end
  vim.list_extend(help, {
    "  j k    move within the section (inbox), column (board)",
    "  h l    previous or next section (inbox), column (board)",
    "  1-" .. #sections .. "    jump to a section",
    "  ^d ^u  scroll the details",
    "  ⇥      switch between inbox and board",
    "  q      quit",
  })

  local items, sel, shown, closed = {}, nil, nil, false
  -- The row each section had selected last, for jumping back to it.
  local last = {}
  -- Running actions, label by key, with the item they are for.
  local jobs, job_count = {}, 0
  local spin = assert(vim.uv.new_timer())
  local layout = { pos = {}, sections = {}, grid = {} }
  local timer = assert(vim.uv.new_timer())
  local dash

  local function selected()
    for _, item in ipairs(items) do
      if item.id == sel then return item end
    end
  end

  -- Places a panel at an outer size that includes its border.
  local function put(p, row, col, w, h, title, active, footer)
    api.nvim_win_set_config(p.win, {
      relative = "editor", row = row, col = col,
      width = math.max(w - 2, 1), height = math.max(h - 2, 1),
      title = title, title_pos = "left", hide = false,
      footer = footer or "", footer_pos = "right",
    })
    local border = active and "RigDashActive" or "RigDashBorder"
    vim.wo[p.win].winhighlight = ("NormalFloat:Normal,FloatBorder:%s,FloatTitle:%s,FloatFooter:%s"):format(border, border, border)
    vim.wo[p.win].cursorline = active and p ~= panels.details and p ~= panels.board
  end

  local function hide(p) api.nvim_win_set_config(p.win, { hide = true }) end

  -- The window keys and the cursor live in.
  local function focus_win()
    if view == "board" then return panels.board.win end
    local at = layout.pos[sel]
    return panels[at and at.section or 2].win
  end

  -- The first section holds only the worktree you are in, so it keeps one row,
  -- like lazygit's Status panel. The rest split what is left evenly, with the
  -- odd rows going to the first ones.
  local function heights(n, total)
    local h = { 3 }
    local rest, m = total - 3, n - 1
    for s = 2, n do
      h[s] = math.floor(rest / m) + (s - 1 <= rest % m and 1 or 0)
    end
    return h
  end

  local function draw()
    if closed or not api.nvim_win_is_valid(base) then return end
    local busy = {}
    for _, job in pairs(jobs) do
      if job.id then busy[job.id] = job.label end
    end
    for _, item in ipairs(items) do
      item.busy = busy[item.id]
    end

    local info = vim.fn.getwininfo(base)[1]
    local top, left = info.winrow - 1, info.wincol - 1
    local W, H = info.width, info.height - 1
    api.nvim_win_set_config(panels.hints.win, {
      relative = "editor", row = top + H, col = left, width = W, height = 1, hide = false,
    })

    if view == "inbox" then
      local side = math.min(math.max(inbox_width(items) + 2, 40), math.floor(W * 0.55))
      local out
      out, layout = inbox(items, side - 2)
      -- A selection that went away moves to the worktree you are in, else the
      -- first item.
      if not layout.pos[sel] then
        sel = nil
        for _, item in ipairs(items) do
          if item.current and layout.pos[item.id] then sel = item.id end
        end
        for _, ids in ipairs(layout.sections) do
          sel = sel or ids[1]
        end
      end
      local at = layout.pos[sel]
      local focus = at and at.section or 2
      if at then last[focus] = sel end
      local h = heights(#out, H)
      local row = top
      for s, sec in ipairs(out) do
        local p = panels[s]
        show(p, sec.lines, sec.marks)
        -- Each section says where its selection is, as lazygit does: the
        -- row it had last, else the first.
        local idx = 0
        if at and s == focus then
          idx = at.row
        elseif #sec.ids > 0 then
          idx = math.max(vim.fn.index(sec.ids, last[s]) + 1, 1)
        end
        local footer = ("%d of %d"):format(idx, #sec.ids)
        put(p, row, left, side, h[s], sec.title, s == focus, footer)
        row = row + h[s]
        if at and s == focus then pcall(api.nvim_win_set_cursor, p.win, { at.row, 1 }) end
      end
      hide(panels.board)
      put(panels.details, top, left + side, W - side, H, "Details", false)
    else
      local details_h = math.min(12, math.floor(H / 2))
      local lines, marks
      lines, marks, layout = board(items, columns, sel, W - 2)
      if not layout.pos[sel] then
        sel = nil
        for _, item in ipairs(items) do
          if item.current and layout.pos[item.id] then sel = item.id end
        end
        for _, ids in ipairs(layout.grid) do
          sel = sel or ids[1]
        end
        if sel then lines, marks, layout = board(items, columns, sel, W - 2) end
      end
      if #lines == 0 then lines = { "", "  Nothing here yet." } end
      for s = 1, #sections do
        hide(panels[s])
      end
      show(panels.board, lines, marks)
      put(panels.board, top, left, W, H - details_h, "Board", true)
      if layout.pos[sel] then pcall(api.nvim_win_set_cursor, panels.board.win, layout.pos[sel]) end
      put(panels.details, top + H - details_h, left, W, details_h, "Details", false)
    end

    -- Follow the selection to its panel, but leave other windows, like an
    -- input prompt or the details, alone.
    local cur = api.nvim_get_current_win()
    local want = focus_win()
    if cur ~= want and (cur == base or cur == panels.board.win or vim.tbl_contains(section_wins, cur)) then
      api.nvim_set_current_win(want)
    end

    -- Key hints on the left, running actions on the right.
    local running = ""
    if job_count > 0 then
      local labels = {}
      for _, job in pairs(jobs) do
        table.insert(labels, job.id and job.id .. ": " .. job.label or job.label)
      end
      table.sort(labels)
      running = spinner() .. " " .. table.concat(labels, " · ") .. " "
    end
    local gap = math.max(W - width(hints) - width(running), 1)
    local bar = hints .. string.rep(" ", gap) .. running
    show(hint_bar, { bar }, { { 0, 0, #hints, "Comment" }, { 0, #hints + gap, #bar, "DiagnosticInfo" } })
  end

  -- Lines given as chunks become plain text plus highlights.
  local function show_chunks(p, given)
    local lines, marks = {}, {}
    for i, line in ipairs(given) do
      if type(line) == "string" then
        lines[i] = line
      else
        local text = ""
        for _, chunk in ipairs(line) do
          if chunk[2] then table.insert(marks, { i - 1, #text, #text + #chunk[1], chunk[2] }) end
          text = text .. chunk[1]
        end
        lines[i] = text
      end
    end
    show(p, lines, marks)
  end

  local function show_details()
    local item = selected()
    shown = sel
    if not item then return show(panels.details, {}) end
    local id = item.id
    local ok, err = pcall(opts.details, item, function(lines)
      vim.schedule(function()
        if sel == id then show_chunks(panels.details, lines) end
      end)
    end)
    if not ok then show(panels.details, vim.split(tostring(err), "\n")) end
  end

  local function refresh()
    if closed then return end
    local ok, res = pcall(opts.items, dash)
    if not ok then return vim.notify("rig dash: " .. tostring(res), vim.log.levels.ERROR) end
    items = res
    draw()
    show_details()
  end

  local function select(id)
    sel = id
    draw()
    if sel ~= shown then
      pcall(api.nvim_win_set_cursor, panels.details.win, { 1, 0 })
      show_details()
    end
  end

  -- The section `s` lands on: the row it had last, else its first.
  local function jump(s)
    local ids = layout.sections[s] or {}
    if #ids == 0 then return end
    select(vim.tbl_contains(ids, last[s]) and last[s] or ids[1])
  end

  -- dr moves within the list or column, dc between sections or board columns.
  local function move(dc, dr)
    if view == "inbox" then
      if dc ~= 0 then
        local at = layout.pos[sel]
        local s = (at and at.section or 1) + dc
        while sections[s] do
          local before = sel
          jump(s)
          if sel ~= before or (layout.pos[sel] and layout.pos[sel].section == s) then return end
          s = s + dc
        end
        return
      end
      local at = layout.pos[sel]
      if not at then return end
      local ids = layout.sections[at.section]
      select(ids[math.min(math.max(at.row + dr, 1), #ids)])
      return
    end
    local grid, c, r = layout.grid, 1, 1
    for ci, ids in ipairs(grid) do
      for ri, id in ipairs(ids) do
        if id == sel then c, r = ci, ri end
      end
    end
    if dc ~= 0 then
      local nc = c + dc
      while grid[nc] and #grid[nc] == 0 do
        nc = nc + dc
      end
      if not grid[nc] then return end
      c, r = nc, math.min(r, #grid[nc])
    elseif grid[c] then
      r = math.min(math.max(r + dr, 1), #grid[c])
    end
    if grid[c] and grid[c][r] then select(grid[c][r]) end
  end

  local function close()
    if closed then return end
    closed = true
    pcall(api.nvim_del_augroup_by_name, "dash_" .. base_buf)
    if saved_cursor then vim.o.guicursor = saved_cursor end
    timer:stop()
    timer:close()
    spin:stop()
    spin:close()
    if not api.nvim_tabpage_is_valid(tab) then return end
    if #api.nvim_list_tabpages() == 1 then
      pcall(vim.cmd, "qa")
    else
      vim.cmd.tabclose(api.nvim_tabpage_get_number(tab))
    end
  end

  local next_job = 0
  local function busy(id, label)
    next_job = next_job + 1
    local key = next_job
    jobs[key], job_count = { id = id, label = label }, job_count + 1
    -- The spinner moves only while something runs.
    if job_count == 1 then spin:start(0, 100, vim.schedule_wrap(function()
      if not closed then draw() end
    end)) end
    draw()
    return function()
      if not jobs[key] then return end
      jobs[key], job_count = nil, job_count - 1
      if job_count == 0 then spin:stop() end
      if not closed then draw() end
    end
  end

  dash = { refresh = refresh, close = close, busy = busy }

  local function scroll(cmd)
    api.nvim_win_call(panels.details.win, function() vim.cmd("normal! " .. api.nvim_replace_termcodes(cmd, true, false, true)) end)
  end

  local list_bufs = { panels.board.buf }
  for s = 1, #sections do
    table.insert(list_bufs, panels[s].buf)
  end
  local function map(buf, lhs, fn) vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true }) end
  for _, buf in ipairs(list_bufs) do
    for _, k in ipairs(keys) do
      map(buf, k[1], function() k[2](selected(), dash) end)
    end
    for lhs, d in pairs({
      j = { 0, 1 }, k = { 0, -1 }, h = { -1, 0 }, l = { 1, 0 },
      ["<Down>"] = { 0, 1 }, ["<Up>"] = { 0, -1 }, ["<Left>"] = { -1, 0 }, ["<Right>"] = { 1, 0 },
      gg = { 0, -math.huge }, G = { 0, math.huge },
    }) do
      map(buf, lhs, function() move(d[1], d[2]) end)
    end
    for s = 1, #sections do
      map(buf, tostring(s), function()
        if view == "inbox" then jump(s) end
      end)
    end
    map(buf, "<C-d>", function() scroll("<C-d>") end)
    map(buf, "<C-u>", function() scroll("<C-u>") end)
    map(buf, "<Tab>", function()
      view = view == "inbox" and "board" or "inbox"
      draw()
    end)
    map(buf, "q", close)
    map(buf, "?", function()
      local hbuf = scratch()
      set_lines(hbuf, help)
      local w = 0
      for _, line in ipairs(help) do
        w = math.max(w, width(line) + 2)
      end
      local win = api.nvim_open_win(hbuf, true, {
        relative = "editor",
        row = math.floor((vim.o.lines - #help) / 2),
        col = math.floor((vim.o.columns - w) / 2),
        width = w,
        height = #help,
        border = "rounded",
        title = " Keys ",
      })
      for _, l in ipairs({ "q", "?", "<Esc>" }) do
        map(hbuf, l, function() api.nvim_win_close(win, true) end)
      end
    end)
  end
  for _, l in ipairs({ "q", "<Esc>" }) do
    map(panels.details.buf, l, function() api.nvim_set_current_win(focus_win()) end)
  end

  local group = api.nvim_create_augroup("dash_" .. base_buf, { clear = true })
  api.nvim_create_autocmd("VimResized", { group = group, callback = draw })
  -- A mouse click on a row selects it.
  for s = 1, #sections do
    api.nvim_create_autocmd("CursorMoved", {
      group = group,
      buffer = panels[s].buf,
      callback = function()
        if view ~= "inbox" or api.nvim_get_current_win() ~= panels[s].win then return end
        local row = api.nvim_win_get_cursor(panels[s].win)[1]
        for id, at in pairs(layout.pos) do
          if at.section == s and at.row == row and id ~= sel then return select(id) end
        end
      end,
    })
  end
  -- The lists show the selection as a highlighted line, so the cursor hides
  -- while you are in one. A cursor group with full blend makes nvim hide it.
  api.nvim_set_hl(0, "RigDashHiddenCursor", { blend = 100, nocombine = true })
  local saved_cursor
  local function show_cursor()
    if saved_cursor then vim.o.guicursor, saved_cursor = saved_cursor, nil end
  end
  for _, buf in ipairs(list_bufs) do
    api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
      group = group,
      buffer = buf,
      callback = function()
        saved_cursor = saved_cursor or vim.o.guicursor
        vim.o.guicursor = "a:RigDashHiddenCursor"
      end,
    })
    api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, { group = group, buffer = buf, callback = show_cursor })
  end
  api.nvim_create_autocmd("TabLeave", { group = group, callback = show_cursor })

  -- The base window only frames the panels, so focus goes back to them.
  api.nvim_create_autocmd("WinEnter", {
    group = group,
    buffer = base_buf,
    callback = function()
      vim.schedule(function()
        if not closed then pcall(api.nvim_set_current_win, focus_win()) end
      end)
    end,
  })
  -- Closing any of its windows closes the whole dashboard.
  local wins = { base }
  for _, p in pairs(panels) do
    table.insert(wins, p.win)
  end
  for _, win in ipairs(wins) do
    api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = tostring(win),
      once = true,
      callback = function() vim.schedule(close) end,
    })
  end

  draw()
  timer:start(0, interval, vim.schedule_wrap(function()
    -- A background tab isn't seen, so it waits until you come back.
    if not closed and api.nvim_get_current_tabpage() == tab then refresh() end
  end))
  return dash
end

return M
