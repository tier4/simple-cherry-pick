#!/bin/bash

set -e

# Extract PR and Repository Info
REPO_NAME=$(jq -r ".repository.full_name" "$GITHUB_EVENT_PATH")
PR_NUMBER=$(jq -r ".issue.number" "$GITHUB_EVENT_PATH")
COMMENT_BODY=$(jq -r ".comment.body" "$GITHUB_EVENT_PATH")
GITHUB_RUN_URL="https://github.com/$REPO_NAME/actions/runs/$GITHUB_RUN_ID"

# Check for the /cherry-pick command
if [[ ! "$COMMENT_BODY" =~ ^/cherry-pick ]]; then
    echo "Not a /cherry-pick command. Exiting."
    exit 0
fi

# Extract source_repo and target_branch from the command
TARGET=$(echo "$COMMENT_BODY" | awk '{ print $2 }')
SOURCE_REPO=$(echo "$TARGET" | awk -F':' '{ print $1 }' | tr -d '[:space:]')
TARGET_BRANCH=$(echo "$TARGET" | awk -F':' '{ print $2 }' | tr -d '[:space:]')

if [[ -z "$SOURCE_REPO" || -z "$TARGET_BRANCH" ]]; then
    echo "Invalid command format."
    gh pr comment $PR_NUMBER --body "🤖 says: ‼️ Please specify the target in the format: \`/cherry-pick source_repo:/target-branch\`."
    exit 1
fi

# Get the merge commit from the PR
URI=https://api.github.com
AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
API_HEADER="Accept: application/vnd.github.v3+json"

pr_resp=$(gh api "${URI}/repos/$REPO_NAME/pulls/$PR_NUMBER")
MERGED=$(echo "$pr_resp" | jq -r .merged)
MERGE_COMMIT=$(echo "$pr_resp" | jq -r .merge_commit_sha)

if [[ "$MERGED" != "true" ]]; then
    gh pr comment $PR_NUMBER --body "🤖 says: ‼️ This PR is not merged yet. Cherry-pick can only be performed on merged PRs."
    exit 1
fi

# Prepare cherry-pick
CHERRY_PICK_BRANCH="cherry-pick/$PR_NUMBER-to-$TARGET_BRANCH"

git config --global user.name "github-actions[bot]"
git config --global user.email "github-actions[bot]@users.noreply.github.com"
git remote set-url origin https://x-access-token:$GITHUB_TOKEN@github.com/$REPO_NAME.git

# Add source repository as remote if it differs from the target repo
if [[ "$SOURCE_REPO" != "$REPO_NAME" ]]; then
    git remote add source https://x-access-token:$GITHUB_TOKEN@github.com/$SOURCE_REPO.git
fi

# Fetch target branch and create new branch for cherry-pick
git fetch origin $TARGET_BRANCH
git checkout -b $CHERRY_PICK_BRANCH origin/$TARGET_BRANCH

# Perform cherry-pick
git cherry-pick $MERGE_COMMIT &> /tmp/error.log || {
    gh pr comment $PR_NUMBER --body "🤖 says: ‼️ Cherry-picking failed.<br/><br/>$(cat /tmp/error.log)"
    exit 1
}

# Push new branch to the target repository
git push origin HEAD:$CHERRY_PICK_BRANCH

# Create PR for cherry-picked changes
PR_TITLE="Cherry-pick PR #$PR_NUMBER to $TARGET_BRANCH"
PR_BODY="🤖 says: This PR cherry-picks changes from PR #$PR_NUMBER into the target branch $TARGET_BRANCH in $SOURCE_REPO."

gh pr create --base $TARGET_BRANCH --head $CHERRY_PICK_BRANCH --title "$PR_TITLE" --body "$PR_BODY" || {
    gh pr comment $PR_NUMBER --body "🤖 says: ‼️ Failed to create Pull Request for the cherry-picked changes. See: $GITHUB_RUN_URL"
    exit 1
}

# Notify success
gh pr comment $PR_NUMBER --body "🤖 says: Cherry-picking completed successfully! A new PR has been created: [View PR](https://github.com/$SOURCE_REPO/pull/$(gh pr view --json number --jq '.number'))."
