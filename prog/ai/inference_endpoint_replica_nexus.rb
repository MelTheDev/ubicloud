# frozen_string_literal: true

require "bcrypt"
require "forwardable"

require_relative "../../lib/util"

class Prog::Ai::InferenceEndpointReplicaNexus < Prog::Base
  subject_is :inference_endpoint_replica

  extend Forwardable
  def_delegators :inference_endpoint_replica, :vm, :inference_endpoint

  semaphore :destroy

  def self.assemble(inference_endpoint_id)
    DB.transaction do
      ubid = InferenceEndpointReplica.generate_ubid

      inference_endpoint = InferenceEndpoint[inference_endpoint_id]
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        "ubi",
        Config.inference_endpoint_service_project_id,
        location: inference_endpoint.location,
        name: ubid.to_s,
        size: inference_endpoint.vm_size,
        storage_volumes: inference_endpoint.storage_volumes,
        boot_image: inference_endpoint.boot_image,
        private_subnet_id: inference_endpoint.load_balancer.private_subnet.id,
        enable_ip4: true
      )

      inference_endpoint.load_balancer.add_vm(vm_st.subject)

      replica = InferenceEndpointReplica.create(
        inference_endpoint_id: inference_endpoint_id,
        vm_id: vm_st.id,
        replica_secret: SecureRandom.alphanumeric(32)
      ) { _1.id = ubid.to_uuid }

      Strand.create(prog: "Ai::InferenceEndpointReplicaNexus", label: "start") { _1.id = replica.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      elsif strand.stack.count > 1
        pop "operation is cancelled due to the destruction of the inference endpoint"
      end
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"

    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    register_deadline(:wait, 15 * 60)

    bud Prog::BootstrapRhizome, {"target_folder" => "inference_endpoint", "subject_id" => vm.id, "user" => "ubi"}
    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    hop_setup if leaf?
    donate
  end

  label def setup
    case vm.sshable.cmd("common/bin/daemonizer --check setup")
    when "Succeeded"
      hop_wait_endpoint_up
    when "Failed", "NotStarted"
      https = inference_endpoint.load_balancer.health_check_protocol == "https"
      params = {
        inference_engine: inference_endpoint.engine,
        inference_engine_params: inference_endpoint.engine_params,
        model: inference_endpoint.model_name,
        replica_ubid: inference_endpoint_replica.ubid,
        public_endpoint: inference_endpoint.public,
        clover_secret: BCrypt::Password.create(inference_endpoint_replica.replica_secret).shellescape,
        ssl_crt_path: https ? "TODO path to ssl crt file" : "",
        ssl_key_path: https ? "TODO path to ssl key file" : ""
      }
      params_json = JSON.generate(params)
      vm.sshable.cmd("common/bin/daemonizer 'sudo inference_endpoint/bin/setup-replica' setup", stdin: params_json)
    end

    nap 5
  end

  label def wait_endpoint_up
    if inference_endpoint.load_balancer.reload.active_vms.map { _1.id }.include? vm.id
      hop_wait
    end

    nap 5
  end

  label def wait
    ping_gateway

    nap 60
  end

  label def destroy
    decr_destroy

    strand.children.each { _1.destroy }
    inference_endpoint.load_balancer.evacuate_vm(vm)
    inference_endpoint.load_balancer.remove_vm(vm)
    vm.incr_destroy
    inference_endpoint_replica.destroy

    pop "inference endpoint replica is deleted"
  end

  # pushes latest config to inference gateway and collects billing information
  def ping_gateway
    projects = if inference_endpoint.public
      Project.all
        .select { _1.get_ff_inference_endpoint && _1.api_keys.any? { |k| k.used_for == "inference_endpoint" } }
        .map do
        {
          ubid: _1.ubid,
          api_keys: _1.api_keys.select { |k| k.used_for == "inference_endpoint" }.map(&:key_hash),
          quota_rps: 1.0,
          quota_tps: 100.0
        }
      end
    else
      [{
        ubid: inference_endpoint.project.ubid,
        api_keys: inference_endpoint.api_keys.map(&:key_hash),
        quota_rps: 1000000.0,
        quota_tps: 1000000.0
      }]
    end
    body = {
      replica_ubid: inference_endpoint_replica.ubid,
      public_endpoint: inference_endpoint.public,
      projects: projects
    }

    uri = URI.parse("#{inference_endpoint.load_balancer.health_check_protocol}://#{vm.ephemeral_net4}:9191")  # TODO: switch to https when inference gateway is started with https, see write_config_files in rhizome/inference_endpoint/lib/replica_setup.rb
    header = {"Content-Type": "text/json", Authorization: "Bearer " + inference_endpoint_replica.replica_secret}
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 5
    req = Net::HTTP::Post.new(uri.request_uri, header)
    req.body = body.to_json
    resp = http.request(req)
    if resp.code == "200"
      project_usage = JSON.parse(resp.body)["projects"]
      # project_usage is a list of the following format:
      # [{"ubid":"aprojectubid","request_count":0,"prompt_token_count":0,"completion_token_count":0}, ...]
      # TODO: produce billing records for public endpoints based on project_usage
      Clog.emit("Successfully pinged inference gateway.") { {inference_endpoint: inference_endpoint.ubid, replica: inference_endpoint_replica.ubid, project_usage: project_usage} }
    else
      Clog.emit("Failed to ping inference gateway.") { {inference_endpoint: inference_endpoint.ubid, replica: inference_endpoint_replica.ubid, http_code: resp.code} }
    end
  end
end
