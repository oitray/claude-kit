# /start-task Gotchas

> **Owner:** <your-name> | **Last verified:** 2026-05-03

Notes on the `/start-task` skill's branch + worktree creation flow that don't fit upstream (the skill itself is user-scope at `~/.claude/commands/start-task.md`).

## "Branch already used by worktree" on step 5

`/start-task` step 4 creates the branch with `git checkout -b`, leaving the branch checked out in the main repo. Step 5 then runs `git worktree add <path> <branch>` and fails with:

```
fatal: '<branch>' is already used by worktree at '<repo-root>'
```

**Workaround.** Insert `git checkout main` between steps 4 and 5. The branch reference is preserved; the main repo just goes back to `main` so the worktree can claim the branch:

```bash
git -C <repo-root> checkout -b <type>/<id>-<slug>  # creates + checks out
git -C <repo-root> checkout main                   # release the branch
git -C <repo-root> worktree add <worktree-path> <type>/<id>-<slug>
```

## Worktree disappearing mid-session

`commit-commands:clean_gone` prunes branches marked `[gone]` (deleted on the remote) and removes their worktrees. A freshly-created branch with no upstream tracking may get flagged depending on the cleanup invocation. The first symptom is usually a Bash command failing with `cd: no such file or directory: <worktree-path>`.

**Recovery.** Recreate via:

```bash
git -C <repo-root> checkout main
git -C <repo-root> branch <branch-name> 2>/dev/null || true   # ignore "already exists"
git -C <repo-root> worktree add <worktree-path> <branch-name>
```

Then change directory back into the worktree (or use `git -C <worktree-path>` for subsequent calls — see CLAUDE.md "Bash Tool Working Directory" for why `cd` doesn't persist across Bash invocations).

## Verify before assuming you're in a tree

The Bash tool's persisted cwd will silently stay at the repo root if the worktree path no longer exists or was never reached. Run `pwd && git branch --show-current` periodically when working through a long planning session — especially after any `clean_gone` or session-cleanup hooks have fired.
