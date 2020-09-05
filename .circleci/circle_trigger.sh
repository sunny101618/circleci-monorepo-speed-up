#!/bin/bash
set -e

CIRCLE_API="https://circleci.com/api"
REPOSITORY_TYPE="github"
ORG_NAME="sunny101618"
PARENT_BRANCH="master"

############################################
## 1. Identify branch type
############################################
DATA="{"
if [[ -z "$CIRCLE_TAG" ]]; then
  ## Pull request / master branch
  DATA+="\"branch\": \"$CIRCLE_BRANCH\""
else
  ## Tag Release
  DATA+="\"tag\": \"$CIRCLE_TAG\""
  CIRCLE_BRANCH="master"
fi

############################################
## 2. Find Commit SHA of Last CI build
############################################
## Step 1: Finding the index of current pipeline
export GET_ALL_PIPELINE_URL="${CIRCLE_API}/v2/project/${REPOSITORY_TYPE}/${ORG_NAME}/${CIRCLE_PROJECT_REPONAME}/pipeline?branch=${CIRCLE_BRANCH}"
echo "Get All Pipeline URL: $GET_ALL_PIPELINE_URL "
curl -Ss -u ${CIRCLE_TOKEN}: ${GET_ALL_PIPELINE_URL} > cci_pipeline.json
## Filter all irrelevant pipeline records
export CURRENT_INDEX=`cat cci_pipeline.json | jq -r --arg CIRCLE_SHA1 $CIRCLE_SHA1 '.items | map(.vcs.revision == $CIRCLE_SHA1) | rindex(true)'`
if [[ ${CURRENT_INDEX} == "null" ]]; then
  echo -e "\e[93mCan't found current build from the pipeline record.\e[0m"
  exit 1
fi

## Step 2: Finding the last pipeline ID
cat cci_pipeline.json | jq --argjson start $CURRENT_INDEX '.items | .[$start:]' > cci_pipeline_filtered.json
export LAST_PIPELINE_ID=`cat cci_pipeline_filtered.json | jq -r 'map(select(.state == "created")) | .[1].id'`

## Step 3: Finding the commit hash of last pipeline
if [[ ${LAST_PIPELINE_ID} != "null" ]]; then
  export GET_A_WORKFLOW_URL="${CIRCLE_API}/v2/pipeline/${LAST_PIPELINE_ID}/workflow"
  echo "Get A Workflow URL: ${GET_A_WORKFLOW_URL}" 
  curl -Ss -u ${CIRCLE_TOKEN}: ${GET_A_WORKFLOW_URL} > cci_workflow.json
  export NUMBER_OF_NOT_RUN=`cat ./cci_workflow.json| jq -r '.items | map(select(.status == "not_run")) | length'`
  if  [ "$NUMBER_OF_NOT_RUN" -eq 0 ]; then
    export LAST_COMPLETED_BUILD_SHA=`cat cci_pipeline_filtered.json | jq -r 'map(select(.state == "created")) | .[1].vcs.revision'`
  fi
fi

## Step 4: Finding the commit hash of last pipeline on master branch
if  [[ -z ${LAST_COMPLETED_BUILD_SHA} ]] || [[ $(git cat-file -t $LAST_COMPLETED_BUILD_SHA) != "commit" ]];then
  echo -e "\e[93mThere are no completed CI builds in branch ${CIRCLE_BRANCH}. Using Master Branch\e[0m"
  export GET_ALL_PIPELINE_URL="${CIRCLE_API}/v2/project/${REPOSITORY_TYPE}/${ORG_NAME}/${CIRCLE_PROJECT_REPONAME}/pipeline?branch=${PARENT_BRANCH}"
  echo "All Master Branch Pipeline URL : $GET_ALL_PIPELINE_URL  "
  curl -Ss -u ${CIRCLE_TOKEN}: ${GET_ALL_PIPELINE_URL} > cci_pipeline.json
  export LAST_COMPLETED_BUILD_SHA=`cat cci_pipeline.json | jq -r '.items | map(select(.state == "created")) | .[1].vcs.revision'`
fi

