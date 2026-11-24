# The .rig folder

Each worktree rig makes has a `.rig/` folder. rig and your skills talk through it: rig writes what the skill needs to start, the skill writes where it is, and the board reads both. rig keeps the folder out of git through the repo's `.git/info/exclude`.

## Written by rig, read by skills

| File | When | What |
|---|---|---|
| `notes.md` | `rig ticket` or `rig adopt` with words after the id or URL | Your instructions for the agent. |
| `base` | `rig ticket --on <PR URL>` | The branch the new PR should target. |
| `review.json` | `rig review` | The PR being reviewed: `url`, `number`, `title`, `remote`, `branch`. |
| `title` | `rig adopt`, and the board when GitHub reports a new title | The PR's title, shown on the board. |

A ticket skill gets the ticket id as its argument (`/my-ticket ABC-123`), and an adopt skill the PR URL. Any other skill gets the PR URL when you give one.

## Written by skills, read by rig

### plan.md (ticket and adopt skills)

Any Markdown, with these lines anywhere in it:

```
Status: <status>
PR: <url>
```

`Status` is one of:

| Status | Board column | Whose turn |
|---|---|---|
| `planning` | Plan | yours: the plan is ready to approve |
| `revise` | Plan | the agent's: it is changing the plan |
| `approved` | Building | the agent's |
| `building` (any text after it, like `building 2/3`) | Building | the agent's |
| `review` | Self-review | the agent's |
| `pr-open` | PR open | yours when there are commits you haven't reviewed or new teammate comments |

`PR` is the pull request's URL, once there is one. Skills with `needs = "pr-open"` (and `revise`) run only at `pr-open`, so rig never types into an agent that is still working. In a `rig review` worktree, which has no plan, they run unless `review.md` says `Status: drafting` or `ask`.

### review.md (review-plan skill)

```
Status: <drafting | ask | ready>
Round: <n> (at <commit>)
Comments: <ISO time, UTC, of the newest PR review or comment the plan has read>
```

`drafting` and `ask` mean the agent is on it; `ready` means the plan for the commit in `Round` is done.

rig checks out the commit to review before starting the skill: the PR's newest push for round 1 (`rig plan`), and again for each later round (`rig update`). `rig update` starts a round when the PR has new commits or comments newer than `Comments`. The skill reviews what is checked out.

### test.md (test skill, optional)

The checks to run by hand, kept apart from the plan so each file has one writer. rig reads only this line:

```
Tests: <building | ready (at <commit>)>
```

The test skill writes `Tests: building` when it starts and `Tests: ready (at <commit>)` once the checks cover that commit. In a `rig review` worktree, rig falls back to a `Tests` line in `review.md` when there is no `test.md`.

In a `rig review` worktree, the board reads the `Status`, `Round` and `Tests` lines, with `walkthrough.json`'s `head`, to show each piece as current or not for the PR's newest commit, and to name the review's step:

| Step | Whose turn | Key |
|---|---|---|
| to review | yours: no plan yet | `p` starts the plan |
| writing plan, answering | the agent's | |
| read plan | yours: the plan is current | `p` opens it, `r` walks the code |
| building tests | the agent's | `t` (the test skill's key) |
| test | yours: the test kit is current | |
| waiting on author | nobody's: you submitted a review of the newest commit | |
| new commits, new replies | yours | `p` starts the next round |

### walkthrough.json (review-plan skill, optional)

The order to read the PR in, for the review tool. rig doesn't read it; it's passed along by opening the review in the worktree (`review.open` gets `opts.dir`). review.nvim shows each step as a card above its code and reopens an open review when the file changes. Steps don't need to cover every change: the rest goes under `skim` or `skip`.

```json
{
  "head": "8a820577aaf",
  "prefix": "src/charts",
  "steps": [
    {
      "title": "Line chart wires it together",
      "why": "What to check in this step.",
      "places": [
        { "path": "line-chart/utils.ts", "start": 1934, "end": 1998 },
        { "path": "common/edge-layout.ts", "start": 36, "end": 56, "side": "RIGHT", "note": "Risk 1: a note for this place." }
      ]
    }
  ],
  "skim": ["common/title-band.ts"],
  "skip": ["__test__/**", "*.def.json"]
}
```

A place can point at a file the PR doesn't change. Other fields are ignored, so a skill can add its own, like a `fix` number on a step. `side` is `RIGHT` (head, the default) or `LEFT` (base).

## rig's own files

`reviewed` (the commit you last reviewed) and `parked` (the state when you parked the worktree). Skills can ignore them.
