#!/usr/bin/env bash
# rapid_triage.sh — ECS/ALB/n8n triage without side effects. (AWS CLI v2 compatible)
# Usage:
#   ./rapid_triage.sh [--user-slug brbaker] [--cluster CLUSTER] [--service SERVICE] \
#     [--region us-east-1] [--profile alog-admin] [--since 30m] [--probe]
#
# Notes:
# - Autodiscovers cluster/service (prefers names containing 'n8n' and/or the user slug).
# - Prints service status, last events, task stop reasons, TD ports, log config, TG/ALB health.
# - If --probe is set, will curl /<user-slug>/healthz (or /healthz if no slug) via the ALB DNS.
# - Requires: aws, jq, curl.
set -euo pipefail

# --- defaults ---
USER_SLUG=""
CLUSTER_IN=""
SERVICE_IN=""
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-default}"
SINCE="30m"
DO_PROBE="0"

# --- args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-slug) USER_SLUG="${2:-}"; shift 2 ;;
    --cluster)   CLUSTER_IN="${2:-}"; shift 2 ;;
    --service)   SERVICE_IN="${2:-}"; shift 2 ;;
    --region)    AWS_REGION="${2:-}"; shift 2 ;;
    --profile)   AWS_PROFILE="${2:-}"; shift 2 ;;
    --since)     SINCE="${2:-}"; shift 2 ;;
    --probe)     DO_PROBE="1"; shift ;;
    -h|--help)
      sed -n '1,120p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- prereqs ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 3; }; }
need aws; need jq; need curl

say() { printf "\n=== %s ===\n" "$*"; }
info() { printf " - %s\n" "$*"; }

# --- discover cluster ---
say "Discovering ECS cluster"
if [[ -n "$CLUSTER_IN" ]]; then
  CLUSTER="$CLUSTER_IN"
