#!/bin/zsh
# 임시 유틸: Supabase Management API로 원격 DB에 read-only SQL 실행
# 사용: ./scripts/sbq.sh "select 1"
set -e
TOKEN=$(security find-generic-password -s "Supabase CLI" -w)
REF=jkanrdxaidumlvpntudy
QUERY=$1
curl -s -X POST "https://api.supabase.com/v1/projects/$REF/database/query" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @<(python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1]}))' "$QUERY")
