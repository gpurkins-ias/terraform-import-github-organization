#!/bin/bash
# set -euo pipefail

###
## GLOBAL VARIABLES
###
GITHUB_TOKEN=''
ORG='sgleske-test'
API_URL_PREFIX=${API_URL_PREFIX:-'https://api.github.com'}

RECENT_SLUG=

###
## FUNCTIONS
###

declare_github_repository () {
    local repo="$1"
    local private="$2"
    local name="$3"
    local data="$( curl -s "${API_URL_PREFIX}/repos/${ORG}/${repo}?access_token=${GITHUB_TOKEN}" )"
    cat << EOF
resource "github_repository" "${name}" {
    name          = "${repo}"
    private       = "${private}"
    description   = "$( jq -r .description <<< "${data}" | sed "s/\"/'/g" )"
    has_wiki      = "$( jq -r .has_wiki <<< "${data}" )"
    has_downloads = "$( jq -r .has_downloads <<< "${data}" )"
    has_issues    = "$( jq -r .has_issues <<< "${data}" )"
}
EOF
}

declare_github_membership () {
    local username="$1"
    local user_url="${API_URL_PREFIX}/orgs/${ORG}/memberships/${username}?access_token=${GITHUB_TOKEN}&per_page=100"
    local role="$( curl -s "${user_url}" -H "Accept: application/vnd.github.hellcat-preview+json" | jq -r .role )"
    cat << EOF
resource "github_membership" "$i" {
    username        = "${username}"
    role            = "${role}"
}
EOF
}

declare_github_team () {
    local team="$1"
    local data="$( curl -s "${API_URL_PREFIX}/teams/${team}?access_token=${GITHUB_TOKEN}&per_page=100" -H "Accept: application/vnd.github.hellcat-preview+json" )"
    local privacy="$( jq -r .privacy <<< "${data}" )"
    local parent="$( jq -r .parent.id <<< "${data}" )"
    RECENT_SLUG=
    [ "${privacy}" == closed ] || [ "${privacy}" == secret ] || return 1
    [ "${parent}" == null ] && parent=
    RECENT_SLUG="$( jq -r .slug <<< "${data}" )"
    cat << EOF
resource "github_team" "${RECENT_SLUG}" {
    name           = "$( jq -r .name <<< "${data}" )"
    description    = "$( jq -r .description <<< "${data}" )"
    privacy        = "${privacy}"
    parent_team_id = "${parent}"
}
EOF
    return 0
}

declare_github_team_membership () {
    local team="$1"
    local teamname="$2"
    local member="$3"
    local data="$(
        curl -s "${API_URL_PREFIX}/teams/${team}/memberships/${member}?access_token=${GITHUB_TOKEN}&per_page=100" \
            -H "Accept: application/vnd.github.hellcat-preview+json"
    )"
    local role="$( jq -r .role <<< "${data}" )"
    case "${role}" in
    maintainer|member|admin)
        ;;
    *)
        return 1
        ;;
    esac
    cat << EOF
resource "github_team_membership" "${teamname}-${member}" {
    username = "${member}"
    team_id  = "\${github_team.${teamname}.id}"
    role     = "${role}"
}
EOF
    return 0
}

declare_team_perms () {
    local resource="$1"
    local team_id="$2"
    local repo="$3"
    local perms="$4"
    cat << EOF
resource "github_team_repository" "${resource}" {
    team_id    = "${team_id}"
    repository = "${repo}"
    permission = "${perms}"
}
EOF
}


# Public Repos
  # You can only list 100 items per page, so you can only clone 100 at a time.
  # This function uses the API to calculate how many pages of public repos you have.
get_public_pagination () {
    public_pages=$(curl -I "${API_URL_PREFIX}/orgs/$ORG/repos?access_token=$GITHUB_TOKEN&type=public&per_page=100" | grep -Eo '&page=\d+' | grep -Eo '[0-9]+' | tail -1;)
    echo ${public_pages:-1}
}
  # This function uses the output from above and creates an array counting from 1->$ 
limit_public_pagination () {
  seq $(get_public_pagination)
}

  # Now lets import the repos, starting with page 1 and iterating through the pages
import_public_repos () {
  for PAGE in $(limit_public_pagination); do
    for i in $(curl -s "${API_URL_PREFIX}/orgs/$ORG/repos?access_token=$GITHUB_TOKEN&type=public&page=$PAGE&per_page=100" | jq -r 'sort_by(.name) | .[] | .name'); do
      # Terraform doesn't like '.' in resource names, so if one exists then replace it with a dash
      TERRAFORM_PUBLIC_REPO_NAME=$(echo $i | tr  "."  "-")
      declare_github_repository "${i}" false "${TERRAFORM_PUBLIC_REPO_NAME}" >> github-public-repos.tf
      terraform import github_repository.$TERRAFORM_PUBLIC_REPO_NAME $i
    done
  done
}

# Private Repos
get_private_pagination () {
    priv_pages=$(curl -I "${API_URL_PREFIX}/orgs/$ORG/repos?access_token=$GITHUB_TOKEN&type=private&per_page=100" | grep -Eo '&page=\d+' | grep -Eo '[0-9]+' | tail -1;)
    echo ${priv_pages:-1}
}

limit_private_pagination () {
  seq $(get_private_pagination)
}

import_private_repos () {
  for PAGE in $(limit_private_pagination); do
    for i in $(curl -s "${API_URL_PREFIX}/orgs/$ORG/repos?access_token=$GITHUB_TOKEN&type=private&page=$PAGE&per_page=100" | jq -r 'sort_by(.name) | .[] | .name'); do
      # Terraform doesn't like '.' in resource names, so if one exists then replace it with a dash
      TERRAFORM_PRIVATE_REPO_NAME=$(echo $i | tr  "."  "-")
      declare_github_repository "${i}" true "${TERRAFORM_PRIVATE_REPO_NAME}" >> github-private-repos.tf
      terraform import github_repository.$TERRAFORM_PRIVATE_REPO_NAME $i
    done
  done
}

