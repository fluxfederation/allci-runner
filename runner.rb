#!/usr/bin/env ruby

require 'net/http'
require 'net/https'
require 'json'
require 'fileutils'
require 'tempfile'
require 'pp'

class ServiceClient
  def initialize(service_url, standard_params)
    @service_url = URI(service_url)
    @http = Net::HTTP.new(@service_url.hostname, @service_url.port)
    @standard_params = standard_params
  end

  def request(path, json_params = {})
    req = Net::HTTP::Post.new(path)
    req.body = @standard_params.merge(json_params).to_json
    req.content_type = 'application/json'
    @http.request(req)
  end
end

class Tasklet
  attr_reader :task_id, :pod_name, :container_name, :container_details, :log_filename, :workdir, :log

  # called in the parent process
  def initialize(task_id:, pod_name:, container_name:, container_details:, log_filename:, workdir:)
    @task_id = task_id
    @pod_name = pod_name
    @container_name = container_name
    @container_details = container_details
    @log_filename = log_filename
    @workdir = workdir
  end

  def spawn_and_run
    @log = File.open(log_filename, "w+").tap { |file| file.sync = true }
    begin
      @pid = fork { call }
    ensure
      @log.close
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

  # subclasses must implement the #call method, which will be called in the spawned child process and should never return
end

class BuildImageTasklet < Tasklet
  def to_s
    "build image #{container_details["image_name"].inspect} from #{container_details["repository_uri"].inspect} branch #{container_details["branch"].inspect} dockerfile #{container_details["dockerfile"].inspect}"
  end

  def call
    dockerfile = "#{workdir}/#{container_details["dockerfile"]}"

    log.puts "Cloning #{container_details["repository_uri"]} and checking out branch #{container_details["branch"]}"
    system("git", "clone", "--branch", container_details["branch"], container_details["repository_uri"], workdir, [:out, :err] => log)
    exit $?.exitstatus unless $?.success?

    unless File.exist?(dockerfile)
      log.puts "Couldn't see a dockerfile named #{container_details["dockerfile"]} in the repository #{container_details["repository_uri"]} on branch #{container_details["branch"]}"
      exit 1
    end

    log.puts "Building #{container_details["image_name"]} using dockerfile #{container_details["dockerfile"]}"
    system("docker", "build", "-t", container_details["image_name"], "-f", dockerfile, workdir, [:out, :err] => log)
    exit $?.exitstatus
  end
end

class PushImageTasklet < Tasklet
  def to_s
    "push image #{container_details["image_name"].inspect}"
  end

  def call
    exec("docker", "push", container_details["image_name"], [:out, :err] => log)
  end
end

class PullImageTasklet < Tasklet
  def to_s
    "pull image #{container_details["image_name"].inspect}"
  end

  def call
    exec("docker", "pull", container_details["image_name"], [:out, :err] => log)
  end
end

class RunImageTasklet < Tasklet
  def to_s
    "run image #{container_details["image_name"].inspect} in pod #{pod_name.inspect}"
  end

  def call
    args = ["--rm", "-a", "STDOUT", "-a", "STDERR"]

    args << "--network"
    args << pod_name

    args << "--name"
    args << "#{pod_name}_#{container_name}"

    args << "--network-alias"
    args << container_name

    args << "--hostname"
    args << (container_details["hostname"] || container_name)

    if container_details["env"]
      Array(container_details["env"]).each do |key, value|
        args << "--env"
        args << "#{key}=#{value}"
      end
    end

    args << container_details["image_name"]

    if container_details["cmd"]
      args.concat Array(container_details["cmd"])
    end

    exec("docker", "run", *args, [:out, :err] => log)
  end

  def finished(process_status, running_tasklets)
    # stop all the other containers in the pod.  we could use running_tasklets.values.each(&:stop) but
    # docker stop is better as it has the automatic fallback to kill the container after 10s.
    system "docker stop $(docker ps --quiet --filter network=#{pod_name})", [:out, :err] => "/dev/null"
  end
end

