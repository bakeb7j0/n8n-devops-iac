aws elbv2 describe-load-balancers \
  --names n8n-dev-alb \
  --query "LoadBalancers[0].DNSName" \
  --output text \
  --region us-east-1 \
  --profile alog-admin

