require 'digest'

class Tasklet
  attr_reader :build_task_id, :build_id, :build_stage, :build_task, :runner_name, :pod_name, :container_name, :container_details, :log_filename, :workdir, :cachedir, :logfile

  # called in the parent process
  def initialize(build_task_id:, build_id:, build_stage:, build_task:, runner_name:, pod_name:, container_name:, container_details:, log_filename:, workdir:, cachedir:)
    @build_task_id = build_task_id
    @build_id = build_id
    @build_stage = build_stage
    @build_task = build_task
    @runner_name = runner_name
    @pod_name = pod_name
    @container_name = container_name
    @container_details = container_details
    @log_filename = log_filename
    @workdir = workdir
    @cachedir = cachedir
  end

  def spawn_and_run
    @logfile = File.open(log_filename, "a+").tap { |file| file.sync = true }
    begin
      @pid = fork { call }
    ensure
      @logfile.close
      @logfile = nil
    end
  end

  def output
    File.read(log_filename)
  end

  def stop
    Process.kill("TERM", @pid) if @pid
  rescue Errno::ESRCH
  end

  def kill
    Process.kill("KILL", @pid) if @pid
  rescue Errno::ESRCH
  end

  def finished(process_status, running_tasklets)
  end

  def exec(*args)
    log("Running", *args)
    super
  end

  def system(*args, exit_on_failure: true)
    log("Running", *args)
    super(*args)
    exit $?.exitstatus if exit_on_failure && !$?.success?
  end

  def log(*args)
    args.pop if args.last.is_a?(Hash)
    (logfile || STDOUT).puts("#{TaskRunner.timestamp} #{args.join ' '}")
  rescue IOError
    STDERR.puts "#{TaskRunner.timestamp} Got #{$!.to_s.inspect} error trying to log the message #{args.join(' ').inspect} to #{log_filename}"
  end

  # subclasses must implement the #call method, which will be called in the spawned child process and should never return
end

class BuildImageTasklet < Tasklet
  def to_s
    "task #{build_task_id} build image #{container_details["image_name"].inspect} from #{container_details["repository_uri"].inspect} branch #{container_details["branch"].inspect} dockerfile #{container_details["dockerfile"].inspect}"
  end

  def call
    if Dir.exist?(repository_cache_path)
      log "Updating #{container_details["repository_uri"]}"
      Dir.chdir(repository_cache_path) { system("git", "fetch", [:out, :err] => logfile) }
    else
      log "Cloning #{container_details["repository_uri"]}"
      system("git", "clone", "--mirror", container_details["repository_uri"], repository_cache_path, [:out, :err] => logfile)
    end

    log "Cloning cached repository and checking out branch #{container_details["branch"]}"
    FileUtils.rm_r(workdir) if File.exist?(workdir)
    system("git", "clone", "--branch", container_details["branch"], repository_cache_path, workdir, [:out, :err] => logfile)

    Dir.chdir(workdir) { system("git", "log", "-n1", "--oneline", [:out, :err] => logfile) }

    dockerfile = "#{workdir}/#{container_details["dockerfile"]}"
    unless File.exist?(dockerfile)
      log "Couldn't see a dockerfile named #{container_details["dockerfile"]} in the repository #{container_details["repository_uri"]} on branch #{container_details["branch"]}"
      exit 1
    end

    # we need to cache the bundle because nothing outside the build context will be available during
    # the docker build, and we would otherwise have to put the deploy key in the docker build.  we
    # also want to reuse gem downloads whereever possible, even if one of the other gems has changed,
    # which isn't possible inside the docker build (you can use a volume at runtime, but not in build).
    # FUTURE: extract this to a generic build hook mechanism, or have a "meta" docker builder container
    package_bundle if File.exist?("#{workdir}/Gemfile.lock")

    log "Building #{container_details["image_name"]} using dockerfile #{container_details["dockerfile"]}"
    args = []

    args << "-t"
    args << container_details["image_name"]

    args << "-f"
    args << dockerfile

    if container_details["build_args"]
      Array(container_details["build_args"]).each do |key, value|
        args << "--build-arg"
        args << "#{key}=#{value}"
      end
    end

    %w(http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY).each do |build_env_var|
      if ENV[build_env_var]
        args << "--build-arg"
        args << "#{build_env_var}=#{ENV[build_env_var]}"
      end
    end

    args << workdir

    system("docker", "build", *args, [:out, :err] => logfile, exit_on_failure: false)
    log "Building #{container_details["image_name"]} #{$?.success? ? "completed successfully" : "failed"}"
    exit $?.exitstatus
  end

  def repository_cache_path
    @repository_cache_path ||= "#{cachedir}/repository/#{Digest::SHA256.hexdigest container_details["repository_uri"]}"
  end

  def package_bundle
    log "Packaging bundle for #{container_details["image_name"]}"

    # we want the gem cache to persist across builds, so we rsync to and from a persistent cache
    # directory.  the alternative would be to make vendor/cache point to the persistent cache, but this
    # would have the downside that when two different sets of gems are being installed by different
    # branches, packaging one would wipe the different gems from the other; there is a --no-prune option
    # to address this, but unfortunately that would have a different downside: then when another gem is
    # added by another branch, it would invalidate the docker layer cache, because the new file would be
    # added by the Dockerfile step that copies in vendor/cache.
    gem_cache_dir = "#{cachedir}/gems/"
    bundle_package_dir = "#{workdir}/vendor/cache/"
    FileUtils.mkdir_p(gem_cache_dir)
    FileUtils.mkdir_p(bundle_package_dir)
    system("rsync", "-ra", "--delete", gem_cache_dir, bundle_package_dir,     [:out, :err] => logfile)

    # download but don't install the gems
    Dir.chdir(workdir) { system("bundle", "package", "--all", "--no-install", [:out, :err] => logfile) }

    # we then reset the timestamps because bundle package --all has to copy the files installed from
    # git gems directly and it always touches their timestamps, which would then make docker's COPY
    # command think the gems directory has changed and would cause it to reinstall rather than using
    # the image of that step from last time.
    system("find #{bundle_package_dir} | xargs touch -t 200001010000.00",     [:out, :err] => logfile)

    system("rsync", "-ra", bundle_package_dir, gem_cache_dir,                 [:out, :err] => logfile)
  end
