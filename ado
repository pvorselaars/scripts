#!/bin/bash
# ado: Azure DevOps at a glance, using your `az login` (no token to manage).
#
#   ado prs                  your open pull requests, and the ones waiting for your review (* = waiting,
#                            also when a team you are in is a reviewer that has not voted yet)
#   ado runs [--all]         the newest run of each of your pipelines per branch (--all: every recent run);
#                            a failure that needs you is marked ! (the newest run failed, and it is not a
#                            validation build of somebody else's pull request)
#   ado items [--all]        your work items that are being worked on (--all: every one that is not closed)
#   ado item ID              one work item: state, iteration, description, and what it is linked to
#   ado branch ID [options]  create a branch for a work item, e.g. feature/156438-short-title (see below)
#   ado menu [items]         pick a pull request or a failed run (or, with items, a work item) in fuzzel
#                            and open it in Firefox
#   ado refresh              look everything up and store the counts for the status bar
#   ado status               print the stored counts: REVIEW FAILED (or "login" when az needs a new sign-in)
#
# ado branch ID [--repo PROJECT/REPO] [--from BRANCH] [--name NAME] [--prefix PREFIX] [--link] [--checkout]
#                          [--yes] [--dry-run]
#   The repo is the one in the folder you are in, else REPO from the config. The branch starts from the
#   default branch of that repo. The name is PREFIX/ID-title: feature for most items, bug for a Bug.
#   It shows what it will do and asks first (--yes skips the question, --dry-run only shows).
#   --link also links the branch to the work item, like the "Create a branch" button does.
#   --checkout then fetches the branch and switches to it, when you are in a clone of that repo.
#
# The settings are in ~/.config/ado/config:
#   ORG=cito-ivit
#   PROJECTS=QuestifyBuilder Another_Project     projects with the repos (_ stands for a space in a name)
#   REPO=QuestifyBuilder/Construction.Platform   where ado branch works when you are not in a clone
#   IGNORE_GROUPS=Testers                        words in team names that must not make a PR wait for you
#   ITEM_STATES=Committed In Progress To Do      the states that mean a work item is being worked on
# `az login` has to be recent: your organisation asks for a new sign-in every 24 hours.
# `ado menu --print` lists the entries without the menu.