## First Build on Master Branch
if [[ ${LAST_COMPLETED_BUILD_SHA} == "null" ]] || [[ $(git cat-file -t $LAST_COMPLETED_BUILD_SHA) != "commit" ]]; then
  echo -e "\e[93mNo CI builds for branch ${PARENT_BRANCH}. Using master.\e[0m"
  LAST_COMPLETED_BUILD_SHA=$(git rev-parse origin/master)
fi

echo "Last Completed Build SHA: $LAST_COMPLETED_BUILD_SHA"

############################################
## 3. Find Changed Packages
############################################
PACKAGES=($(ls ./packages/))

## The CircleCI API parameters object
PARAMETERS='"main":false'
ALL_WORKFLOW_PARAMETERS=$PARAMETERS
COUNT=0

## Detect change in each project
for PACKAGE in ${PACKAGES[@]}
do
  ALL_WORKFLOW_PARAMETERS+=", \"$PACKAGE\":true"
  PACKAGE_PATH="./packages/$PACKAGE"
  LATEST_COMMIT_SINCE_LAST_BUILD=$(git log -1 $LAST_COMPLETED_BUILD_SHA..$CIRCLE_SHA1 --first-parent --no-merges --abbrev-commit --pretty=oneline --full-diff ${PACKAGE_PATH})
  echo "$PACKAGE: $LATEST_COMMIT_SINCE_LAST_BUILD"
  if [[ -z "$LATEST_COMMIT_SINCE_LAST_BUILD" ]]; then
    echo -e "\e[90m  [-] $PACKAGE \e[0m"
  else
    PARAMETERS+=", \"$PACKAGE\":true"
    COUNT=$((COUNT + 1))
    echo -e "\e[36m  [+] ${PACKAGE} \e[21m (changed in [${LATEST_COMMIT_SINCE_LAST_BUILD:0:7}])\e[0m"
  fi
done

## Trigger all workflows
## if hits .circleci folder, storybook folder and files in the root directory matching the conditions
ROOT_LOC_OF_INTEREST=`find . -maxdepth 1 -name '*.*' -not -name "*.md" -not -name ".*" | sed '1{x;s/^/.circleci/p;x;}'`
ROOT_DIRECTORY_CHANGE=`echo $ROOT_LOC_OF_INTEREST | xargs git log $LAST_COMPLETED_BUILD_SHA..$CIRCLE_SHA1 --first-parent --no-merges --abbrev-commit --pretty=oneline --full-diff -- | wc -l`
if [[ $PARAMETERS == *"storybook"* || "ROOT_DIRECTORY_CHANGE" -gt 0 ]]; then
  PARAMETERS=$ALL_WORKFLOW_PARAMETERS
  echo "Common:"
  echo -e "\e[93m  Have change detected in common file. Will trigger all workflows\e[0m"
  COUNT=$((COUNT + 1))
fi

## Tag Release
if [[ -n "$CIRCLE_TAG" ]]; then
  PARAMETERS=$ALL_WORKFLOW_PARAMETERS
  echo "Tag Release:"
  echo -e "\e[93m  Enforce to trigger all workflows\e[0m"
  COUNT=$((COUNT + 1))
fi

if [[ $COUNT -eq 0 ]]; then
  echo -e "\e[93mNo changes detected in packages. Skip triggering workflows.\e[0m"
  exit 0
fi

############################################
## 4. Trigger CicleCI REST API call
############################################
DATA+=", \"parameters\": { $PARAMETERS } }"

echo "Triggering pipeline with data:"
echo -e "  $DATA"

URL="${CIRCLE_API}/v2/project/${REPOSITORY_TYPE}/${ORG_NAME}/${CIRCLE_PROJECT_REPONAME}/pipeline"
HTTP_RESPONSE=$(curl -s -u "${CIRCLE_TOKEN}:" -o response.txt -w "%{http_code}" -X POST --header "Content-Type: application/json" -d "$DATA" "$URL")

if [ "$HTTP_RESPONSE" -ge "200" ] && [ "$HTTP_RESPONSE" -lt "300" ]; then
  echo "API call succeeded."
  echo "Response:"
  cat response.txt
else
  echo -e "\e[93mReceived status code: ${HTTP_RESPONSE}\e[0m"
  echo "Response:"
  cat response.txt
  exit 1
fi