#!/bin/bash

set -e

VPC_DIR="/var/run/vpcctl"
POLICY_DIR="/etc/vpcctl/policies"
mkdir -p "$VPC_DIR" "$POLICY_DIR"

# Log Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

get_gateway_ip() {
    echo "$1" | sed 's/\.[0-9]*\//.1/'
}

get_host_ip() {
    echo "$1" | sed 's/\.[0-9]*\//.2/'
}

create_vpc() {
    local vpc_name=$1
    local cidr=$2
    
    if [[ -f "$VPC_DIR/$vpc_name.conf" ]]; then
        log_error "VPC $vpc_name already exists"
        return 1
    fi
    
    log_info "Creating VPC: $vpc_name with CIDR: $cidr"
    
    # Create bridge for VPC
    local bridge="br-$vpc_name"
    ip link add name "$bridge" type bridge
    ip link set "$bridge" up
    log_success "Bridge $bridge created and activated"
    
    # Store VPC metadata
    echo "CIDR=$cidr" > "$VPC_DIR/$vpc_name.conf"
    echo "BRIDGE=$bridge" >> "$VPC_DIR/$vpc_name.conf"
    
    log_success "VPC $vpc_name created successfully"
}

add_subnet() {
    local vpc_name=$1
    local subnet_name=$2
    local subnet_cidr=$3
    local subnet_type=${4:-private}
    
    if [[ ! -f "$VPC_DIR/$vpc_name.conf" ]]; then
        log_error "VPC $vpc_name does not exist"
        return 1
    fi
    
    log_info "Adding subnet: $subnet_name ($subnet_type) to VPC: $vpc_name"
    
    local bridge=$(grep "BRIDGE=" "$VPC_DIR/$vpc_name.conf" | cut -d= -f2)
    local ns_name="ns-$vpc_name-$subnet_name"
    local veth_br="veth-$vpc_name-$subnet_name"
    local veth_ns="eth0"
    
    if ip netns list | grep -q "^$ns_name"; then
        log_error "Subnet namespace $ns_name already exists"
        return 1
    fi
    
    # Create namespace
    log_info "Creating namespace: $ns_name"
    ip netns add "$ns_name"
    
    # Create veth pair
    log_info "Creating veth pair: $veth_br <-> $veth_ns"
    ip link add "$veth_br" type veth peer name "$veth_ns"
    
    log_info "Attaching $veth_br to bridge $bridge"
    ip link set "$veth_br" master "$bridge"
    ip link set "$veth_br" up
    
    log_info "Moving $veth_ns to namespace $ns_name"
    ip link set "$veth_ns" netns "$ns_name"
    
    local gateway=$(get_gateway_ip "$subnet_cidr")
    local host_ip=$(get_host_ip "$subnet_cidr")
    
    log_info "Assigning IP $host_ip to $veth_ns in namespace"
    ip netns exec "$ns_name" ip addr add "$host_ip" dev "$veth_ns"
    ip netns exec "$ns_name" ip link set "$veth_ns" up
    ip netns exec "$ns_name" ip link set lo up
    
    log_info "Configuring default route via $gateway"
    ip netns exec "$ns_name" ip route add default via "${gateway%/*}"
    
    if ! ip addr show "$bridge" | grep -q "${gateway%/*}"; then
        log_info "Assigning gateway IP $gateway to bridge"
        ip addr add "$gateway" dev "$bridge"
    fi
    
    echo "SUBNET_${subnet_name}_CIDR=$subnet_cidr" >> "$VPC_DIR/$vpc_name.conf"
    echo "SUBNET_${subnet_name}_NS=$ns_name" >> "$VPC_DIR/$vpc_name.conf"
    echo "SUBNET_${subnet_name}_TYPE=$subnet_type" >> "$VPC_DIR/$vpc_name.conf"
    
    log_success "Subnet $subnet_name added successfully"
}

