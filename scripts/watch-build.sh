#!/bin/bash
# Usage: nohup ./scripts/watch-build.sh > build-watch.log 2>&1 &
cd "$(dirname "$0")/.."
PR=$(oc get pipelinerun -n windows-build --sort-by=.metadata.creationTimestamp \
     -o jsonpath='{.items[-1].metadata.name}')
echo "$(date) watching $PR"
while true; do
  s=$(oc get pipelinerun "$PR" -n windows-build -o jsonpath='{.status.conditions[0].status}')
  if [ "$s" = "True" ]; then
    echo "$(date) pipeline succeeded"
    oc apply -f vms/win10-01.yaml
    break
  fi
  if [ "$s" = "False" ]; then
    echo "$(date) pipeline FAILED: $(oc get pipelinerun "$PR" -n windows-build -o jsonpath='{.status.conditions[0].message}')"
    break
  fi
  sleep 300
done