class TaskRunner
  attr_reader :task, :pod_name, :buildroot

  def initialize(task:, pod_name:, buildroot:)
    @task = task
    @pod_name = pod_name
    @buildroot = buildroot

    @workdir = "#{buildroot}/workdir"
    reset_workdir
  end

  def create_pod
    system "docker network create --driver bridge #{pod_name}", [:out, :err] => "/dev/null"
  end

  def remove_pod
    system "docker rm -f $(docker ps --quiet --filter network=#{pod_name}); docker network rm #{pod_name}", [:out, :err] => "/dev/null"
  end

  def run(klass)
    # instantiate one tasklet object per component (ie. container)
    tasklets = task["components"].collect do |container_name, container_details|
      klass.new(
        task_id: task["task_id"],
        pod_name: pod_name,
        container_name: container_name,
        container_details: container_details,
        log_filename: logfile_for(container_name),
        workdir: workdir_for(container_name))
    end

    # fork and run each tasklet
    running_tasklets = tasklets.each_with_object({}) do |tasklet, results|
      puts "task #{tasklet.task_id} tasklet #{tasklet} starting."
      results[tasklet.spawn_and_run] = tasklet
    end

    # if we fail to spawn a child process, we've already failed
    success = running_tasklets[nil].nil?

    # otherwise, we wait for them all to exit
    output = {}
    exit_code = {}
    while !running_tasklets.empty? do
      # wait for the first one of them to exit
      exited_child, process_status = Process.wait2
      tasklet = running_tasklets.delete(exited_child)
      output[tasklet.container_name] = tasklet.output
      exit_code[tasklet.container_name] = process_status.exitstatus
      success &= process_status.success?

      if process_status.success?
        puts "task #{tasklet.task_id} tasklet #{tasklet} successful."
      else
        puts "task #{tasklet.task_id} tasklet #{tasklet} failed with exit code #{exit_code[tasklet.container_name]}.  container output:\n\n\t#{output[tasklet.container_name].gsub "\n", "\n\t"}"
      end

      # depending on the tasklet, it may then tell all the others to stop
      tasklet.finished(process_status, running_tasklets)
    end

    [success, output, exit_code]
  end

protected
  def workdir
    @workdir ||= File.join(buildroot, "workdir")
  end

  def logfile_for(container_name)
    File.join(workdir, "#{container_name.tr('^A-Za-z0-9_', '_')}.log")
  end

  def workdir_for(container_name)
    File.join(workdir, container_name.tr('^A-Za-z0-9_', '_'))
  end

  def reset_workdir
    FileUtils.rm_rf(workdir)
    FileUtils.mkdir_p(workdir)

    task["components"].each do |container_name, container_details|
      FileUtils.mkdir_p(workdir_for(container_name))
    end
  end
end

raise("must specify the CI service URL in CI_SERVICE_URL") unless ENV["CI_SERVICE_URL"]
runner_name = ENV["RUNNER_NAME"] || Socket.gethostname
client = ServiceClient.new(ENV["CI_SERVICE_URL"], "runner_name": runner_name)

pod_name = "allci-runner"
buildroot = "tmp/build"

poll_frequency = ENV["CI_POLL_FREQUENCY"].to_i
poll_frequency = 5 if poll_frequency.zero?

failed_poll_frequency = ENV["CI_FAILED_POLL_FREQUENCY"].to_i
failed_poll_frequency = poll_frequency if failed_poll_frequency.zero?

loop do
  response = client.request("/tasks/pull")

  if response.is_a?(Net::HTTPOK)
    task = JSON.parse(response.body)
    puts "task #{task["task_id"]} stage #{task["stage"]} task #{task["task"]} assigned"

    task_runner = TaskRunner.new(task: task, pod_name: pod_name, buildroot: buildroot)
    task_runner.create_pod

    if task["stage"] == "bootstrap"
      success, output, exit_code = task_runner.run(BuildImageTasklet)
      success, output, exit_code = task_runner.run(PushImageTasklet) if success
      success, output, exit_code = task_runner.run(RunImageTasklet) if success
    else
      success, output, exit_code = task_runner.run(PullImageTasklet)
      success, output, exit_code = task_runner.run(RunImageTasklet) if success
    end

    task_runner.remove_pod

    puts "task #{task["task_id"]} finished, #{success ? 'success' : 'failed'}"
    if success
      client.request("/tasks/success", "task_id" => task["task_id"], "output" => output, "exit_code" => exit_code)
    else
      client.request("/tasks/failed", "task_id" => task["task_id"], "output" => output, "exit_code" => exit_code)
    end
  elsif response.is_a?(Net::HTTPNoContent)
    puts "no tasks to run"
    sleep poll_frequency
  else
    STDERR.puts response.inspect
    sleep failed_poll_frequency
  end
end