enable_nat() {
    local vpc_name=$1
    local subnet_name=$2
    local internet_iface=${3:-eth0}
    
    if [[ ! -f "$VPC_DIR/$vpc_name.conf" ]]; then
        log_error "VPC $vpc_name does not exist"
        return 1
    fi
    
    log_info "Enabling NAT for subnet: $subnet_name via interface: $internet_iface"
    
    local subnet_cidr=$(grep "SUBNET_${subnet_name}_CIDR=" "$VPC_DIR/$vpc_name.conf" | cut -d= -f2)
    local bridge=$(grep "BRIDGE=" "$VPC_DIR/$vpc_name.conf" | cut -d= -f2)
    
    log_info "Enabling IP forwarding"
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    log_info "Configuring NAT rules for $subnet_cidr"
    iptables -t nat -A POSTROUTING -s "$subnet_cidr" -o "$internet_iface" -j MASQUERADE
    iptables -A FORWARD -i "$bridge" -o "$internet_iface" -j ACCEPT
    iptables -A FORWARD -i "$internet_iface" -o "$bridge" -m state --state RELATED,ESTABLISHED -j ACCEPT
    
    echo "NAT_${subnet_name}=$internet_iface" >> "$VPC_DIR/$vpc_name.conf"
    
    log_success "NAT enabled for subnet $subnet_name"
}

peer_vpcs() {
    local vpc1=$1
    local vpc2=$2
    
    if [[ ! -f "$VPC_DIR/$vpc1.conf" ]] || [[ ! -f "$VPC_DIR/$vpc2.conf" ]]; then
        log_error "One or both VPCs do not exist"
        return 1
    fi
    
    log_info "Peering VPC: $vpc1 with VPC: $vpc2"
    
    local bridge1=$(grep "BRIDGE=" "$VPC_DIR/$vpc1.conf" | cut -d= -f2)
    local bridge2=$(grep "BRIDGE=" "$VPC_DIR/$vpc2.conf" | cut -d= -f2)
    local veth1="peer-$vpc1-$vpc2"
    local veth2="peer-$vpc2-$vpc1"
    
    log_info "Creating veth pair for peering: $veth1 <-> $veth2"
    ip link add "$veth1" type veth peer name "$veth2"
    
    log_info "Attaching veth ends to bridges"
    ip link set "$veth1" master "$bridge1"
    ip link set "$veth2" master "$bridge2"
    ip link set "$veth1" up
    ip link set "$veth2" up
    
    local cidr1=$(grep "^CIDR=" "$VPC_DIR/$vpc1.conf" | cut -d= -f2)
    local cidr2=$(grep "^CIDR=" "$VPC_DIR/$vpc2.conf" | cut -d= -f2)
    
    log_info "Adding routes between VPCs"
    ip route add "$cidr2" dev "$bridge1" 2>/dev/null || true
    ip route add "$cidr1" dev "$bridge2" 2>/dev/null || true
    
    echo "PEER_$vpc2=$veth1" >> "$VPC_DIR/$vpc1.conf"
    echo "PEER_$vpc1=$veth2" >> "$VPC_DIR/$vpc2.conf"
    
    log_success "VPC peering established between $vpc1 and $vpc2"
}

apply_policy() {
    local vpc_name=$1
    local subnet_name=$2
    local policy_file=$3
    
    if [[ ! -f "$VPC_DIR/$vpc_name.conf" ]]; then
        log_error "VPC $vpc_name does not exist"
        return 1
    fi
    
    if [[ ! -f "$policy_file" ]]; then
        log_error "Policy file $policy_file not found"
        return 1
    fi
    
    log_info "Applying security policy to subnet: $subnet_name"
    
    local ns_name=$(grep "SUBNET_${subnet_name}_NS=" "$VPC_DIR/$vpc_name.conf" | cut -d= -f2)
    
    log_info "Flushing existing rules in namespace $ns_name"
    ip netns exec "$ns_name" iptables -F INPUT 2>/dev/null || true
    ip netns exec "$ns_name" iptables -P INPUT DROP
    
    while IFS= read -r line; do
        if echo "$line" | grep -q '"port"'; then
            local port=$(echo "$line" | grep -o '"port": *[0-9]*' | grep -o '[0-9]*')
            local protocol=$(echo "$line" | grep -o '"protocol": *"[^"]*"' | sed 's/"protocol": *"\([^"]*\)"/\1/')
            local action=$(echo "$line" | grep -o '"action": *"[^"]*"' | sed 's/"action": *"\([^"]*\)"/\1/')
            
            if [[ "$action" == "allow" ]]; then
                log_info "Allowing $protocol port $port"
                ip netns exec "$ns_name" iptables -A INPUT -p "$protocol" --dport "$port" -j ACCEPT
            else
                log_info "Denying $protocol port $port"
                ip netns exec "$ns_name" iptables -A INPUT -p "$protocol" --dport "$port" -j DROP
            fi
        fi
    done < "$policy_file"
    
    ip netns exec "$ns_name" iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    log_success "Security policy applied to $subnet_name"
}

