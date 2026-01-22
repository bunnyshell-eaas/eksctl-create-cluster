# EKS Cluster Setup with eksctl

Scripts to quickly setup a Kubernetes cluster on AWS using `eksctl`.

## 1. Prerequisites & Environment Variables

Export the necessary AWS and EKS variables. Choose either your local profile or direct credentials.

```bash
export AWS_REGION=eu-west-1
export EKS_CLUSTER_NAME=test-cluster-1
export EKS_KUBE_VERSION=1.34

# Option A: Use a local AWS Profile
export AWS_PROFILE=profile-name

# Option B: Use manual credentials
export AWS_ACCESS_KEY_ID="XXXX"
export AWS_SECRET_ACCESS_KEY="XXXX"
export AWS_SESSION_TOKEN="XXXX" # Optional
```

### Tools Management (Optional: mise)

This repository includes a `mise.toml` to manage required tools (`eksctl`, `kubectl`, `helm`, `jq`, `yq`, etc.). If you have [mise](https://mise.jenv.nz/) installed, you can simply run:

```bash
# Install mise if you haven't already
# curl https://mise.run | sh

# Install all required tools
mise install

# The tools will be automatically available in your shell when you are in this directory.
```

---

## 2. Cluster Configuration

### Tweak the Template
Edit `eksctl_template.yaml` to customize your cluster requirements:
- Enable/disable encryption at rest for node groups.
- Set instance sizes and desired capacity (nodes).
- Add or modify managed node groups.

Search for `# edit-this` comments in the template for quick changes.

### Generate Final Manifest
Substitute the environment variables into the template:
```bash
envsubst < eksctl_template.yaml > eksctl_final.yaml
```

---

## 3. Deployment

### Create the Cluster
This process typically takes ~15 minutes.
```bash
eksctl create cluster -f eksctl_final.yaml
```

### Get Kubeconfig
Store your cluster credentials in a local file:
```bash
export KUBECONFIG=$(pwd)/kubeconfig.yaml
aws eks update-kubeconfig --region $AWS_REGION --name $EKS_CLUSTER_NAME
```

---

## 4. Access Management (IAM)

By default, only the IAM entity that created the cluster has access to it. To allow other users (like a dedicated Bunnyshell service account) to manage the cluster, follow these steps:

### Step 4.1: Create the IAM User
You can create the user via the AWS Console or the CLI.

#### Option A: CLI (Fastest)
```bash
export IAM_USER_NAME=bunnyshell-test-cluster-1

# 1. Create the user
aws iam create-user --user-name $IAM_USER_NAME

# 2. Attach required policies
aws iam attach-user-policy --user-name $IAM_USER_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
aws iam attach-user-policy --user-name $IAM_USER_NAME --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
aws iam attach-user-policy --user-name $IAM_USER_NAME --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

# 3. Create Access Keys (Save the output!)
aws iam create-access-key --user-name $IAM_USER_NAME
```

#### Option B: AWS Console
1. **IAM > Users > Create User**: Name it `bunnyshell-test-cluster-1`.
2. **Attach Policies**: `AmazonEBSCSIDriverPolicy`, `AmazonEKSClusterPolicy`, and `AdministratorAccess`.
3. **Security Credentials**: Create an "Access key" for a "Third-party service".

---

### Step 4.2: Grant Cluster Access (Mapping)
Creating the AWS user is not enough; you must map the IAM ARN to a Kubernetes group.

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export IAM_USER_NAME=bunnyshell-test-cluster-1

eksctl create iamidentitymapping \
    --cluster $EKS_CLUSTER_NAME \
    --region $AWS_REGION \
    --arn arn:aws:iam::${AWS_ACCOUNT_ID}:user/${IAM_USER_NAME} \
    --group system:masters \
    --no-duplicate-arns \
    --username $IAM_USER_NAME
```

### Option 2: Manually Edit ConfigMap
```bash
kubectl edit configMap aws-auth -n kube-system
```
Add to `mapUsers`:
```yaml
mapUsers: |
  - groups:
      - system:masters
    userarn: arn:aws:iam::123456789012:user/your-user
    username: admin
```

---

## 5. Storage Configuration

### Step 1: Create the Primary Disk (gp3) Storage Class
This creates a modern `gp3` storage class and sets it as the cluster default.
```bash
kubectl create -f k8s/sc_disk.yaml
```

### Step 2: Update Legacy gp2
Update the existing legacy `gp2` class to use the modern CSI driver and `gp3` volumes for backward compatibility.
```bash
kubectl delete sc gp2  # Delete first
kubectl apply -f k8s/update_gp2.yaml
```



### Step 3: Test Storage
```bash
kubectl apply -f k8s/test_ebs.yaml  # Creates a pvc
kubectl apply -f k8s/test_ebs_withpod.yaml
kubectl get pvc # Should be bound
kubectl delete -f k8s/test_ebs_withpod.yaml
kubectl delete -f k8s/test_ebs.yaml
```

### Step 4: (Optional) EFS Network Storage
For multi-node shared storage (ReadWriteMany):
```bash
bash configure_efs.sh

# Test EFS
kubectl create -f k8s/test_efs.yaml
kubectl get pvc
kubectl delete -f k8s/test_efs.yaml   # Delete pvc
```

---

## 6. Bunnyshell Connection

Retrieve the details needed to connect your cluster to the Bunnyshell platform:
```bash
CLUSTER_URL=$(yq ".clusters[0].cluster.server" < $KUBECONFIG)
CERT_DATA=$(yq ".clusters[0].cluster.certificate-authority-data" < $KUBECONFIG)

echo "Connect to Bunnyshell using these values:"
echo "Cluster Name: ${EKS_CLUSTER_NAME}"
echo "Cluster URL: ${CLUSTER_URL}"
echo "CA Data: ${CERT_DATA}"
```

---

## 7. Cleanup

To avoid ongoing AWS costs, delete all resources when finished:
```bash
eksctl delete cluster -f eksctl_final.yaml
bash cleanup.sh
```