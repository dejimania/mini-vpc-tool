#!/bin/bash

echo "=== VPC Demo Script ==="

echo -e "\n1. Creating VPC1"
sudo ./vpcctl.sh create vpc1 10.0.0.0/16

echo -e "\n2. Adding subnets to VPC1"
sudo ./vpcctl.sh add-subnet vpc1 public 10.0.1.0/24 public
sudo ./vpcctl.sh add-subnet vpc1 private 10.0.2.0/24 private

echo -e "\n3. Enabling NAT for public subnet"
sudo ./vpcctl.sh enable-nat vpc1 public eth0

echo -e "\n4. Creating VPC2"
sudo ./vpcctl.sh create vpc2 10.1.0.0/16

echo -e "\n5. Adding subnet to VPC2"
sudo ./vpcctl.sh add-subnet vpc2 public 10.1.1.0/24 public

echo -e "\n6. Listing all VPCs"
sudo ./vpcctl.sh list

echo -e "\n7. Testing connectivity within VPC1"
sudo ip netns exec ns-vpc1-public ping -c 2 10.0.1.1

echo -e "\n8. Peering VPC1 and VPC2"
sudo ./vpcctl.sh peer vpc1 vpc2

echo -e "\n9. Applying security policy"
sudo ./vpcctl.sh apply-policy vpc1 public example-policy.json

echo -e "\n=== Demo Complete ==="
