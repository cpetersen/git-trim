require "git-trim/version"
require "json"
require "open3"
require "optparse"
require "shellwords"

class GitTrim
  GH_TIMEOUT = 15
  GH_PR_LIMIT = 1000

  # gh must never stop to ask a question: no prompts, no update notices,
  # no spinner, no colour codes in the JSON.
  GH_ENV = {
    "GH_PROMPT_DISABLED" => "1",
    "GH_NO_UPDATE_NOTIFIER" => "1",
    "GH_SPINNER_DISABLED" => "1",
    "NO_COLOR" => "1",
  }.freeze

  # Identity for the throwaway commit built by the offline squash check, so it
  # works even when user.name/user.email aren't configured.
  TMP_COMMIT_ENV = {
    "GIT_AUTHOR_NAME" => "git-trim",
    "GIT_AUTHOR_EMAIL" => "git-trim@localhost",
    "GIT_COMMITTER_NAME" => "git-trim",
    "GIT_COMMITTER_EMAIL" => "git-trim@localhost",
  }.freeze

  # Why a branch counts as merged. Only a regular merge can use `git branch
  # -d`; git refuses -d for squash-merged branches, so the other proofs force.
  Proof = Struct.new(:reason, :force)

  def initialize(gh_timeout: GH_TIMEOUT)
    @gh_timeout = gh_timeout
  end

  def run(argv=nil)
    @dry_run = false
    @use_gh = true
    help = false
    version = false
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: git trim [--dry-run] [--no-gh]"
      opts.on("-n", "--dry-run", "Show what would be removed, and why, without changing anything") { @dry_run = true }
      opts.on("--[no-]gh", "Use the GitHub CLI to detect merged PRs (default: on when available)") { |value| @use_gh = value }
      opts.on("-v", "--version", "Show the version") { version = true }
      opts.on("-h", "--help", "Show this help") { help = true }
    end
    begin
      parser.parse(argv || [])
    rescue OptionParser::ParseError => e
      warn "git-trim: #{e.message}"
      warn parser.banner
      return 1
    end
    if help
      puts parser
      return 0
    end
    if version
      puts "git-trim #{VERSION}"
      return 0
    end
    remove_instance_variable(:@merged_prs) if defined?(@merged_prs)

    %x{git fetch -ap}

    protected_branches = read_protected_branches
    protected_branches << "main"

    base = base_ref
    unless base
      warn "git-trim: neither 'main' nor 'origin/main' exists; nothing to trim against"
      return 1
    end

    worktrees = linked_worktrees
    branch_worktrees = worktrees.select { |wt| wt[:branch] }.to_h { |wt| [wt[:branch], wt[:path]] }

    merged = %x{git branch --merged #{Shellwords.escape(base)} --format='%(refname:short)'}.split("\n").collect(&:strip)
    excluded = protected_branches + [current_branch, main_worktree_branch].compact

    local_branches.each do |branch|
      next if excluded.include?(branch[:name])

      proof = merge_proof(branch, base, merged)
      if proof.is_a?(Proof)
        trim_branch(branch[:name], proof, branch_worktrees[branch[:name]])
      elsif proof.nil? && branch[:gone]
        puts "Keeping branch '#{branch[:name]}': its upstream is gone but nothing proves it was merged (possibly stale)"
      end
    end

    here = current_worktree
    worktrees.select { |wt| wt[:detached] }.each do |wt|
      next if same_path?(wt[:path], here)
      reason = detached_merge_reason(wt[:head], base)
      trim_detached_worktree(wt[:path], reason) if reason
    end

    0
  end

  def current_branch
    %x{git branch --show-current}.strip
  end

  # Local main when it exists; otherwise origin/main (e.g. bare-repo +
  # worktrees layouts where no local main is checked out). Nil if neither.
  def base_ref
    ["main", "origin/main"].find do |ref|
      %x{git rev-parse --verify --quiet #{Shellwords.escape(ref)}}
      $?.success?
    end
  end

  # Linked worktrees as {path:, branch:, head:, detached:}. The first entry
  # in `git worktree list` is the main worktree, which is never removable.
  def linked_worktrees
    worktree_entries.drop(1)
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

  private

  def read_protected_branches
    path = find_file(".git-protected-branches")
    return [] unless path
    File.read(path).split("\n").collect(&:strip).reject(&:empty?)
  end

  def worktree_entries
    %x{git worktree list --porcelain}.split("\n\n").collect do |entry|
      {
        path: entry[/^worktree (.+)$/, 1],
        branch: entry[/^branch refs\/heads\/(.+)$/, 1],
        head: entry[/^HEAD (\h+)$/, 1],
        detached: entry.match?(/^detached$/),
      }
    end.select { |wt| wt[:path] }
  end

  def main_worktree_branch
    worktree_entries.first&.fetch(:branch)
  end

  def current_worktree
    git("rev-parse", "--show-toplevel")
  end

  def same_path?(a, b)
    return false unless a && b
    File.realpath(a) == File.realpath(b)
  rescue SystemCallError
    a == b
  end

  def local_branches
    format = "%(refname:short)%09%(objectname)%09%(upstream:track)"
    %x{git for-each-ref refs/heads --format=#{Shellwords.escape(format)}}.split("\n").collect do |line|
      name, tip, track = line.split("\t")
      { name: name, tip: tip, gone: track.to_s.include?("gone") }
    end
  end

  # A Proof when some signal shows the branch is merged into base; :mismatch
  # when a merged PR exists but the local branch has moved on (already
  # reported); nil when there's no evidence either way.
  def merge_proof(branch, base, merged)
    return Proof.new("merged into #{base}", false) if merged.include?(branch[:name])
    return Proof.new("squash-merged into #{base} (patch already in #{base})", true) if squash_merged?(base, branch[:tip])
    github_merge_proof(branch)
  end

  # Offline squash detection: collapse the branch into one commit on top of
  # its merge base, then ask `git cherry` whether base already has an
  # equivalent patch. A leading "-" means it does.
  def squash_merged?(base, tip)
    merge_base = git("merge-base", base, tip) or return false
    tree = git("rev-parse", "#{tip}^{tree}") or return false
    # Nothing to compare when the branch makes no net change.
    return false if tree == git("rev-parse", "#{merge_base}^{tree}")
    tmp = git("commit-tree", tree, "-p", merge_base, "-m", "_", env: TMP_COMMIT_ENV) or return false
    cherry = git("cherry", base, tmp) or return false
    cherry.start_with?("-")
  end

  # Proof from GitHub: a merged PR for this branch name whose head is exactly
  # the local tip. A merged PR at a different commit is not proof.
  def github_merge_proof(branch)
    prs = merged_prs or return nil
    matching = prs.select { |pr| pr["headRefName"] == branch[:name] }
    return nil if matching.empty?

    if (pr = matching.find { |candidate| candidate["headRefOid"] == branch[:tip] })
      return Proof.new("merged PR ##{pr["number"]}", true)
    end

    pr = matching.first
    if ancestor?(pr["headRefOid"], branch[:tip])
      puts "Skipping branch '#{branch[:name]}': it has commits that merged PR ##{pr["number"]} never had"
    else
      puts "Skipping branch '#{branch[:name]}': its tip doesn't match the head of merged PR ##{pr["number"]}"
    end
    :mismatch
  end

  def detached_merge_reason(head, base)
    return nil unless head
    return "HEAD is in #{base}" if ancestor?(head, base)
    pr = merged_prs&.find { |candidate| candidate["headRefOid"] == head }
    "HEAD is the head of merged PR ##{pr["number"]}" if pr
  end

  def trim_branch(name, proof, worktree_path)
    if @dry_run
      if worktree_path && dirty?(worktree_path)
        puts "Would skip branch '#{name}': worktree at #{worktree_path} has local changes"
        return
      end
      puts "Would remove worktree #{worktree_path} (#{proof.reason})" if worktree_path
      puts "Would delete branch #{name} (#{proof.reason})"
      return
    end

    if worktree_path
      output = %x{git worktree remove #{Shellwords.escape(worktree_path)} 2>&1}
      unless $?.success?
        if output.include?("contains modified or untracked files")
          puts "Skipping branch '#{name}': worktree at #{worktree_path} has local changes"
        else
          puts "Skipping branch '#{name}': could not remove worktree at #{worktree_path}"
          puts output
        end
        return
      end
      puts "Removed worktree #{worktree_path}"
    end

    flag = proof.force ? "-D" : "-d"
    output = %x{git branch #{flag} #{Shellwords.escape(name)} 2>&1}
    if $?.success?
      puts "#{output.strip} [#{proof.reason}]"
    else
      puts "Skipping branch '#{name}': could not delete it"
      puts output
    end
  end

  def trim_detached_worktree(path, reason)
    if @dry_run
      if dirty?(path)
        puts "Would skip detached worktree at #{path}: it has local changes"
      else
        puts "Would remove detached worktree #{path} (#{reason})"
      end
      return
    end

    output = %x{git worktree remove #{Shellwords.escape(path)} 2>&1}
    if $?.success?
      puts "Removed detached worktree #{path} [#{reason}]"
    elsif output.include?("contains modified or untracked files")
      puts "Skipping detached worktree at #{path}: it has local changes"
    else
      puts "Skipping detached worktree at #{path}: could not remove it"
      puts output
    end
  end

  def dirty?(path)
    status = git("-C", path, "status", "--porcelain")
    status.nil? || !status.empty?
  end

  def ancestor?(commit, descendant)
    _, _, status = Open3.capture3("git", "merge-base", "--is-ancestor", commit, descendant)
    status.success?
  end

  # Stripped stdout of a git command, or nil if it failed.
  def git(*args, env: {})
    out, _, status = Open3.capture3(env, "git", *args)
    out.strip if status.success?
  end

  # Merged PRs from GitHub as [{"number", "headRefName", "headRefOid"}], or
  # nil when gh can't give a trustworthy answer. Fetched at most once, and
  # only if some branch or worktree actually needs it.
  def merged_prs
    return @merged_prs if defined?(@merged_prs)
    @merged_prs = fetch_merged_prs
  end

  def fetch_merged_prs
    return nil unless @use_gh
    return gh_unavailable("gh not installed") unless system("command -v gh >/dev/null 2>&1")
    return gh_unavailable("no GitHub remote") unless github_remote?

    status, = gh("auth", "status")
    return gh_unavailable("gh timed out after #{@gh_timeout}s") if status == :timeout
    unless status&.success?
      # `auth status` checks the token online and reports a network failure
      # as an invalid token. `auth token` is offline, so it tells "never
      # logged in" apart from "logged in but couldn't verify".
      token_status, = gh("auth", "token")
      return gh_unavailable("gh not logged in") unless token_status.is_a?(Process::Status) && token_status.success?
      return gh_unavailable("gh couldn't verify its login (GitHub unreachable or token rejected)")
    end

    status, out, err = gh("pr", "list", "--state", "merged", "--limit", GH_PR_LIMIT.to_s,
                          "--json", "number,headRefName,headRefOid")
    return gh_unavailable("gh timed out after #{@gh_timeout}s") if status == :timeout
    return gh_unavailable(gh_failure(err)) unless status&.success?

    parse_prs(out) || gh_unavailable("gh returned unparseable output")
  end

  def gh_unavailable(reason)
    warn "git-trim: #{reason}; skipping GitHub PR check, using git-only detection"
    nil
  end

  def gh_failure(stderr)
    case stderr
    when /rate limit/i then "GitHub API rate limit hit"
    when /could not resolve|no such host|dial tcp|connection refused|network is unreachable|i\/o timeout|tls/i
      "can't reach GitHub"
    else "gh pr list failed"
    end
  end

  # Raw remote URLs (not insteadOf-rewritten), since gh resolves the repo
  # from those too.
  def github_remote?
    hosts = ["github.com", ENV["GH_HOST"]].compact.reject(&:empty?)
    urls = git("config", "--get-regexp", '^remote\..*\.url$').to_s.split("\n")
    urls.any? { |line| hosts.any? { |host| line.include?(host) } }
  end

  # An error, empty output or a malformed payload is never evidence.
  def parse_prs(json)
    prs = JSON.parse(json)
    return nil unless prs.is_a?(Array)
    valid = prs.all? do |pr|
      pr.is_a?(Hash) && pr["headRefName"].is_a?(String) && !pr["headRefName"].empty? &&
        pr["headRefOid"].is_a?(String) && pr["headRefOid"].match?(/\A(\h{40}|\h{64})\z/)
    end
    prs if valid
  rescue JSON::ParserError
    nil
  end

  # Runs gh with no TTY and a hard deadline. Returns [status, stdout, stderr],
  # with status :timeout if gh was killed, or nil if it couldn't start.
  def gh(*args)
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    begin
      pid = Process.spawn(GH_ENV, "gh", *args, in: File::NULL, out: out_w, err: err_w, pgroup: true)
    rescue SystemCallError
      return [nil, "", ""]
    ensure
      out_w.close
      err_w.close
    end

    readers = [out_r, err_r].collect { |io| Thread.new { io.read } }
    waiter = Thread.new { Process.wait2(pid).last }
    status = if waiter.join(@gh_timeout)
      waiter.value
    else
      # Kill the whole process group so children holding the pipes die too.
      begin
        Process.kill("KILL", -pid)
      rescue SystemCallError
        nil
      end
      waiter.join
      :timeout
    end
    [status, *readers.collect(&:value)]
  ensure
    out_r&.close
    err_r&.close
  end
end
