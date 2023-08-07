# eksctl-create-cluster
scripts to quicky setup a K8s cluster using eksctl

## How to use

### Export AWS and EKS varibles

```
export AWS_PROFILE=profile-name
export AWS_REGION=eu-west-1
export EKS_CLUSTER_NAME=test-cluster-2
export EKS_KUBE_VERSION=1.27
```

### Tweak eksctl_template.yaml

You might want to edit the managed node groups or add extra addons

### Generate the eksctl config file

Substitute the env vars from the template file using this command:

```
envsubst < eksctl_template.yaml > eksctl_final.yaml
```


### Create the cluster

Generate the cluster using the generated config file.
This will take ~10 minutes, you need to wait.

```
eksctl create cluster -f eksctl_final.yaml
```

### Add Cluster to your kubectl configuration.

Add the cluster to your `kubectl` configuration by downloading the config from AWS using the following command:
```
aws eks update-kubeconfig --region $AWS_REGION --name $EKS_CLUSTER_NAME
```

### Create the disk (EBS) storage class

Create the storage class:

```
kubectl create -f k8s/sc_disk.yaml

```

And test:

```
kubectl create -f k8s/test_ebs.yaml
kubectl get pvc
```


### Configure EFS storage

This script will create an EFS file system (with a security group and a mount target).
Next, it will install nfs-subdir-external-provisioner (via helm) and configure it to use the EFS.

```
chmod +x configure_efs.sh
sudo ./configure_efs.sh
```

### Finally, test EFS is working
```
kubectl create -f k8s/test_efs.yaml
kubectl get pvc
```
