# wt

A small zsh module for managing [git worktrees](https://git-scm.com/docs/git-worktree)
without thinking about paths.

Worktrees for a repo `foo` are created as siblings of it, grouped in one
folder: `foo-worktrees/<branch>/` next to `foo/`. That keeps every worktree
out of the repo itself (nothing to `.gitignore`) and out of your way (one
extra folder per repo, not one per branch).

```
~/dev/
├── foo/                       # main checkout
└── foo-worktrees/
    ├── feature-login/         # `wt new feature/login`
    └── hotfix/                # `wt new hotfix main`
```

## Install

```sh
git clone https://github.com/tauantcamargo/wt.git ~/.config/wt
echo '[ -s "$HOME/.config/wt/wt.zsh" ] && source "$HOME/.config/wt/wt.zsh"' >> ~/.zshrc
```

Requires zsh and git. [fzf](https://github.com/junegunn/fzf) is optional —
`wt cd` and `wt rm` use it for interactive picking when you don't pass a
branch name.

## Usage

```
wt new <branch> [base]   create (or attach to) a worktree and cd into it
wt ls                    list worktrees for the current repo
wt cd [branch]           cd into a worktree (fzf picker if no branch)
wt rm [branch] [-f]      remove a worktree (fzf picker if no branch)
wt prune                 drop stale worktree metadata + empty sibling dir
wt root                  cd to the main repo checkout
```

`wt new` reuses the branch if it already exists locally, otherwise creates
it — from `base` if given, otherwise from the current `HEAD`. Every command
works from inside any worktree, not just the main checkout: paths are
always resolved off the repo's shared `.git` dir.

`wt rm` refuses to remove the main worktree, backs you out first if you're
standing inside the one being removed, and offers to delete the local
branch too once the worktree is gone.

## Hook

Drop an executable `.worktree-hook` at the repo root and `wt new` runs it
right after creating a worktree — cwd is the new worktree, `$1` is the
branch name. Useful for copying `.env`, symlinking `node_modules`, or
`direnv allow`:

```sh
#!/bin/sh
cp "$(git rev-parse --path-format=absolute --git-common-dir)/../.env" .
npm install
```

## License

MIT