CONFIG=${ADO_CONFIG:-$HOME/.config/ado/config}
CACHE=${XDG_RUNTIME_DIR:-/tmp}/ado
API=${ADO_API:-https://dev.azure.com}
VSSPS=${ADO_VSSPS:-https://vssps.dev.azure.com}
RESOURCE=499b84ac-1321-427f-aa17-267ca6975798     # the Azure DevOps resource: what az needs to know

die() { echo "ado: $*" >&2; exit 1; }

# the comment block at the top of this file, without the "# "
usage() { sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; }

# --- configuration, sign-in -----------------------------------------------------------------------

load_config() {
    local name value
    ORG=cito-ivit
    PROJECTS=QuestifyBuilder
    REPO=QuestifyBuilder/Construction.Platform
    IGNORE_GROUPS=""
    ITEM_STATES="Committed In Progress To Do"
    if [ -r "$CONFIG" ]; then
        for name in ORG PROJECTS REPO IGNORE_GROUPS ITEM_STATES; do
            value=$(sed -n "s/^$name=//p" "$CONFIG" | head -n 1)
            [ -n "$value" ] && printf -v "$name" '%s' "$value"
        done
    fi
    [ -n "$ORG" ] && [ -n "$PROJECTS" ] || die "ORG and PROJECTS must be set in $CONFIG"
}

# a project name as it is written in the config ("_" for a space) and as it goes into a URL
project_name() { echo "${1//_/ }"; }
project_path() { local name; name=$(project_name "$1"); echo "${name// /%20}"; }

# token: an Azure DevOps token from az, kept until it nearly runs out
token() {
    local file="$CACHE/token" expires token out
    if [ -r "$file" ]; then
        { read -r expires; read -r token; } < "$file"
        if [ "$expires" -gt "$(date +%s)" ]; then
            echo "$token"
            return
        fi
    fi

    out=$(az account get-access-token --resource "$RESOURCE" --query '[expires_on, accessToken]' -o tsv 2>&1) \
        || { echo "ado: az could not give a token (run az login): $(echo "$out" | grep -oE 'AADSTS[0-9]+' | head -n 1)" >&2; return 1; }
    expires=${out%%$'\n'*}      # az prints the two values on two lines
    token=${out#*$'\n'}
    [[ $expires =~ ^[0-9]+$ ]] || expires=$(( $(date +%s) + 3000 ))
    mkdir -p "$CACHE"
    chmod 700 "$CACHE"
    printf '%s\n%s\n' "$(( expires - 120 ))" "$token" > "$file"
    chmod 600 "$file"
    echo "$token"
}

# api PATH: the JSON of an Azure DevOps request (PATH starts with / and has its api-version)
api() {
    local token
    token=$(token) || return 1
    curl -fsS -H "Authorization: Bearer $token" "$API/$ORG$1"
}

# vssps PATH: the same for the identity service of the organisation
vssps() {
    local token
    token=$(token) || return 1
    curl -fsS -H "Authorization: Bearer $token" "$VSSPS/$ORG$1"
}

# api_send METHOD PATH JSON [CONTENT_TYPE]: send JSON to Azure DevOps; on an error print its message and fail
api_send() {
    local method=$1 path=$2 body=$3 type=${4:-application/json} token response status
    token=$(token) || return 1
    response=$(curl -sS -X "$method" -H "Authorization: Bearer $token" -H "Content-Type: $type" -d "$body" \
        -w $'\n%{http_code}' "$API/$ORG$path") || { echo "ado: could not reach Azure DevOps" >&2; return 1; }
    status=${response##*$'\n'}
    response=${response%$'\n'*}
    if [ "$status" -ge 400 ]; then
        echo "ado: Azure DevOps answered $status: $(jq -r '.message // empty' <<< "$response" 2>/dev/null | head -n 1)" >&2
        return 1
    fi
    echo "$response"
}

# my_id: your Azure DevOps user id
my_id() {
    local file="$CACHE/me" id
    if [ ! -s "$file" ]; then
        id=$(api "/_apis/connectionData?api-version=7.1-preview" | jq -r '.authenticatedUser.id // empty')
        [ -n "$id" ] || return 1
        mkdir -p "$CACHE"
        echo "$id" > "$file"
    fi
    cat "$file"
}

# my_groups: the groups and teams you are in, as a JSON array of {id, name}; looked up once a day.
# A pull request can ask a team for a review, and the team's id is what its reviewer entry carries.
my_groups() {
    local file="$CACHE/groups.json" me descriptors
    if [ -s "$file" ] && [ -z "$(find "$file" -mmin +1440 2>/dev/null)" ]; then
        cat "$file"
        return
    fi
    me=$(my_id) || return 1
    descriptors=$(vssps "/_apis/identities?identityIds=$me&queryMembership=Expanded&api-version=7.1" |
        jq -r '.value[0].memberOf | join(",")') || return 1
    mkdir -p "$CACHE"
    vssps "/_apis/identities?descriptors=$descriptors&api-version=7.1" |
        jq -c '[.value[] | select(.isContainer == true) | {id, name: (.providerDisplayName // .displayName)}]' \
        > "$file.new" || return 1
    mv "$file.new" "$file"
    cat "$file"
}

# --- pull requests and runs -----------------------------------------------------------------------

# pull_requests: one JSON object per active pull request that is yours or waits for you, over all projects:
#   {project, repo, id, title, author, created, draft, mine, waiting, via, url}
# A PR waits for you when it is not a draft and not yours, you have not voted, and either you are a
# reviewer or a team you are in is a required reviewer that has not voted yet (via lists those teams).
# A team votes when one of its members votes for it, so a team with a vote of 0 still needs someone.
pull_requests() {
    local me groups project path
    me=$(my_id) || return 1
    groups=$(my_groups) || return 1
    for project in $PROJECTS; do
        path=$(project_path "$project")
        api "/$path/_apis/git/pullrequests?searchCriteria.status=active&\$top=200&api-version=7.1" |
            jq -c --arg project "$(project_name "$project")" --arg path "$path" --arg org "$ORG" --arg me "$me" \
                  --argjson groups "$groups" --arg ignore "$IGNORE_GROUPS" '
                def team_name: sub("^.*\\\\"; "");
                .value[] | . as $pr
                | ([($pr.reviewers // [])[] | select(.id == $me)] | first) as $my_entry
                | [($pr.reviewers // [])[]
                   | select(.isContainer == true and (.isRequired // false) and .vote == 0
                            and (.id as $id | $groups | any(.[]; .id == $id))
                            and ((.displayName | team_name) as $name
                                 | ($ignore | split(" ") | map(select(. != "")) | any(.[]; . as $word | $name | contains($word)))
                                 | not))
                   | .displayName | team_name] as $via
                | {
                    project: $project,
                    repo: .repository.name,
                    id: .pullRequestId,
                    title,
                    author: .createdBy.displayName,
                    created: .creationDate,
                    draft: (.isDraft // false),
                    mine: (.createdBy.id == $me),
                    via: $via,
                    waiting: ((.isDraft // false | not) and (.createdBy.id != $me)
                              and ($my_entry == null or $my_entry.vote == 0)
                              and ($my_entry != null or ($via | length) > 0)),
                    url: ("https://dev.azure.com/\($org)/\($path)/_git/\(.repository.name | @uri)/pullrequest/\(.pullRequestId)")
                  }
                | select(.mine or .waiting)' || return 1
    done | jq -sc 'sort_by(.created) | reverse | .[]'
}

# runs: one JSON object per recent pipeline run of yours, over all projects:
#   {project, id, name, number, branch, result, status, finished, url, stale}
# `stale` is false for the newest run of a pipeline on a branch only, so a failure that a later
# run has fixed does not count.
runs() {
    local me project path
    me=$(my_id) || return 1
    for project in $PROJECTS; do
        path=$(project_path "$project")
        api "/$path/_apis/build/builds?requestedForId=$me&\$top=50&queryOrder=queueTimeDescending&api-version=7.1" |
            jq -c --arg project "$(project_name "$project")" '
                .value | to_entries | map(.value + {order: .key}) | .[] | {
                    project: $project,
                    id,
                    name: .definition.name,
                    number: .buildNumber,
                    branch: (.sourceBranch | sub("^refs/heads/"; "")),
                    pr: ((.sourceBranch | capture("^refs/pull/(?<id>[0-9]+)/merge$") | .id | tonumber) // null),
                    result: (.result // .status),
                    status,
                    finished: (.finishTime // .queueTime),
                    url: ._links.web.href,
                    key: "\(.definition.id)/\(.sourceBranch)"
                }' || return 1
    done | jq -sc '
        reduce .[] as $r ({seen: {}, out: []};
            if .seen[$r.key] then .out += [$r + {stale: true}]
            else .seen[$r.key] = true | .out += [$r + {stale: false}] end)
        | .out[]'
}

# annotate_runs RUNS PRS: the runs, each with `attention`: true for a failure that needs you. That is the
# newest run of a pipeline on a branch that failed, unless it is a validation build of somebody else's pull
# request: `requestedFor` also holds builds you started or re-ran on pull requests that are not yours.
annotate_runs() {
    local mine
    mine=$(jq -s '[.[] | select(.mine) | .id]' <<< "$2")
    jq -c --argjson mine "$mine" '
        . + {attention: (.result == "failed" and (.stale | not)
                         and (.pr == null or (.pr as $pr | $mine | index($pr) != null)))}' <<< "$1"
}

# age ISO_TIMESTAMP: "3d", "5h", "12m"
age() {
    local seconds=$(( $(date +%s) - $(date -d "$1" +%s 2>/dev/null || echo 0) ))
    if   [ "$seconds" -ge 86400 ]; then echo "$((seconds / 86400))d"
    elif [ "$seconds" -ge 3600 ];  then echo "$((seconds / 3600))h"
    else echo "$((seconds / 60))m"
    fi
}

# --- work items -----------------------------------------------------------------------------------

# the text of an HTML field (a work item description) without tags and entities
html_to_text() {
    sed -e 's/<br[^>]*>/\n/g' -e 's/<\/\(p\|div\|li\|h[1-6]\)>/\n/g' -e 's/<[^>]*>//g' \
        -e 's/&nbsp;/ /g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e 's/&amp;/\&/g'
}

# work_items [--all]: one JSON object per work item assigned to you, the most recently changed first:
#   {id, type, state, title, project, iteration, url}
# The work items can be in another project than the code (here: Cito, while the repos are in QuestifyBuilder),
# so the query is not limited to one project.
work_items() {
    local where state query ids list=""
    if [ "$1" = --all ]; then
        where="[System.State] NOT IN ('Done','Removed','Closed','Resolved')"
    else
        for state in $ITEM_STATES; do list+="'$state',"; done
        where="[System.State] IN (${list%,})"
    fi
    query=$(jq -n --arg q "SELECT [System.Id] FROM WorkItems WHERE [System.AssignedTo] = @Me AND $where ORDER BY [System.ChangedDate] DESC" '{query: $q}')
    ids=$(api_send POST '/_apis/wit/wiql?$top=50&api-version=7.1' "$query" | jq -r '[.workItems[].id] | join(",")') || return 1
    [ -n "$ids" ] || return 0

    api "/_apis/wit/workitems?ids=$ids&fields=System.Id,System.WorkItemType,System.State,System.Title,System.TeamProject,System.IterationPath&api-version=7.1" |
        jq -c --arg ids "$ids" --arg org "$ORG" '
            ($ids | split(",") | map(tonumber)) as $order
            | .value | sort_by(.id as $id | $order | index($id)) | .[] | {
                id,
                type: .fields["System.WorkItemType"],
                state: .fields["System.State"],
                title: .fields["System.Title"],
                project: .fields["System.TeamProject"],
                iteration: (.fields["System.IterationPath"] | split("\\") | last),
                url: "https://dev.azure.com/\($org)/\(.fields["System.TeamProject"] | @uri)/_workitems/edit/\(.id)"
            }'
}

# --- branches -------------------------------------------------------------------------------------

# repo_from_git: "PROJECT/REPO" of the Azure DevOps clone in the current folder (fails when there is none)
repo_from_git() {
    local url rest project
    url=$(git remote get-url origin 2>/dev/null) || return 1
    case $url in
        *ssh.dev.azure.com:v3/*)        # git@ssh.dev.azure.com:v3/ORG/PROJECT/REPO
            rest=${url#*:v3/}
            rest=${rest#*/}
            echo "${rest//%20/ }"
            ;;
        *dev.azure.com/*/_git/*)        # https://ORG@dev.azure.com/ORG/PROJECT/_git/REPO
            rest=${url#*dev.azure.com/}
            rest=${rest#*/}
            project=${rest%%/_git/*}
            echo "${project//%20/ }/${rest#*/_git/}"
            ;;
        *) return 1 ;;
    esac
}

# branch_slug TITLE: the title as it goes into a branch name: ASCII words in lower case with single dashes,
# except acronyms, which keep their capitals (the branches here are named like
# feature/156438-gebruikersbeheer-scherm-binnen-CP). At most 50 characters.
branch_slug() {
    local word slug=""
    for word in $(printf '%s' "$1" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null | sed -E 's/[^A-Za-z0-9]+/ /g'); do
        [[ $word =~ ^[A-Z]{2,}[0-9]*$ ]] || word=${word,,}      # CP and QTI stay, Cypress becomes cypress
        slug+="${slug:+-}$word"
    done
    echo "${slug:0:50}" | sed -E 's/-+$//'
}

# --- commands --------------------------------------------------------------------------------------

cmd_prs() {
    local data line mark via
    data=$(pull_requests) || exit 1
    [ -n "$data" ] || { echo "no open pull requests"; return; }
    while IFS= read -r line; do
        mark=" "; [ "$(jq -r .waiting <<< "$line")" = true ] && mark="*"
        via=$(jq -r 'if .waiting and (.via | length) > 0 then "  via " + (.via | join(", ")) else "" end' <<< "$line")
        printf '%s !%-6s %-14.14s %-48.48s %-18.18s %s%s\n' "$mark" \
            "$(jq -r .id <<< "$line")" "$(jq -r .repo <<< "$line")" "$(jq -r .title <<< "$line")" \
            "$(jq -r .author <<< "$line")" "$(age "$(jq -r .created <<< "$line")")" "$via"
    done <<< "$data"
}

cmd_runs() {
    local prs data line mark
    prs=$(pull_requests) || exit 1
    data=$(runs) || exit 1
    data=$(annotate_runs "$data" "$prs")
    # by default only the newest run of each pipeline on each branch; --all shows every run
    [ "$1" = --all ] || data=$(jq -c 'select(.stale | not)' <<< "$data")
    [ -n "$data" ] || { echo "no recent runs"; return; }
    while IFS= read -r line; do
        mark=" "; [ "$(jq -r .attention <<< "$line")" = true ] && mark="!"
        printf '%s %-10.10s %-34.34s %-26.26s %-10s %s\n' "$mark" "$(jq -r .number <<< "$line")" \
            "$(jq -r .name <<< "$line")" "$(jq -r .branch <<< "$line")" "$(jq -r .result <<< "$line")" \
            "$(age "$(jq -r .finished <<< "$line")")"
    done <<< "$data"
}

# the short name of a work item type: Product Backlog Item -> PBI
short_type() { sed 's/Product Backlog Item/PBI/'; }

cmd_items() {
    local data line
    data=$(work_items "$1") || exit 1
    [ -n "$data" ] || { echo "no work items assigned to you in these states (ado items --all shows more)"; return; }
    while IFS= read -r line; do
        printf '  %-7s %-8s %-12.12s %-14.14s %s\n' "$(jq -r .id <<< "$line")" \
            "$(jq -r .type <<< "$line" | short_type)" "$(jq -r .state <<< "$line")" \
            "$(jq -r .iteration <<< "$line")" "$(jq -r .title <<< "$line")"
    done <<< "$data"
}

cmd_item() {
    local id=$1 json field text
    [[ $id =~ ^[0-9]+$ ]] || die "usage: ado item ID"
    json=$(api "/_apis/wit/workitems/$id?\$expand=all&api-version=7.1") || exit 1
    jq -r --arg org "$ORG" '
        .fields as $f
        | "\($f["System.WorkItemType"]) \(.id): \($f["System.Title"])",
          "state      \($f["System.State"])",
          "assigned   \($f["System.AssignedTo"].displayName // "-")",
          "project    \($f["System.TeamProject"])",
          "area       \($f["System.AreaPath"])",
          "iteration  \($f["System.IterationPath"])",
          (if $f["System.Tags"] then "tags       \($f["System.Tags"])" else empty end),
          "link       https://dev.azure.com/\($org)/\($f["System.TeamProject"] | @uri)/_workitems/edit/\(.id)"' <<< "$json"
    jq -r '[.relations[]? | select(.rel == "ArtifactLink") | .attributes.name] | group_by(.) | map("\(.[0]) x\(length)")
           | if length > 0 then "linked     " + join(", ") else empty end' <<< "$json"

    # the long text fields are HTML
    for field in System.Description Microsoft.VSTS.Common.AcceptanceCriteria Microsoft.VSTS.TCM.ReproSteps; do
        text=$(jq -r --arg f "$field" '.fields[$f] // empty' <<< "$json" | html_to_text | sed '/^[[:space:]]*$/d' | head -n 20)
        if [ -n "$text" ]; then
            echo
            echo "${field##*.}:"
            sed 's/^/  /' <<< "$text"
        fi
    done
}

cmd_branch() {
    local id="" repo_arg="" from="" name="" prefix="" link=0 checkout=0 yes=0 dry=0
    while [ $# -gt 0 ]; do
        case $1 in
            --repo)     repo_arg=$2; shift ;;
            --from)     from=$2; shift ;;
            --name)     name=$2; shift ;;
            --prefix)   prefix=$2; shift ;;
            --link)     link=1 ;;
            --checkout) checkout=1 ;;
            --yes)      yes=1 ;;
            --dry-run)  dry=1 ;;
            -*)         die "unknown option $1 (ado --help)" ;;
            *)          id=$1 ;;
        esac
        shift
    done
    [[ $id =~ ^[0-9]+$ ]] || die "usage: ado branch ID [options] (ado --help)"

    local item type title where repo_spec project repo_name info repo_id project_id default_branch
    local base base_sha heads clash answer body response name_given=0
    [ -n "$name" ] && name_given=1

    item=$(api "/_apis/wit/workitems/$id?api-version=7.1") || exit 1
    type=$(jq -r '.fields["System.WorkItemType"]' <<< "$item")
    title=$(jq -r '.fields["System.Title"]' <<< "$item")

    # the repo: --repo, else the clone you are in, else the one in the config
    if [ -n "$repo_arg" ]; then repo_spec=$repo_arg; where="--repo"
    elif repo_spec=$(repo_from_git); then where="the folder you are in"
    else repo_spec=$REPO; where="the config"
    fi
    project=${repo_spec%%/*}
    repo_name=${repo_spec#*/}
    [ "$project" != "$repo_spec" ] || die "the repo has to be written as PROJECT/REPO, not '$repo_spec'"

    info=$(api "/$(project_path "$project")/_apis/git/repositories/$repo_name?api-version=7.1" 2>/dev/null) \
        || die "there is no repo $repo_spec (or no access to it)"
    repo_id=$(jq -r .id <<< "$info")
    project_id=$(jq -r .project.id <<< "$info")
    default_branch=$(jq -r '.defaultBranch // empty | sub("^refs/heads/"; "")' <<< "$info")
    base=${from:-$default_branch}
    [ -n "$base" ] || die "$repo_spec has no default branch: give one with --from"

    base_sha=$(api "/$(project_path "$project")/_apis/git/repositories/$repo_id/refs?filter=heads/$base&api-version=7.1" |
        jq -r --arg ref "refs/heads/$base" '.value[] | select(.name == $ref) | .objectId')
    [ -n "$base_sha" ] || die "there is no branch $base in $repo_spec"

    if [ -z "$name" ]; then
        if [ -z "$prefix" ]; then
            case $type in Bug) prefix=bug ;; *) prefix=feature ;; esac
        fi
        name="$prefix/$id-$(branch_slug "$title")"
    fi
    # the branches of the repo: the new name must not exist yet (in any letter case), and unless you chose
    # the name yourself, there must not be a branch for this work item already (feature/ID-... or bug/ID_...)
    heads=$(api "/$(project_path "$project")/_apis/git/repositories/$repo_id/refs?filter=heads/&\$top=1000&api-version=7.1" |
        jq -r '.value[].name | sub("^refs/heads/"; "")') || die "could not list the branches of $repo_spec"
    clash=$(grep -iFx -- "$name" <<< "$heads")
    [ -z "$clash" ] || die "the branch $clash already exists in $repo_spec"
    if [ "$name_given" = 0 ]; then
        clash=$(grep -E "(^|/)$id[-_]" <<< "$heads" | head -n 3)
        [ -z "$clash" ] || die "work item $id already has a branch in $repo_spec: $(tr '\n' ' ' <<< "$clash")(--name makes another one)"
    fi

    printf 'work item   %s  %s  %s\n' "$id" "$(short_type <<< "$type")" "$title"
    printf 'repo        %s   (from %s)\n' "$repo_spec" "$where"
    printf 'from        %s  (%s)\n' "$base" "${base_sha:0:8}"
    printf 'new branch  %s%s\n' "$name" "$([ "$link" = 1 ] && echo '   (and linked to the work item)')"
    [ "$dry" = 1 ] && exit 0
    if [ "$yes" != 1 ]; then
        read -r -p "Create it? [y/N] " answer
        [[ $answer == [yY]* ]] || { echo "not created"; exit 0; }
    fi

    body=$(jq -n --arg name "refs/heads/$name" --arg sha "$base_sha" \
        '[{name: $name, oldObjectId: "0000000000000000000000000000000000000000", newObjectId: $sha}]')
    response=$(api_send POST "/$(project_path "$project")/_apis/git/repositories/$repo_id/refs?api-version=7.1" "$body") || exit 1
    jq -e '.value[0].success == true' >/dev/null <<< "$response" || die "the branch was not created: $(jq -r '.value[0].customMessage // "unknown reason"' <<< "$response")"
    echo "created $name"

    if [ "$link" = 1 ]; then
        # the link has the same form as the one the "Create a branch" button makes: project, repo and ref ids
        body=$(jq -n --arg url "vstfs:///Git/Ref/$project_id%2F$repo_id%2FGB${name//\//%2F}" \
            '[{op: "add", path: "/relations/-", value: {rel: "ArtifactLink", url: $url, attributes: {name: "Branch"}}}]')
        if api_send PATCH "/_apis/wit/workitems/$id?api-version=7.1" "$body" application/json-patch+json >/dev/null; then
            echo "linked to work item $id"
        else
            echo "ado: the branch exists, but it could not be linked to work item $id" >&2
        fi
    fi

    if [ "$checkout" = 1 ]; then
        if [ "$(repo_from_git)" = "$repo_spec" ]; then
            git fetch origin "$name" && git switch --track -c "$name" "origin/$name"
        else
            echo "ado: --checkout needs a clone of $repo_spec in the current folder" >&2
        fi
    else
        echo "to work on it:  git fetch origin && git switch $name"
    fi
}

