#!/bin/bash

VPC_DIR="/var/run/vpcctl"
mkdir -p "$VPC_DIR"

create_vpc() {
    local vpc_name=$1
    local cidr=$2
    
    if [[ -f "$VPC_DIR/$vpc_name" ]]; then
        echo "Error: VPC $vpc_name already exists"
        return 1
    fi
    
    # Create bridge for VPC
    ip link add name "vpc-$vpc_name" type bridge
    ip link set "vpc-$vpc_name" up
    
    # Store VPC metadata
    echo "CIDR=$cidr" > "$VPC_DIR/$vpc_name"
    echo "BRIDGE=vpc-$vpc_name" >> "$VPC_DIR/$vpc_name"
    
    echo "VPC $vpc_name created with CIDR $cidr"
}

add_subnet() {
    local vpc_name=$1
    local subnet_name=$2
    local subnet_cidr=$3
    
    if [[ ! -f "$VPC_DIR/$vpc_name" ]]; then
        echo "Error: VPC $vpc_name does not exist"
        return 1
    fi
    
    local bridge=$(grep "BRIDGE=" "$VPC_DIR/$vpc_name" | cut -d= -f2)
    local ns_name="ns-$vpc_name-$subnet_name"
    local veth_vpc="veth-$subnet_name"
    local veth_ns="eth0"
    
    # Create namespace
    ip netns add "$ns_name"
    
    # Create veth pair
    ip link add "$veth_vpc" type veth peer name "$veth_ns"
    
    # Attach one end to bridge
    ip link set "$veth_vpc" master "$bridge"
    ip link set "$veth_vpc" up
    
    # Move other end to namespace
    ip link set "$veth_ns" netns "$ns_name"
    
    # Configure namespace interface
    local gateway=$(echo $subnet_cidr | sed 's/\.[0-9]*\//.1\//')
    local host_ip=$(echo $subnet_cidr | sed 's/\.[0-9]*\//.2\//')
    
    ip netns exec "$ns_name" ip addr add "$host_ip" dev "$veth_ns"
    ip netns exec "$ns_name" ip link set "$veth_ns" up
    ip netns exec "$ns_name" ip link set lo up
    ip netns exec "$ns_name" ip route add default via "${gateway%/*}"
    
    # Add gateway IP to bridge
    ip addr add "$gateway" dev "$bridge"
    
    # Store subnet metadata
    echo "SUBNET_${subnet_name}=$subnet_cidr" >> "$VPC_DIR/$vpc_name"
    echo "NS_${subnet_name}=$ns_name" >> "$VPC_DIR/$vpc_name"
    
    echo "Subnet $subnet_name added to VPC $vpc_name with CIDR $subnet_cidr"
}

delete_vpc() {
    local vpc_name=$1
    
    if [[ ! -f "$VPC_DIR/$vpc_name" ]]; then
        echo "Error: VPC $vpc_name does not exist"
        return 1
    fi
    
    local bridge=$(grep "BRIDGE=" "$VPC_DIR/$vpc_name" | cut -d= -f2)
    
    # Delete all namespaces
    for ns in $(grep "^NS_" "$VPC_DIR/$vpc_name" | cut -d= -f2); do
        ip netns del "$ns" 2>/dev/null
    done
    
    # Delete bridge
    ip link del "$bridge" 2>/dev/null
    
    # Remove metadata
    rm -f "$VPC_DIR/$vpc_name"
    
    echo "VPC $vpc_name deleted"
}

case "$1" in
    create-vpc)
        create_vpc "$2" "$3"
        ;;
    add-subnet)
        add_subnet "$2" "$3" "$4"
        ;;
    delete-vpc)
        delete_vpc "$2"
        ;;
    *)
        echo "Usage: $0 {create-vpc|add-subnet|delete-vpc} [args]"
        echo "  create-vpc <vpc-name> <cidr>"
        echo "  add-subnet <vpc-name> <subnet-name> <subnet-cidr>"
        echo "  delete-vpc <vpc-name>"
        exit 1
        ;;
esac
