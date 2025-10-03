# Files Service - OCI Object Storage Configuration

This service uses Oracle Cloud Infrastructure (OCI) storage for serving static files.

## Storage Options

The PVC configuration supports two OCI storage backends:

### Option 1: OCI Block Volume (Default - `oci-bv`)
- **Storage Class**: `oci-bv`
- **Access Mode**: ReadWriteOnce (RWO)
- **Use Case**: Single pod access, high-performance block storage
- **Best For**: Single replica deployments

### Option 2: OCI File Storage Service (FSS - `oci-fss`)
- **Storage Class**: `oci-fss`
- **Access Mode**: ReadWriteMany (RWX)
- **Use Case**: Multi-pod access, NFS-based shared storage
- **Best For**: Multi-replica deployments, shared file access

## Setup Instructions

### Prerequisites

1. **OCI CSI Driver** must be installed in your OKE cluster:
   ```bash
   kubectl get storageclass
   # Should show: oci-bv and/or oci-fss
   ```

2. **Configure OCI credentials** (usually automatic on OKE):
   - The CSI driver needs permissions to create block volumes or file systems
   - Ensure your cluster's node pool has proper IAM policies

### Deployment

1. **Apply the PVC**:
   ```bash
   kubectl apply -f pvc.yaml
   ```

2. **Verify PVC is bound**:
   ```bash
   kubectl get pvc -n dylanmtaylor files-oci-pvc
   ```

3. **Deploy the service**:
   ```bash
   kubectl apply -f deployment.yaml
   kubectl apply -f service.yaml
   kubectl apply -f configmap.yaml
   ```

### Switching Storage Backends

To use **OCI FSS** instead of Block Volume:

1. Edit `pvc.yaml` and uncomment the FSS section
2. Comment out or remove the `oci-bv` section
3. Update `accessModes` in deployment if scaling to multiple replicas

### Data Migration

To migrate existing files from hostPath to OCI storage:

```bash
# Create a temporary pod with both volumes mounted
kubectl run -n dylanmtaylor file-migrator --image=busybox --rm -it --restart=Never \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "migrator",
      "image": "busybox",
      "command": ["sh"],
      "volumeMounts": [
        {"name": "source", "mountPath": "/source"},
        {"name": "dest", "mountPath": "/dest"}
      ]
    }],
    "volumes": [
      {"name": "source", "hostPath": {"path": "/var/www/files.dylanmtaylor.com/html"}},
      {"name": "dest", "persistentVolumeClaim": {"claimName": "files-oci-pvc"}}
    ]
  }
}' -- sh -c "cp -av /source/* /dest/"
```

## Monitoring

Check volume status:
```bash
# View PVC details
kubectl describe pvc -n dylanmtaylor files-oci-pvc

# View OCI volume in console
# Go to OCI Console → Block Storage → Block Volumes (or File Storage → File Systems)
```

## Cost Considerations

- **Block Volume**: ~$0.0255/GB-month (varies by region)
- **File Storage**: ~$0.025/GB-month + performance pricing
- Consider sizing appropriately for your file storage needs

## Troubleshooting

### PVC stuck in Pending
- Check if CSI driver is running: `kubectl get pods -n kube-system | grep csi`
- Verify storage class exists: `kubectl get sc`
- Check node permissions in OCI IAM

### Mount errors
- Verify the volume is attached to the node
- Check pod events: `kubectl describe pod -n dylanmtaylor <pod-name>`
- Review CSI driver logs: `kubectl logs -n kube-system <csi-driver-pod>`

## References

- [OCI CSI Driver Documentation](https://github.com/oracle/oci-cloud-controller-manager/blob/master/container-storage-interface.md)
- [OCI Block Volume](https://docs.oracle.com/en-us/iaas/Content/Block/Concepts/overview.htm)
- [OCI File Storage Service](https://docs.oracle.com/en-us/iaas/Content/File/Concepts/filestorageoverview.htm)
