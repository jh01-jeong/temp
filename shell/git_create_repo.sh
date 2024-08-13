#!/bin/bash

# GitHub Enterprise Domain
GITHUB_ENTERPRISE_DOMAIN="your_github_enterprise_domain"

# GitHub Personal Access Token
GITHUB_TOKEN="your_github_token_here"

# List of org:repo pairs
ORG_REPO_PAIRS=(
    "org1:repo1"
    "org2:repo2"
    "org3:repo3"
)

# Function to create develop branch, set it as default, and apply branch protection
setup_repo() {
  local org_name=$1
  local repo_name=$2

  # Retrieve the SHA of the main branch
  sha=$(curl -s -H "Authorization: token $GITHUB_TOKEN" https://$GITHUB_ENTERPRISE_DOMAIN/api/v3/repos/$org_name/$repo_name/git/ref/heads/main | grep '"sha"' | head -n 1 | sed 's/.*"sha": "\([^"]*\)".*/\1/')

  if [ -z "$sha" ]; then
    echo "Failed: Could not retrieve the SHA for the main branch in '$repo_name'."
    return 1
  fi
  
  # Create develop branch from main
  http_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $GITHUB_TOKEN" \
       -H "Accept: application/vnd.github.v3+json" \
       -X POST \
       -d "{\"ref\": \"refs/heads/develop\", \"sha\": \"$sha\"}" \
       https://$GITHUB_ENTERPRISE_DOMAIN/api/v3/repos/$org_name/$repo_name/git/refs)
  
  if [ "$http_status" -eq 201 ]; then
    echo "Success: Created develop branch in '$repo_name'."
  else
    echo "Failed: Could not create develop branch in '$repo_name'. HTTP Status: $http_status"
    return 1
  fi

  # Set develop as the default branch
  http_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $GITHUB_TOKEN" \
       -H "Accept: application/vnd.github.v3+json" \
       -X PATCH \
       -d "{\"default_branch\": \"develop\"}" \
       https://$GITHUB_ENTERPRISE_DOMAIN/api/v3/repos/$org_name/$repo_name)

  if [ "$http_status" -eq 200 ]; then
    echo "Success: Set develop as the default branch in '$repo_name'."
  else
    echo "Failed: Could not set develop as the default branch in '$repo_name'. HTTP Status: $http_status"
    return 1
  fi

  # Protect develop branch
  http_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $GITHUB_TOKEN" \
       -H "Accept: application/vnd.github.luke-cage-preview+json" \
       -X PUT \
       -d '{"required_status_checks":{"strict":true,"contexts":[]},"enforce_admins":true,"required_pull_request_reviews":{"dismiss_stale_reviews":true},"restrictions":null}' \
       https://$GITHUB_ENTERPRISE_DOMAIN/api/v3/repos/$org_name/$repo_name/branches/develop/protection)
  
  if [ "$http_status" -eq 200 ]; then
    echo "Success: Protected develop branch in '$repo_name'."
  else
    echo "Failed: Could not protect develop branch in '$repo_name'. HTTP Status: $http_status"
    return 1
  fi

  # Protect main branch
  http_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $GITHUB_TOKEN" \
       -H "Accept: application/vnd.github.luke-cage-preview+json" \
       -X PUT \
       -d '{"required_status_checks":{"strict":true,"contexts":[]},"enforce_admins":true,"required_pull_request_reviews":{"dismiss_stale_reviews":true},"restrictions":null}' \
       https://$GITHUB_ENTERPRISE_DOMAIN/api/v3/repos/$org_name/$repo_name/branches/main/protection)
  
  if [ "$http_status" -eq 200 ]; then
    echo "Success: Protected main branch in '$repo_name'."
  else
    echo "Failed: Could not protect main branch in '$repo_name'. HTTP Status: $http_status"
    return 1
  fi
}

# Loop through the list and set up repositories
for ORG_REPO in "${ORG_REPO_PAIRS[@]}"; do
  # Split the org:repo pair into org name and repo name
  ORG_NAME=$(echo $ORG_REPO | cut -d ':' -f 1)
  REPO_NAME=$(echo $ORG_REPO | cut -d ':' -f 2)
  
  # Call the function to setup the repository
  setup_repo "$ORG_NAME" "$REPO_NAME"
done
