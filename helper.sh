#!/bin/bash

ignored_labels=(
    "beta.kubernetes.io/arch"
    "beta.kubernetes.io/os"
    "kubernetes.io/arch"
    "kubernetes.io/hostname"
    "kubernetes.io/os"
)

node_info=$(kubectl get nodes -o json)
node_names=$(echo "$node_info" | jq -r '.items[].metadata.name')

show_labels() {
    echo "Showing Node Labels (excluding ignored)..."
    while IFS= read -r node; do
        echo "Node: $node"
        labels=$(echo "$node_info" | jq -r --arg node "$node" \
            '.items[] | select(.metadata.name == $node) | .metadata.labels | to_entries[] | "\(.key): \(.value)"')

        while IFS= read -r label; do
            key="${label%%:*}"
            is_ignored=false
            for ignored_label in "${ignored_labels[@]}"; do
                if [[ "$key" == "$ignored_label" ]]; then
                    is_ignored=true
                    break
                fi
            done

            if [[ $is_ignored == false ]]; then
                echo "  - $label"
            fi
        done <<< "$labels"
        echo ""
    done <<< "$node_names"
}

show_taints() {
    echo "Showing Node Taints..."
    while IFS= read -r node; do
        echo "Node: $node"
        taints=$(echo "$node_info" | jq -r --arg node "$node" '
            .items[] 
            | select(.metadata.name == $node) 
            | .spec.taints // [] 
            | map("\(.key)=\(.value):\(.effect)") 
            | .[]')

        if [[ -z "$taints" ]]; then
            echo "  (no taints)"
        else
            while IFS= read -r taint; do
                echo "  - $taint"
            done <<< "$taints"
        fi
        echo ""
    done <<< "$node_names"
}


mark_volume() {
    echo "[+] Annotating Pods with specific PVC volume names for Velero backup..."
    namespaces=$(kubectl get namespaces -o=jsonpath='{.items[*].metadata.name}')
    for namespace in $namespaces; do
        if [[ "$namespace" == "velero" ]]; then
            continue
        fi
        pods=$(kubectl get pods -n "$namespace" -o=jsonpath='{.items[*].metadata.name}')
        for pod in $pods; do
            volume_names=$(kubectl get pod "$pod" -n "$namespace" -o json | \
                jq -r '[.spec.volumes[] | select(.persistentVolumeClaim != null) | .name] | join(",")')
            if [[ ! -z "$volume_names" ]]; then
                echo "  -> Annotating pod '$pod' in namespace '$namespace' with volumes: $volume_names"
                kubectl -n "$namespace" annotate pod "$pod" \
                    "backup.velero.io/backup-volumes=$volume_names" --overwrite
            fi
        done
    done
    echo "Done annotating pods with volume names."
}

unmark_volume () {
    echo "[+] Removing Velero volume annotations from Pods..."
    namespaces=$(kubectl get namespaces -o=jsonpath='{.items[*].metadata.name}')
    for namespace in $namespaces; do
        if [[ "$namespace" == "velero" ]]; then
            continue
        fi
        pods=$(kubectl get pods -n "$namespace" -o=jsonpath='{.items[*].metadata.name}')
        for pod in $pods; do
            has_annotation=$(kubectl get pod "$pod" -n "$namespace" -o json | \
                jq -r '.metadata.annotations["backup.velero.io/backup-volumes"] // empty')
            if [[ ! -z "$has_annotation" ]]; then
                echo "  -> Removing annotation from pod '$pod' in namespace '$namespace'"
                kubectl annotate pod "$pod" -n "$namespace" backup.velero.io/backup-volumes- --overwrite
            fi
        done
    done
    echo "Done removing annotations."
}


GetNamespaceResourceLabel() {
    kubectl api-resources --verbs=list --namespaced -o name | \
    xargs -n 1 kubectl get --show-kind --ignore-not-found --namespace="$1" -o json | \
    jq -c '.items[] | {kind: .kind, name: .metadata.name, labels: .metadata.labels}'
}

GetClusterResourceLabel() {
    kubectl api-resources --namespaced=false --verbs=list -o name | xargs -n 1 kubectl get --show-kind --ignore-not-found -o json | \
    jq -c '.items[] | {kind: .kind, name: .metadata.name, labels: .metadata.labels}'
}

test() {
    echo "Testing resource labels..."
    # namespace="kube-system"
    resource_labels=$(GetClusterResourceLabel)
    while IFS= read -r label_info; do
        echo "Resource Label: $label_info"
    done <<< "$resource_labels"
}


usage() {
    echo "Usage: $0 [label|taint|mark-volume|unmark_volume|all]"
    exit 1
}

case "$1" in
    label)
        show_labels
        ;;
    taint)
        show_taints
        ;;
    mark-volume)
        mark_volume
        ;;
    unmark_volume)
        unmark_volume
        ;;
    test)
        test
        ;;
    all)
        show_labels
        show_taints
        ;;
    *)
        usage
        ;;
esac

