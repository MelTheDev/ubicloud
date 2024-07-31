# frozen_string_literal: true

class Prog::Vnet::UpdateLoadBalancer < Prog::Base
  subject_is :vm

  def load_balancer
    @load_balancer ||= LoadBalancer[frame.fetch("load_balancer_id")]
  end

  label def update_load_balancer
    # if there is literally no up resources to balance for, we simply not do
    # load balancing. This is a bit of a hack, but it's a simple way to avoid
    # the need to have a separate state for the load balancer.
    hop_remove_load_balancer if load_balancer.active_vms.count == 0
    vm.vm_host.sshable.cmd("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: generate_lb_based_nat_rules)

    pop "load balancer is updated"
  end

  label def remove_load_balancer
    if vm
      vm.vm_host.sshable.cmd("sudo ip netns exec #{vm.inhost_name} nft --file -", stdin: generate_nat_rules(vm.ephemeral_net4.to_s, vm.nics.first.private_ipv4.network.to_s))
    end

    pop "load balancer is updated"
  end

  def generate_lb_based_nat_rules
    public_ipv4 = vm.ephemeral_net4.to_s
    public_ipv6 = vm.ephemeral_net6.to_s
    private_ipv4 = vm.nics.first.private_ipv4.network
    private_ipv6 = vm.nics.first.private_ipv6.nth(2)
    neighbor_vms = load_balancer.active_vms.reject { _1.id == vm.id }
    neighbor_ips_v4_set, neighbor_ips_v6_set = generate_lb_ip_set_definition(neighbor_vms)
    modulo = load_balancer.active_vms.count
    ipv4_map_def, ipv6_map_def = generate_lb_map_defs

    balance_mode_ip4, balance_mode_ip6 = if load_balancer.algorithm == "round_robin"
      ["numgen inc", "numgen inc"]
    elsif load_balancer.algorithm == "hash_based"
      ["jhash ip saddr . tcp sport . ip daddr . tcp dport", "jhash ip6 saddr . tcp sport . ip6 daddr . tcp dport"]
    else
      fail ArgumentError, "Unsupported load balancer algorithm: #{load_balancer.algorithm}"
    end

    <<TEMPLATE
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table inet nat {
  set neighbor_ips_v4 {
    type ipv4_addr;
#{neighbor_ips_v4_set}
  }

  set neighbor_ips_v6 {
    type ipv6_addr;
#{neighbor_ips_v6_set}
  }

  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr #{public_ipv4} tcp dport #{load_balancer.src_port} ct state established,related,new counter dnat to #{balance_mode_ip4} mod #{modulo} map { #{ipv4_map_def} }
    ip6 daddr #{public_ipv6} tcp dport #{load_balancer.src_port} ct state established,related,new counter dnat to #{balance_mode_ip6} mod #{modulo} map { #{ipv6_map_def} }
    ip daddr #{public_ipv4} dnat to #{private_ipv4}
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip daddr @neighbor_ips_v4 tcp dport #{load_balancer.dst_port} ct state established,related,new counter snat to #{private_ipv4}
    ip6 daddr @neighbor_ips_v6 tcp dport #{load_balancer.dst_port} ct state established,related,new counter snat to #{private_ipv6}
    ip saddr #{private_ipv4} ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to #{public_ipv4}
    ip saddr #{private_ipv4} ip daddr #{private_ipv4} snat to #{public_ipv4}
  }
}
TEMPLATE
  end

  def generate_lb_ip_set_definition(neighbor_vms)
    return ["", ""] if neighbor_vms.empty?

    ["elements = {#{neighbor_vms.map { _1.nics.first.private_ipv4.network }.join(", ")}}",
      "elements = {#{neighbor_vms.map { _1.nics.first.private_ipv6.nth(2) }.join(", ")}}"]
  end

  def generate_lb_map_defs
    [load_balancer.active_vms.map.with_index { |vm, i| "#{i} : #{vm.nics.first.private_ipv4.network} . #{load_balancer.dst_port}" }.join(", "),
      load_balancer.active_vms.map.with_index { |vm, i| "#{i} : #{vm.nics.first.private_ipv6.nth(2)} . #{load_balancer.dst_port}" }.join(", ")]
  end

  def generate_nat_rules(current_public_ipv4, current_private_ipv4)
    <<NAT
table ip nat;
delete table ip nat;
table inet nat;
delete table inet nat;
table ip nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr #{current_public_ipv4} dnat to #{current_private_ipv4}
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr #{current_private_ipv4} ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to #{current_public_ipv4}
    ip saddr #{current_private_ipv4} ip daddr #{current_private_ipv4} snat to #{current_public_ipv4}
  }
}
NAT
  end
end