else
  mapfile -t CLUSTERS < <(aws ecs list-clusters --region "$AWS_REGION" --profile "$AWS_PROFILE" | jq -r '.clusterArns[]?')
  if [[ ${#CLUSTERS[@]} -eq 0 ]]; then
    echo "No ECS clusters found in region $AWS_REGION (profile $AWS_PROFILE)"; exit 4
  fi
  CANDIDATE=$(printf "%s\n" "${CLUSTERS[@]}" | grep -i 'n8n' | head -n1 || true)
  CLUSTER="${CANDIDATE##*/}"
  if [[ -z "$CLUSTER" ]]; then
    CLUSTER="${CLUSTERS[0]##*/}"
  fi
fi
info "Cluster: $CLUSTER"

# --- discover service ---
say "Discovering ECS service"
if [[ -n "$SERVICE_IN" ]]; then
  SERVICE="$SERVICE_IN"
else
  mapfile -t SVCS < <(aws ecs list-services --cluster "$CLUSTER" --region "$AWS_REGION" --profile "$AWS_PROFILE" | jq -r '.serviceArns[]?')
  if [[ ${#SVCS[@]} -eq 0 ]]; then
    echo "No ECS services found in cluster $CLUSTER"; exit 5
  fi
  CAND=""
  if [[ -n "$USER_SLUG" ]]; then
    CAND=$(printf "%s\n" "${SVCS[@]}" | grep -i "$USER_SLUG" | head -n1 || true)
  fi
  if [[ -z "$CAND" ]]; then
    CAND=$(printf "%s\n" "${SVCS[@]}" | grep -i 'n8n' | head -n1 || true)
  fi
  SERVICE="${CAND##*/}"
  if [[ -z "$SERVICE" ]]; then
    SERVICE="${SVCS[0]##*/}"
  fi
fi
info "Service: $SERVICE"

# --- service status & events ---
say "ECS Service Status"
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  --query 'services[0].{Status:status,Desired:desiredCount,Running:runningCount,LaunchType:launchType,TaskDef:taskDefinition}'

say "Recent Service Events (newest first)"
# Some accounts have empty events arrays; handle gracefully.
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  --query 'services[0].events[:12].[createdAt,message]' || echo "No events found."

# --- task inventory ---
say "Tasks (RUNNING/STOPPED)"
RUN_TASKS=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status RUNNING \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" | jq -r '.taskArns[]?')
STOP_TASKS=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status STOPPED \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" | jq -r '.taskArns[]?' | head -n 3)

info "Running tasks:"
if [[ -n "${RUN_TASKS:-}" ]]; then printf "%s\n" "$RUN_TASKS"; else echo "<none>"; fi
info "Recent stopped tasks:"
if [[ -n "${STOP_TASKS:-}" ]]; then printf "%s\n" "$STOP_TASKS"; else echo "<none>"; fi

if [[ -n "${STOP_TASKS:-}" ]]; then
  say "Stopped Task Reasons (up to 3)"
  aws ecs describe-tasks --cluster "$CLUSTER" --tasks $STOP_TASKS \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query 'tasks[].{Task:lastStatus,StopCode:stopCode,StoppedReason:stoppedReason,Containers:containers[].{Name:name,Reason:reason}}'
fi

# --- task definition & ports/logs ---
TD_ARN=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  --query 'services[0].taskDefinition' --output text)

say "Task Definition"
info "TaskDef: $TD_ARN"
aws ecs describe-task-definition --task-definition "$TD_ARN" \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  --query 'taskDefinition.containerDefinitions[].{Name:name,Image:image,PortMappings:portMappings,Env:environment,LogConfig:logConfiguration}'

# Extract a log group if awslogs is used
LOG_GROUP=$(aws ecs describe-task-definition --task-definition "$TD_ARN" \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  | jq -r '.taskDefinition.containerDefinitions[]?.logConfiguration? // empty | select(.logDriver=="awslogs") | .options."awslogs-group"' | head -n1)

if [[ -n "$LOG_GROUP" && "$LOG_GROUP" != "None" ]]; then
  say "CloudWatch Logs (group: $LOG_GROUP) — last $SINCE (not following)"
  aws logs tail "$LOG_GROUP" --since "$SINCE" --format short --region "$AWS_REGION" --profile "$AWS_PROFILE" || \
    info "No log streams yet (task may not have started)."
else
  info "No awslogs group configured in TD (or not detected)."
fi

# --- load balancer / target group / health ---
say "Load Balancer & Target Group"
LB_SECT=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" --query 'services[0].loadBalancers')
echo "${LB_SECT:-[]}" | jq .

TG_ARN=$(echo "${LB_SECT:-[]}" | jq -r '.[0].targetGroupArn // empty')
if [[ -n "$TG_ARN" ]]; then
  info "Target Group: $TG_ARN"
  aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query 'TargetGroups[0].{Protocol:Protocol,Port:Port,HealthCheckPath:HealthCheckPath,Matcher:Matcher.HttpCode}'
  say "Target Health"
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query 'TargetHealthDescriptions[].{Id:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}'

  # ALB inference
  LB_ARN=$(aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query 'TargetGroups[0].LoadBalancerArns[0]' --output text 2>/dev/null || true)
  if [[ -n "$LB_ARN" && "$LB_ARN" != "None" ]]; then
    ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" \
      --region "$AWS_REGION" --profile "$AWS_PROFILE" \
      --query 'LoadBalancers[0].DNSName' --output text)
    info "ALB DNS: $ALB_DNS"
    if [[ "$DO_PROBE" == "1" && -n "$ALB_DNS" && "$ALB_DNS" != "None" ]]; then
      say "ALB Health Probe"
      if [[ -n "$USER_SLUG" ]]; then
        PROBE_PATH="/$USER_SLUG/healthz"
      else
        PROBE_PATH="/healthz"
      fi
      info "curl -I http://$ALB_DNS$PROBE_PATH"
      curl -sS -I "http://$ALB_DNS$PROBE_PATH" || true
    fi
  fi
else
  info "No targetGroupArn on service (service may be headless or misconfigured)."
fi

say "Done"

