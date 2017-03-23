require 'net/http'
require 'net/https'
require 'json'

class AllciClient
  attr_reader :service_url, :runner_name

  def initialize(service_url = ENV["CI_SERVICE_URL"], runner_name = ENV["RUNNER_NAME"])
    @service_url = URI(service_url)
    @runner_name = runner_name
    @http = Net::HTTP.new(@service_url.hostname, @service_url.port)
    @standard_params = { "runner_name" => @runner_name }
  end

  def request(path, json_params = {})
    req = Net::HTTP::Post.new(path)
    req.body = @standard_params.merge(json_params).to_json
    req.content_type = 'application/json'

    response = @http.request(req)

    return nil if response.is_a?(Net::HTTPNoContent)
    response.error! unless response.is_a?(Net::HTTPOK)
    JSON.parse(response.body)
  end
end
