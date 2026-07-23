# Velero destination resource-modifier examples

## Overview

A source workload often contains values that are valid only on the source platform, such as an image registry, ingress class, StorageClass, security context or platform-specific annotation.

Velero resource modifiers can alter restored resources without changing the source objects or editing the backup itself. Apply and test the required modifier configuration on the destination cluster before creating the restore.

These examples are illustrative. Match conditions narrowly so that unrelated resources are not modified.

## Prerequisites

```bash
export VKS_KUBECONFIG="${HOME}/vks-kubeconfig"
alias vks='kubectl --kubeconfig="${VKS_KUBECONFIG}"'

vks get namespace velero
```

## Example 1: map an image registry

The Velero image-registry mapping plugin configuration can replace a source registry with a destination registry during restore.

```bash
vks -n velero apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: migration-image-registry-mapping
  labels:
    velero.io/change-image-name: RestoreItemAction
    velero.io/plugin-config: ""
data:
  source-to-destination: harbor.source.example.com,harbor.vks.example.com
EOF
```

Verify the ConfigMap:

```bash
vks -n velero get configmap migration-image-registry-mapping -o yaml
```

The exact plugin and label requirements depend on the Velero deployment. Confirm that the image-name RestoreItemAction plugin is installed before relying on this mapping.

## Example 2: change an ingress class

Create a resource-modifier rules file:

```bash
cat > ingress-resource-modifiers.yaml <<'EOF'
version: v1
resourceModifierRules:
  - conditions:
      groupResource: ingresses.networking.k8s.io
      namespaces:
        - application-namespace
    patches:
      - operation: replace
        path: /spec/ingressClassName
        value: contour
EOF
```

Create the destination ConfigMap:

```bash
vks -n velero create configmap migration-ingress-modifiers \
  --from-file=resource-modifier-config.yaml=ingress-resource-modifiers.yaml \
  --dry-run=client -o yaml | vks apply -f -
```

Reference it when creating the restore:

```bash
velero restore create application-restore \
  --kubeconfig="${VKS_KUBECONFIG}" \
  --from-backup application-backup \
  --resource-modifier-configmap migration-ingress-modifiers
```

## Example 3: remove a source-only annotation

Use a JSON Patch `remove` operation only when the field is known to exist on every matching resource. Otherwise, narrow the conditions or use a translation process that tolerates absent fields.

```bash
cat > remove-source-annotation.yaml <<'EOF'
version: v1
resourceModifierRules:
  - conditions:
      groupResource: ingresses.networking.k8s.io
      namespaces:
        - application-namespace
    patches:
      - operation: remove
        path: /metadata/annotations/route.openshift.io~1termination
EOF
```

In JSON Pointer syntax, `/` inside an annotation key is escaped as `~1`.

## Validate restored resources

```bash
vks -n application-namespace get deployment -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
vks -n application-namespace get ingress -o custom-columns='NAME:.metadata.name,CLASS:.spec.ingressClassName,HOSTS:.spec.rules[*].host'
```

Also inspect Velero restore warnings and errors:

```bash
velero restore describe application-restore \
  --kubeconfig="${VKS_KUBECONFIG}" \
  --details
```

## Notes

- Resource modifiers translate Kubernetes objects; they do not migrate image content between registries.
- Helm-managed applications may be better reconstructed from their chart and destination-specific values rather than restored as rendered objects.
- OpenShift-specific resources such as `Route`, `SecurityContextConstraints` and operators generally need explicit replacement or omission on VKS.
