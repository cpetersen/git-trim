require "tmpdir"
require "stringio"
require "json"
require "timeout"

RSpec.describe GitTrim do
  it "has a version number" do
    expect(GitTrim::VERSION).not_to be nil
  end

  describe "#run" do
    # Every example runs with a PATH holding only git (and, when a test
    # installs one, a fake gh), so the real gh is never consulted.
    around do |example|
      Dir.mktmpdir do |tmp|
        @tmp = File.realpath(tmp)
        @bin = File.join(@tmp, "bin")
        Dir.mkdir(@bin)
        real_git = ENV["PATH"].split(File::PATH_SEPARATOR)
          .collect { |dir| File.join(dir, "git") }
          .find { |path| File.executable?(path) }
        File.symlink(real_git, File.join(@bin, "git"))
        original_path = ENV["PATH"]
        ENV["PATH"] = @bin
        begin
          example.run
        ensure
          ENV["PATH"] = original_path
        end
      end
    end

    let(:origin) { File.join(@tmp, "origin") }
    let(:repo) { File.join(@tmp, "repo") }
    let(:gh_log) { File.join(@tmp, "gh.log") }

    def git(dir, *args)
      system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) or
        raise "git #{args.join(' ')} failed in #{dir}"
    end

    def run_trim(*argv, gh_timeout: GitTrim::GH_TIMEOUT)
      Dir.chdir(repo) do
        original_stdout, original_stderr = $stdout, $stderr
        $stdout, $stderr = StringIO.new, StringIO.new
        begin
          status = GitTrim.new(gh_timeout: gh_timeout).run(argv)
          { status: status, stdout: $stdout.string, stderr: $stderr.string }
        ensure
          $stdout, $stderr = original_stdout, original_stderr
        end
      end
    end

    def rev(ref, dir = repo)
      %x{git -C #{dir} rev-parse #{ref}}.strip
    end

    # Points origin at a github.com URL (so git-trim will consult gh) while
    # insteadOf keeps fetches going to the local origin repo.
    def use_github_remote
      url = "https://github.com/example/repo.git"
      git(repo, "config", "remote.origin.url", url)
      git(repo, "config", "url.#{origin}.insteadOf", url)
    end

    # Installs a fake gh on PATH. `pr_list` is either an array of PRs to
    # return as JSON or a raw shell snippet. Every call is logged to gh_log.
    def install_fake_gh(auth_exit: 0, pr_list: [])
      use_github_remote
      body = if pr_list.is_a?(Array)
        json = File.join(@tmp, "prs.json")
        File.write(json, JSON.generate(pr_list))
        "/bin/cat #{json}"
      else
        pr_list
      end
      gh = File.join(@bin, "gh")
      File.write(gh, <<~SH)
        #!/bin/sh
        echo "$*" >> #{gh_log}
        case "$1 $2" in
          "auth status") exit #{auth_exit} ;;
          "pr list") #{body} ;;
          *) exit 1 ;;
        esac
      SH
      File.chmod(0755, gh)
    end

    def gh_calls
      File.exist?(gh_log) ? File.read(gh_log).split("\n") : []
    end

    def commit_file(dir, name, content, message = "add #{name}")
      File.write(File.join(dir, name), content)
      git(dir, "add", name)
      git(dir, "commit", "-m", message)
    end

    # A branch whose work landed on main as a squash commit identical to the
    # branch's combined diff.
    def squash_merge(branch)
      git(repo, "checkout", "-b", branch)
      commit_file(repo, "#{branch}-a.txt", "a")
      commit_file(repo, "#{branch}-b.txt", "b")
      git(repo, "checkout", "main")
      git(repo, "merge", "--squash", branch)
      git(repo, "commit", "-m", "#{branch} (#1)")
      commit_file(repo, "later.txt", "later work on main")
    end

    # A branch whose PR was squash-merged with an edit at merge time, so the
    # patch on main differs from the branch and only GitHub can prove it.
    def squash_merge_with_edit(branch)
      git(repo, "checkout", "-b", branch)
      commit_file(repo, "#{branch}.txt", "feature")
      git(repo, "checkout", "main")
      commit_file(repo, "#{branch}.txt", "feature, tweaked during merge", "#{branch} (#2)")
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

    it "falls back to origin/main when no local main exists" do
      git(repo, "checkout", "-b", "feature")
      git(repo, "branch", "-D", "main")
      git(repo, "branch", "merged-branch", "origin/main")
      run_trim
      expect(branches).not_to include("merged-branch")
      expect(branches).to include("feature")
    end

    it "warns and returns 1 when neither main nor origin/main exists" do
      git(repo, "checkout", "-b", "feature")
      git(repo, "branch", "-D", "main")
      git(repo, "remote", "remove", "origin")
      result = run_trim
      expect(result[:stderr]).to match(/neither 'main' nor 'origin\/main' exists/)
      expect(result[:status]).to eq(1)
    end

    it "skips dirty worktrees and keeps their branch" do
      wt = File.join(@tmp, "wt-dirty")
      git(repo, "worktree", "add", "-b", "dirty-wt-branch", wt, "main")
      File.write(File.join(wt, "untracked.txt"), "uncommitted")
      result = run_trim
      expect(branches).to include("dirty-wt-branch")
      expect(worktree_paths).to include(wt)
      expect(File).to exist(File.join(wt, "untracked.txt"))
      expect(result[:stdout]).to include("Skipping branch 'dirty-wt-branch': worktree at #{wt} has local changes")
      expect(result[:stdout]).not_to include("fatal")
    end

    describe "squash-merge detection" do
      it "deletes a squash-merged branch via the offline patch check" do
        squash_merge("squashed")
        result = run_trim
        expect(branches).not_to include("squashed")
        expect(result[:stdout]).to match(/Deleted branch squashed .*\[squash-merged into main/)
        expect(result[:status]).to eq(0)
      end

      it "does not consult gh when git alone proves every branch merged" do
        squash_merge("squashed")
        install_fake_gh
        run_trim
        expect(gh_calls).to be_empty
      end

      it "deletes a branch whose merged PR head matches the local tip" do
        squash_merge_with_edit("via-gh")
        install_fake_gh(pr_list: [{ number: 2, headRefName: "via-gh", headRefOid: rev("via-gh") }])
        result = run_trim
        expect(branches).not_to include("via-gh")
        expect(result[:stdout]).to match(/Deleted branch via-gh .*\[merged PR #2\]/)
        expect(result[:stderr]).to be_empty
      end

      it "fetches merged PRs in one batched gh call" do
        squash_merge_with_edit("first")
        squash_merge_with_edit("second")
        install_fake_gh(pr_list: [
          { number: 3, headRefName: "first", headRefOid: rev("first") },
          { number: 4, headRefName: "second", headRefOid: rev("second") },
        ])
        run_trim
        expect(branches).not_to include("first", "second")
        expect(gh_calls.grep(/^pr list/).size).to eq(1)
        expect(gh_calls.grep(/^pr list/).first).to include("--state merged")
      end

      it "keeps a branch with commits its merged PR never had" do
        squash_merge_with_edit("moved-on")
        pr_head = rev("moved-on")
        git(repo, "checkout", "moved-on")
        commit_file(repo, "follow-up.txt", "more work")
        git(repo, "checkout", "main")
        install_fake_gh(pr_list: [{ number: 5, headRefName: "moved-on", headRefOid: pr_head }])
        result = run_trim
        expect(branches).to include("moved-on")
        expect(result[:stdout]).to include("Skipping branch 'moved-on': it has commits that merged PR #5 never had")
      end

      it "keeps a branch whose upstream is gone when nothing proves it merged" do
        git(repo, "checkout", "-b", "abandoned")
        commit_file(repo, "abandoned.txt", "closed without merging")
        git(repo, "push", "-u", "origin", "abandoned")
        git(repo, "checkout", "main")
        git(repo, "push", "origin", "--delete", "abandoned")
        result = run_trim
        expect(branches).to include("abandoned")
        expect(result[:stdout]).to include("Keeping branch 'abandoned': its upstream is gone but nothing proves it was merged (possibly stale)")
      end
    end

    describe "detached worktrees" do
      it "removes a clean detached worktree whose HEAD is in main" do
        wt = File.join(@tmp, "wt-detached")
        git(repo, "worktree", "add", "--detach", wt, "main")
        result = run_trim
        expect(worktree_paths).not_to include(wt)
        expect(File).not_to exist(wt)
        expect(result[:stdout]).to include("Removed detached worktree #{wt} [HEAD is in main]")
      end

      it "removes a detached worktree at a merged PR's head" do
        squash_merge_with_edit("reviewed")
        head = rev("reviewed")
        wt = File.join(@tmp, "wt-review")
        git(repo, "worktree", "add", "--detach", wt, head)
        git(repo, "branch", "-D", "reviewed")
        install_fake_gh(pr_list: [{ number: 6, headRefName: "reviewed", headRefOid: head }])
        result = run_trim
        expect(worktree_paths).not_to include(wt)
        expect(result[:stdout]).to include("[HEAD is the head of merged PR #6]")
      end

      it "keeps a detached worktree whose HEAD is not merged" do
        git(repo, "checkout", "-b", "wip")
        commit_file(repo, "wip.txt", "wip")
        git(repo, "checkout", "main")
        wt = File.join(@tmp, "wt-wip")
        git(repo, "worktree", "add", "--detach", wt, "wip")
        run_trim
        expect(worktree_paths).to include(wt)
      end

      it "keeps a dirty detached worktree and says why" do
        wt = File.join(@tmp, "wt-dirty-detached")
        git(repo, "worktree", "add", "--detach", wt, "main")
        File.write(File.join(wt, "notes.txt"), "uncommitted")
        result = run_trim
        expect(worktree_paths).to include(wt)
        expect(File).to exist(File.join(wt, "notes.txt"))
        expect(result[:stdout]).to include("Skipping detached worktree at #{wt}: it has local changes")
      end

      it "never removes the detached worktree it is running from" do
        wt = File.join(@tmp, "wt-here")
        git(repo, "worktree", "add", "--detach", wt, "main")
        Dir.chdir(wt) do
          $stdout = StringIO.new
          begin
            GitTrim.new.run([])
          ensure
            $stdout = STDOUT
          end
        end
        expect(worktree_paths).to include(wt)
      end
    end

    describe "when gh is unavailable" do
      before { squash_merge_with_edit("needs-gh") }

      def expect_git_only_fallback(result, warning)
        expect(result[:status]).to eq(0)
        expect(branches).to include("needs-gh")
        warnings = result[:stderr].lines
        expect(warnings.size).to eq(1)
        expect(warnings.first).to include(warning)
        expect(warnings.first).to include("skipping GitHub PR check, using git-only detection")
      end

      it "warns once and falls back when gh is not installed" do
        use_github_remote
        git(repo, "branch", "plain-merged")
        squash_merge("still-trimmed")
        result = run_trim
        expect_git_only_fallback(result, "gh not installed")
        expect(branches).not_to include("plain-merged", "still-trimmed")
      end

      it "warns once and falls back when gh is not logged in" do
        install_fake_gh(auth_exit: 1, pr_list: [{ number: 7, headRefName: "needs-gh", headRefOid: rev("needs-gh") }])
        result = run_trim
        expect_git_only_fallback(result, "gh not logged in")
        expect(gh_calls.grep(/^pr list/)).to be_empty
      end

      it "warns once and falls back when gh has a token but can't verify it" do
        install_fake_gh(auth_exit: 1)
        File.write(File.join(@bin, "gh"), File.read(File.join(@bin, "gh")).sub(%q{"auth status")}, %q{"auth token") echo gho_fake ;; "auth status")}))
        expect_git_only_fallback(run_trim, "gh couldn't verify its login")
      end

      it "warns once and falls back when gh returns garbage JSON" do
        install_fake_gh(pr_list: "echo 'merged: yes {'")
        expect_git_only_fallback(run_trim, "gh returned unparseable output")
      end

      it "warns once and falls back when gh returns JSON of the wrong shape" do
        install_fake_gh(pr_list: %q{echo '[{"headRefName": "needs-gh"}]'})
        expect_git_only_fallback(run_trim, "gh returned unparseable output")
      end

      it "warns once and falls back when gh returns nothing" do
        install_fake_gh(pr_list: "exit 0")
        expect_git_only_fallback(run_trim, "gh returned unparseable output")
      end

      it "warns once and falls back when gh pr list fails" do
        install_fake_gh(pr_list: "echo 'API rate limit exceeded' >&2; exit 1")
        expect_git_only_fallback(run_trim, "GitHub API rate limit hit")
      end

      it "warns once and falls back when gh hangs" do
        install_fake_gh(pr_list: "exec /bin/sleep 30")
        result = nil
        elapsed = Timeout.timeout(20) do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result = run_trim(gh_timeout: 1)
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        end
        expect(elapsed).to be < 10
        expect_git_only_fallback(result, "gh timed out after 1s")
      end

      it "warns once and falls back when the remote is not on GitHub" do
        install_fake_gh(pr_list: [{ number: 8, headRefName: "needs-gh", headRefOid: rev("needs-gh") }])
        git(repo, "config", "remote.origin.url", origin)
        result = run_trim
        expect_git_only_fallback(result, "no GitHub remote")
        expect(gh_calls).to be_empty
      end

      it "skips gh entirely with --no-gh" do
        install_fake_gh(pr_list: [{ number: 9, headRefName: "needs-gh", headRefOid: rev("needs-gh") }])
        result = run_trim("--no-gh")
        expect(result[:status]).to eq(0)
        expect(result[:stderr]).to be_empty
        expect(branches).to include("needs-gh")
        expect(gh_calls).to be_empty
      end
    end

    describe "--dry-run" do
      it "reports what it would remove, and why, without changing anything" do
        git(repo, "branch", "plain-merged")
        squash_merge("squashed")
        squash_merge_with_edit("via-gh")
        wt_branch = File.join(@tmp, "wt-branch")
        git(repo, "worktree", "add", "-b", "wt-merged", wt_branch, "main")
        wt_detached = File.join(@tmp, "wt-detached")
        git(repo, "worktree", "add", "--detach", wt_detached, "main")
        install_fake_gh(pr_list: [{ number: 10, headRefName: "via-gh", headRefOid: rev("via-gh") }])

        branches_before = branches
        worktrees_before = worktree_paths
        result = run_trim("--dry-run")

        expect(result[:status]).to eq(0)
        expect(branches).to eq(branches_before)
        expect(worktree_paths).to eq(worktrees_before)
        expect(result[:stdout]).to include("Would delete branch plain-merged (merged into main)")
        expect(result[:stdout]).to include("Would delete branch squashed (squash-merged into main")
        expect(result[:stdout]).to include("Would delete branch via-gh (merged PR #10)")
        expect(result[:stdout]).to include("Would remove worktree #{wt_branch} (merged into main)")
        expect(result[:stdout]).to include("Would remove detached worktree #{wt_detached} (HEAD is in main)")
      end
    end

    it "prints its version with --version" do
      result = run_trim("--version")
      expect(result[:status]).to eq(0)
      expect(result[:stdout]).to eq("git-trim #{GitTrim::VERSION}\n")
    end

    it "rejects unknown options" do
      result = run_trim("--bogus")
      expect(result[:status]).to eq(1)
      expect(result[:stderr]).to include("invalid option: --bogus")
    end

    it "finds .git-protected-branches in a parent directory" do
      git(repo, "branch", "staging")
      File.write(File.join(@tmp, ".git-protected-branches"), "staging\n")
      run_trim
      expect(branches).to include("staging")
    end
  end
end