# Users
import_users () {
  for i in $(curl -s "${API_URL_PREFIX}/orgs/$ORG/members?access_token=$GITHUB_TOKEN&per_page=100" | jq -r 'sort_by(.login) | .[] | .login'); do
    declare_github_membership "$i" >> github-users.tf
    terraform import github_membership.$i $ORG:$i
  done
}

# Teams
import_teams () {
  local results
  local tempfile=github-teams.recent-slug
  for i in $(curl -s "${API_URL_PREFIX}/orgs/$ORG/teams?access_token=$GITHUB_TOKEN&per_page=100" -H "Accept: application/vnd.github.hellcat-preview+json" | jq -r 'sort_by(.name) | .[] | .id'); do
    if ! declare_github_team "${i}" > "${tempfile}" ; then
        rm -f "${tempfile}"
        continue
    fi
    mv "${tempfile}" "github-teams-${RECENT_SLUG}.tf"
    terraform import github_team.$RECENT_SLUG $i
  done
}

# Team Memberships 
import_team_memberships () {
  for i in $(curl -s "${API_URL_PREFIX}/orgs/$ORG/teams?access_token=$GITHUB_TOKEN&per_page=100" -H "Accept: application/vnd.github.hellcat-preview+json" | jq -r 'sort_by(.slug) | .[] | .id'); do
    TEAM_NAME=$(curl -s "${API_URL_PREFIX}/teams/$i?access_token=$GITHUB_TOKEN&per_page=100" -H "Accept: application/vnd.github.hellcat-preview+json" | jq -r .slug)
    for j in $(curl -s "${API_URL_PREFIX}/teams/$i/members?access_token=$GITHUB_TOKEN&per_page=100" -H "Accept: application/vnd.github.hellcat-preview+json" | jq -r .[].login); do
      TEAM_ROLE=$(curl -s "${API_URL_PREFIX}/teams/$i/memberships/$j?access_token=$GITHUB_TOKEN&per_page=100" -H "Accept: application/vnd.github.hellcat-preview+json" | jq -r .role)
      declare_github_team_membership "${i}" "${TEAM_NAME}" "${j}" >> "github-team-memberships-${TEAM_NAME}.tf" || continue
      terraform import github_team_membership.$TEAM_NAME-$j $i:$j
    done
  done
}

get_team_pagination () {
    team_pages=$(curl -I "${API_URL_PREFIX}/orgs/$ORG/repos?access_token=$GITHUB_TOKEN&per_page=100" | grep -Eo '&page=\d+' | grep -Eo '[0-9]+' | tail -1;)
    echo ${team_pages:-1}
}
  # This function uses the out from above and creates an array counting from 1->$ 
limit_team_pagination () {
  seq $(get_team_pagination)
}

get_team_ids () {
  curl -s "${API_URL_PREFIX}/orgs/$ORG/teams?access_token=$GITHUB_TOKEN&per_page=100" -H "Accept: application/vnd.github.hellcat-preview+json" | jq -r 'sort_by(.name) | .[] | .id'
}

get_team_repos () {
  local team_data="$( curl -s "${API_URL_PREFIX}/teams/${TEAM_ID}?access_token=${GITHUB_TOKEN}" )"
  local team_name="$( jq -r .name <<< "${team_data}" )"
  local team_slug="$( jq -r .slug <<< "${team_data}" )"
  local perms=

  for PAGE in $(limit_team_pagination); do
    for i in $(curl -s "${API_URL_PREFIX}/teams/$TEAM_ID/repos?access_token=$GITHUB_TOKEN&page=$PAGE&per_page=100" | jq -r 'sort_by(.name) | .[] | .name'); do
    
    TERRAFORM_TEAM_REPO_NAME=$(echo $i | tr  "."  "-")
    ADMIN_PERMS=$(curl -s "${API_URL_PREFIX}/teams/$TEAM_ID/repos/$ORG/$i?access_token=$GITHUB_TOKEN" -H "Accept: application/vnd.github.v3.repository+json" | jq -r .permissions.admin )
    PUSH_PERMS=$(curl -s "${API_URL_PREFIX}/teams/$TEAM_ID/repos/$ORG/$i?access_token=$GITHUB_TOKEN" -H "Accept: application/vnd.github.v3.repository+json" | jq -r .permissions.push )
    PULL_PERMS=$(curl -s "${API_URL_PREFIX}/teams/$TEAM_ID/repos/$ORG/$i?access_token=$GITHUB_TOKEN" -H "Accept: application/vnd.github.v3.repository+json" | jq -r .permissions.pull )
  
    if [[ "$ADMIN_PERMS" == "true" ]]; then
        perms=admin
    elif [[ "$PUSH_PERMS" == "true" ]]; then
        perms=push
    elif [[ "$PULL_PERMS" == "true" ]]; then
        perms=pull
    else
        continue
    fi
    declare_team_perms "${TEAM_SLUG}-${TERRAFORM_TEAM_REPO_NAME}" "${TEAM_ID}" "${i}" "${perms}" >> github-teams-$TEAM_SLUG.tf
    terraform import github_team_repository.$TEAM_SLUG-$TERRAFORM_TEAM_REPO_NAME $TEAM_ID:$i
    done
  done
}

import_team_repos () {
for TEAM_ID in $(get_team_ids); do
  get_team_repos
done
}

import_all_team_resources () {
  import_teams
  import_team_memberships
  import_team_repos
}

###
## DO IT YO
###
import_public_repos
import_private_repos
import_users
import_all_team_resources