# menu_entries [items]: "url TAB label" lines for the picker. Without items: waiting PRs first, then the
# failed runs, then your own PRs. With items: your work items.
menu_entries() {
    local prs failed
    if [ "$1" = items ]; then
        work_items | jq -r '"\(.url)\t\(.type | sub("Product Backlog Item"; "PBI"))  #\(.id)  \(.state)  \(.title)"'
        return
    fi
    prs=$(pull_requests) || return 1
    failed=$(runs) || return 1
    failed=$(annotate_runs "$failed" "$prs")
    {
        jq -r 'select(.waiting) | "\(.url)\t* review  !\(.id)  \(.title)  (\(.author))\(if (.via | length) > 0 then "  via " + (.via | join(", ")) else "" end)"' <<< "$prs"
        jq -r 'select(.attention) | "\(.url)\t! failed  \(.name)  \(.branch)  #\(.number)"' <<< "$failed"
        jq -r 'select(.mine) | "\(.url)\t  my PR   !\(.id)  \(.title)"' <<< "$prs"
    } | sed '/^$/d'
}

cmd_menu() {
    local entries choice url mode="" print=0 arg
    for arg in "$@"; do
        case $arg in
            items)   mode=items ;;
            --print) print=1 ;;
        esac
    done
    entries=$(menu_entries "$mode") || exit 1
    [ -n "$entries" ] || entries=$'about:blank\tnothing to show'
    if [ "$print" = 1 ]; then
        cut -f2 <<< "$entries"
        return
    fi
    choice=$(cut -f2 <<< "$entries" | fuzzel --dmenu --index --prompt 'devops> ' --width 100 --lines 12) || exit 0
    url=$(sed -n "$((choice + 1))p" <<< "$entries" | cut -f1)
    [ "$url" = about:blank ] && exit 0
    exec firefox "$url" >/dev/null 2>&1
}

