# wt — git worktree manager
#
# Worktrees for a repo `foo` are created as siblings of it, grouped in one
# folder: `foo-worktrees/<branch>/` next to `foo/`. That keeps every
# worktree out of the repo itself (nothing to .gitignore) and out of your
# way (one extra folder per repo, not one per branch).
#
#   wt new <branch> [base]   create (or attach to) a worktree and cd into it
#   wt ls                    list worktrees for the current repo
#   wt cd [branch]           cd into a worktree (fzf picker if no branch)
#   wt rm [branch] [-f]      remove a worktree (fzf picker if no branch)
#   wt rmf [branch]          force-remove a worktree (fzf picker if no branch)
#   wt rml [-f]              remove multiple worktrees (fzf multi-picker,
#                            asks force-all unless -f is passed)
#   wt prune                 drop stale worktree metadata + empty sibling dir
#   wt root                  cd to the main repo checkout
#
# `wt new <branch>` resolution order: an existing local branch is attached
# as-is; otherwise, with [base] given, a new branch is created from it
# (local or remote, e.g. `wt new my-work origin/main`); otherwise, if
# origin/<branch> exists, a new local branch is created tracking it;
# otherwise a new branch is created off HEAD.
#
# Works from inside any worktree, not just the main checkout — it always
# resolves paths off the repo's shared .git dir.
#
# Optional hook: an executable `.worktree-hook` at the repo root runs right
# after `wt new` creates a worktree (cwd = the new worktree, $1 = branch
# name). Use it for things like `cp "$root/.env" .`, symlinking
# node_modules, or `direnv allow`.

_wt_repo_root() {
  local common_dir
  common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  dirname "$common_dir"
}

_wt_worktrees_dir() {
  local root parent name
  root=$(_wt_repo_root) || return 1
  parent=$(dirname "$root")
  name=$(basename "$root")
  echo "$parent/${name}-worktrees"
}

_wt_slug() { echo "${1//\//-}" }

