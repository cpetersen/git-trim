# git trim

Deletes local branches — and the [linked worktrees](https://git-scm.com/docs/git-worktree) that hold them — once they are merged into `main`, including squash merges. Run it after a round of PRs merge and it cleans up everything that's done, while refusing to touch anything that still has work in it.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'git-trim'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install git-trim

## Usage

Run `git trim` from anywhere inside a repository. It fetches (with prune), then removes every local branch that is merged into `main`, unless the branch is:

- `main` itself,
- the branch you currently have checked out (or the one checked out in the main worktree), or
- listed in a `.git-protected-branches` file.

If no local `main` exists (common in bare-repo + worktrees layouts), it compares against `origin/main` instead.

### Options

| Flag | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print exactly what would be removed and which signal proved it merged, without deleting anything. It still runs `git fetch -ap`, so the report reflects the current remote. |
| `--no-gh` | Skip the GitHub check entirely and use git-only detection. |
| `-v`, `--version` | Print the installed version. |
| `-h`, `--help` | Show usage. |

### How merges are detected

A branch is trimmed when **any** of these proves it is merged:

1. **Regular merge.** The branch is in `git branch --merged main`. It is deleted with `git branch -d`.
2. **Squash merge, offline.** git-trim builds a throwaway commit holding the branch's whole diff on top of its merge base (`git commit-tree <branch>^{tree} -p $(git merge-base main <branch>)`) and asks `git cherry main <tmp>` whether `main` already has an equivalent patch. No network needed.
3. **Merged GitHub PR.** A merged PR whose head branch has the same name **and** whose head commit is exactly the local tip. All merged PRs are fetched in one `gh pr list --state merged` call (up to 1000, most recent first).

Branches proven by (2) or (3) are deleted with `git branch -D`, since `-d` refuses squash-merged branches. `-D` is never used for anything else.

Some cases are reported and left alone:

- **Extra local commits.** If a merged PR exists for the branch but the local branch has commits the PR never had, the branch is kept:
  `Skipping branch 'feature-x': it has commits that merged PR #42 never had`
- **Gone upstream, no proof.** A branch whose upstream was deleted (`[gone]`) is **not** trimmed for that reason alone, because a PR closed without merging looks the same. It is reported as possibly stale:
  `Keeping branch 'spike': its upstream is gone but nothing proves it was merged (possibly stale)`

### The GitHub CLI is optional

Signal (3) uses [`gh`](https://cli.github.com/) when it is available and is skipped otherwise. git-trim prints one warning naming the reason, carries on with git-only detection, and exits 0 as usual:

```
git-trim: gh not installed; skipping GitHub PR check, using git-only detection
```

The reasons are: `gh` is not installed, no remote points at GitHub, `gh` is not logged in, `gh` can't verify its login (GitHub unreachable or token rejected), GitHub is unreachable, the API rate limit was hit, `gh` timed out, or it returned output that couldn't be parsed. An error, empty output or malformed JSON never counts as evidence that a branch is merged.

`gh` is consulted only when git alone can't prove some branch or detached worktree merged. It runs with `GH_PROMPT_DISABLED=1`, with no terminal on stdin, and under a 15-second timeout, so a hung auth prompt or network call can't stall the run.

### Worktrees

If a merged branch is checked out in a linked worktree, `git trim` removes the worktree first and then deletes the branch. Worktrees with uncommitted changes or untracked files are left alone, along with their branch:

```
$ git trim
Removed worktree /Users/you/src/project/feature-a
Deleted branch feature-a (was fa68cf94). [merged into main]
Deleted branch feature-c (was 1b2c3d4e). [squash-merged into main (patch already in main)]
Skipping branch 'feature-b': worktree at /Users/you/src/project/feature-b has local changes
```

Commit or stash the local changes and run `git trim` again to clean up the rest.

**Detached worktrees** (detached HEAD, such as the ones agents create for read-only review) are removed when they are clean and their HEAD is contained in `main`, or equals the head commit of a merged PR:

```
Removed detached worktree /Users/you/src/project/review-42 [HEAD is the head of merged PR #42]
Skipping detached worktree at /Users/you/src/project/review-43: it has local changes
```

The main worktree and the worktree you run `git trim` from are never removed.

### Protected branches

The `.git-protected-branches` file can reside in the current directory or any parent directory; the nearest one wins. Branch names are each listed on a line in the file. For example:

```
main
staging
production
```

## Releasing

Releases are cut from the GitHub Actions **Release** workflow (Actions → Release → Run workflow → enter a version like `0.2.0`). The workflow runs the specs, bumps `lib/git-trim/version.rb`, tags `v<version>`, publishes to RubyGems via [trusted publishing](https://guides.rubygems.org/trusted-publishing/) (no API key), and creates a GitHub release.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/cpetersen/git-trim. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Git::Trim project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/cpetersen/git-trim/blob/main/CODE_OF_CONDUCT.md).
