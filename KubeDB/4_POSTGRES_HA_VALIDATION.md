# PostgreSQL HA Validation
Deploys a three-member PostgreSQL cluster with TLS and monitoring, then validates failover, day-2 OpsRequests, backup and restore, and monitoring. Output is taken from the validation run and will differ in names, ages, and identifiers.

## Versions
* PostgreSQL 18.3
* KubeDB v2026.10.12
* KubeStash v2026.10.12

## Requirements
* [Step 3 - Option A](3A_KUBEDB_PLATFORM_INSTALLER.md) or [Step 3 - Option B](3B_KUBEDB_HELM.md) completed
* openssl
* kubectl-kubestash plugin, for on-demand backups (see [client-vm-configuration.md](client-vm-configuration.md))
* An S3-compatible bucket and access keys for the backup test

## Deployment Procedure

### 1. Create the namespace and the TLS CA Issuer
In production, reference an enterprise ClusterIssuer instead of a self-signed CA.
```bash
kubectl create namespace demo
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout ca.key -out ca.crt -subj "/CN=postgres/O=kubedb"
kubectl create secret tls pg-ca --cert=ca.crt --key=ca.key -n demo
kubectl apply -f manifests/pg-ca-issuer.yaml
```
<br>
<br>

### 2. Deploy PostgreSQL
[manifests/pg-ha.yaml](manifests/pg-ha.yaml): PostgreSQL 18.3, 3 members (one primary, two hot standbys), 50Gi per member on `vsan-esa-default-policy-raid5`, TLS through `pg-ca-issuer`, and a ServiceMonitor for kube-prometheus-stack.
```bash
kubectl apply -f manifests/pg-ha.yaml
kubectl get postgres -n demo -w
```
<details>
<summary>Expected output</summary>

```shell
kubectl get postgres -n demo
NAME    VERSION   STATUS   AGE
pg-ha   18.3      Ready    2m

kubectl get pods -n demo -l app.kubernetes.io/instance=pg-ha -L kubedb.com/role
NAME      READY   STATUS    RESTARTS   AGE   ROLE
pg-ha-0   3/3     Running   0          63s   primary
pg-ha-1   3/3     Running   0          47s   standby
pg-ha-2   3/3     Running   0          37s   standby
```
Each pod runs three containers: postgres, the pg-coordinator sidecar that handles leader election, and the Prometheus exporter.
</details>
<br>
<br>

### 3. Check the persistent volumes
Each member has its own claim on the vSAN StorageClass. The same volumes can also be viewed in vCenter under **Cloud Native Storage > Container Volumes**, together with their storage policy compliance.
```bash
kubectl get pvc -n demo
```
<details>
<summary>Expected output</summary>

```shell
NAME           STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
data-pg-ha-0   Bound    pvc-975af0b3-633a-4dd2-ae73-9b4bdd23c621   50Gi       RWO            vsan-esa-default-policy-raid5
data-pg-ha-1   Bound    pvc-ce4c444d-5ed7-4740-9ee4-529d8167ca47   50Gi       RWO            vsan-esa-default-policy-raid5
data-pg-ha-2   Bound    pvc-688e11a0-e965-49a7-9bfb-0ee8279e5ee8   50Gi       RWO            vsan-esa-default-policy-raid5
```
</details>
<br>
<br>

### 4. Write and read test data
Write through the primary Service (`pg-ha`) and read back through the standby Service (`pg-ha-standby`). A member pod serves only as the psql client.
```bash
PGPASSWORD=$(kubectl get secret -n demo pg-ha-auth -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n demo pg-ha-0 -c postgres -- env PGPASSWORD="$PGPASSWORD" \
  psql "host=pg-ha user=postgres sslmode=require" \
  -c "CREATE TABLE ra(id int); INSERT INTO ra VALUES (1),(2),(3);"    # primary Service
kubectl exec -n demo pg-ha-0 -c postgres -- env PGPASSWORD="$PGPASSWORD" \
  psql "host=pg-ha-standby user=postgres sslmode=require" \
  -c "SELECT count(*) FROM ra;"    # standby Service
```
<details>
<summary>Expected output</summary>

```shell
 count
-------
     3
(1 row)
```
</details>
<br>
<br>

### 5. Automatic failover
Delete the primary pod. A standby is promoted, the primary Service follows it, and the old primary rejoins as a standby.
```bash
kubectl delete pod -n demo pg-ha-0
kubectl get pods -n demo -l app.kubernetes.io/instance=pg-ha -L kubedb.com/role -w
```
<details>
<summary>Expected output</summary>

```shell
NAME      READY   STATUS    RESTARTS   AGE    ROLE
pg-ha-0   3/3     Running   0          16s    standby
pg-ha-1   3/3     Running   0          119s   primary
pg-ha-2   3/3     Running   0          109s   standby
```
</details>

Write through the primary Service, which now routes to the new primary:
```bash
kubectl exec -n demo pg-ha-2 -c postgres -- env PGPASSWORD="$PGPASSWORD" \
  psql "host=pg-ha user=postgres sslmode=require" \
  -c "INSERT INTO ra VALUES (4);"
```
<br>
<br>

