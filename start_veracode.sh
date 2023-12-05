#!/usr/bin/env bash

#### Setup variables ####

# Stop the script as soon as the first command fails
set -euo pipefail

# Set WEBHOOK to webhook secret (without URL)
WEBHOOK=$1

# Set the Veracode API ID
API_ID=$2

# Set the Veracode API SECRET
API_SECRET=$3

# Set the API endpoint
API_ENDPOINT=api.veracode.com
API_PATH=dae/api/core-api/webhook

#### Setup the build system ####

mkdir -p test-reports

 generate_hmac_header() { 
 VERACODE_AUTH_SCHEMA="VERACODE-HMAC-SHA-256"
 VERACODE_API_VERSION="vcode_request_version_1"
 signing_data=$1

 nonce="$(cat /dev/random | xxd -p | head -c 32)"
 timestamp=$(date +%s"000")

 nonce_key=$(echo "$nonce" | xxd -r -p | openssl dgst -sha256 -mac HMAC -macopt hexkey:"$API_SECRET" | awk -F" " '{ print $2 }')
 time_key=$(echo -n "$timestamp" | openssl dgst -sha256 -mac HMAC -macopt hexkey:"$nonce_key" | awk -F" " '{ print $2 }')
 sig_key=$(echo -n "$VERACODE_API_VERSION" | openssl dgst -sha256 -mac HMAC -macopt hexkey:"$time_key" | awk -F" " '{ print $2 }')
 signature=$(echo -n "$signing_data" | openssl dgst -sha256 -mac HMAC -macopt hexkey:"$sig_key" | awk -F" " '{ print $2 }')

echo "$VERACODE_AUTH_SCHEMA id=$API_ID,ts=$timestamp,nonce=$nonce,sig=$signature"
 } 

#### Start Security Scan ####

# Start Scan and get scan ID

signing_data="id=$API_ID&host=$API_ENDPOINT&url=$API_PATH/$WEBHOOK&method=POST"

VERACODE_AUTH_HEADER=$(generate_hmac_header $signing_data)

SCAN_ID=`curl --silent -X POST -H "Authorization: $VERACODE_AUTH_HEADER" --data "" https://$API_ENDPOINT/$API_PATH/$WEBHOOK | jq .data.scanId`
# Check if a positive integer was returned as SCAN_ID
if ! [ $SCAN_ID -ge 0 ] 2>/dev/null
then
   echo "Could not start Scan for Webhook $WEBHOOK."
   exit 1
fi

echo "Started Scan for Webhook $WEBHOOK. Scan ID is $SCAN_ID."

#### Check Security Scan Status ####

# Set status to Queued (100)
STATUS=100

# Run the scan until the status is not queued (100) or running (101) anymore
while [ $STATUS -le 101 ]
do
   echo "Scan Status currently is $STATUS (101 = Running)"

   # Only poll every minute
   sleep 60

signing_data="id=$API_ID&host=$API_ENDPOINT&url=$API_PATH/$WEBHOOK/scans/$SCAN_ID/status&method=GET"

VERACODE_AUTH_HEADER=$(generate_hmac_header $signing_data)

   # Refresh status
    STATUS=`curl --silent -H "Authorization: $VERACODE_AUTH_HEADER" https://$API_ENDPOINT/$API_PATH/$WEBHOOK/scans/$SCAN_ID/status | jq .data.status.status_code`

done

echo "Scan finished with status $STATUS."

#### Download Scan Report ####

signing_data="id=$API_ID&host=$API_ENDPOINT&url=$API_PATH/$WEBHOOK/scans/$SCAN_ID/report/junit&method=GET"

VERACODE_AUTH_HEADER=$(generate_hmac_header $signing_data)

curl --silent -H "Authorization: $VERACODE_AUTH_HEADER" https://$API_ENDPOINT/$API_PATH/$WEBHOOK/scans/$SCAN_ID/report/junit -o test-reports/report.xml
echo "Downloaded Report to test-reports/report.xml"
