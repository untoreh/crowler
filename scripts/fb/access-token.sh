#!/usr/bin/env bash

# Template cmd:
# FB_PAGE_ID= \
# FB_SHORT_TOKEN= \
# FB_APP_ID= \
# FB_APP_SECRET= \
# bash scripts/fb/access-token.sh

echo Insert short token:
read -r FB_SHORT_TOKEN
[ -n "$FB_SHORT_TOKEN" ] || { echo facebook short token is empty; exit 1; }
echo Insert app id:
read -r FB_APP_ID
[ -n "$FB_APP_ID" ] || { echo facebook app_id is empty; exit 1; }
echo Insert app secret:
read -r FB_APP_SECRET
[ -n "$FB_APP_SECRET" ] || { echo facebook app_secret is empty; exit 1; }
echo Insert page id:
read -r FB_PAGE_ID
[ -n "$FB_PAGE_ID" ] || { echo facebook page_id is empty; exit 1; }

# GET LONG FROM SHORT
LONG_TOKEN=$(curl -s -X GET "https://graph.facebook.com/oauth/access_token?grant_type=fb_exchange_token&client_id=${FB_APP_ID}&client_secret=${FB_APP_SECRET}&fb_exchange_token=${FB_SHORT_TOKEN}" | jq -r '.access_token' )

# GET PERMANENT FROM LONG
echo -n "Token for page $FB_PAGE_ID: "
curl -s -X GET "https://graph.facebook.com/${FB_PAGE_ID}?fields=access_token&access_token=${LONG_TOKEN}" | jq -r '.access_token'
