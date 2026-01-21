#!/bin/bash

set -e
set -o pipefail
set -u

# set -x to print all commands for debugging
# set -x



# Function to check if a command is installed
check_command() {
  command -v "$1" >/dev/null 2>&1
}

# Check if watch is installed
if ! check_command "watch"; then
  echo "watch is not installed. Please install it using your package manager."
  exit 1
fi

# Check if jq is installed
if ! check_command "jq"; then
  echo "jq is not installed. Please install it using your package manager."
  exit 1
fi

# Check if sleep is installed
if ! check_command "sleep"; then
  echo "sleep command is not installed. Please install it using your package manager."
  exit 1
fi

# Check if helm is installed
if ! check_command "helm"; then
  echo "helm command is not installed. Please install it using your package manager."
  exit 1
fi
# generate a cleanup script
echo '#!/bin/bash' > cleanup.sh

export RESOURCE_TAGS="Key=for,Value=$EKS_CLUSTER_NAME"

#create efs file system
export FILE_SYSTEM_ID=$(aws efs create-file-system --output json --no-cli-pager --tags $RESOURCE_TAGS | jq --raw-output '.FileSystemId')
echo "Created EFS file system with ID: $FILE_SYSTEM_ID"
echo "to delete the EFS file system, run the following command:"
echo "aws efs delete-file-system --file-system-id $FILE_SYSTEM_ID"
echo "aws efs delete-file-system --file-system-id $FILE_SYSTEM_ID" >> cleanup.sh
echo ""


# Check the LifeCycleState of the file system using the following command and wait until it changes from creating to available before you proceed to the next step.
while true; do
  FS_STATUS=$(aws efs describe-file-systems --file-system-id $FILE_SYSTEM_ID --output json --no-cli-pager | jq --raw-output '.FileSystems[].LifeCycleState')
  if [ "$FS_STATUS" == "available" ]; then
    echo "EFS file system is available."
    break
  fi
  echo "EFS file system is not available yet. Waiting for 10 seconds..."
  sleep 10
done

# extract the DNS name of the EFS
export EFS_DNS_NAME=$FILE_SYSTEM_ID.efs.$AWS_REGION.amazonaws.com

export VPC_ID=$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --query "cluster.resourcesVpcConfig.vpcId" --output text --no-cli-pager)
export CIDR_BLOCK=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query "Vpcs[].CidrBlock" --output text --no-cli-pager)



# create a security group for the EFS mount targets
MOUNT_TARGET_GROUP_NAME="eks-efs-group-${EKS_CLUSTER_NAME}"
MOUNT_TARGET_GROUP_DESC="NFS access to EFS from EKS worker nodes"
# MOUNT_TARGET_GROUP_ID=$(aws ec2 create-security-group --group-name $MOUNT_TARGET_GROUP_NAME --description "$MOUNT_TARGET_GROUP_DESC" --vpc-id $VPC_ID  --tag-specifications 'ResourceType=security-group,Tags=[{Key=for,Value=$EKS_CLUSTER_NAME}]' $RESOURCE_TAGS --output json --no-cli-pager | jq --raw-output '.GroupId')
# echo "aws ec2 create-security-group --group-name $MOUNT_TARGET_GROUP_NAME --description '$MOUNT_TARGET_GROUP_DESC' --vpc-id $VPC_ID  --tag-specifications 'ResourceType=security-group,Tags=[{Key=for,Value="$EKS_CLUSTER_NAME"}]' --output json --no-cli-pager "
MOUNT_TARGET_GROUP_ID=$(aws ec2 create-security-group --group-name $MOUNT_TARGET_GROUP_NAME --description "$MOUNT_TARGET_GROUP_DESC" --vpc-id $VPC_ID  \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=for,Value=$EKS_CLUSTER_NAME}]" \
    --output json --no-cli-pager | jq --raw-output '.GroupId')
aws ec2 authorize-security-group-ingress --group-id $MOUNT_TARGET_GROUP_ID --protocol tcp --port 2049 --cidr $CIDR_BLOCK --no-cli-pager
echo "Created security group for EFS mount targets with ID: $MOUNT_TARGET_GROUP_ID"
echo "to delete the security group, run the following command:"
echo "aws ec2 delete-security-group --group-id $MOUNT_TARGET_GROUP_ID"
echo "aws ec2 delete-security-group --group-id $MOUNT_TARGET_GROUP_ID" >> cleanup.sh
echo ""

# The following set of commands identifies the public subnets in your cluster VPC and creates a mount target in each one of them 
# as well as associate that mount target with the security group you created above.

TAG1=tag:alpha.eksctl.io/cluster-name
TAG2=tag:kubernetes.io/role/elb
subnets=($(aws ec2 describe-subnets --filters "Name=$TAG1,Values=$EKS_CLUSTER_NAME" "Name=$TAG2,Values=1" --output json --no-cli-pager | jq --raw-output '.Subnets[].SubnetId'))
for subnet in ${subnets[@]}
do
    echo "creating mount target in subnet $subnet"
    TMP_ID=$(aws efs create-mount-target --file-system-id $FILE_SYSTEM_ID --subnet-id $subnet --security-groups $MOUNT_TARGET_GROUP_ID --no-cli-pager | jq --raw-output '.MountTargetId')
    #echo $TMP_ID
    echo "created mount target $TMP_ID in " $subnet
    echo "to delete the mount target, run the following command:"
    echo "aws efs delete-mount-target --mount-target-id $TMP_ID"
    echo "aws efs delete-mount-target --mount-target-id $TMP_ID" >> cleanup.sh
    echo ""
done

# wait until all mount targets are available
# if on Mac, install watch with:
# brew install watch
#watch "aws efs describe-mount-targets --file-system-id $FILE_SYSTEM_ID | jq --raw-output '.MountTargets[].LifeCycleState'"
while true; do
    # Run the aws command and store the output in a variable
    output=$(aws efs describe-mount-targets --file-system-id $FILE_SYSTEM_ID --output json --no-cli-pager | jq --raw-output '.MountTargets[].LifeCycleState')

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
helm upgrade nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --set nfs.server=$EFS_DNS_NAME \
    --set nfs.path=/ \
    --set storageClass.name=bns-network-sc \
    --install

echo "Waiting for NFS subdir provisioner to be ready..."
kubectl wait --for=condition=Ready pod --timeout=600s -l  app=nfs-subdir-external-provisioner

echo "NFS subdir provisioner is ready."
