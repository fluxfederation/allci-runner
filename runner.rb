#!/usr/bin/env ruby

$LOAD_PATH.unshift '.'

require 'fileutils'
require 'tempfile'
require 'allci_client'
require 'task_runner'
require 'tasklets'

service_url = ENV["CI_SERVICE_URL"] or raise("must specify the CI service URL in CI_SERVICE_URL")
runner_name = ENV["RUNNER_NAME"] || Socket.gethostname
client = AllciClient.new(service_url, runner_name)

pod_name = "allci-runner-#{runner_name}"
build_root = ENV["BUILD_ROOT"] || "tmp/build"

poll_frequency = ENV["CI_POLL_FREQUENCY"].to_i
poll_frequency = 5 if poll_frequency.zero?

failed_poll_frequency = ENV["CI_FAILED_POLL_FREQUENCY"].to_i
failed_poll_frequency = poll_frequency if failed_poll_frequency.zero?

loop do
  response = client.request("/tasks/pull")

  if response.is_a?(Net::HTTPOK)
    task = JSON.parse(response.body)
    puts "task #{task["task_id"]} stage #{task["stage"]} task #{task["task"]} assigned".squeeze(" ")

    task_runner = TaskRunner.new(task: task, pod_name: pod_name, build_root: build_root)
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
