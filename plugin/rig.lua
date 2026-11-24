-- :Rig runs the rig command from nvim; `:Rig dash` opens the board in a tab
-- of this nvim.
if vim.g.loaded_rig then return end
vim.g.loaded_rig = true

vim.api.nvim_create_user_command("Rig", function(opts)
  if opts.fargs[1] == "dash" then return require("rig.board").open() end
  local cmd = vim.list_extend({ require("rig.paths").bin() }, opts.fargs)
  vim.system(cmd, { text = true }, function(r)
    vim.schedule(function()
      local msg = vim.trim((r.stderr or "") .. (r.stdout or ""))
      if msg ~= "" then vim.notify(msg, r.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR) end
    end)
  end)
end, {
  nargs = "+",
  complete = function(_, line)
    if #vim.split(line, "%s+") > 2 then return {} end
    local out = vim.system({ require("rig.paths").bin(), "names", "commands" }, { text = true }):wait().stdout or ""
    return vim.split(vim.trim(out), "\n")
  end,
  desc = "Run a rig command",
})
