#!/usr/bin/env bash
set -euo pipefail

USER_SLUG="${1:-}"
if [[ -z "$USER_SLUG" ]]; then
  echo "Usage: $0 <user-slug>   (e.g., $0 brbaker)"
  exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-default}"

jqget() { jq -r "$1"; }

echo "== Discovering ECS cluster =="
CLUSTER_ARN=$(aws ecs list-clusters --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  | jq -r '.clusterArns[]' | grep -i n8n | head -n1 || true)
if [[ -z "$CLUSTER_ARN" ]]; then
  echo "No ECS cluster found containing 'n8n'. Listing all:"
  aws ecs list-clusters --region "$AWS_REGION" --profile "$AWS_PROFILE"
  exit 2
fi
CLUSTER="${CLUSTER_ARN##*/}"
echo "Using cluster: $CLUSTER"

echo "== Discovering ECS service for user '$USER_SLUG' =="
SERVICE_ARN=$(aws ecs list-services --cluster "$CLUSTER" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  | jq -r '.serviceArns[]' | grep -i "$USER_SLUG" | head -n1 || true)
if [[ -z "$SERVICE_ARN" ]]; then
  # fallback: first n8n service
  SERVICE_ARN=$(aws ecs list-services --cluster "$CLUSTER" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    | jq -r '.serviceArns[]' | grep -i n8n | head -n1 || true)
fi
if [[ -z "$SERVICE_ARN" ]]; then
  echo "No ECS services found. Did you deploy any?"
  exit 3
fi
SERVICE="${SERVICE_ARN##*/}"
echo "Using service: $SERVICE"

echo "== Current service status =="
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  --query 'services[0].{Status:status,Desired:desiredCount,Running:runningCount,Events:events[:10]}'

echo "== Scale DesiredCount to 1 (if needed) =="
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --desired-count 1 --region "$AWS_REGION" --profile "$AWS_PROFILE" >/dev/null || true

echo "== Discovering Target Group and Listener =="
# Find the target group from the service's loadBalancers section
LB_JSON=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" --query 'services[0].loadBalancers' -r)
TG_ARN=$(echo "$LB_JSON" | jq -r '.[0].targetGroupArn // empty')
if [[ -z "$TG_ARN" ]]; then
  echo "No targetGroupArn on the service. You may need to (re)create listener/target-group binding."
  echo "Service loadBalancers:"; echo "$LB_JSON" | jq .
else
  echo "Target Group: $TG_ARN"
  echo "== Set TG health check to /healthz and matcher 200-399 =="
  aws elbv2 modify-target-group --target-group-arn "$TG_ARN" \
    --health-check-path "/healthz" \
    --matcher HttpCode=200-399 \
    --health-check-interval-seconds 15 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" >/dev/null || true

  echo "TG health check now:"
  aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query 'TargetGroups[0].{Port:Port,Protocol:Protocol,HealthCheckPath:HealthCheckPath,Matcher:Matcher.HttpCode}'

  echo "== Target health =="
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query 'TargetHealthDescriptions[].{Id:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}'
fi

echo "== Finding ALB DNS and path rule =="
# Try to infer the ALB from the target group
LB_ARN=$(aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  --query 'TargetGroups[0].LoadBalancerArns[0]' -r 2>/dev/null || true)

ALB_DNS=""
if [[ -n "$LB_ARN" && "$LB_ARN" != "null" ]]; then
  ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query 'LoadBalancers[0].DNSName' -r || true)
  echo "ALB: $LB_ARN  DNS: $ALB_DNS"
fi

echo "== Verify listener rules route /$USER_SLUG/* to TG =="
if [[ -n "$LB_ARN" && "$LB_ARN" != "null" ]]; then
  LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$LB_ARN" \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query 'Listeners[?Port==`80` || Port==`443`][0].ListenerArn' -r || true)
  if [[ -n "$LISTENER_ARN" && "$LISTENER_ARN" != "null" ]]; then
    aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
      --region "$AWS_REGION" --profile "$AWS_PROFILE" \
      --query 'Rules[].{Id:RuleArn,Cond:Conditions,Actions:Actions}'
    echo "If no rule for path /$USER_SLUG/*, create one pointing to $TG_ARN:"
    echo "aws elbv2 create-rule --listener-arn $LISTENER_ARN --priority 200 --conditions Field=path-pattern,Values=/$USER_SLUG/* --actions Type=forward,TargetGroupArn=$TG_ARN --region $AWS_REGION --profile $AWS_PROFILE"
  fi
fi

echo "== Show recent service events =="
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  --query 'services[0].events[:12].{Time:createdAt,Msg:message}'

echo "== Check current tasks =="
TASK_ARN=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" | jq -r '.taskArns[0] // empty')
if [[ -n "$TASK_ARN" ]]; then
  aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query 'tasks[0].{LastStatus:lastStatus,StopCode:stopCode,StopReason:stoppedReason,Containers:containers[].{Name:name,Last:lastStatus}}'
fi

if [[ -n "$ALB_DNS" ]]; then
  echo "== Probing health endpoint via ALB =="
  curl -sS -I "http://$ALB_DNS/$USER_SLUG/healthz" || true
fi

echo "== Done =="