end

class PushImageTasklet < Tasklet
  def to_s
    "task #{build_task_id} push image #{container_details["image_name"].inspect}"
  end

  def call
    exec("docker", "push", container_details["image_name"], [:out, :err] => logfile)
  end
end

class PullImageTasklet < Tasklet
  def to_s
    "task #{build_task_id} pull image #{container_details["image_name"].inspect}"
  end

  def call
    system("docker", "inspect", container_details["image_name"], [:out, :err] => "/dev/null", exit_on_failure: false)

    unless $?.success?
      exec("docker", "pull", container_details["image_name"], [:out, :err] => logfile)
    end
  end
end

class RunImageTasklet < Tasklet
  def to_s
    "task #{build_task_id} run image #{container_details["image_name"].inspect} in pod #{pod_name.inspect}"
  end

  def call
    command = ["docker", "run", "--rm", "-a", "STDOUT", "-a", "STDERR"]

    command << "--network"
    command << pod_name

    command << "--name"
    command << "#{pod_name}_#{container_name}"

    command << "--network-alias"
    command << container_name

    command << "--hostname"
    command << (container_details["hostname"] || container_name)

    if container_details["runtime_env"]
      Array(container_details["runtime_env"]).each do |key, value|
        command << "--env"
        command << "#{key}=#{value}"
      end
    end

    command << "--env"
    command << "CI_SERVICE_URL=#{ENV["CI_SERVICE_URL"]}"

    command << "--env"
    command << "RUNNER_NAME=#{runner_name}"

    command << "--env"
    command << "POD_NAME=#{pod_name}"

    command << "--env"
    command << "CONTAINER_NAME=#{container_name}"

    command << "--env"
    command << "BUILD_TASK_ID=#{build_task_id}"

    command << "--env"
    command << "BUILD_ID=#{build_id}"

    command << "--env"
    command << "BUILD_STAGE=#{build_stage}"

    command << "--env"
    command << "BUILD_TASK=#{build_task}"

    if container_details["tmpfs"]
      command << "--tmpfs"
      command << container_details["tmpfs"]
    end

    command << container_details["image_name"]

    if container_details["cmd"]
      command.concat Array(container_details["cmd"])
    end

    exec(*command, [:out, :err] => logfile)
  end

  def finished(process_status, running_tasklets)
    # stop all the other containers in the pod.  we could use running_tasklets.values.each(&:stop) but
    # docker stop is better as it has the automatic fallback to kill the container after 10s.
    system "docker stop $(docker ps --quiet --filter network=#{pod_name})", [:out, :err] => "/dev/null", exit_on_failure: false
  end
end
