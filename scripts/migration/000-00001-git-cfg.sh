#!/usr/bin/env bash
# hello: git config additions: user, work includeif, diffview mergetool, colors, extra aliases, lfs
set -euo pipefail

CONFIG="$HOME/.config/git/config"

if [[ ! -f "$CONFIG" ]]; then
  echo "git config skipped (file not found)"
  exit 1
fi

echo "appending git config customizations..."

cat >> "$CONFIG" << 'GITCONFIG'

# --- BEGIN ko komarchy ---

[user]
	name = kodev
	email = kjortego@gmail.com

[includeIf "gitdir:~/rpc/repo/"]
	path = ~/.gitconfig.work

[core]
	autocrlf = false

[pull]
	rebase = false           # Default merge on pull (overrides omarchy rebase = true)

[merge]
	tool = diffview
[mergetool "diffview"]
	cmd = nvim -n -c \"DiffviewOpen\" \"$MERGE\"
	trustExitCode = true

[color]
	ui = auto
[color "branch"]
	current = yellow reverse
	local = yellow
	remote = green
[color "diff"]
	meta = yellow bold
	frag = magenta bold
	old = red bold
	new = green bold
[color "decorate"]
	HEAD = bold yellow
	branch = bold cyan
	remoteBranch = dim bold cyan
	tag = bold magenta
[color "status"]
	added = green
	changed = yellow
	untracked = cyan

[alias]
	lg = log --graph --abbrev-commit --decorate --format=format:'%C(bold yellow)%h%C(reset) - %C(dim white)%s%C(reset)%C(auto)%d%C(reset)' --all
	lg2 = log --graph --abbrev-commit --decorate --format=format:'%C(bold yellow)%h%C(reset) - %C(dim white)%s%C(reset) %C(bold green)- %an%C(reset) %C(dim bold green)(%ar)%C(reset)%C(auto)%d%C(reset)' --all
	lgf = diff-tree --no-commit-id --name-only -r

[filter "lfs"]
	required = true
	clean = git-lfs clean -- %f
	smudge = git-lfs smudge -- %f
	process = git-lfs filter-process

# --- END ko komarchy ---
GITCONFIG

echo "git config applied"
