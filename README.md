# eksctl-create-cluster

scripts to quicky setup a K8s cluster using eksctl

## How to use

### Export AWS and EKS varibles

```bash
export AWS_PROFILE=profile-name
export AWS_REGION=eu-west-1
export EKS_CLUSTER_NAME=test-cluster-2
export EKS_KUBE_VERSION=1.29
```

### Tweak eksctl_template.yaml

You want to edit template to:

- enable/disable encryption at rest for the node group instances (not the PVs)
- set number of nodes and node size
- add other node groups

Edit the template, especially the sections below `# edit-this` comments

### Generate the eksctl config file

Substitute the env vars from the template file using this command:

```bash
envsubst < eksctl_template.yaml > eksctl_final.yaml
```

### Create the cluster

Generate the cluster using the generated config file.
This will take ~10 minutes, you need to wait.

```bash
eksctl create cluster -f eksctl_final.yaml
```

### Grant other IAM users access to the cluster

By default only the IAM user used to create the cluster will have access to cluster in the AWS console.
If the user you will use to connect the cluster to Bunnyshell is not the user used to create the cluster, you need to grant access to this extra user.
To grant other IAM users access to the cluster, use one of the two approaches:

#### Option 1: use eksctl

Set these variables:

```bash
# your AWS account ID
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --no-cli-pager)

# set this to the IAM account name that you will use to connect the cluster to Bunnyshell (or other IAM user you wish to grant access to the cluster)
export IAM_USER_NAME=__RELEVANT-IAM-USER-NAME__
```

Run this command:

```bash
eksctl create iamidentitymapping \
    --cluster $EKS_CLUSTER_NAME \
    --region $AWS_REGION \
    --arn arn:aws:iam::${AWS_ACCOUNT_ID}:user/${IAM_USER_NAME} \
    --group system:masters \
    --no-duplicate-arns \
    --username admin-user1
```

#### Option 2: Manually Edit the ConfigMap

Manually edit the `aws-auth` configMap using this command.

```bash
kubectl edit configMap aws-auth -n kube-system -o yaml
```

and add/edit the `mapUsers` section, replace `$AWS_ACCOUNT_ID`, `$IAM_USER_NAME` accordingly:

```yaml
apiVersion: v1
data:
  mapRoles: |
    - groups:
      - system:bootstrappers
      - system:nodes
      rolearn: arn:aws:iam::967682345001:role/eksctl-ao-test-2024-03-nodegroup-d-NodeInstanceRole-HOab7BogHnEV
      username: system:node:{{EC2PrivateDNSName}}
  mapUsers: |
    - groups:
      - system:masters
      userarn: arn:aws:iam::$AWS_ACCOUNT_ID:user/$IAM_USER_NAME
      username: admin
kind: ConfigMap
```


### Get the kubeconfig.yaml for the cluster

Set the value of KUBECONFIG variable to the path of the file where you want to store your `kubeconfig.yaml`, then export with `aws eks update-kubeconfig` 

```bash
export KUBECONFIG=$(pwd)/kubeconfig.yaml
aws eks update-kubeconfig --region $AWS_REGION --name $EKS_CLUSTER_NAME
```

### Connect the cluster to Bunnyshell

Run this command to get the details needed to connect you new cluster to Bunnyshell:

```bash
CLUSTER_URL=$(cat $KUBECONFIG | yq ".clusters[0].cluster.server")
CERT_DATA=$(cat $KUBECONFIG | yq ".clusters[0].cluster.certificate-authority-data")

echo "\nConnect to Bunnyshell using these values:" \
    && echo "cluster name: ${EKS_CLUSTER_NAME}" \
    && echo "cluster URL: ${CLUSTER_URL}" \
    && echo "certificate authority data: \n${CERT_DATA}"
```

### (OPTIONAL) Configure storage for the cluster

You can skip this section if you use the Bunnyshell Volumes Add-on to create volumes on this cluster.

#### 1. Create the disk (EBS) storage class

Create the storage class:

```bash
kubectl create -f k8s/sc_disk.yaml

```

And test:

```bash
kubectl create -f k8s/test_ebs.yaml
kubectl get pvc
```

#### 2. Configure EFS storage

You can skip this step if you use the Bunnyshell Volumes Add-on to create volumes on this cluster.

This script will create an EFS file system (with a security group and a mount target).
Next, it will install nfs-subdir-external-provisioner (via helm) and configure it to use the EFS.

```bash
sh configure_efs.sh
```

Finally, test EFS is working:

```bash
kubectl create -f k8s/test_efs.yaml
kubectl get pvc
```

### Delete the cluster

Run this command to delete the cluster.

```bash
eksctl delete cluster -f eksctl_final.yaml

bash cleanup.sh
```

List all resources created outside of CloudFormation

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=for,Values=$EKS_CLUSTER_NAME
```