# Find a remote-tracking ref matching <branch> (e.g. origin/foo for foo),
# preferring origin when more than one remote has it. Echoes the ref
# (remote/branch) and returns 0, or returns 1 if no remote has it.
_wt_remote_branch_ref() {
  local root=$1 branch=$2 ref suffix
  local -a refs matches
  refs=(${(f)"$(git -C "$root" for-each-ref --format='%(refname:short)' refs/remotes)"})
  for ref in "${refs[@]}"; do
    suffix=${ref#*/}
    [[ $suffix == $branch ]] && matches+=("$ref")
  done
  (( ${#matches[@]} == 0 )) && return 1
  if (( ${#matches[@]} > 1 )) && (( ${matches[(Ie)origin/$branch]} )); then
    echo "origin/$branch"
  else
    echo "${matches[1]}"
  fi
}

_wt_help() {
  cat <<'EOF'
usage: wt <command> [args]

  wt new <branch> [base]   create (or attach to) a worktree and cd into it
  wt ls                    list worktrees for the current repo
  wt cd [branch]           cd into a worktree (fzf picker if no branch)
  wt rm [branch] [-f]      remove a worktree (fzf picker if no branch)
  wt rmf [branch]          force-remove a worktree (fzf picker if no branch)
  wt rml [-f]              remove multiple worktrees (fzf multi-picker,
                           asks force-all unless -f is passed)
  wt prune                 drop stale worktree metadata + empty sibling dir
  wt root                  cd to the main repo checkout
EOF
}

_wt_new() {
  local branch=$1 base=$2 root wdir wtpath
  if [[ -z $branch ]]; then
    echo "usage: wt new <branch> [base-branch]" >&2
    return 1
  fi

  root=$(_wt_repo_root) || { echo "wt: not inside a git repository" >&2; return 1 }
  wdir=$(_wt_worktrees_dir) || return 1
  mkdir -p "$wdir"

  wtpath="$wdir/$(_wt_slug "$branch")"

  if [[ -e $wtpath ]]; then
    echo "wt: $wtpath already exists — cd'ing into it"
    cd "$wtpath" || return 1
    return 0
  fi

  if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$root" worktree add "$wtpath" "$branch" || return 1
  elif [[ -n $base ]]; then
    git -C "$root" worktree add -b "$branch" "$wtpath" "$base" || return 1
  else
    local remote_ref
    remote_ref=$(_wt_remote_branch_ref "$root" "$branch")
    if [[ -n $remote_ref ]]; then
      echo "wt: tracking $remote_ref"
      git -C "$root" worktree add -b "$branch" "$wtpath" "$remote_ref" || return 1
    else
      git -C "$root" worktree add -b "$branch" "$wtpath" || return 1
    fi
  fi

  cd "$wtpath" || return 1

  if [[ -x "$root/.worktree-hook" ]]; then
    echo "wt: running .worktree-hook"
    "$root/.worktree-hook" "$branch"
  fi

  echo "wt: ready at $wtpath"
}

_wt_ls() {
  local root pwd_real line wpath
  root=$(_wt_repo_root) || { echo "wt: not inside a git repository" >&2; return 1 }
  pwd_real=$(pwd -P)

  git -C "$root" worktree list | while IFS= read -r line; do
    wpath=${line%% *}
    if [[ "$(cd "$wpath" 2>/dev/null && pwd -P)" == "$pwd_real" ]]; then
      print -P "%F{green}* $line%f"
    else
      echo "  $line"
    fi
  done
}

_wt_cd() {
  local root branch target
  root=$(_wt_repo_root) || { echo "wt: not inside a git repository" >&2; return 1 }
  branch=$1

  if [[ -n $branch ]]; then
    target="$(_wt_worktrees_dir)/$(_wt_slug "$branch")"
    if [[ ! -d $target ]]; then
      echo "wt: no worktree for '$branch' (looked in $target)" >&2
      return 1
    fi
  elif command -v fzf >/dev/null 2>&1; then
    target=$(git -C "$root" worktree list | fzf --prompt="worktree> " | awk '{print $1}')
    [[ -z $target ]] && return 1
  else
    echo "usage: wt cd <branch>   (install fzf for interactive picking)" >&2
    return 1
  fi

  cd "$target"
}

_wt_rm() {
  local root wdir branch wtpath force=0 arg root_real wtpath_real reply
  local -a positional
  root=$(_wt_repo_root) || { echo "wt: not inside a git repository" >&2; return 1 }
  wdir=$(_wt_worktrees_dir)

  for arg in "$@"; do
    case $arg in
      -f|--force) force=1 ;;
      *) positional+=("$arg") ;;
    esac
  done
  branch=${positional[1]}

  if [[ -n $branch ]]; then
    wtpath="$wdir/$(_wt_slug "$branch")"
  elif command -v fzf >/dev/null 2>&1; then
    wtpath=$(git -C "$root" worktree list --porcelain \
      | awk -v root="$root" '/^worktree /{p=$2} /^$/{if (p!="" && p!=root) print p; p=""}' \
      | fzf --prompt="remove worktree> ")
    [[ -z $wtpath ]] && return 1
  else
    echo "usage: wt rm <branch> [-f]" >&2
    return 1
  fi

  if [[ -z $wtpath || ! -e $wtpath ]]; then
    echo "wt: no worktree found at ${wtpath:-<none>}" >&2
    return 1
  fi

  root_real=$(cd "$root" && pwd -P)
  wtpath_real=$(cd "$wtpath" && pwd -P)

  if [[ $wtpath_real == "$root_real" ]]; then
    echo "wt: refusing to remove the main worktree" >&2
    return 1
  fi

  branch=$(git -C "$wtpath" symbolic-ref --quiet --short HEAD 2>/dev/null)

  case "$(pwd -P)" in
    "$wtpath_real"|"$wtpath_real"/*) cd "$root" ;;
  esac

  local -a rm_args
  rm_args=(worktree remove "$wtpath")
  (( force )) && rm_args+=(--force)
  if ! git -C "$root" "${rm_args[@]}"; then
    echo "wt: has uncommitted changes — rerun 'wt rm ${branch:-<branch>} -f' to discard them" >&2
    return 1
  fi

  if [[ -n $branch ]] && git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    printf "wt: delete local branch '%s' too? [y/N] " "$branch"
    read -r reply
    if [[ $reply == [yY]* ]]; then
      git -C "$root" branch -d "$branch" 2>/dev/null || git -C "$root" branch -D "$branch"
    fi
  fi

  rmdir "$wdir" 2>/dev/null

  echo "wt: removed $wtpath"
}

_wt_rml() {
  local root wdir force=0 arg reply failed=0
  local -a selections removed_branches rm_args
  root=$(_wt_repo_root) || { echo "wt: not inside a git repository" >&2; return 1 }
  wdir=$(_wt_worktrees_dir)

  for arg in "$@"; do
    case $arg in
      -f|--force) force=1 ;;
    esac
  done

  if ! command -v fzf >/dev/null 2>&1; then
    echo "wt: rml requires fzf" >&2
    return 1
  fi

  selections=(${(f)"$(git -C "$root" worktree list --porcelain \
    | awk -v root="$root" '/^worktree /{p=$2} /^$/{if (p!="" && p!=root) print p; p=""}' \
    | fzf -m --prompt="remove worktrees> " \
        --header='tab/space: toggle select · enter: confirm' \
        --bind 'space:toggle+down')"})
  (( ${#selections[@]} == 0 )) && return 1

  if (( ! force )); then
    printf "wt: force-remove all %d selected worktree(s) (discards uncommitted changes)? [y/N] " ${#selections[@]}
    read -r reply
    [[ $reply == [yY]* ]] && force=1
  fi

  local wtpath wtpath_real root_real branch
  root_real=$(cd "$root" && pwd -P)

  for wtpath in "${selections[@]}"; do
    [[ -z $wtpath || ! -e $wtpath ]] && continue
    wtpath_real=$(cd "$wtpath" && pwd -P)
    if [[ $wtpath_real == "$root_real" ]]; then
      echo "wt: refusing to remove the main worktree" >&2
      continue
    fi

    branch=$(git -C "$wtpath" symbolic-ref --quiet --short HEAD 2>/dev/null)

    case "$(pwd -P)" in
      "$wtpath_real"|"$wtpath_real"/*) cd "$root" ;;
    esac

    rm_args=(worktree remove "$wtpath")
    (( force )) && rm_args+=(--force)
    if git -C "$root" "${rm_args[@]}"; then
      echo "wt: removed $wtpath"
      [[ -n $branch ]] && removed_branches+=("$branch")
    else
      echo "wt: failed to remove $wtpath (uncommitted changes — rerun 'wt rml -f')" >&2
      failed=1
    fi
  done

  if (( ${#removed_branches[@]} )); then
    printf "wt: delete local branch(es) %s too? [y/N] " "${(j:, :)removed_branches}"
    read -r reply
    if [[ $reply == [yY]* ]]; then
      for branch in "${removed_branches[@]}"; do
        git -C "$root" show-ref --verify --quiet "refs/heads/$branch" || continue
        git -C "$root" branch -d "$branch" 2>/dev/null || git -C "$root" branch -D "$branch"
      done
    fi
  fi

  rmdir "$wdir" 2>/dev/null
  return $failed
}

_wt_prune() {
  local root wdir
  root=$(_wt_repo_root) || { echo "wt: not inside a git repository" >&2; return 1 }
  git -C "$root" worktree prune -v
  wdir=$(_wt_worktrees_dir)
  [[ -d $wdir ]] && rmdir "$wdir" 2>/dev/null && echo "wt: removed empty $wdir"
  return 0
}

_wt_root() {
  local root
  root=$(_wt_repo_root) || { echo "wt: not inside a git repository" >&2; return 1 }
  cd "$root"
}

wt() {
  local cmd=$1
  case $cmd in
    new) shift; _wt_new "$@" ;;
    ls|list) shift; _wt_ls "$@" ;;
    cd) shift; _wt_cd "$@" ;;
    rm|remove) shift; _wt_rm "$@" ;;
    rmf) shift; _wt_rm "$@" -f ;;
    rml) shift; _wt_rml "$@" ;;
    prune) shift; _wt_prune "$@" ;;
    root|main) _wt_root ;;
    ""|-h|--help|help) _wt_help ;;
    *) echo "wt: unknown command '$cmd' (try: wt help)" >&2; return 1 ;;
  esac
}

_wt_complete() {
  local -a subs
  subs=(new ls cd rm rmf rml prune root help)
  if (( CURRENT == 2 )); then
    _describe 'command' subs
  elif (( CURRENT == 3 )) && [[ ${words[2]} == (cd|rm|rmf) ]]; then
    local root wdir
    root=$(_wt_repo_root 2>/dev/null) || return
    local -a names
    names=(${(f)"$(git -C "$root" worktree list --porcelain 2>/dev/null | awk -v root="$root" '/^worktree /{if ($2!=root) print $2}')"})
    names=(${names:t})
    _describe 'worktree' names
  fi
}
(( $+functions[compdef] )) && compdef _wt_complete wt
