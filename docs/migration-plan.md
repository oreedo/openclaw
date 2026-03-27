# Kubernetes Cluster Migration Plan

**Source Cluster:** hosted on Hetzner Cloud (~59 EUR/month)
**Target:** TBD (self-hosted or alternative cloud environment)

---

## Overview
This document outlines the steps required to migrate the Kubernetes cluster, emphasizing critical components:
- **Vault**
- **MSSQL**
- **Rentek**

---

## Step 1: Assess Current Cluster

### 1.1 Backup Cluster Configuration
- Export Kubernetes manifests (all resources):
  ```bash
  kubectl get all -A -o yaml > all-resources.yaml
  ```
- Record current Helm releases:
  ```bash
  helm list -A > helm-list-summary.txt
  ```

### 1.2 Specific Components
#### Vault
- Create a backup of Vault:
  ```bash
  vault operator snapshot save vault-backup.snap
  ```
- Secure the unseal keys and root tokens.

#### MSSQL
- Backup MSSQL databases:
  ```bash
  BACKUP DATABASE [YourDB] TO DISK = N'/var/opt/mssql/backups/YourDB.bak'
  ```

#### Rentek
- Export Rentek manifests:
  ```bash
  kubectl get deployment rentek -n rentek -o yaml > rentek-deployment.yaml
  kubectl get svc rentek -n rentek -o yaml > rentek-service.yaml
  ```

---

## Step 2: Prepare Target Environment

### 2.1 Install Kubernetes
- Choose the distribution (MicroK8s, K3s, or kubeadm).
- Configure the networking (CNI with Calico, DNS).

### 2.2 Replicate Storage Class
- Ensure storage mechanism matches (e.g., microk8s-hostpath).
- Replicate or configure Persistent Volume bindings.

### 2.3 Install Critical Tools
- Install Ingress NGINX:
  ```bash
  helm install ingress-nginx ingress-nginx/ingress-nginx
  ```
- Install Helm if not already installed.

---

## Step 3: Restore Critical Components

### 3.1 Vault
1. Deploy Vault using Helm on the new cluster.
2. Restore the snapshot:
   ```bash
   vault operator snapshot restore vault-backup.snap
   ```

### 3.2 MSSQL
1. Deploy MSSQL Helm chart.
2. Restore the database backup:
   ```bash
   RESTORE DATABASE [YourDB] FROM DISK = N'/var/opt/mssql/backups/YourDB.bak'
   ```

### 3.3 Rentek
1. Apply the deployment and service manifests:
   ```bash
   kubectl apply -f rentek-deployment.yaml
   kubectl apply -f rentek-service.yaml
   ```
2. Ensure ingress and DNS point to the updated target.

---

## Step 4: Validate and Test

### 4.1 Smoke Testing
- Verify the readiness of Vault and its unseal process.
- Test database integrity for MSSQL.
- Test Rentek application functionality.

### 4.2 Performance Testing
- Check load handling of the new environment.

---

## Step 5: Switch Over

### 5.1 Update DNS Records
- Point domains to the new target IP.

### 5.2 Decommission Old Cluster
- Ensure smooth switchover before shutting down Vestner instance.

---

_End of Document_