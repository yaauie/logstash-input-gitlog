# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require 'set'

require "rjgit"

require 'java'

# Generate a repeating message.
#
# This plugin is intented only as an example.

class LogStash::Inputs::Gitlog < LogStash::Inputs::Base

  import 'org.eclipse.jgit.revwalk.RevWalk'
  import 'org.eclipse.jgit.revwalk.RevSort'

  config_name "gitlog"

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, "plain"

  config :path, :validate => :string, :required => true

  config :head, :validate => :string, :default => 'master'

  config :limit, :validate => :number, :default => nil

  config :diff, :validate => :boolean, :default => false

  config :delay, :validate => :number, :default => nil


  public
  def register
    # ensure that configured `@path` points to a real file path
    unless File.exists?(@path)
      logger.error("path not found: `#{@path}`")
      fail "path not found: `#{@path}`"
    end

    # ensure that configured `@path` points to a valid git repository
    @repo = RJGit::Repo.new(@path)
    unless @repo.valid?
      logger.error("not a valid git repository `#{@path}`")
      fail "not a valid git repository `#{@path}`"
    end

    # ensure that configured `@head` is a valid head reference
    branch_head = @repo.jrepo.resolve(@head)
    if branch_head.nil?
      logger.error("not a valid branch, tag, or commit reference `#{@head}`", path: @path)
      fail "not a valid branch, tag, or commit reference `#{@head}`"
    else
      logger.debug("resolved head `#{@head}` to `#{branch_head.get_name}`", path: @path)
    end
  end # def register

  def run(queue)
    # delay-tactic enables testability
    unless @delay.nil?
      logger.info("delaying for `#{delay}` seconds...")
      sleep(@delay)
    end

    unprocessed_commits = Set.new

    commits.each do |commit|
      # we can abort the loop if stop? becomes true
      break if stop?

      hevent = {
        "id"             => commit.id,
        "parents"        => commit.parents.map(&:id),
        "actor"          => {
          "name" => commit.actor.name,
          "email" => commit.actor.email,
        },
        "committer"      => {
          "name" => commit.committer.name,
          "email" => commit.committer.email,
        },
        "authored_date"  => commit.authored_date,
        "committed_date" => commit.committed_date,
        "message"        => commit.message,
        "short_message"  => commit.short_message,
      }

      # add diffs only if enabled
      hevent["diffs"]= commit.diffs if @diffs

      logger.trace("Created event from commit", event: hevent)

      event = LogStash::Event.new(hevent)

      decorate(event)
      queue << event

      # dragons: tracking unprocessed commits in this manner requires
      # topographic children-before-parents processing.
      commit.parents.each do |parent|
        unprocessed_commits.add(parent.id)
      end
      unprocessed_commits.delete(commit.id)
    end # loop

    unless unprocessed_commits.empty?
      logger.debug("unprocessed commits", commits: unprocessed_commits)
    end
  end # def run


  def stop
    # nothing to do in this case so it is not necessary to define stop
    # examples of common "stop" tasks:
    #  * close sockets (unblocking blocking reads/accepts)
    #  * cleanup temporary files
    #  * terminate spawned threads
  end

  private

  # returns a lazy Enumerator that will walk upwards on the repo from the configured `@head`,
  # following all parents and respecting `@limit`.
  #
  # @return [Enumerator::Lazy<RJGit::Commit>] if no block given
  # @yieldparam commit [RJGit::Commit]
  # @yieldreturn [Object]
  def commits
    return enum_for(:commits).lazy unless block_given?

    jrepo = @repo.jrepo
    objhead = jrepo.resolve(@head)
    walk = RevWalk.new(jrepo)

    # dragons: the way unprocessed children are tracked requires TOPO ordering to be enabled
    walk.sort(RevSort::TOPO, true)
    walk.sort(RevSort::COMMIT_TIME_DESC, true)

    root = walk.parse_commit(objhead)
    walk.mark_start(root)

    loop.with_index do |_, index|
      logger.debug("crawling commits", index: index) if (index%1000).zero?

      if @limit && (index >= @limit)
        logger.info("crawl limit reached", index: index)
        break
      end

      jcommit = walk.next
      if jcommit.nil?
        logger.info("crawl complete", index: index)
        break
      end

      yield(RJGit::Commit.new(@repo, jcommit))
    end
  end
end # class LogStash::Inputs::Gitlog