list_vpcs() {
    log_info "Listing all VPCs"
    for conf in "$VPC_DIR"/*.conf; do
        if [[ -f "$conf" ]]; then
            local vpc=$(basename "$conf" .conf)
            local cidr=$(grep "^CIDR=" "$conf" | cut -d= -f2)
            echo -e "${GREEN}VPC:${NC} $vpc ${BLUE}CIDR:${NC} $cidr"
            grep "^SUBNET_" "$conf" | grep "_CIDR=" | while read line; do
                local subnet=$(echo "$line" | sed 's/SUBNET_\(.*\)_CIDR=.*/\1/')
                local scidr=$(echo "$line" | cut -d= -f2)
                echo -e "  ${YELLOW}Subnet:${NC} $subnet ${BLUE}CIDR:${NC} $scidr"
            done
        fi
    done
}

delete_vpc() {
    local vpc_name=$1
    
    if [[ ! -f "$VPC_DIR/$vpc_name.conf" ]]; then
        log_error "VPC $vpc_name does not exist"
        return 1
    fi
    
    log_info "Deleting VPC: $vpc_name"
    
    local bridge=$(grep "BRIDGE=" "$VPC_DIR/$vpc_name.conf" | cut -d= -f2)
    
    log_info "Removing NAT rules"
    grep "^SUBNET_.*_CIDR=" "$VPC_DIR/$vpc_name.conf" | cut -d= -f2 | while read cidr; do
        iptables -t nat -D POSTROUTING -s "$cidr" -j MASQUERADE 2>/dev/null || true
    done
    
    log_info "Deleting namespaces"
    grep "^SUBNET_.*_NS=" "$VPC_DIR/$vpc_name.conf" | cut -d= -f2 | while read ns; do
        log_info "Deleting namespace: $ns"
        ip netns del "$ns" 2>/dev/null || true
    done
    
    log_info "Deleting bridge: $bridge"
    ip link del "$bridge" 2>/dev/null || true
    
    log_info "Removing configuration"
    rm -f "$VPC_DIR/$vpc_name.conf"
    
    log_success "VPC $vpc_name deleted successfully"
}

case "$1" in
    create)
        create_vpc "$2" "$3"
        ;;
    add-subnet)
        add_subnet "$2" "$3" "$4" "$5"
        ;;
    enable-nat)
        enable_nat "$2" "$3" "$4"
        ;;
    peer)
        peer_vpcs "$2" "$3"
        ;;
    apply-policy)
        apply_policy "$2" "$3" "$4"
        ;;
    list)
        list_vpcs
        ;;
    delete)
        delete_vpc "$2"
        ;;
    *)
        echo "Usage: $0 {create|add-subnet|enable-nat|peer|apply-policy|list|delete}"
        echo "  create <vpc-name> <cidr>"
        echo "  add-subnet <vpc-name> <subnet-name> <subnet-cidr> [public|private]"
        echo "  enable-nat <vpc-name> <subnet-name> [internet-interface]"
        echo "  peer <vpc1> <vpc2>"
        echo "  apply-policy <vpc-name> <subnet-name> <policy-file>"
        echo "  list"
        echo "  delete <vpc-name>"
        exit 1
        ;;
esac
