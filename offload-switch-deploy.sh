#!/bin/bash

# Exit on error
#set -e

# This script deploys the chart using the zenoh-bridge-dds
# Usage:
# ./offload-switch-deploy.sh [switch|delete|apply]
# switch: switches the deployment between local and remote mode
# delete: deletes the deployment
# apply: installs the deployment

PATH_TO_FOLDER="./charts/rb-theron-sim-zenoh-bridge-dds/"
DEPLOYMENT_NAME="theron-sim"

status="LOCAL"

# Function to check if a Helm deployment exists
check_helm_deployment_exists() {
  local deployment_name=$1

  # Use helm list and grep to check for the deployment name
  if helm list --short | grep -q "^${deployment_name}$"; then
    echo "Deployment ${deployment_name} exists."
    return 0
  else
    echo "Deployment ${deployment_name} does not exist."
    return 1
  fi
}
# Function to check if the number of replicas for a deployment is 0
check_replicas_zero() {
  local deployment_name=$1
  local namespace=$2

  # Get the number of replicas for the deployment
  replicas=$(kubectl get deployment "$deployment_name" -n "$namespace" -o json | jq '.spec.replicas')

  # Check if the number of replicas is 0
  if [ "$replicas" -eq 0 ]; then
    echo "The number of replicas for deployment $deployment_name is 0."
    return 0
  else
    echo "The number of replicas for deployment $deployment_name is not 0. Current replicas: $replicas"
    return 1
  fi
}

# Function to wait for a deployment to complete its rollout
wait_for_rollout() {
  local deployment_name=$1
  local namespace=$2

  echo "Waiting for deployment $deployment_name to complete its rollout..."
  kubectl rollout status deployment "$deployment_name" -n "$namespace"
}

# Function to handle the switch command
handle_switch() {
  if [ "$status" == "LOCAL" ]; then
      kubectl patch deployment robot-1-navigation -n default --type='json' -p='[{
        "op": "replace",
        "path": "/spec/template/spec/affinity",
        "value": {
          "nodeAffinity": {
            "requiredDuringSchedulingIgnoredDuringExecution": {
              "nodeSelectorTerms": [
                {
                  "matchExpressions": [
                    {
                      "key": "liqo.io/type",
                      "operator": "In",
                      "values": ["virtual-node"]
                    }
                  ]
                }
              ]
            }
          }
        }
      }]'
      wait_for_rollout robot-1-navigation default
      status="REMOTE"
  elif [ "$status" == "REMOTE" ]; then
      kubectl patch deployment robot-1-navigation -n default --type='json' -p='[{
        "op": "replace",
        "path": "/spec/template/spec/affinity",
        "value": {
          "nodeAffinity": {
            "requiredDuringSchedulingIgnoredDuringExecution": {
              "nodeSelectorTerms": [
                {
                  "matchExpressions": [
                    {
                      "key": "liqo.io/type",
                      "operator": "NotIn",
                      "values": ["virtual-node"]
                    }
                  ]
                }
              ]
            }
          }
        }
      }]'
      wait_for_rollout robot-1-navigation default
      status="LOCAL"    
  else
      echo "Invalid status: $status"
  fi
}


do_charge_robot() {
  echo "Charging robot, press any key to stop charging..."

  # switch off switchable nodes, which are identified by the switch-off label set to true
  # Get all deployments with the label switch-off=true
  deployments=$(kubectl get deployments -l switchOff=enabled -o jsonpath='{.items[*].metadata.name}')

  # Loop through each deployment and patch it to set replicas to 0
  for deployment in $deployments; do
    echo "Patching deployment $deployment to set replicas to 0"
    kubectl patch deployment $deployment --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":0}]'
  done

  # wait for a keypress
  read -n 1 -s -r -p ""

  # Get all deployments with the label switch-off=true
  deployments=$(kubectl get deployments -l switchOff=enabled -o jsonpath='{.items[*].metadata.name}')

  # Loop through each deployment and patch it to set replicas to 0
  for deployment in $deployments; do
    echo "Patching deployment $deployment to set replicas to 1"
    kubectl patch deployment $deployment --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":1}]'
  done
}



# Function to handle termination
terminate_deployment() {
  echo "Terminating deployment..."
  helm delete "$DEPLOYMENT_NAME"
  exit 0
}

# Trap SIGINT and SIGTERM to terminate the deployment
trap terminate_deployment SIGINT SIGTERM

# Start the deployment
if ! check_helm_deployment_exists "$DEPLOYMENT_NAME"; then
  echo "Deployment not found. Installing it now..."
  #echo "Offloading default namespace..."
  #liqoctl offload namespace default
  helm install "$DEPLOYMENT_NAME" "$PATH_TO_FOLDER" --values "$PATH_TO_FOLDER/values.yaml" --wait
  echo "Waiting for deployment $deployment_name to complete its rollout..."
  kubectl rollout status deployment "$deployment_name" -n "$namespace"

  echo "Waiting for all pods in namespace $NAMESPACE to be running..."
  while true; do
    not_ready_pods=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase!=Running | wc -l)
    if [ "$not_ready_pods" -eq 0 ]; then
      echo "All pods in namespace $NAMESPACE are running."
      break
    else
      echo "There are $not_ready_pods pods not running yet. Waiting..."
      sleep 5
    fi
  done
fi

# Monitor for the switch and monitor commands
while true; do
  read -r -p "Enter command (switch to switch mode, monitor to monitor pods, charge to charge, exit to exit): " cmd
  if [ "$cmd" == "switch" ] || [ "$cmd" == "s" ] || [ "$cmd" == "sw" ]; then
    handle_switch
  elif [ "$cmd" == "monitor" ] || [ "$cmd" == "m" ] || [ "$cmd" == "mon" ]; then
    kubectl get pods -o=wide
  elif [ "$cmd" == "charge" ] || [ "$cmd" == "c" ]; then
    do_charge_robot
  elif [ "$cmd" == "exit" ] || [ "$cmd" == "quit" ] || [ "$cmd" == "q" ]; then
    terminate_deployment
  fi
done