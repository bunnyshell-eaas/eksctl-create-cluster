#!/bin/bash

set -e

# Function to check if a command is installed
check_command() {
  command -v "$1" >/dev/null 2>&1
}

# Check if watch is installed
if check_command "watch"; then
  echo "watch is installed."
else
  echo "watch is not installed. Please install it using your package manager."
fi

# Check if jq is installed
if check_command "jq"; then
  echo "jq is installed."
else
  echo "jq is not installed. Please install it using your package manager."
fi

#create efs file system
export FILE_SYSTEM_ID=$(aws efs create-file-system | jq --raw-output '.FileSystemId')

# Check the LifeCycleState of the file system using the following command and wait until it changes from creating to available before you proceed to the next step.
aws efs describe-file-systems --file-system-id $FILE_SYSTEM_ID

# extract the DNS name of the EFS
export EFS_DNS_NAME=$FILE_SYSTEM_ID.efs.$AWS_REGION.amazonaws.com

export VPC_ID=$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --query "cluster.resourcesVpcConfig.vpcId" --output text)
export CIDR_BLOCK=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query "Vpcs[].CidrBlock" --output text)



# create a security group for the EFS mount targets
MOUNT_TARGET_GROUP_NAME="eks-efs-group-${EKS_CLUSTER_NAME}"
MOUNT_TARGET_GROUP_DESC="NFS access to EFS from EKS worker nodes"
MOUNT_TARGET_GROUP_ID=$(aws ec2 create-security-group --group-name $MOUNT_TARGET_GROUP_NAME --description "$MOUNT_TARGET_GROUP_DESC" --vpc-id $VPC_ID | jq --raw-output '.GroupId')
aws ec2 authorize-security-group-ingress --group-id $MOUNT_TARGET_GROUP_ID --protocol tcp --port 2049 --cidr $CIDR_BLOCK


# The following set of commands identifies the public subnets in your cluster VPC and creates a mount target in each one of them 
# as well as associate that mount target with the security group you created above.

TAG1=tag:alpha.eksctl.io/cluster-name
TAG2=tag:kubernetes.io/role/elb
subnets=($(aws ec2 describe-subnets --filters "Name=$TAG1,Values=$EKS_CLUSTER_NAME" "Name=$TAG2,Values=1" | jq --raw-output '.Subnets[].SubnetId'))
for subnet in ${subnets[@]}
do
    echo "creating mount target in " $subnet
    aws efs create-mount-target --file-system-id $FILE_SYSTEM_ID --subnet-id $subnet --security-groups $MOUNT_TARGET_GROUP_ID --no-cli-pager
done

# wait until all mount targets are available
# if on Mac, install watch with:
# brew install watch
#watch "aws efs describe-mount-targets --file-system-id $FILE_SYSTEM_ID | jq --raw-output '.MountTargets[].LifeCycleState'"
while true; do
    # Run the aws command and store the output in a variable
    output=$(aws efs describe-mount-targets --file-system-id $FILE_SYSTEM_ID | jq --raw-output '.MountTargets[].LifeCycleState')

    # Check if all rows are available (LifeCycleState == "available")
    if [[ $output == *"available"* ]]; then
        echo "All mount targets are available."
        break  # Exit the loop if all rows are available
    fi
    echo "Mount targets not available yet. "
    # Wait for a few seconds before checking again
    sleep 2
done


# add helm repo
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/

# install helm chart
helm install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --set nfs.server=$EFS_DNS_NAME \
    --set nfs.path=/ \
    --set storageClass.name=bns-network-sc