require "git-trim/version"
require "shellwords"

class GitTrim
  def run(argv=nil)
    %x{git fetch -ap}

    if File.exist?(".git-protected-branches")
      protected_branches = File.read(".git-protected-branches").split("\n")
    end
    protected_branches ||= []
    protected_branches << "main"

    branches = %x{git branch --merged main --format='%(refname:short)'}.split("\n").collect(&:strip)
    branches -= protected_branches
    branches -= [current_branch]

    worktrees = linked_worktrees

    branches.each do |branch|
      if (path = worktrees[branch])
        %x{git worktree remove #{Shellwords.escape(path)}}
        unless $?.success?
          puts "Skipping branch '#{branch}': could not remove worktree at #{path}"
          next
        end
        puts "Removed worktree #{path}"
      end
      puts %x{git branch -d #{Shellwords.escape(branch)}}
    end
  end

  def current_branch
    %x{git branch --show-current}.strip
  end

  # Maps branch name => worktree path for linked worktrees. The first entry
  # in `git worktree list` is the main worktree, which is never removable.
  def linked_worktrees
    entries = %x{git worktree list --porcelain}.split("\n\n")
    entries.drop(1).each_with_object({}) do |entry, map|
      path = entry[/^worktree (.+)$/, 1]
      branch = entry[/^branch refs\/heads\/(.+)$/, 1]
      map[branch] = path if path && branch
    end
  end

  def find_file(filename, directory=Dir.pwd)
    local_filename = File.expand_path(filename, directory)
    if File.exist?(local_filename)
      return local_filename
    elsif directory == "/"
      return nil
    else
      return find_file(filename, File.expand_path("..", directory))
    end
  end
end
