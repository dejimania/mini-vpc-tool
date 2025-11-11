# mini-vpc-tool
A mini VPC creation CLI that supports subnets, routing, NAT on Linux Machine

## Features
- Create isolated VPCs with custom CIDR ranges
- Add public/private subnets using network namespaces
- Enable NAT for internet access
- VPC peering for cross-VPC communication
- JSON-based security policies with iptables
- Colored logging for all operations
- Idempotent operations with proper cleanup

## Usage

### Create a VPC
```bash
sudo ./vpcctl.sh create myvpc 10.0.0.0/16
```

### Add Subnets
```bash
sudo ./vpcctl.sh add-subnet myvpc public 10.0.1.0/24 public
sudo ./vpcctl.sh add-subnet myvpc private 10.0.2.0/24 private
```

### Enable NAT (for public subnet)
```bash
sudo ./vpcctl.sh enable-nat myvpc public eth0
```

### Peer Two VPCs
```bash
sudo ./vpcctl.sh peer vpc1 vpc2
```

### Apply Security Policy
```bash
sudo ./vpcctl.sh apply-policy myvpc public example-policy.json
```

### List All VPCs
```bash
sudo ./vpcctl.sh list
```

### Delete a VPC
```bash
sudo ./vpcctl.sh delete myvpc
```

## Testing Connectivity

### Test within namespace
```bash
sudo ip netns exec ns-myvpc-public ping 10.0.1.1
```

### Run web server in namespace
```bash
sudo ip netns exec ns-myvpc-public python3 -m http.server 80
```

### Test internet access
```bash
sudo ip netns exec ns-myvpc-public ping 8.8.8.8
```

## Log Types
- **[INFO]** (Blue): Informational messages about operations
- **[SUCCESS]** (Green): Successful completion of operations
- **[WARN]** (Yellow): Warning messages
- **[ERROR]** (Red): Error messages

## Requirements
- Linux with network namespace support
- Root/sudo privileges
- iptables
- iproute2 package
