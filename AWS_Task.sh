#!/bin/bash

# Set the desired AWS region
region="us-east-1"

# Create VPC
vpc_id=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text --region $region)
echo "VPC created with ID: $vpc_id"

# Create Subnet
subnet_id=$(aws ec2 create-subnet --vpc-id $vpc_id --cidr-block 10.0.1.0/24 --availability-zone ${region}a --query 'Subnet.SubnetId' --output text --region $region)
echo "Subnet created with ID: $subnet_id"

# Create Security Group
security_group_id=$(aws ec2 create-security-group --group-name my-security-group --description "My security group" --vpc-id $vpc_id --output text --region $region)
echo "Security Group created with ID: $security_group_id"

# Allow SSH access
aws ec2 authorize-security-group-ingress --group-id $security_group_id --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $region

# Allow HTTP access for the web application
aws ec2 authorize-security-group-ingress --group-id $security_group_id --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $region

# Create Elastic Container Registry (ECR)
ecr_repo_uri=$(aws ecr create-repository --repository-name spring-petclinic --image-scanning-configuration scanOnPush=true --encryption-configuration encryptionType=AES256 --query 'repository.repositoryUri' --output text --region $region)
echo "ECR Repository URI: $ecr_repo_uri"

# Authenticate Docker client to ECR
aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $ecr_repo_uri

# Tag Docker image
docker tag mihailinternul/main:latest $ecr_repo_uri:latest

# Push Docker image to ECR
docker push $ecr_repo_uri:latest

# User Data for installing Docker and running container
user_data=$(cat <<EOF
#!/bin/bash
yum update -y
yum install docker -y
systemctl start docker
systemctl enable docker
usermod -a -G docker ec2-user

# Login to Amazon ECR
aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $ecr_repo_uri

# Pull the Docker image from Amazon ECR and run it
docker pull $ecr_repo_uri:latest
docker run -d -p 80:8080 $ecr_repo_uri:latest
EOF
)

# Attach Internet Gateway to VPC
igw_id=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text --region $region)
aws ec2 attach-internet-gateway --vpc-id $vpc_id --internet-gateway-id $igw_id --region $region
echo "Internet Gateway $igw_id attached to VPC $vpc_id"

# Create a route table for the VPC
route_table_id=$(aws ec2 create-route-table --vpc-id $vpc_id --query 'RouteTable.RouteTableId' --output text --region $region)
echo "Route table created with ID: $route_table_id"

# Create a route in the route table that points all traffic (0.0.0.0/0) to the Internet Gateway
aws ec2 create-route --route-table-id $route_table_id --destination-cidr-block 0.0.0.0/0 --gateway-id $igw_id --region $region
echo "Route created in route table $route_table_id to direct traffic to Internet Gateway $igw_id"

# Associate the subnet with the route table
aws ec2 associate-route-table  --subnet-id $subnet_id --route-table-id $route_table_id --region $region
echo "Subnet $subnet_id associated with route table $route_table_id"

# Create EC2 Key Pair
aws ec2 create-key-pair --key-name my-key-pair --query 'KeyMaterial' --output text > my-key-pair.pem
chmod 400 my-key-pair.pem

# Launch EC2 Instance with User Data
instance_id=$(aws ec2 run-instances --image-id ami-0f403e3180720dd7e --count 1 --instance-type t2.micro --key-name my-key-pair --subnet-id $subnet_id --security-group-ids $security_group_id --user-data "$user_data" --query 'Instances[0].InstanceId' --output text --region $region)
echo "EC2 Instance launched with ID: $instance_id"

# Wait for the instance to be in a running state
aws ec2 wait instance-running --instance-ids $instance_id --region $region

# Allocate Elastic IP
allocation_id=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text --region $region)

# Associate Elastic IP with EC2 Instance
aws ec2 associate-address --instance-id $instance_id --allocation-id $allocation_id --region $region
public_ip=$(aws ec2 describe-addresses --allocation-ids $allocation_id --query 'Addresses[0].PublicIp' --output text --region $region)
echo "EC2 Instance launched with Public IP: $public_ip"
