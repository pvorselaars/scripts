#!/bin/bash
# ado: Azure DevOps at a glance, using your `az login` (no token to manage).
#
#   ado prs             your open pull requests, and the ones waiting for your review (* = waiting)
#   ado runs [--all]    the newest run of each of your pipelines per branch (--all: every recent run);
#                       a failure that needs you is marked ! (the newest run failed, and it is not a
#                       validation build of somebody else's pull request)
#   ado menu            pick a pull request or a failed run in fuzzel and open it in Firefox
#   ado refresh         look everything up and store the counts for the status bar
#   ado status          print the stored counts: REVIEW FAILED (or "login" when az needs a new sign-in)
#
# The organisation and the projects to look at are in ~/.config/ado/config:
#   ORG=cito-ivit
#   PROJECTS=QuestifyBuilder Another Project     (separated by spaces; use _ for a space inside a name)
# `az login` has to be recent: your organisation asks for a new sign-in every 24 hours.
# `ado menu --print` lists the entries without the menu.

CONFIG=${ADO_CONFIG:-$HOME/.config/ado/config}
CACHE=${XDG_RUNTIME_DIR:-/tmp}/ado
API=${ADO_API:-https://dev.azure.com}
RESOURCE=499b84ac-1321-427f-aa17-267ca6975798     # the Azure DevOps resource: what az needs to know

die() { echo "ado: $*" >&2; exit 1; }

# the comment block at the top of this file, without the "# "
usage() { sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; }

# --- configuration, sign-in -----------------------------------------------------------------------

load_config() {
    ORG=cito-ivit
    PROJECTS=QuestifyBuilder
    if [ -r "$CONFIG" ]; then
        ORG=$(sed -n 's/^ORG=//p' "$CONFIG" | head -n 1)
        PROJECTS=$(sed -n 's/^PROJECTS=//p' "$CONFIG" | head -n 1)
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

# --- looking things up ----------------------------------------------------------------------------

# pull_requests: one JSON object per active pull request that is yours or waits for you, over all projects:
#   {project, repo, id, title, author, created, draft, mine, waiting, url}
# A PR waits for you when you are a reviewer who has not voted yet and it is not a draft.
pull_requests() {
    local me project path
    me=$(my_id) || return 1
    for project in $PROJECTS; do
        path=$(project_path "$project")
        for filter in creatorId reviewerId; do
            api "/$path/_apis/git/pullrequests?searchCriteria.status=active&searchCriteria.$filter=$me&api-version=7.1" |
                jq -c --arg project "$(project_name "$project")" --arg path "$path" --arg org "$ORG" --arg me "$me" '
                    .value[] | {
                        project: $project,
                        repo: .repository.name,
                        id: .pullRequestId,
                        title,
                        author: .createdBy.displayName,
                        created: .creationDate,
                        draft: (.isDraft // false),
                        mine: (.createdBy.id == $me),
                        waiting: ((.isDraft // false | not) and (.createdBy.id != $me)
                                  and any(.reviewers[]?; .id == $me and .vote == 0)),
                        url: ("https://dev.azure.com/\($org)/\($path)/_git/\(.repository.name | @uri)/pullrequest/\(.pullRequestId)")
                    }' || return 1
        done
    done | jq -sc 'unique_by([.project, .repo, .id]) | sort_by(.created) | reverse | .[]'
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

# --- commands --------------------------------------------------------------------------------------

cmd_prs() {
    local data line mark
    data=$(pull_requests) || exit 1
    [ -n "$data" ] || { echo "no open pull requests"; return; }
    while IFS= read -r line; do
        mark=" "; [ "$(jq -r .waiting <<< "$line")" = true ] && mark="*"
        printf '%s !%-6s %-14.14s %-48.48s %-18.18s %s\n' "$mark" \
            "$(jq -r .id <<< "$line")" "$(jq -r .repo <<< "$line")" "$(jq -r .title <<< "$line")" \
            "$(jq -r .author <<< "$line")" "$(age "$(jq -r .created <<< "$line")")"
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

# menu_entries: "url TAB label" lines for the picker: waiting PRs first, then the failed runs, then your own PRs
menu_entries() {
    local prs failed
    prs=$(pull_requests) || return 1
    failed=$(runs) || return 1
    failed=$(annotate_runs "$failed" "$prs")
    {
        jq -r 'select(.waiting) | "\(.url)\t* review  !\(.id)  \(.title)  (\(.author))"' <<< "$prs"
        jq -r 'select(.attention) | "\(.url)\t! failed  \(.name)  \(.branch)  #\(.number)"' <<< "$failed"
        jq -r 'select(.mine) | "\(.url)\t  my PR   !\(.id)  \(.title)"' <<< "$prs"
    } | sed '/^$/d'
}

cmd_menu() {
    local entries choice url
    entries=$(menu_entries) || exit 1
    [ -n "$entries" ] || entries=$'about:blank\tnothing to do: no reviews waiting, no failed runs, no open pull requests of yours'
    if [ "$1" = --print ]; then
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
    prs|runs|menu|refresh|status) ;;
    *) die "unknown command '$command' (ado --help)" ;;
esac

load_config
case $command in
    prs)     cmd_prs ;;
    runs)    cmd_runs "$@" ;;
    menu)    cmd_menu "$@" ;;
    refresh) cmd_refresh ;;
    status)  cmd_status ;;
esac
