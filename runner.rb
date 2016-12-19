#!/usr/bin/env ruby

require 'net/http'
require 'net/https'
require 'json'
require 'pp'

class ServiceClient
  def initialize(service_url, standard_params)
    @service_url = URI(service_url)
    @http = Net::HTTP.new(@service_url.hostname, @service_url.port)
    @standard_params = standard_params
  end

  def request(path, json_params)
    req = Net::HTTP::Post.new(path)
    req.body = @standard_params.merge(json_params).to_json
    req.content_type = 'application/json'
    @http.request(req)
  end
end

def capture(*args)
  r, w = IO.pipe
  puts args.inspect
  pid = spawn(*args, :out => w)
  w.close
  output = w.read
  result = Process.wait(pid)
  [result, output]
end

raise("must specify the CI service URL in CI_SERVICE_URL") unless ENV["CI_SERVICE_URL"]
runner_name = ENV["RUNNER_NAME"] || Socket.gethostname
client = ServiceClient.new(ENV["CI_SERVICE_URL"], "runner_name": runner_name)

poll_frequency = ENV["CI_POLL_FREQUENCY"].to_i
poll_frequency = 5 if poll_frequency.zero?

failed_poll_frequency = ENV["CI_FAILED_POLL_FREQUENCY"].to_i
failed_poll_frequency = poll_frequency if failed_poll_frequency.zero?

def run_options(json)
  args = ["--rm", "-a", "STDOUT,STDERR"]

  if json["hostname"]
    args << "--hostname"
    args << json["hostname"]
  end

  if json["env"]
    Array(json["env"]).each do |env|
      args << "--env"
      args << env
    end
  end

  if json["privileged"]
    args << "--privileged"
  end

  if json["cmd"]
    args.concat Array(json["cmd"])
  end

  args
end

loop do
  response = client.request("/tasks/pull", "stage" => "build_component_images")

  if response.is_a?(Net::HTTPOK)
    json = JSON.parse(response.body)
    STDOUT.puts "assigned #{json}"

    result, output = capture("docker", "pull", json["image"])
    result, output = capture("docker", "run", "-i", json["image"], *run_options(json)) if result.success?

    if result.success?
      client.request("/tasks/complete", "task_id" => json["task_id"], "output" => output)
    else
      client.request("/tasks/failed", "task_id" => json["task_id"], "output" => output)
    end
  elsif response.is_a?(Net::HTTPNoContent)
    STDOUT.puts "no tasks to run"
    sleep poll_frequency
  else
    STDERR.puts response.inspect
    sleep failed_poll_frequency
  end
end
