#!/bin/bash
set -euo pipefail
MIRROR=quay.local.labmesh.org/mirror
SRC=registry.redhat.io/container-native-virtualization

for img in kubevirt-tekton-tasks-create-datavolume-rhel9 \
           kubevirt-tekton-tasks-disk-virt-customize-rhel9 \
           virtio-win-rhel9; do
  skopeo copy --all --preserve-digests \
    docker://$SRC/$img:v4.21.0 docker://$MIRROR/$img:v4.21.0
done

skopeo copy --all --preserve-digests \
  docker://registry.redhat.io/openshift4/ose-cli@sha256:3d5b31cc3fbf878015e5c3ed1d48379d74b15b77a1a823024a7a2b7cd5e2e86d \
  docker://$MIRROR/ose-cli:pipelines-0.2.2
