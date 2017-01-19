#!/usr/bin/env ruby

require 'net/http'
require 'net/https'
require 'json'
require 'fileutils'
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

def capture(*args)
  w, r = IO.pipe
  puts args.inspect
  pid = spawn(*args, :out => w)
  r.close
  output = w.read
  pid, result = Process.wait2(pid)
  [result, output]
end

raise("must specify the CI service URL in CI_SERVICE_URL") unless ENV["CI_SERVICE_URL"]
runner_name = ENV["RUNNER_NAME"] || Socket.gethostname
client = ServiceClient.new(ENV["CI_SERVICE_URL"], "runner_name": runner_name)

buildroot = "tmp/build"

poll_frequency = ENV["CI_POLL_FREQUENCY"].to_i
poll_frequency = 5 if poll_frequency.zero?

failed_poll_frequency = ENV["CI_FAILED_POLL_FREQUENCY"].to_i
failed_poll_frequency = poll_frequency if failed_poll_frequency.zero?

def build_images(task, buildroot)
  workdir = "#{buildroot}/workdir"

  task["components"].each do |container_name, container_details|
    FileUtils.rm_rf(workdir)
    FileUtils.mkdir_p(workdir)

    result, output = capture("git", "clone", "--branch", container_details["branch"], container_details["repository_uri"], workdir)
    return [result.success?, output] unless result.success?

    result, output = capture("docker", "build", "-t", container_details["image_name"], "-f", "#{workdir}/#{container_details["dockerfile"]}", workdir)
    return [result.success?, output]
  end
  true
end

def push_images(task)
  task["components"].each do |container_name, container_details|
    result, output = capture("docker", "push", container_details["image_name"])
    return [result.success?, output]
  end
  true
end

def pull_images(task)
  task["components"].each do |container_name, container_details|
    if container_name.include?('/')
      result, output = capture("docker", "pull", container_details["image_name"])
      return [result.success?, output]
    end
  end
  true
end

def run_options(container_name, container_details)
  args = ["--rm", "-a", "STDOUT", "-a", "STDERR"]

  args << "--hostname"
  args << (container_details["hostname"] || container_name)

  if container_details["env"]
    Array(container_details["env"]).each do |env|
      args << "--env"
      args << env
    end
  end

  args << container_details["image_name"]

  if container_details["cmd"]
    args.concat Array(container_details["cmd"])
  end

  args
end

def run_task(task)
  # fork and run each container
  children = task["components"].collect do |container_name, container_details|
    fork { Kernel.exec("docker", "run", *run_options(container_name, container_details)) }
  end

  # if we fail to spawn a child process, we've already failed
  success = children.compact!.nil?

  # otherwise, we wait for them all to exit
  while !children.empty? do
    # wait for the first one of them to exit
    exited_child, status = Process.wait2
    success &= status.success?
    children.delete(exited_child)

    # then tell all the others to terminate
    children.each { |child| Process.kill('TERM', child) }
  end

  output = "TODO: some container failed :(" unless success
  [success, output]
end

loop do
  response = client.request("/tasks/pull")

  if response.is_a?(Net::HTTPOK)
    task = JSON.parse(response.body)
    STDOUT.puts "assigned #{task}"

    if task["stage"] == "bootstrap"
      success, output = build_images(task, buildroot)
      success, output = push_images(task) if success
    else
      success, output = pull_images(task)
      success, output = run_task(task) if success
    end

    if success
      client.request("/tasks/success", "task_id" => task["task_id"], "output" => output)
    else
      client.request("/tasks/failed", "task_id" => task["task_id"], "output" => output)
    end
  elsif response.is_a?(Net::HTTPNoContent)
    STDOUT.puts "no tasks to run"
    sleep poll_frequency
  else
    STDERR.puts response.inspect
    sleep failed_poll_frequency
  end
end
