# git trim

Welcome to your new gem! In this directory, you'll find the files you need to be able to package up your Ruby library into a gem. Put your Ruby code in the file `lib/git/trim`. To experiment with that code, run `bin/console` for an interactive prompt.

TODO: Delete this and the text above, and describe your gem

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

You can call `git trim` and it will remove any branch that is fully merged into `main`, unless it is listed in the `.git-protected-branches` file. It will not remove the main branch or the branch you currently have checked out.

If a merged branch is checked out in a [linked worktree](https://git-scm.com/docs/git-worktree), `git trim` removes the worktree first and then deletes the branch. Worktrees with uncommitted changes or untracked files are left alone (along with their branch).

The `.git-protected-branches` file can reside in the current directory or any parent directory. Branch names are each listed on a line in the file. For example:

```
main
staging
production
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/git-trim. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Git::Trim project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/[USERNAME]/git-trim/blob/main/CODE_OF_CONDUCT.md).
