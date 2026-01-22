#!/bin/bash

# This script cleans up EFS resources created for the EKS cluster.
# It discovers resources based on the EKS_CLUSTER_NAME environment variable.

# export AWS_REGION=eu-west-1
# export EKS_CLUSTER_NAME=test-cluster-1


if [ -z "$EKS_CLUSTER_NAME" ]; then
  echo "Error: EKS_CLUSTER_NAME environment variable is not set."
  exit 1
fi

if [ -z "$AWS_REGION" ]; then
  echo "Error: AWS_REGION environment variable is not set."
  exit 1
fi

echo "--- Starting EFS Cleanup for cluster: $EKS_CLUSTER_NAME ---"

# 1. Discover File System ID by tag
FILE_SYSTEM_ID=$(aws efs describe-file-systems --query "FileSystems[?Tags[?Key=='for' && Value=='$EKS_CLUSTER_NAME']].FileSystemId" --output text --region $AWS_REGION)

if [ -z "$FILE_SYSTEM_ID" ] || [ "$FILE_SYSTEM_ID" == "None" ]; then
  echo "No EFS file system found for cluster $EKS_CLUSTER_NAME. Skipping..."
else
  echo "Found File System: $FILE_SYSTEM_ID"

  # 2. Delete Mount Targets first
  MOUNT_TARGET_IDS=$(aws efs describe-mount-targets --file-system-id $FILE_SYSTEM_ID --query "MountTargets[].MountTargetId" --output text --region $AWS_REGION)
  
  for MT_ID in $MOUNT_TARGET_IDS; do
    echo "Deleting Mount Target: $MT_ID"
    aws efs delete-mount-target --mount-target-id $MT_ID --region $AWS_REGION 2>/dev/null || true
  done

  if [ -n "$MOUNT_TARGET_IDS" ]; then
    echo "Waiting for mount targets to be fully deleted..."
    while true; do
      MT_COUNT=$(aws efs describe-mount-targets --file-system-id $FILE_SYSTEM_ID --query "length(MountTargets)" --output text --region $AWS_REGION 2>/dev/null || echo 0)
      if [ "$MT_COUNT" -eq 0 ]; then
        echo "All mount targets deleted."
        break
      fi
      sleep 5
    done
  fi

  # 3. Delete Security Group
  # Discover SG by name/tag
  SG_ID=$(aws ec2 describe-security-groups --filters "Name=tag:for,Values=$EKS_CLUSTER_NAME" "Name=group-name,Values=eks-efs-group-$EKS_CLUSTER_NAME" --query "SecurityGroups[0].GroupId" --output text --region $AWS_REGION)
  
  if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
    echo "No EFS security group found. Skipping..."
  else
    echo "Deleting Security Group: $SG_ID"
    # SGs sometimes take a moment to release after MTs are gone
    RETRY=0
    while [ $RETRY -lt 5 ]; do
      if aws ec2 delete-security-group --group-id $SG_ID --region $AWS_REGION 2>/dev/null; then
        echo "Security group deleted."
        break
      else
        echo "Security group still in use, retrying in 10s... ($((RETRY+1))/5)"
        sleep 10
        RETRY=$((RETRY+1))
      fi
    done
  fi

  # 4. Finally Delete File System
  echo "Deleting File System: $FILE_SYSTEM_ID"
  aws efs delete-file-system --file-system-id $FILE_SYSTEM_ID --region $AWS_REGION 2>/dev/null || true
  
  echo "Waiting for File System to be fully deleted..."
  while aws efs describe-file-systems --file-system-id $FILE_SYSTEM_ID --region $AWS_REGION 2>/dev/null; do
    sleep 5
  done
  echo "File system deleted."
fi

# 5. Uninstall Helm chart if it exists (only if cluster is still reachable)
if kubectl version --client >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
  if helm list -A 2>/dev/null | grep -q "nfs-subdir-external-provisioner"; then
    echo "Uninstalling Helm chart: nfs-subdir-external-provisioner"
    helm uninstall nfs-subdir-external-provisioner 2>/dev/null || true
  fi
else
  echo "Cluster is unreachable or already deleted. Skipping Helm cleanup."
fi

echo "--- Cleanup Complete ---"
