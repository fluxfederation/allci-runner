#!/usr/bin/env ruby

$LOAD_PATH.unshift '.'

require 'fileutils'
require 'tempfile'
require 'allci_client'
require 'task_runner'
require 'tasklets'

service_url = ENV["CI_SERVICE_URL"] or raise("must specify the CI service URL in CI_SERVICE_URL")
runner_name = ENV["RUNNER_NAME"] || Socket.gethostname
pod_name = "#{runner_name.sub(/^[^a-zA-Z0-9]/, '_').gsub(/[^a-zA-Z0-9_.-]/, '_')}"
client = AllciClient.new(service_url, runner_name)

build_root = ENV["BUILD_ROOT"] || "tmp/build"
cache_root = ENV["CACHE_ROOT"] || "tmp/cache"

poll_frequency = ENV["CI_POLL_FREQUENCY"].to_i
poll_frequency = 5 if poll_frequency.zero?

stages_to_work_on = (ENV["STAGES"] || "bootstrap,spawn").split(",")

dots = false

loop do
  # FUTURE: move the BuildImageTasklet inside a privileged docker container, and remove the need for a special bootstrap stage
  task = client.request("/tasks/pull", stage: stages_to_work_on)

  if task
    puts if dots
    dots = false
    puts "task #{task["task_id"]} stage #{task["stage"]} task #{task["task"]} assigned".squeeze(" ")

    task_runner = TaskRunner.new(task: task, runner_name: runner_name, pod_name: pod_name, build_root: build_root, cache_root: cache_root)

    if task["stage"] == "bootstrap"
      success, output, exit_code = task_runner.run(BuildImageTasklet)
      success, output, exit_code = task_runner.run(PushImageTasklet) if success
      success, output, exit_code = task_runner.run(RunImageTasklet) if success
    else
      success, output, exit_code = task_runner.run(PullImageTasklet)
      success, output, exit_code = task_runner.run(RunImageTasklet) if success
    end

    puts "task #{task["task_id"]} finished, #{success ? 'success' : 'failed'}"
    if success
      client.request("/tasks/success", "task_id" => task["task_id"], "output" => output, "exit_code" => exit_code)
    else
      client.request("/tasks/failed", "task_id" => task["task_id"], "output" => output, "exit_code" => exit_code)
    end
  else
    print "."
    dots = true
    sleep poll_frequency
  end
end