# refresh: store the counts, or the reason they could not be looked up, for `ado status`
cmd_refresh() {
    local prs failed review mine broken
    mkdir -p "$CACHE"
    if prs=$(pull_requests) && failed=$(runs); then
        review=$(jq -s '[.[] | select(.waiting)] | length' <<< "$prs")
        mine=$(jq -s '[.[] | select(.mine)] | length' <<< "$prs")
        broken=$(jq -s '[.[] | select(.attention)] | length' <<< "$(annotate_runs "$failed" "$prs")")
        jq -n --argjson review "$review" --argjson mine "$mine" --argjson failed "$broken" --arg at "$(date +%s)" \
            '{review: $review, mine: $mine, failed: $failed, at: ($at | tonumber)}' > "$CACHE/summary.json"
    else
        jq -n --arg at "$(date +%s)" '{error: "login", at: ($at | tonumber)}' > "$CACHE/summary.json"
        exit 1
    fi
}

cmd_status() {
    [ -r "$CACHE/summary.json" ] || { echo "none"; return; }
    jq -r 'if .error then .error else "\(.review) \(.failed)" end' "$CACHE/summary.json"
}

# --- main ------------------------------------------------------------------------------------------

command=${1:-}
[ $# -gt 0 ] && shift

case $command in
    ""|-h|--help|help) usage; exit 0 ;;
    prs|runs|items|item|branch|menu|refresh|status) ;;
    *) die "unknown command '$command' (ado --help)" ;;
esac

load_config
case $command in
    prs)     cmd_prs ;;
    runs)    cmd_runs "$@" ;;
    items)   cmd_items "$@" ;;
    item)    cmd_item "$@" ;;
    branch)  cmd_branch "$@" ;;
    menu)    cmd_menu "$@" ;;
    refresh) cmd_refresh ;;
    status)  cmd_status ;;
esac