### 6. Day-2 OpsRequests
Apply each OpsRequest after the previous one reports `Successful`.
```bash
kubectl apply -f manifests/ops-volume-expansion.yaml        # online, 50Gi -> 100Gi
kubectl apply -f manifests/ops-horizontal-scale-up.yaml     # 3 -> 4 members
kubectl apply -f manifests/ops-horizontal-scale-down.yaml   # 4 -> 3 members
kubectl apply -f manifests/ops-vertical-scaling.yaml        # cpu 3 / memory 10Gi
kubectl apply -f manifests/ops-reconfigure-tls.yaml         # rotate certificates
kubectl get postgresopsrequest -n demo -w
```
* Volume expansion grows every member volume while the database stays online; vSphere CSI expands the CNS volumes and file systems in place.
* With four members, KubeDB adds a small arbiter pod (`pg-ha-arbiter-0`) that runs only the coordinator, so leader election always has a quorum. Scaling back to three removes it.
* Vertical scaling and TLS rotation restart the members one at a time, standbys first, and finish with a switchover.
* Version updates use `type: UpdateVersion`.

<details>
<summary>Expected output</summary>

```shell
NAME               TYPE                STATUS       AGE
pg-ha-expand       VolumeExpansion     Successful   16m
pg-ha-scale-4      HorizontalScaling   Successful   14m
pg-ha-scale-3      HorizontalScaling   Successful   13m
pg-ha-vscale       VerticalScaling     Successful   10m
pg-ha-tls-rotate   ReconfigureTLS      Successful   7m
```
</details>
<br>
<br>

### 7. Backup with KubeStash
Update the endpoint, bucket, and region in [manifests/backup-storage.yaml](manifests/backup-storage.yaml). S3-compatible stores such as MinIO also need a region value. If the endpoint uses a certificate from a private CA, add the CA certificate to `s3-secret` as `CA_CERT_DATA`. The BackupStorage is not marked as the cluster default because the AppsCode installer already creates one.
```bash
kubectl create secret generic -n demo s3-secret \
  --from-literal=AWS_ACCESS_KEY_ID=<KEY> --from-literal=AWS_SECRET_ACCESS_KEY=<SECRET>
kubectl create secret generic -n demo encrypt-secret --from-literal=RESTIC_PASSWORD=<PASSWORD>

kubectl apply -f manifests/backup-storage.yaml
kubectl apply -f manifests/retention-policy.yaml
kubectl apply -f manifests/backup-configuration.yaml

kubectl get backupconfiguration,backupsession -n demo
kubectl get snapshots -n demo -l kubestash.com/repo-name=pg-ha-repo
```
KubeStash takes the first backup as soon as the BackupConfiguration is created and then follows the schedule (`0 1 * * *`). To take a backup on demand:
```bash
kubectl kubestash trigger pg-ha-backup -n demo --sessions nightly
```
<br>
<br>

### 8. Restore into a new database
`waitForInitialRestore` keeps `pg-restored` from accepting connections until the RestoreSession completes.
```bash
kubectl apply -f manifests/pg-restored.yaml
kubectl apply -f manifests/restore-session.yaml
kubectl get restoresession -n demo -w
```
The restored database contains every row written to pg-ha, including the row written after the failover. Any member of pg-restored can become its primary, so do not assume pod 0 is the primary; reads work on every member.
```bash
kubectl exec -n demo pg-restored-0 -c postgres -- psql -U postgres -c "SELECT count(*) FROM ra;"
```
<details>
<summary>Expected output</summary>

```shell
 count
-------
     4
(1 row)
```
</details>
<br>
<br>

### 9. Monitoring
KubeDB creates the ServiceMonitor `pg-ha-stats` with the label `release: kube-prometheus-stack`. Prometheus scrapes two endpoints on every member: the PostgreSQL exporter (`metrics`) and the pg-coordinator (`raft-metrics`). In Grafana, the **KubeDB / Postgres / Summary** dashboard shows the database.
```bash
kubectl get servicemonitor -n demo pg-ha-stats

# Prometheus query: up{namespace="demo", job="pg-ha-stats"}
# Returns 1 for all six targets (three members x two endpoints)
```

## Validation Results

| Test | Expected result | Result |
|---|---|---|
| Provisioning | Status Ready; one primary and two standbys; three bound CNS volumes | Pass. Ready in 71 s |
| Failover | A standby is promoted; the primary Service follows it; the old primary rejoins as a standby | Pass. Standby promoted in 31 s; old primary rejoined in 47 s |
| Volume expansion | All PVCs grow to the new size without restart | Pass. 2 min 28 s; no pod restarts |
| Horizontal scaling | Replica count changes with the database available | Pass. 68 s up; 1 min 51 s down |
| Vertical scaling | Every member runs with the new CPU and memory after a rolling restart | Pass. 3 min 8 s |
| TLS rotation | New server certificates are issued; data is intact | Pass. 5 min 3 s |
| Backup and restore | Snapshot succeeds; restored database contains the test data | Pass. Backup in 9 s; restore in 37 s; all rows restored |
| Monitoring | Database metrics are scraped and displayed | Pass. All pg-ha targets up; dashboard populated |

## Cleanup Procedure
```bash
kubectl delete -f manifests/restore-session.yaml -f manifests/pg-restored.yaml
kubectl delete -f manifests/backup-configuration.yaml -f manifests/retention-policy.yaml -f manifests/backup-storage.yaml
kubectl delete postgresopsrequest -n demo --all
kubectl delete -f manifests/pg-ha.yaml -f manifests/pg-ca-issuer.yaml
kubectl delete namespace demo
```
