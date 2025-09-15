#!/usr/bin/env bash
set -euo pipefail
USER_SLUG="${1:?Usage: $0 <user-slug> [--region us-east-1] [--profile prof]}"
AWS_REGION="us-east-1"; AWS_PROFILE="default"; shift || true
while [[ $# -gt 0 ]]; do case "$1" in --region) AWS_REGION="$2"; shift 2;; --profile) AWS_PROFILE="$2"; shift 2;;
	*) echo "Unknown $1" >&2; exit 2;; esac; done
		need(){ command -v "$1" >/dev/null || { echo "Missing: $1"; exit 1; }; }; need aws; need jq
			CL=$(aws ecs list-clusters --region "$AWS_REGION" --profile "$AWS_PROFILE"|jq -r '.clusterArns[]'|grep -i n8n|head -n1|awk -F/ '{print $NF}')
			SV=$(aws ecs list-services --cluster "$CL" --region "$AWS_REGION" --profile "$AWS_PROFILE"|jq -r '.serviceArns[]'|grep -i "$USER_SLUG"|head -n1|awk -F/ '{print $NF}')
			TG=$(aws ecs describe-services --cluster "$CL" --services "$SV" --region "$AWS_REGION" --profile "$AWS_PROFILE" --query 'services[0].loadBalancers[0].targetGroupArn' --output text)
			LB=$(aws elbv2 describe-target-groups --target-group-arns "$TG" --region "$AWS_REGION" --profile "$AWS_PROFILE" --query 'TargetGroups[0].LoadBalancerArns[0]' --output text)
			LJSON=$(aws elbv2 describe-listeners --load-balancer-arn "$LB" --region "$AWS_REGION" --profile "$AWS_PROFILE")
			LIST=$(echo "$LJSON"|jq -r '.Listeners[] | select(.Port==80).ListenerArn'|head -n1)
			[[ -n "$LIST" ]] || LIST=$(echo "$LJSON"|jq -r '.Listeners[]|select(.Port==443).ListenerArn'|head -n1)
			[[ -n "$LIST" ]] || LIST=$(echo "$LJSON"|jq -r '.Listeners[0].ListenerArn')
			RJSON=$(aws elbv2 describe-rules --listener-arn "$LIST" --region "$AWS_REGION" --profile "$AWS_PROFILE")
			RULE=$(echo "$RJSON"|jq -r --arg p "/$USER_SLUG/*" '.Rules[] | select(any(.Conditions[]?; .Field=="path-pattern" and any(.Values[]?; .==$p))) | .RuleArn')
			if [[ -n "$RULE" && "$RULE" != "null" ]]; then
				  # If forwards to wrong TG, modify
				    CUR_TG=$(aws elbv2 describe-rules --rule-arns "$RULE" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
					        --query 'Rules[0].Actions[0].TargetGroupArn' --output text 2>/dev/null || true)
				      if [[ "$CUR_TG" != "$TG" ]]; then
					          aws elbv2 modify-rule --rule-arn "$RULE" \
							        --actions Type=forward,TargetGroupArn="$TG" \
								      --region "$AWS_REGION" --profile "$AWS_PROFILE" >/dev/null
						      echo "Updated rule $RULE to forward to $TG"
						        else
								    echo "Rule exists and forwards correctly."
								      fi
							      else
								        # find free priority (200..899)
									  USED=$(echo "$RJSON"|jq -r '.Rules[].Priority'|grep -E '^[0-9]+$'|sort -n)
									    PRIO=200; for p in $USED; do [[ "$p" -eq "$PRIO" ]] && ((PRIO++)); done
									      aws elbv2 create-rule --listener-arn "$LIST" --priority "$PRIO" \
										          --conditions Field=path-pattern,Values="/$USER_SLUG/*" \
											      --actions Type=forward,TargetGroupArn="$TG" \
											          --region "$AWS_REGION" --profile "$AWS_PROFILE" >/dev/null
									        echo "Created rule /$USER_SLUG/* -> $TG (priority $PRIO)"
			fi
