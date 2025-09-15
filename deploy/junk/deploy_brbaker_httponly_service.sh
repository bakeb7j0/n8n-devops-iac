#!/bin/bash
set -euo pipefail
source ./n8n.env

SERVICE_NAME="n8n-brbaker"
TG_NAME="tg-brbaker"
PRIORITY=10

# Fetch the ALB DNS
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --query "LoadBalancers[0].DNSName" --output text \
  --region "$REGION" --profile "$PROFILE")
echo "ALB DNS: $ALB_DNS"

# Clean up previous Target Group if it exists
EXISTING_TG_ARN=$(aws elbv2 describe-target-groups \
  --names "$TG_NAME" \
  --query "TargetGroups[0].TargetGroupArn" --output text \
  --region "$REGION" --profile "$PROFILE" || echo "")

if [[ -n "$EXISTING_TG_ARN" && "$EXISTING_TG_ARN" != "None" ]]; then
  # Try to delete listener rule first
  LISTENER_ARN=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[?Port==\`80\`].ListenerArn" --output text \
    --region "$REGION" --profile "$PROFILE")

  RULE_ARN=$(aws elbv2 describe-rules \
    --listener-arn "$LISTENER_ARN" \
    --query "Rules[?Conditions[?Field=='path-pattern' && Values[0]=='/$SERVICE_NAME/*']].RuleArn" --output text \
    --region "$REGION" --profile "$PROFILE" || echo "")

  if [[ -n "$RULE_ARN" && "$RULE_ARN" != "None" ]]; then
    aws elbv2 delete-rule --rule-arn "$RULE_ARN" --region "$REGION" --profile "$PROFILE"
  fi

  aws elbv2 delete-target-group \
    --target-group-arn "$EXISTING_TG_ARN" \
    --region "$REGION" --profile "$PROFILE" || true
fi

# Create target group
TG_ARN=$(aws elbv2 create-target-group \
  --name "$TG_NAME" \
  --protocol HTTP \
  --port 5678 \
  --target-type ip \
  --vpc-id "$VPC_ID" \
  --region "$REGION" --profile "$PROFILE" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Update n8n.env with new TG_ARN
sed -i.bak "/^TG_ARN=/d" ./n8n.env
echo "TG_ARN=$TG_ARN" >> ./n8n.env

# Register listener rule
LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query "Listeners[?Port==\`80\`].ListenerArn" --output text \
  --region "$REGION" --profile "$PROFILE")

aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" \
  --conditions Field=path-pattern,Values="/$SERVICE_NAME/*" \
  --priority $PRIORITY \
  --actions Type=forward,TargetGroupArn="$TG_ARN" \
  --region "$REGION" --profile "$PROFILE"

# Update n8n.env with new LISTENER_ARN
sed -i.bak "/^LISTENER_ARN=/d" ./n8n.env
echo "LISTENER_ARN=$LISTENER_ARN" >> ./n8n.env

echo "Listener rule for /$SERVICE_NAME/* added"

# Create ECS service
aws ecs create-service \
  --cluster "$CLUSTER_NAME" \
  --service-name "$SERVICE_NAME" \
  --task-definition "$SERVICE_NAME" \
  --launch-type FARGATE \
  --desired-count 1 \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID_A,$SUBNET_ID_B],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=n8n,containerPort=5678" \
  --region "$REGION" --profile "$PROFILE"

echo "ECS service deployed for $SERVICE_NAME (HTTP)"
echo "Access your service here:"
echo "http://$ALB_DNS/$SERVICE_NAME/"

