#!/bin/bash

# Namespace
NAMESPACE="simulators"

# Loop from 4800 to 4999
for i in $(seq 4800 4999); do
  POD_NAME="rea-assets-$i"
  LOG_FILE="rea-assets-$i.log"
  
  echo "Collecting logs from $POD_NAME..."
  kubectl logs "$POD_NAME" -n "$NAMESPACE" > "$LOG_FILE"
done

echo "Log collection complete."

