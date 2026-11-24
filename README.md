# rig

Run several coding tasks side by side from Neovim: one git worktree, terminal session, and agent per task, and a board that shows whose turn each one is.

- **Worktrees.** `rig ticket ABC-123` makes a worktree and session for the ticket and starts your agent skill in it. `rig review <PR URL>` does the same for a teammate's PR, without an agent.
- **Board.** `rig dash` lists every worktree: the plan stage, the PR, and what is waiting on you. Keys open the plan, open a code review, run your skills, park, or remove.

Sessions come from [mux](https://github.com/snesjhon/mux.nvim), which rig builds on: each worktree gets its own mux session through rig's session source.

rig ships no skills. You write them for your tracker and repo, and the config says which skill each repo uses. They talk to rig through the files described in [docs/contract.md](docs/contract.md).

## Install

Needs [mux](https://github.com/snesjhon/mux.nvim), nvim 0.12 or later, git, gh, and the claude CLI.

```lua
-- in your nvim config
vim.pack.add({ "https://github.com/snesjhon/mux.nvim", "https://github.com/snesjhon/rig.nvim" })
```

rig finds mux through the `mux` command on PATH (`mux setup` links it), else next to it, as `vim.pack` puts them. Add rig's session source to the mux config, so mux lists and starts worktree sessions:

```lua
-- ~/.config/mux/config.lua
sources = { ["rig.source"] = "~/.local/share/nvim/site/pack/core/opt/rig.nvim" },
```

Then run `rig setup` once, from the plugin's `bin/rig`:

```sh
~/.local/share/nvim/site/pack/core/opt/rig.nvim/bin/rig setup
```

It checks the tools above and the mux config, links `rig` into `~/.local/bin`, and asks before adding its hooks to `~/.claude/settings.json`. The hooks tell the board whether Claude is working or waiting on you. Running it again changes nothing.

For zsh completion, add the plugin's `zsh` folder to `fpath`:

```zsh
(( $+commands[rig] )) && fpath=(${commands[rig]:A:h:h}/zsh $fpath)
```

## Config

`~/.config/rig/config.lua` (or `$RIG_CONFIG`). Repos are keyed by the name of their mux session, whose folder is the repo. A `config.local.lua` next to it is merged in by repo name, for repos you keep out of a shared config. It can be a link to a file in another repo.

```lua
return {
  repos = {
    app = {                                  -- the mux session for ~/Developer/app
      worktrees = "~/Developer/app-trees",   -- one session per worktree, made here
      copy = { "build/modules" },            -- ignored files each new worktree needs
      skills = {
        ticket = "/gh-ticket",               -- rig ticket <id>
        adopt = "/gh-ticket adopt",          -- rig adopt <PR URL>
        revise = "/gh-ticket revise",        -- send your review to the agent
        ["review-plan"] = "/gh-pr-review",   -- plan a review of a teammate's PR
        test = { "/gh-ticket test", needs = "pr-open", key = "t", desc = "build and test" },
      },
    },
  },
  -- How the board opens a code review. Optional.
  review = {
    open = function(opts) end, -- opts.dir, opts.pr, opts.on_submit(head)
  },
}
```

Worktree sessions get their repo session's tabs, and the agent runs in the first one. See `lua/rig/config.lua` for every field. A skill with a name of its own (`test` above) is also a command: `rig test [worktree]`. `needs` keeps it from running before the plan reaches that status, and `key` puts it on the board.

## The board in a float

Point mux's float at the board, and its float key shows or hides it over the current tab:

```lua
-- ~/.config/mux/config.lua
float = { "rig", "dash", "--float" },
```

## Commands

```
rig new <branch> [base]           worktree and session, no agent
rig ticket <id|URL> [-n name | -b branch] [--on <PR URL>] [notes...]
rig adopt <PR URL> [-n name] [notes...]
rig review <PR URL> [-n name]     open the code review of a teammate's PR, making its worktree first
rig dash                          the board

On a worktree, by default the one this shell is in. Each is also a board key:
rig plan [name]                   p  open the plan (the review plan when reviewing)
rig update [name]                 u  reviewing: bring the PR's new commits and comments into the review plan
rig review [name]                 r  open the code review
rig mark [name]                   m  mark the code reviewed
rig pr [name]                     o  open the PR in the browser
rig revise [name]                 s  send your review to the agent
rig park [name]                   x  stop the session and hide it until something changes
rig rm [name]                     d  stop the session, remove the worktree, keep the branch
rig <skill> [name] [PR URL]       run a skill from the config

rig setup | hook
```

Moving between sessions, restarting and stopping them is mux's (`mux`, `mux restart`, `mux kill`).

Inside a session, `rig plan` and `rig review` open in tabs named `plan` and `review`, which close when you quit their nvim. Running one again goes back to its tab.

Inside nvim, `:Rig <command>` runs the same commands, and `:Rig dash` opens the board in a tab.
