#!/usr/bin/env bash
# check_listener_rule.sh — Verify ALB listener rules for a given user slug
#
# Usage:
#   ./check_listener_rule.sh <user-slug> [--region us-east-1] [--profile alog-admin]
#
# What it does:
# - Discovers cluster/service (prefers names containing n8n and the slug)
# - Finds TG + ALB
# - Chooses listener (80 preferred, then 443, else first)
# - Lists rules and checks for /<slug>/* path rule
# - Shows the forward target group if present
# - Prints the create-rule command if missing

set -euo pipefail

USER_SLUG="${1:-}"
if [[ -z "$USER_SLUG" ]]; then
	  echo "Usage: $0 <user-slug> [--region us-east-1] [--profile alog-admin]" >&2
	    exit 1
fi
shift || true

AWS_REGION="us-east-1"
AWS_PROFILE="default"
while [[ $# -gt 0 ]]; do
	  case "$1" in
		      --region)  AWS_REGION="$2"; shift 2 ;;
		          --profile) AWS_PROFILE="$2"; shift 2 ;;
			      *) echo "Unknown arg: $1" >&2; exit 2 ;;
			        esac
			done

			need(){ command -v "$1" >/dev/null || { echo "Missing: $1"; exit 1; }; }
			need aws; need jq

			say(){ printf "\n=== %s ===\n" "$*"; }

			# --- discover cluster/service ---
			say "Discover ECS cluster/service"
			CLUSTER=$(aws ecs list-clusters --region "$AWS_REGION" --profile "$AWS_PROFILE" \
				  | jq -r '.clusterArns[]? | split("/")[-1]' | grep -i n8n | head -n1)
			if [[ -z "$CLUSTER" ]]; then
				  CLUSTER=$(aws ecs list-clusters --region "$AWS_REGION" --profile "$AWS_PROFILE" \
					      | jq -r '.clusterArns[]? | split("/")[-1]' | head -n1)
			fi
			[[ -n "$CLUSTER" ]] || { echo "No ECS clusters found"; exit 3; }
			echo "Cluster: $CLUSTER"

			SERVICE=$(aws ecs list-services --cluster "$CLUSTER" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
				  | jq -r '.serviceArns[]? | split("/")[-1]' | grep -i "$USER_SLUG" | head -n1)
			if [[ -z "$SERVICE" ]]; then
				  SERVICE=$(aws ecs list-services --cluster "$CLUSTER" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
					      | jq -r '.serviceArns[]? | split("/")[-1]' | grep -i n8n | head -n1)
			fi
			[[ -n "$SERVICE" ]] || { echo "No ECS services found in $CLUSTER"; exit 4; }
			echo "Service: $SERVICE"

			# --- find target group + ALB ---
			say "Get Target Group + ALB"
			TG_ARN=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
				  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
				    --query 'services[0].loadBalancers[0].targetGroupArn' --output text)
			[[ "$TG_ARN" != "None" ]] || { echo "Service has no targetGroupArn"; exit 5; }
			echo "Target Group: $TG_ARN"

			LB_ARN=$(aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
				  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
				    --query 'TargetGroups[0].LoadBalancerArns[0]' --output text)
			[[ "$LB_ARN" != "None" ]] || { echo "Target group not attached to an ALB"; exit 6; }

			ALB_JSON=$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" \
				  --region "$AWS_REGION" --profile "$AWS_PROFILE")
							  ALB_DNS=$(echo "$ALB_JSON" | jq -r '.LoadBalancers[0].DNSName')
							  ALB_NAME=$(echo "$ALB_JSON" | jq -r '.LoadBalancers[0].LoadBalancerName')
							  echo "ALB: $ALB_NAME"
							  echo "ALB DNS: $ALB_DNS"

							  # --- pick a listener (80 preferred, then 443, else first) ---
							  say "Select listener"
							  LISTENERS_JSON=$(aws elbv2 describe-listeners --load-balancer-arn "$LB_ARN" \
								    --region "$AWS_REGION" --profile "$AWS_PROFILE")
							  echo "$LISTENERS_JSON" | jq -r '.Listeners[] | {Port, Protocol, ListenerArn}'

							  LISTENER_ARN=$(echo "$LISTENERS_JSON" | jq -r '.Listeners[] | select(.Port==80) | .ListenerArn' | head -n1)
							  if [[ -z "$LISTENER_ARN" || "$LISTENER_ARN" == "null" ]]; then
								    LISTENER_ARN=$(echo "$LISTENERS_JSON" | jq -r '.Listeners[] | select(.Port==443) | .ListenerArn' | head -n1)
							  fi
							  if [[ -z "$LISTENER_ARN" || "$LISTENER_ARN" == "null" ]]; then
								    LISTENER_ARN=$(echo "$LISTENERS_JSON" | jq -r '.Listeners[0].ListenerArn')
							  fi
							  [[ -n "$LISTENER_ARN" && "$LISTENER_ARN" != "null" ]] || { echo "No listeners found on ALB"; exit 7; }
							  echo "Using listener: $LISTENER_ARN"

							  # --- list rules on chosen listener ---
							  say "Listener Rules"
							  RULES_JSON=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
								    --region "$AWS_REGION" --profile "$AWS_PROFILE")
							  echo "$RULES_JSON" | jq -r '.Rules[] | {Priority, Conditions, Actions}'

							  # --- check for /user/* rule and where it forwards ---
							  say "Check for rule /$USER_SLUG/*"
							  MATCH_PATH="/$USER_SLUG/*"

							  RULE_INFO=$(echo "$RULES_JSON" | jq -r --arg p "$MATCH_PATH" '
							    .Rules[]
							      | select(any(.Conditions[]?;
							                     (.Field=="path-pattern" or .Field=="path-pattern" or .Field=="path-patterns")
									                    and (any(.Values[]?; . == $p))))
											      | {RuleArn, Priority, Actions}
											      ')

											      if [[ -n "$RULE_INFO" ]]; then
												        RULE_ARN=$(echo "$RULE_INFO" | jq -r '.RuleArn')
													  echo "✔ Found rule: $RULE_ARN  (priority $(echo "$RULE_INFO" | jq -r '.Priority'))"
													    # Extract the first forward TG (handles both forward and weighted-forward)
													      FORWARD_TG=$(echo "$RULE_INFO" | jq -r '
													          .Actions[]
														      | select(.Type=="forward")
														          | ( .TargetGroupArn // ( .ForwardConfig.TargetGroups[0].TargetGroupArn ) )
															    ' | head -n1)
															      if [[ -n "$FORWARD_TG" && "$FORWARD_TG" != "null" ]]; then
																          echo "  ↳ Forwards to TG: $FORWARD_TG"
																	      if [[ "$FORWARD_TG" == "$TG_ARN" ]]; then
																		            echo "  ✅ It forwards to THIS service's target group."
																			        else
																					      echo "  ⚠ It forwards to a DIFFERENT target group."
																					          fi
																						    else
																							        echo "  ⚠ Rule has no forward action parsed."
																								  fi
																							  else
																								    echo "✘ No rule found for $MATCH_PATH"
																								      echo
																								        echo "To create one (priority 200; adjust if taken):"
																									  echo "aws elbv2 create-rule \\"
																									    echo "  --listener-arn $LISTENER_ARN \\"
																									      echo "  --priority 200 \\"
																									        echo "  --conditions Field=path-pattern,Values=$MATCH_PATH \\"
																										  echo "  --actions Type=forward,TargetGroupArn=$TG_ARN \\"
																										    echo "  --region $AWS_REGION --profile $AWS_PROFILE"
											      fi
