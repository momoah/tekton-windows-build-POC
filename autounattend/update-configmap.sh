#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
oc create configmap win10-soe-autounattend -n windows-build \
  --from-file=autounattend.xml --from-file=post-install.ps1 \
  --dry-run=client -o yaml | oc apply -f -
oc get configmap win10-soe-autounattend -n windows-build \
  -o go-template='{{range $k, $v := .data}}{{$k}}  {{len $v}} bytes{{"\n"}}{{end}}'
