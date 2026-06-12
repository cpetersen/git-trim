require "tmpdir"
require "stringio"

RSpec.describe GitTrim do
  it "has a version number" do
    expect(GitTrim::VERSION).not_to be nil
  end

  describe "#run" do
    around do |example|
      Dir.mktmpdir do |tmp|
        @tmp = File.realpath(tmp)
        example.run
      end
    end

    let(:origin) { File.join(@tmp, "origin") }
    let(:repo) { File.join(@tmp, "repo") }

    def git(dir, *args)
      system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) or
        raise "git #{args.join(' ')} failed in #{dir}"
    end

    def run_trim
      Dir.chdir(repo) do
        original_stdout = $stdout
        $stdout = StringIO.new
        begin
          GitTrim.new.run
        ensure
          $stdout = original_stdout
        end
      end
    end

    def branches
      %x{git -C #{repo} branch --format='%(refname:short)'}.split("\n")
    end

    def worktree_paths
      %x{git -C #{repo} worktree list --porcelain}.scan(/^worktree (.+)$/).flatten
    end

    before do
      git(@tmp, "init", "-b", "main", origin)
      git(origin, "config", "user.email", "test@example.com")
      git(origin, "config", "user.name", "Test")
      git(origin, "commit", "--allow-empty", "-m", "initial")
      git(@tmp, "clone", origin, repo)
      git(repo, "config", "user.email", "test@example.com")
      git(repo, "config", "user.name", "Test")
    end

    it "deletes branches that are merged into main" do
      git(repo, "branch", "merged-branch")
      run_trim
      expect(branches).not_to include("merged-branch")
    end

    it "keeps branches that are not merged into main" do
      git(repo, "checkout", "-b", "unmerged-branch")
      git(repo, "commit", "--allow-empty", "-m", "unmerged work")
      git(repo, "checkout", "main")
      run_trim
      expect(branches).to include("unmerged-branch")
    end

    it "keeps main" do
      run_trim
      expect(branches).to include("main")
    end

    it "keeps main even when it is checked out in a worktree" do
      git(repo, "checkout", "-b", "feature")
      git(repo, "worktree", "add", File.join(@tmp, "wt-main"), "main")
      run_trim
      expect(branches).to include("main")
    end

    it "keeps the current branch even when merged" do
      git(repo, "checkout", "-b", "current-merged")
      run_trim
      expect(branches).to include("current-merged")
    end

    it "keeps branches listed in .git-protected-branches" do
      git(repo, "branch", "staging")
      File.write(File.join(repo, ".git-protected-branches"), "staging\n")
      run_trim
      expect(branches).to include("staging")
    end

    it "removes worktrees whose branch is merged, then deletes the branch" do
      wt = File.join(@tmp, "wt-merged")
      git(repo, "worktree", "add", "-b", "merged-wt-branch", wt, "main")
      run_trim
      expect(branches).not_to include("merged-wt-branch")
      expect(worktree_paths).not_to include(wt)
      expect(File).not_to exist(wt)
    end

    it "keeps worktrees whose branch is not merged" do
      wt = File.join(@tmp, "wt-unmerged")
      git(repo, "worktree", "add", "-b", "unmerged-wt-branch", wt, "main")
      git(wt, "commit", "--allow-empty", "-m", "unmerged work")
      run_trim
      expect(branches).to include("unmerged-wt-branch")
      expect(worktree_paths).to include(wt)
    end

    it "skips dirty worktrees and keeps their branch" do
      wt = File.join(@tmp, "wt-dirty")
      git(repo, "worktree", "add", "-b", "dirty-wt-branch", wt, "main")
      File.write(File.join(wt, "untracked.txt"), "uncommitted")
      run_trim
      expect(branches).to include("dirty-wt-branch")
      expect(worktree_paths).to include(wt)
      expect(File).to exist(File.join(wt, "untracked.txt"))
    end
  end
end
