# git trim

Deletes local branches — and the [linked worktrees](https://git-scm.com/docs/git-worktree) that hold them — once they are fully merged into `main`. Run it after a round of PRs merge and it cleans up everything that's done, while refusing to touch anything that still has work in it.

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

Run `git trim` from anywhere inside a repository. It fetches (with prune), then removes every local branch that is fully merged into `main`, unless the branch is:

- `main` itself,
- the branch you currently have checked out, or
- listed in a `.git-protected-branches` file.

If no local `main` exists (common in bare-repo + worktrees layouts), it compares against `origin/main` instead.

### Worktrees

If a merged branch is checked out in a linked worktree, `git trim` removes the worktree first and then deletes the branch. Worktrees with uncommitted changes or untracked files are left alone, along with their branch:

```
$ git trim
Removed worktree /Users/you/src/project/feature-a
Deleted branch feature-a (was fa68cf94).
Skipping branch 'feature-b': worktree at /Users/you/src/project/feature-b has local changes
```

Commit or stash the local changes and run `git trim` again to clean up the rest.

### Protected branches

The `.git-protected-branches` file can reside in the current directory or any parent directory. Branch names are each listed on a line in the file. For example:

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
