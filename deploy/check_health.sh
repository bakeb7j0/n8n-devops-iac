#!/usr/bin/env bash
set -euo pipefail
ALB="n8n-dev-alb-1332110457.us-east-1.elb.amazonaws.com"
BASE="/$1"
for path in "/" "/rest/health" "/healthz"; do
	  URL="http://${ALB}${BASE}${path}"
	    CODE=$(curl -s -o /dev/null -w "%{http_code}" "$URL")
	      echo "GET $URL -> $CODE"
      done
      # Also show the root of the app path
      curl -sS -I "http://${ALB}${BASE}/" || true
