#!/bin/bash
# ado: Azure DevOps at a glance, using your `az login` (no token to manage).
#
#   ado prs                  your open pull requests, and the ones waiting for your review (* = waiting,
#                            also when a team you are in is a reviewer that has not voted yet)
#   ado runs [--all]         the newest run of each of your pipelines per branch (--all: every recent run);
#                            a failure that needs you is marked ! (the newest run failed, and it is not a
#                            validation build of somebody else's pull request)
#   ado items [--all]        your work items that are being worked on (--all: every one that is not closed)
#   ado item [ID]            one work item: state, iteration, description, and what it is linked to
#   ado branch [ID] [options] create a branch for a work item, e.g. feature/156438-short-title (see below)
#                            Without an ID, item and branch let you pick one of your work items with fzf
#                            (with a preview of the item; --all: every one that is not closed).
#   ado start [ID]           start work on a work item: create its branch (linked), move it to In Progress (or
#                            Committed) and open a terminal on the branch in your clone (--plan: only say what
#                            it would do, --yes, --no-terminal)
#   ado pr [--item ID]       create a pull request from the branch you are in (or the branch of a work item):
#                            to the default branch, linked to the work item, titled FEATURE [ID] title
#                            (--draft, --title, --description, --target, --plan, --yes, --open)
#   ado complete NUMBER      complete a pull request by itself when it may (squash, branch deleted, see
#                            MERGE_STRATEGY); --cancel takes it back, --keep-branch, --strategy, --yes
#   ado reply NUMBER THREAD TEXT...  add a comment to a comment thread (the thread numbers: ado comments)
#   ado resolve NUMBER THREAD        resolve a thread (--wontfix, --reactivate)
#   ado undo                 take back the last vote, state change or auto-complete (for 30 minutes)
#   ado vote NUMBER WORD     vote on a pull request: approve, suggest (approve with suggestions), wait (for the
#                            author), reject or reset; asks first (--yes skips the question)
#   ado comments [NUMBER]    the open comment threads of a pull request; without a number, of your own PRs
#   ado checkout NUMBER      switch the clone you are in to the branch of a pull request (--print: only show
#                            the git commands)
#   ado rerun [RUN_ID]       queue a run of a pipeline again on the same branch; without an id, pick one of
#                            your failed runs (--yes skips the question)
#   ado state [ID] [STATE]   move a work item to another state, e.g. Done; without them, pick (--yes, --list)
#   ado sprint [--mine] [--all]  the work items of your team in the current sprint, by state (--all: done ones too)
#   ado new [TYPE] TITLE...  make a work item: a Task unless you say task, bug, pbi, devbug, feature or impediment;
#                            assigned to you, in the current sprint and your team's area. --parent ID makes
#                            it a child of that work item; also --assign, --iteration, --description, --plan,
#                            --yes, --open
#   ado menu [items]         pick a pull request, a failed run or one of your work items (with items: only
#                            the work items) in fuzzel. Enter shows what you can do with it: open it in
#                            Firefox, vote, show the open comments, copy the link or the checkout command,
#                            run it again, start work, create a branch, change the state. The first entries
#                            search all work items, make a new one and show the sprint board; the last five
#                            things you picked come right after them.
#   ado menu search [WORDS]  search the titles of all work items (not only yours) for WORDS, or for what you
#                            type in fuzzel; pick one to open it. A number (156438 or #156438) opens that
#                            work item directly.
#   ado refresh              look everything up and store the counts for the status bar (a timer does this every
#                            five minutes), and send a notification for what is new since the last time: a
#                            review that is asked, a failed run, a vote or a comment on a pull request of yours,
#                            and a review or pull request that has been waiting too long (once each)
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
#   ITEM_STATES=Committed|In Progress|To Do      the states that mean a work item is being worked on (| between them)
#   START_STATES=In Progress|Committed           where ado start moves a work item to: the first of these its type has
#   TEAM=Constructie                             your team: its current sprint and its area are where ado sprint and ado new work
#   ITEM_PROJECT=Cito                            the project of the work items (the repos can be in another one)
#   MERGE_STRATEGY=squash                        how ado complete merges: squash, noFastForward, rebase or rebaseMerge
#   CLONE=~/Projects/x/repo                      the clone ado start opens a terminal in (else the folder you are in,
#                                                or a clone of the repo found in ~/Projects)
#   NOTIFY=1                                     0: ado refresh does not send notifications
#   NUDGE_REVIEW_HOURS=24                        a review that waits this long turns the status bar count red
#   NUDGE_PR_DAYS=2                              a pull request of yours without any vote for this long is noted
# `az login` has to be recent: your organisation asks for a new sign-in every 24 hours.
# `ado menu --print` lists the entries without the menu (--raw: with their url, kind and number).
# ADO_DRY_RUN=1 makes vote, rerun, state and branch print what they would send, and change nothing.

CONFIG=${ADO_CONFIG:-$HOME/.config/ado/config}
CACHE=${XDG_RUNTIME_DIR:-/tmp}/ado
API=${ADO_API:-https://dev.azure.com}
VSSPS=${ADO_VSSPS:-https://vssps.dev.azure.com}
RESOURCE=499b84ac-1321-427f-aa17-267ca6975798     # the Azure DevOps resource: what az needs to know
SELF=$(readlink -f "$0")                          # this script, for the preview of fzf and the menu actions
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/ado   # what is remembered between runs: recent picks, the last change
UNDO=$STATE_DIR/undo
UNDO_MINUTES=30                                   # how long the last change can be undone

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
    ITEM_STATES="Committed|In Progress|To Do"
    START_STATES="In Progress|Committed"
    CLONE=""
    MERGE_STRATEGY=squash
    TEAM=Constructie
    ITEM_PROJECT=Cito
    NOTIFY=1
    NUDGE_REVIEW_HOURS=24
    NUDGE_PR_DAYS=2
    if [ -r "$CONFIG" ]; then
        for name in ORG PROJECTS REPO IGNORE_GROUPS ITEM_STATES START_STATES CLONE MERGE_STRATEGY TEAM ITEM_PROJECT NOTIFY NUDGE_REVIEW_HOURS NUDGE_PR_DAYS; do
            value=$(sed -n "s/^$name=//p" "$CONFIG" | head -n 1)
            [ -n "$value" ] && printf -v "$name" '%s' "$value"
        done
    fi
    [ -n "$ORG" ] && [ -n "$PROJECTS" ] || die "ORG and PROJECTS must be set in $CONFIG"
    CLONE=${CLONE/#\~/$HOME}
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

# api_send METHOD PATH JSON [CONTENT_TYPE]: send JSON to Azure DevOps; on an error print its message and fail.
# With ADO_DRY_RUN=1 nothing is changed: what would be sent is printed (queries still go out, they only read).
api_send() {
    local method=$1 path=$2 body=$3 type=${4:-application/json} token response status
    if [ "${ADO_DRY_RUN:-}" = 1 ] && [[ $path != */wiql* ]]; then
        echo "ado (dry run): $method $path $body" >&2
        echo '{"dryRun": true, "value": [{"success": true}]}'
        return 0
    fi
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
#   {project, path, repo, repo_id, branch, id, title, author, created, draft, mine, votes, waiting, via, url}
# (votes: the reviewers that have voted, as {name, vote})
# (path is the project as it goes into a URL)
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
                    path: $path,
                    repo: .repository.name,
                    repo_id: .repository.id,
                    branch: (.sourceRefName | sub("^refs/heads/"; "")),
                    id: .pullRequestId,
                    title,
                    author: .createdBy.displayName,
                    created: .creationDate,
                    draft: (.isDraft // false),
                    mine: (.createdBy.id == $me),
                    votes: [($pr.reviewers // [])[] | select(.vote != 0) | {name: .displayName, vote}],
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
#   {project, id, definition, name, number, branch, result, status, finished, url, stale}
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
                    definition: .definition.id,
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
#   {id, type, state, title, project, iteration, assigned, url}
# The work items can be in another project than the code (here: Cito, while the repos are in QuestifyBuilder),
# so the query is not limited to one project.
work_items() {
    local where state states query ids list=""
    if [ "$1" = --all ]; then
        where="[System.State] NOT IN ('Done','Removed','Closed','Resolved')"
    else
        IFS='|' read -ra states <<< "$ITEM_STATES"
        for state in "${states[@]}"; do list+="'$state',"; done
        where="[System.State] IN (${list%,})"
    fi
    query=$(jq -n --arg q "SELECT [System.Id] FROM WorkItems WHERE [System.AssignedTo] = @Me AND $where ORDER BY [System.ChangedDate] DESC" '{query: $q}')
    ids=$(api_send POST '/_apis/wit/wiql?$top=50&api-version=7.1' "$query" | jq -r '[.workItems[].id] | join(",")') || return 1
    items_from_ids "$ids"
}

# search_items TEXT: like work_items, but for any work item whose title contains all the words of TEXT
# (not only yours, in any state), the most recently changed first
search_items() {
    local word where="" query ids
    for word in $1; do
        where+=" AND [System.Title] CONTAINS '${word//\'/\'\'}'"
    done
    [ -n "$where" ] || return 0
    query=$(jq -n --arg q "SELECT [System.Id] FROM WorkItems WHERE [System.Id] > 0$where ORDER BY [System.ChangedDate] DESC" '{query: $q}')
    ids=$(api_send POST '/_apis/wit/wiql?$top=50&api-version=7.1' "$query" | jq -r '[.workItems[].id] | join(",")') || return 1
    items_from_ids "$ids"
}

# items_from_ids IDS: the work_items JSON objects for comma separated work item numbers, in that order
items_from_ids() {
    local ids=$1
    [ -n "$ids" ] || return 0

    api "/_apis/wit/workitems?ids=$ids&fields=System.Id,System.WorkItemType,System.State,System.Title,System.TeamProject,System.IterationPath,System.AssignedTo&api-version=7.1" |
        jq -c --arg ids "$ids" --arg org "$ORG" '
            ($ids | split(",") | map(tonumber)) as $order
            | .value | sort_by(.id as $id | $order | index($id)) | .[] | {
                id,
                type: .fields["System.WorkItemType"],
                state: .fields["System.State"],
                title: .fields["System.Title"],
                project: .fields["System.TeamProject"],
                iteration: (.fields["System.IterationPath"] | split("\\") | last),
                assigned: (.fields["System.AssignedTo"].displayName // "-"),
                url: "https://dev.azure.com/\($org)/\(.fields["System.TeamProject"] | @uri)/_workitems/edit/\(.id)"
            }'
}

# --- branches -------------------------------------------------------------------------------------

# repo_from_git [DIR]: "PROJECT/REPO" of the Azure DevOps clone in DIR, or in the current folder (fails when there is none)
repo_from_git() {
    local url rest project
    url=$(git -C "${1:-.}" remote get-url origin 2>/dev/null) || return 1
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

# pick_from PROMPT LIST [PREVIEW_ARGS]: choose one line of LIST ("key TAB label" lines) and print its key. fzf shows
# the labels, and with PREVIEW_ARGS (the arguments of ado, the key is added) a preview next to them; without fzf or
# without a terminal it is a numbered list. ADO_PICKER=list forces the list and ADO_PICKER=fzf forces fzf.
# Status: 0 picked, 3 nothing picked.
pick_from() {
    local prompt=$1 list=$2 preview=${3:-} choice n use_fzf=0 args=()
    # fzf when it is installed and there is a terminal for it, unless ADO_PICKER says otherwise
    case ${ADO_PICKER:-auto} in
        fzf)  use_fzf=1 ;;
        list) ;;
        *)    [ -t 0 ] && [ -t 2 ] && use_fzf=1 ;;
    esac
    command -v fzf >/dev/null || use_fzf=0

    if [ "$use_fzf" = 1 ]; then
        [ -n "$preview" ] && args=(--preview "'$SELF' $preview {1}" --preview-window 'right,55%,wrap')
        choice=$(fzf --delimiter '\t' --with-nth 2 --prompt "$prompt> " "${args[@]}" <<< "$list") || return 3
    else
        cut -f2 <<< "$list" | nl -w2 -s'. ' >&2
        read -r -p "Number: " n
        [[ $n =~ ^[0-9]+$ ]] || return 3
        choice=$(sed -n "${n}p" <<< "$list")
    fi
    [ -n "$choice" ] || return 3
    echo "${choice%%$'\t'*}"
}

# pick_item [--all]: choose one of your work items and print its number. Status: 0 picked, 3 nothing picked, 1 an error.
pick_item() {
    local list
    list=$(work_items "$1" | jq -r '"\(.id)\t\(.type | sub("Product Backlog Item"; "PBI"))  \(.state)  \(.iteration)  \(.title)"') || return 1
    [ -n "$list" ] || { echo "ado: no work items assigned to you in these states (--all shows more)" >&2; return 1; }
    pick_from 'work item' "$list" item
}

# resolve_item ID ALL: the work item number that was given, or else one picked from your work items.
# Status like pick_item; callers do: id=$(resolve_item "$id" "$all"); case $? in 0) ;; 3) exit 0 ;; *) exit 1 ;; esac
resolve_item() {
    local id=$1 all=$2 picked status
    if [ -z "$id" ]; then
        picked=$(pick_item "$all")
        status=$?
        [ "$status" -eq 0 ] || return "$status"
        id=$picked
    fi
    [[ $id =~ ^[0-9]+$ ]] || { echo "ado: a work item number is needed" >&2; return 1; }
    echo "$id"
}

# confirm_cli QUESTION YES: unless YES is 1, ask on the terminal; status 0 when it may go ahead
confirm_cli() {
    local answer
    [ "$2" = 1 ] && return 0
    read -r -p "$1 [y/N] " answer
    [[ $answer == [yY]* ]]
}

# --- commands--------------------------------------------------------------------------------------

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
    local id="" all="" arg json field text
    for arg in "$@"; do
        case $arg in
            --all) all=--all ;;
            *)     id=$arg ;;
        esac
    done
    id=$(resolve_item "$id" "$all"); case $? in 0) ;; 3) exit 0 ;; *) exit 1 ;; esac
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
    local id="" all="" repo_arg="" from="" name="" prefix="" link=0 checkout=0 yes=0 dry=0
    while [ $# -gt 0 ]; do
        case $1 in
            --all)      all=--all ;;
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
    id=$(resolve_item "$id" "$all"); case $? in 0) ;; 3) exit 0 ;; *) exit 1 ;; esac

    local item type title where repo_spec project repo_name info repo_id project_id default_branch
    local base base_sha heads clash body response name_given=0
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
    confirm_cli "Create it?" "$yes" || { echo "not created"; exit 0; }

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

# --- pull requests: votes, comments, checkout; builds; work item state ------------------------------

# pr_json NUMBER: the pull request, found by its number alone (they are numbered over the whole organisation)
pr_json() { api "/_apis/git/pullrequests/$1?api-version=7.1"; }

# pr_threads PROJECT REPO NUMBER: one JSON object per comment thread of a pull request that is still open:
#   {id, status, file, line, author, text, replies, comments}      (comments: all of them, as {author, text}; PROJECT and REPO as they go into a URL: names or ids)
pr_threads() {
    api "/$1/_apis/git/repositories/$2/pullRequests/$3/threads?api-version=7.1" | jq -c '
        .value[]
        | select((.status == "active" or .status == "pending") and (.isDeleted | not)
                 and ((.comments[0].commentType // "text") != "system"))
        | {id, status, file: .threadContext.filePath,
           line: (.threadContext.rightFileStart.line // .threadContext.leftFileStart.line),
           author: .comments[0].author.displayName, text: (.comments[0].content // ""),
           replies: ((.comments | length) - 1),
           comments: [.comments[] | select((.isDeleted | not) and ((.commentType // "text") != "system"))
                      | {author: .author.displayName, text: (.content // "")}]}'
}

# thread_line: from threads (JSON lines) on stdin, one text line each: file:line, who, what, replies
thread_line() {
    jq -r '"#\(.id)  \(.file // "(general)")\(if .line then ":\(.line)" else "" end)  \(.author): \(.text | gsub("\\s+"; " ") | .[0:90])\(if .replies > 0 then "  (+\(.replies))" else "" end)"'
}

# thread_view: from one thread (JSON) on stdin, the conversation as text: where it is, then each comment with its author.
# At most the last 30 lines; the long lines are left to the reader to wrap.
thread_view() {
    jq -r '"\(.file // "(general)")\(if .line then ":\(.line)" else "" end)   [\(.status)]",
           (.comments[] | "", "\(.author):", (.text | split("\n")[] | "  " + .))' |
        awk '{ line[NR] = $0 } END { start = NR > 30 ? NR - 29 : 1; if (start > 1) print "... (" start - 1 " earlier lines left out)"; for (i = start; i <= NR; i++) print line[i] }'
}

# vote_value WORD: the number Azure DevOps keeps for a vote (fails for an unknown word)
vote_value() {
    case $1 in
        approve) echo 10 ;;
        suggest) echo 5 ;;
        wait)    echo -5 ;;
        reject)  echo -10 ;;
        reset)   echo 0 ;;
        *)       return 1 ;;
    esac
}

# vote_word NUMBER: the word for a vote number (the other way round from vote_value)
vote_word() {
    case $1 in
        10)  echo approve ;;
        5)   echo suggest ;;
        -5)  echo wait ;;
        -10) echo reject ;;
        *)   echo reset ;;
    esac
}

vote_text() {
    case $1 in
        approve) echo "approved" ;;
        suggest) echo "approved with suggestions" ;;
        wait)    echo "waiting for the author" ;;
        reject)  echo "rejected" ;;
        reset)   echo "vote reset" ;;
    esac
}

cmd_vote() {
    local id="" word="" yes=0 arg value pr title me previous
    for arg in "$@"; do
        case $arg in
            --yes) yes=1 ;;
            -*)    die "unknown option $arg (ado --help)" ;;
            *)     if [ -z "$id" ]; then id=${arg#!}; else word=$arg; fi ;;
        esac
    done
    [[ $id =~ ^[0-9]+$ ]] && [ -n "$word" ] || die "usage: ado vote NUMBER approve|suggest|wait|reject|reset [--yes]"
    value=$(vote_value "$word") || die "unknown vote '$word' (approve, suggest, wait, reject or reset)"
    pr=$(pr_json "$id") || die "there is no pull request $id (or no access to it)"
    title=$(jq -r .title <<< "$pr")
    confirm_cli "Vote '$word' on !$id  $title?" "$yes" || { echo "not voted"; return; }
    me=$(my_id) || exit 1
    previous=$(jq -r --arg me "$me" '[.reviewers[]? | select(.id == $me) | .vote][0] // 0' <<< "$pr")
    api_send PUT "/$(jq -r .repository.project.id <<< "$pr")/_apis/git/repositories/$(jq -r .repository.id <<< "$pr")/pullrequests/$id/reviewers/$me?api-version=7.1" \
        "$(jq -n --argjson vote "$value" '{vote: $vote}')" >/dev/null || exit 1
    record_undo "$(vote_text "$word") !$id" vote "$id" "$(vote_word "$previous")" --yes
    echo "$(vote_text "$word"): !$id  $title"
}

# cmd_comments [NUMBER [THREAD]]: the open comment threads of a pull request; without a number, of all your own pull
# requests; with a thread number, that thread in full (every comment)
cmd_comments() {
    local id=${1#!} thread=${2#\#} pr line threads
    if [ -n "$id" ]; then
        [[ $id =~ ^[0-9]+$ ]] || die "a pull request number is needed"
        pr=$(pr_json "$id") || die "there is no pull request $id (or no access to it)"
        threads=$(pr_threads "$(jq -r .repository.project.id <<< "$pr")" "$(jq -r .repository.id <<< "$pr")" "$id") || exit 1
        if [ -n "$thread" ]; then
            threads=$(jq -c --argjson id "${thread:-0}" 'select(.id == $id)' <<< "$threads")
            [ -n "$threads" ] || die "!$id has no open thread $thread (ado comments $id lists them)"
            thread_view <<< "$threads"
            return
        fi
        [ -n "$threads" ] || { echo "no open comments on !$id"; return; }
        thread_line <<< "$threads"
        return
    fi
    local any=0
    while IFS= read -r line; do
        threads=$(pr_threads "$(jq -r .path <<< "$line")" "$(jq -r .repo_id <<< "$line")" "$(jq -r .id <<< "$line")") || exit 1
        [ -n "$threads" ] || continue
        any=1
        echo "!$(jq -r .id <<< "$line")  $(jq -r .title <<< "$line")"
        thread_line <<< "$threads" | sed 's/^/  /'
    done < <(pull_requests | jq -c 'select(.mine)')
    [ "$any" = 1 ] || echo "no open comments on your pull requests"
}

# cmd_checkout NUMBER [--print]: switch the clone you are in to the branch of a pull request
# (--print: only show the commands, for a clone you are not in)
cmd_checkout() {
    local id="" print=0 arg pr repo branch
    for arg in "$@"; do
        case $arg in
            --print) print=1 ;;
            -*)      die "unknown option $arg (ado --help)" ;;
            *)       id=${arg#!} ;;
        esac
    done
    [[ $id =~ ^[0-9]+$ ]] || die "usage: ado checkout NUMBER [--print]"
    pr=$(pr_json "$id") || die "there is no pull request $id (or no access to it)"
    repo=$(jq -r '"\(.repository.project.name)/\(.repository.name)"' <<< "$pr")
    branch=$(jq -r '.sourceRefName | sub("^refs/heads/"; "")' <<< "$pr")
    if [ "$print" = 1 ]; then
        echo "git fetch origin $branch && git switch $branch"
        return
    fi
    [ "$(repo_from_git)" = "$repo" ] || die "this folder is not a clone of $repo"
    git fetch origin "$branch" || exit 1
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git switch "$branch"
    else
        git switch --track -c "$branch" "origin/$branch"
    fi
}

# cmd_rerun [BUILD_ID] [--yes]: queue a run of the same pipeline on the same branch again; without an id, pick
# one of your failed runs
cmd_rerun() {
    local id="" yes=0 arg list build project path name ref definition body response prs
    for arg in "$@"; do
        case $arg in
            --yes) yes=1 ;;
            -*)    die "unknown option $arg (ado --help)" ;;
            *)     id=$arg ;;
        esac
    done
    if [ -z "$id" ]; then
        prs=$(pull_requests) || exit 1
        list=$(annotate_runs "$(runs)" "$prs" | jq -r 'select(.attention) | "\(.id)\t\(.name)  \(.branch)  #\(.number)"') || exit 1
        [ -n "$list" ] || die "none of your runs has failed"
        id=$(pick_from 'failed run' "$list"); case $? in 0) ;; 3) exit 0 ;; *) exit 1 ;; esac
    fi
    [[ $id =~ ^[0-9]+$ ]] || die "a run number is needed (the id in the link of the run)"

    build=""
    for project in $PROJECTS; do
        path=$(project_path "$project")
        build=$(api "/$path/_apis/build/builds/$id?api-version=7.1" 2>/dev/null) && break
        build=""
    done
    [ -n "$build" ] || die "there is no run $id in $PROJECTS"
    name=$(jq -r .definition.name <<< "$build")
    definition=$(jq -r .definition.id <<< "$build")
    ref=$(jq -r .sourceBranch <<< "$build")
    confirm_cli "Run $name again on ${ref#refs/heads/}?" "$yes" || { echo "not queued"; return; }

    body=$(jq -n --argjson definition "$definition" --arg ref "$ref" '{definition: {id: $definition}, sourceBranch: $ref}')
    response=$(api_send POST "/$path/_apis/build/builds?api-version=7.1" "$body") || exit 1
    echo "queued $name #$(jq -r '.buildNumber // "?"' <<< "$response") on ${ref#refs/heads/}"
}

# cmd_state [NUMBER] [STATE] [--yes] [--list]: move a work item to another state, e.g. Done (the states are those
# of its type; without a state, pick one). --list only prints the states it can go to.
cmd_state() {
    local id="" state="" yes=0 list=0 arg item type project title current states match body
    for arg in "$@"; do
        case $arg in
            --yes)  yes=1 ;;
            --list) list=1 ;;
            -*)     die "unknown option $arg (ado --help)" ;;
            *)      if [ -z "$id" ] && [[ $arg =~ ^[0-9]+$ ]]; then id=$arg; else state+="${state:+ }$arg"; fi ;;
        esac
    done
    id=$(resolve_item "$id" ""); case $? in 0) ;; 3) exit 0 ;; *) exit 1 ;; esac
    item=$(api "/_apis/wit/workitems/$id?api-version=7.1") || exit 1
    type=$(jq -r '.fields["System.WorkItemType"]' <<< "$item")
    project=$(jq -r '.fields["System.TeamProject"]' <<< "$item")
    title=$(jq -r '.fields["System.Title"]' <<< "$item")
    current=$(jq -r '.fields["System.State"]' <<< "$item")
    states=$(api "/${project// /%20}/_apis/wit/workitemtypes/${type// /%20}/states?api-version=7.1" | jq -r '.value[].name') || exit 1

    if [ "$list" = 1 ]; then
        grep -vFx -- "$current" <<< "$states"
        return
    fi
    if [ -z "$state" ]; then
        state=$(pick_from "state of $id (now $current)" "$(grep -vFx -- "$current" <<< "$states" | awk '{print $0 "\t" $0}')")
        case $? in 0) ;; 3) exit 0 ;; *) exit 1 ;; esac
    fi
    match=$(grep -ixF -- "$state" <<< "$states" | head -n 1)
    [ -n "$match" ] || die "work item $id ($type) has no state '$state' (it has: $(paste -sd, <<< "$states" | sed 's/,/, /g'))"
    [ "$match" != "$current" ] || { echo "work item $id is $current already"; return; }
    confirm_cli "Move work item $id from $current to $match?  $title" "$yes" || { echo "not changed"; return; }

    body=$(jq -n --arg state "$match" '[{op: "add", path: "/fields/System.State", value: $state}]')
    api_send PATCH "/_apis/wit/workitems/$id?api-version=7.1" "$body" application/json-patch+json >/dev/null || exit 1
    record_undo "work item $id: $current -> $match" state "$id" "$current" --yes
    echo "work item $id: $current -> $match  $title"
}

# --- replying, completing, creating pull requests; undo -------------------------------------------------

# pr_target NUMBER: "PROJECT_ID TAB REPO_ID TAB TITLE" of a pull request (fails when there is none)
pr_target() {
    local out
    out=$(pr_json "$1" 2>/dev/null | jq -r '[.repository.project.id, .repository.id, .title] | @tsv')
    [ -n "$out" ] || return 1
    echo "$out"
}

# cmd_reply NUMBER THREAD TEXT...: add a comment to a thread of a pull request (the thread numbers are in ado comments)
cmd_reply() {
    local id=${1#!} thread=${2:-} text target project repo title
    shift 2 2>/dev/null
    text="$*"
    [[ $id =~ ^[0-9]+$ ]] && [[ ${thread#\#} =~ ^[0-9]+$ ]] && [ -n "$text" ] || die "usage: ado reply NUMBER THREAD TEXT..."
    thread=${thread#\#}
    target=$(pr_target "$id") || die "there is no pull request $id (or no access to it)"
    IFS=$'\t' read -r project repo title <<< "$target"
    api_send POST "/$project/_apis/git/repositories/$repo/pullRequests/$id/threads/$thread/comments?api-version=7.1" \
        "$(jq -n --arg text "$text" '{content: $text, parentCommentId: 1, commentType: 1}')" >/dev/null || exit 1
    echo "replied on thread $thread of !$id  $title"
}

# cmd_resolve NUMBER THREAD [--wontfix|--reactivate]: mark a thread of a pull request as resolved
cmd_resolve() {
    local id="" thread="" status=fixed arg target project repo title word=resolved
    for arg in "$@"; do
        case $arg in
            --wontfix)    status=wontFix; word="closed as won't fix" ;;
            --reactivate) status=active; word=reactivated ;;
            -*)           die "unknown option $arg (ado --help)" ;;
            *)            if [ -z "$id" ]; then id=${arg#!}; else thread=${arg#\#}; fi ;;
        esac
    done
    [[ $id =~ ^[0-9]+$ ]] && [[ $thread =~ ^[0-9]+$ ]] || die "usage: ado resolve NUMBER THREAD [--wontfix|--reactivate]"
    target=$(pr_target "$id") || die "there is no pull request $id (or no access to it)"
    IFS=$'\t' read -r project repo title <<< "$target"
    api_send PATCH "/$project/_apis/git/repositories/$repo/pullRequests/$id/threads/$thread?api-version=7.1" \
        "$(jq -n --arg status "$status" '{status: $status}')" >/dev/null || exit 1
    echo "thread $thread of !$id $word"
}

# cmd_complete NUMBER [--cancel] [--keep-branch] [--strategy S] [--yes]: complete a pull request by itself as soon as
# it may be (reviews and builds are in), the way the website's "Set auto-complete" does. The branch is deleted
# afterwards, and the merge is MERGE_STRATEGY (squash), unless you say otherwise. --cancel takes it back.
cmd_complete() {
    local id="" cancel=0 keep=0 strategy=$MERGE_STRATEGY yes=0 arg pr me title body delete=true
    while [ $# -gt 0 ]; do
        case $1 in
            --cancel)      cancel=1 ;;
            --keep-branch) keep=1 ;;
            --strategy)    strategy=${2:-}; shift ;;
            --yes)         yes=1 ;;
            -*)            die "unknown option $1 (ado --help)" ;;
            *)             id=${1#!} ;;
        esac
        shift
    done
    [[ $id =~ ^[0-9]+$ ]] || die "usage: ado complete NUMBER [--cancel] [--keep-branch] [--strategy squash|noFastForward|rebase|rebaseMerge] [--yes]"
    case $strategy in squash|noFastForward|rebase|rebaseMerge) ;; *) die "unknown merge strategy '$strategy'" ;; esac
    pr=$(pr_json "$id") || die "there is no pull request $id (or no access to it)"
    title=$(jq -r .title <<< "$pr")
    [ "$(jq -r '.isDraft // false' <<< "$pr")" != true ] || die "!$id is a draft: publish it first"
    [ "$keep" = 1 ] && delete=false

    if [ "$cancel" = 1 ]; then
        confirm_cli "Cancel auto-complete of !$id  $title?" "$yes" || { echo "not changed"; return; }
        body='{"autoCompleteSetBy": {"id": "00000000-0000-0000-0000-000000000000"}}'
    else
        confirm_cli "Complete !$id  $title by itself when it may ($strategy, $([ "$keep" = 1 ] && echo "keep" || echo "delete") the branch)?" "$yes" \
            || { echo "not changed"; return; }
        me=$(my_id) || exit 1
        body=$(jq -n --arg me "$me" --arg strategy "$strategy" --argjson delete "$delete" '
            {autoCompleteSetBy: {id: $me},
             completionOptions: ({mergeStrategy: $strategy, deleteSourceBranch: $delete}
                                 + (if $strategy == "squash" then {squashMerge: true} else {} end))}')
    fi
    api_send PATCH "/$(jq -r .repository.project.id <<< "$pr")/_apis/git/repositories/$(jq -r .repository.id <<< "$pr")/pullrequests/$id?api-version=7.1" \
        "$body" >/dev/null || exit 1
    if [ "$cancel" = 1 ]; then
        echo "auto-complete cancelled: !$id  $title"
    else
        record_undo "auto-complete of !$id" complete "$id" --cancel --yes
        echo "will complete when ready: !$id  $title"
    fi
}

# load_repo PROJECT/REPO: look a repo up. Sets REPO_PATH (the project as it goes into a URL), REPO_ID,
# REPO_DEFAULT (its default branch) and REPO_HEADS (its branches, one per line).
load_repo() {
    local spec=$1 project name info
    project=${spec%%/*}
    name=${spec#*/}
    [ "$project" != "$spec" ] || die "the repo has to be written as PROJECT/REPO, not '$spec'"
    REPO_PATH=$(project_path "$project")
    info=$(api "/$REPO_PATH/_apis/git/repositories/$name?api-version=7.1" 2>/dev/null) \
        || die "there is no repo $spec (or no access to it)"
    REPO_ID=$(jq -r .id <<< "$info")
    REPO_DEFAULT=$(jq -r '.defaultBranch // empty | sub("^refs/heads/"; "")' <<< "$info")
    REPO_HEADS=$(api "/$REPO_PATH/_apis/git/repositories/$REPO_ID/refs?filter=heads/&\$top=1000&api-version=7.1" |
        jq -r '.value[].name | sub("^refs/heads/"; "")') || die "could not list the branches of $spec"
}

# cmd_pr [--item ID] [--draft] [--title T] [--description TEXT] [--target BRANCH] [--yes] [--plan] [--open]
# Create a pull request from the branch you are in (the clone you are in), or with --item from the branch of a work
# item. It goes to the default branch of the repo, is linked to the work item in the branch name, and is titled like
# the others here: FEATURE [156438] title of the work item. --plan only says what it would do.
cmd_pr() {
    local item_id="" draft=false title="" description="" target="" yes=0 plan=0 open=0 arg
    local repo_spec branch wid item prefix existing summary body response id name
    while [ $# -gt 0 ]; do
        case $1 in
            --item)        item_id=${2:-}; shift ;;
            --draft)       draft=true ;;
            --title)       title=${2:-}; shift ;;
            --description) description=${2:-}; shift ;;
            --target)      target=${2:-}; shift ;;
            --yes)         yes=1 ;;
            --plan)        plan=1 ;;
            --open)        open=1 ;;
            *)             die "unknown argument $1 (ado --help)" ;;
        esac
        shift
    done

    repo_spec=$(repo_from_git) || { [ -n "$item_id" ] && repo_spec=$REPO; } \
        || die "run this in a clone of an Azure DevOps repo, or give --item NUMBER"
    load_repo "$repo_spec"
    name=${repo_spec#*/}
    if [ -n "$item_id" ]; then
        [[ $item_id =~ ^[0-9]+$ ]] || die "--item needs a work item number"
        branch=$(grep -E "(^|/)$item_id[-_]" <<< "$REPO_HEADS" | head -n 1)
        [ -n "$branch" ] || die "work item $item_id has no branch in $repo_spec yet (ado start $item_id makes one)"
    else
        branch=$(git branch --show-current 2>/dev/null)
        [ -n "$branch" ] || die "no branch: you are not on a branch in this folder"
    fi
    grep -qxF -- "$branch" <<< "$REPO_HEADS" || die "$branch is not on the server yet (git push -u origin $branch)"
    target=${target:-$REPO_DEFAULT}
    [ "$branch" != "$target" ] || die "$branch is the target branch itself"
    existing=$(api "/$REPO_PATH/_apis/git/pullrequests?searchCriteria.repositoryId=$REPO_ID&searchCriteria.sourceRefName=refs/heads/$branch&searchCriteria.status=active&api-version=7.1" |
        jq -r '.value[0].pullRequestId // empty')
    [ -z "$existing" ] || die "$branch has pull request !$existing already"

    # the work item in the branch name (feature/156438-title) gives the link and the title
    wid=""
    [[ $branch =~ (^|/)([0-9]+)[-_] ]] && wid=${BASH_REMATCH[2]}
    if [ -z "$title" ]; then
        prefix=""
        [[ $branch == */* ]] && prefix="${branch%%/*}" && prefix="${prefix^^} "
        if [ -n "$wid" ] && item=$(api "/_apis/wit/workitems/$wid?api-version=7.1" 2>/dev/null); then
            title="$prefix[$wid] $(jq -r '.fields["System.Title"]' <<< "$item")"
        else
            wid=""
            title="$prefix$(sed -E 's/[-_]+/ /g' <<< "${branch##*/}")"
        fi
    fi

    summary="$title  ($branch -> $target$([ "$draft" = true ] && echo ", draft"))"
    if [ "$plan" = 1 ]; then
        echo "$summary"
        return
    fi
    confirm_cli "Create pull request: $summary?" "$yes" || { echo "not created"; return; }

    body=$(jq -n --arg src "refs/heads/$branch" --arg tgt "refs/heads/$target" --arg title "$title" --arg description "$description" \
                 --argjson draft "$draft" --arg wid "$wid" \
        '{sourceRefName: $src, targetRefName: $tgt, title: $title, description: $description, isDraft: $draft}
         + (if $wid != "" then {workItemRefs: [{id: $wid}]} else {} end)')
    response=$(api_send POST "/$REPO_PATH/_apis/git/repositories/$REPO_ID/pullrequests?api-version=7.1" "$body") || exit 1
    id=$(jq -r '.pullRequestId // "?"' <<< "$response")
    echo "created !$id  $title"
    [ "$id" != "?" ] || return 0
    echo "https://dev.azure.com/$ORG/$REPO_PATH/_git/$name/pullrequest/$id"
    [ "$open" = 1 ] && open_url "https://dev.azure.com/$ORG/$REPO_PATH/_git/$name/pullrequest/$id"
    return 0
}

# record_undo DESCRIPTION ARGS...: remember how to take back what was just done; ARGS are the arguments of ado that
# do it. Only the last change is kept, for UNDO_MINUTES. Nothing for a dry run, nor for an undo itself.
record_undo() {
    if [ "${ADO_DRY_RUN:-}" = 1 ] || [ -n "${ADO_NO_UNDO:-}" ]; then
        return 0
    fi
    local desc=$1
    shift
    mkdir -p "$STATE_DIR"
    jq -n --arg desc "$desc" --argjson at "$(date +%s)" --argjson cmd "$(printf '%s\n' "$@" | jq -R . | jq -sc .)" \
        '{at: $at, desc: $desc, cmd: $cmd}' > "$UNDO"
}

# undo_info: what can be undone, with how long ago ("approved !32332 (3m ago)"); fails when there is nothing
undo_info() {
    [ -r "$UNDO" ] || return 1
    jq -er --argjson now "$(date +%s)" --argjson limit "$((UNDO_MINUTES * 60))" \
        'select($now - .at <= $limit) | "\(.desc) (\(($now - .at) / 60 | floor)m ago)"' "$UNDO" 2>/dev/null
}

# cmd_undo [--yes] [--print]: take back the last vote, state change or auto-complete (--print: only say what it is)
cmd_undo() {
    local yes=0 info args
    case ${1:-} in
        --yes)   yes=1 ;;
        --print) undo_info || echo "nothing to undo"; return ;;
    esac
    info=$(undo_info) || die "nothing to undo (there is no recent change, or it is older than $UNDO_MINUTES minutes)"
    confirm_cli "Undo: $info?" "$yes" || { echo "not undone"; return; }
    mapfile -t args < <(jq -r '.cmd[]' "$UNDO")
    ADO_NO_UNDO=1 "$SELF" "${args[@]}" && rm -f "$UNDO"
}

# --- sprint, new work items ---------------------------------------------------------------------------

# the order of the states in a list: the ones at the start of the work first
STATE_ORDER='["New","Approved","To Do","Committed","In Progress","Done","Closed","Resolved","Removed"]'

# team_path: your team as it goes into a URL: PROJECT/TEAM
team_path() { echo "${ITEM_PROJECT// /%20}/${TEAM// /%20}"; }

# team_area: the area path of your team (where its work items are)
team_area() { api "/$(team_path)/_apis/work/teamsettings/teamfieldvalues?api-version=7.1" | jq -er '.defaultValue'; }

# sprint_info: the current sprint of your team as JSON {name, path, start, end} (fails when there is none)
sprint_info() {
    api "/$(team_path)/_apis/work/teamsettings/iterations?\$timeframe=current&api-version=7.1" |
        jq -ce '.value[0] | select(. != null) | {name, path, start: .attributes.startDate, end: .attributes.finishDate}'
}

# sprint_items [--mine] [--all]: the work items of your team in the current sprint (work_items JSON lines), the
# states in STATE_ORDER and the most recently changed first. Not the ones that are done, unless --all.
sprint_items() {
    local mine="" closed=" AND [System.State] NOT IN ('Done','Removed','Closed','Resolved')" arg area query ids
    for arg in "$@"; do
        case $arg in
            --mine) mine=" AND [System.AssignedTo] = @Me" ;;
            --all)  closed="" ;;
        esac
    done
    area=$(team_area) || return 1
    query=$(jq -n --arg q "SELECT [System.Id] FROM WorkItems WHERE [System.IterationPath] = @CurrentIteration AND [System.AreaPath] UNDER '${area//\'/\'\'}'$mine$closed ORDER BY [System.ChangedDate] DESC" '{query: $q}')
    ids=$(api_send POST "/$(team_path)/_apis/wit/wiql?\$top=200&api-version=7.1" "$query" | jq -r '[.workItems[].id] | join(",")') || return 1
    items_from_ids "$ids" | jq -sc --argjson order "$STATE_ORDER" 'sort_by(.state as $s | ($order | index($s)) // 99) | .[]'
}

# cmd_sprint [--mine] [--all]: the work items of your team in the current sprint, by state
cmd_sprint() {
    local arg info data line kind a b c d
    for arg in "$@"; do
        case $arg in --mine|--all) ;; *) die "unknown argument $arg (ado --help)" ;; esac
    done
    info=$(sprint_info) || die "team $TEAM has no current sprint"
    jq -r '"\(.name)  (\(.start[0:10]) to \(.end[0:10]))"' <<< "$info"
    data=$(sprint_items "$@") || exit 1
    [ -n "$data" ] || { echo "nothing in it"; return; }
    jq -rs 'group_by(.state) | map({state: .[0].state, items: .}) | .[]
            | "H\t\(.state) (\(.items | length))", (.items[] | "I\t\(.id)\t\(.type | sub("Product Backlog Item"; "PBI"))\t\(.assigned | split(" ")[0])\t\(.title)")' <<< "$data" |
        while IFS=$'\t' read -r kind a b c d; do
            if [ "$kind" = H ]; then echo; echo "$a"; else printf '  %-7s %-8s %-12.12s %s\n' "$a" "$b" "$c" "$d"; fi
        done
}

# sprint_entries [--mine]: menu entries for the work items in the current sprint (with who has it)
sprint_entries() {
    sprint_items "$@" | jq -r '"\(.url)\t\(.state)  \(.type | sub("Product Backlog Item"; "PBI"))  #\(.id)  \(.assigned | split(" ")[0])  \(.title)\titem\t\(.id)"'
}

# new_type WORD: the work item type that WORD stands for (fails for a word that is none)
new_type() {
    case ${1,,} in
        task)         echo "Task" ;;
        bug)          echo "Bug" ;;
        pbi|backlog)  echo "Product Backlog Item" ;;
        devbug)       echo "Dev Bug" ;;
        feature)      echo "Feature" ;;
        impediment)   echo "Impediment" ;;
        *)            return 1 ;;
    esac
}

# my_account: the account name of you (what an Assigned To field takes)
my_account() {
    local file="$CACHE/account" account
    if [ ! -s "$file" ]; then
        account=$(api "/_apis/connectionData?api-version=7.1-preview" | jq -r '.authenticatedUser.properties.Account["$value"] // empty')
        [ -n "$account" ] || return 1
        mkdir -p "$CACHE"
        echo "$account" > "$file"
    fi
    cat "$file"
}

# cmd_new [TYPE] TITLE... [options]: make a work item: a Task unless you name a type (task, bug, pbi, devbug,
# feature, impediment), assigned to you, in the current sprint and the area of your team.
#   --type T  --title TEXT   the same, for a title that starts with a word that is a type
#   --parent ID              make it a child of that work item (a task under a PBI); it takes the area and sprint of the parent
#   --assign me|none         who gets it (default: you)
#   --iteration current|none|PATH   the sprint (default: the current one)
#   --description TEXT  --plan  --yes  --open
cmd_new() {
    local type="" parent="" assign=me iteration=current title="" description="" yes=0 plan=0 open=0 words=() t
    local project area iter account parent_item summary ops response id link who
    while [ $# -gt 0 ]; do
        case $1 in
            --type)        type=$(new_type "${2:-}") || die "unknown type '${2:-}' (task, bug, pbi, devbug, feature, impediment)"; shift ;;
            --title)       title=${2:-}; shift ;;
            --parent)      parent=${2#\#}; shift ;;
            --assign)      assign=${2:-}; shift ;;
            --iteration)   iteration=${2:-}; shift ;;
            --description) description=${2:-}; shift ;;
            --yes)         yes=1 ;;
            --plan)        plan=1 ;;
            --open)        open=1 ;;
            -*)            die "unknown option $1 (ado --help)" ;;
            *)             words+=("$1") ;;
        esac
        shift
    done
    if [ -z "$type" ] && [ -z "$title" ] && [ "${#words[@]}" -gt 1 ] && t=$(new_type "${words[0]}"); then
        type=$t
        words=("${words[@]:1}")
    fi
    [ -n "$title" ] || title="${words[*]}"
    [ -n "$title" ] || die "usage: ado new [TYPE] TITLE... [--parent ID] [--assign me|none] [--iteration current|none|PATH] [--description TEXT] [--plan] [--yes] [--open]"
    type=${type:-Task}
    [ -z "$parent" ] || [[ $parent =~ ^[0-9]+$ ]] || die "--parent needs a work item number"

    # where it goes: the sprint and area of the parent, else those of your team
    if [ -n "$parent" ]; then
        parent_item=$(api "/_apis/wit/workitems/$parent?api-version=7.1") || die "there is no work item $parent"
        project=$(jq -r '.fields["System.TeamProject"]' <<< "$parent_item")
        area=$(jq -r '.fields["System.AreaPath"]' <<< "$parent_item")
        iter=$(jq -r '.fields["System.IterationPath"]' <<< "$parent_item")
    else
        project=$ITEM_PROJECT
        area=$(team_area) || die "could not look up the area of team $TEAM"
        iter=""
    fi
    case $iteration in
        none)    iter="" ;;
        current) [ -n "$iter" ] || iter=$(sprint_info | jq -r .path) ;;
        *)       iter=$iteration ;;
    esac
    case $assign in
        me)   account=$(my_account) || die "could not look up your account" ;;
        none) account="" ;;
        *)    die "--assign is me or none" ;;
    esac

    who=${account:+you}; who=${who:-nobody}
    summary="$type \"$title\" in ${iter##*\\}, assigned to $who${parent:+, under #$parent}"
    if [ "$plan" = 1 ]; then
        echo "$summary"
        return
    fi
    confirm_cli "Create $summary?" "$yes" || { echo "not created"; return; }

    ops=$(jq -n --arg title "$title" --arg area "$area" --arg iter "$iter" --arg account "$account" --arg description "$description" \
                --arg parent "$parent" --arg org "$ORG" '
        [{op: "add", path: "/fields/System.Title", value: $title},
         {op: "add", path: "/fields/System.AreaPath", value: $area}]
        + (if $iter != "" then [{op: "add", path: "/fields/System.IterationPath", value: $iter}] else [] end)
        + (if $account != "" then [{op: "add", path: "/fields/System.AssignedTo", value: $account}] else [] end)
        + (if $description != "" then [{op: "add", path: "/fields/System.Description", value: $description}] else [] end)
        + (if $parent != "" then [{op: "add", path: "/relations/-", value: {rel: "System.LinkTypes.Hierarchy-Reverse",
                                   url: "https://dev.azure.com/\($org)/_apis/wit/workItems/\($parent)"}}] else [] end)')
    response=$(api_send POST "/${project// /%20}/_apis/wit/workitems/\$${type// /%20}?api-version=7.1" "$ops" application/json-patch+json) || exit 1
    id=$(jq -r '.id // "?"' <<< "$response")
    echo "created $type $id: $title"
    [ "$id" != "?" ] || return 0
    link="https://dev.azure.com/$ORG/${project// /%20}/_workitems/edit/$id"
    echo "$link"
    [ "$open" = 1 ] && open_url "$link"
    return 0
}

# --- start work ---------------------------------------------------------------------------------------

# find_clone REPO_SPEC: the folder of a clone of PROJECT/REPO: CLONE from the config, the folder you are in, or
# a clone in ~/Projects (up to two levels down). Fails when there is none.
find_clone() {
    local dir
    for dir in "$CLONE" "$PWD" "$HOME"/Projects/*/ "$HOME"/Projects/*/*/; do
        [ -n "$dir" ] && [ -e "$dir/.git" ] || continue
        if [ "$(repo_from_git "$dir")" = "$1" ]; then
            echo "${dir%/}"
            return
        fi
    done
    return 1
}

# cmd_start [ID] [--yes] [--plan] [--no-terminal]: start work on a work item: make its branch (linked to the item, as
# ado branch --link does; an existing branch of the item is used as it is), move the item to START_STATES
# (not when it is in one of them already), and open a terminal on the branch in a clone of the repo.
# --plan only says what it would do.
cmd_start() {
    local id="" yes=0 plan=0 terminal=1 arg item type title current project repo_spec
    local heads existing name states target="" state want summary clone out
    for arg in "$@"; do
        case $arg in
            --yes)         yes=1 ;;
            --plan)        plan=1 ;;
            --no-terminal) terminal=0 ;;
            -*)            die "unknown option $arg (ado --help)" ;;
            *)             id=$arg ;;
        esac
    done
    id=$(resolve_item "$id" ""); case $? in 0) ;; 3) exit 0 ;; *) exit 1 ;; esac

    item=$(api "/_apis/wit/workitems/$id?api-version=7.1") || exit 1
    type=$(jq -r '.fields["System.WorkItemType"]' <<< "$item")
    title=$(jq -r '.fields["System.Title"]' <<< "$item")
    current=$(jq -r '.fields["System.State"]' <<< "$item")
    project=$(jq -r '.fields["System.TeamProject"]' <<< "$item")

    # the repo: the clone you are in, else the one in the config (as ado branch does)
    repo_spec=$(repo_from_git) || repo_spec=$REPO
    load_repo "$repo_spec"
    heads=$REPO_HEADS
    existing=$(grep -E "(^|/)$id[-_]" <<< "$heads" | head -n 1)
    if [ -n "$existing" ]; then
        name=$existing
    else
        name=$("$SELF" branch "$id" --repo "$repo_spec" --dry-run | sed -n 's/^new branch  *//p')
        [ -n "$name" ] || die "could not work out a branch name for work item $id"
    fi

    # the state to move to: the first of START_STATES that the type has, unless it is in one of them already
    states=$(api "/${project// /%20}/_apis/wit/workitemtypes/${type// /%20}/states?api-version=7.1" | jq -r '.value[].name') || exit 1
    IFS='|' read -ra want <<< "$START_STATES"
    for state in "${want[@]}"; do
        [ "$state" = "$current" ] && { target=""; break; }
        [ -z "$target" ] && grep -qxF -- "$state" <<< "$states" && target=$state
    done

    summary="branch $name ($([ -n "$existing" ] && echo "exists" || echo "new"))"
    [ -n "$target" ] && summary+=", $current -> $target"
    if [ "$plan" = 1 ]; then
        echo "$summary"
        return
    fi
    confirm_cli "Start work on $id ($title): $summary?" "$yes" || { echo "not started"; return; }

    if [ -z "$existing" ]; then
        out=$("$SELF" branch "$id" --repo "$repo_spec" --link --yes 2>&1) || die "${out##*$'\n'}"
        echo "created $name"
    fi
    if [ -n "$target" ]; then
        "$SELF" state "$id" "$target" --yes > /dev/null || die "the branch is made, but the state of work item $id was not changed"
        echo "work item $id: $current -> $target"
    fi
    [ "$terminal" = 1 ] || return 0

    if clone=$(find_clone "$repo_spec"); then
        setsid foot --working-directory "$clone" bash -c \
            'git fetch origin "$1" && git switch "$1"; exec "${SHELL:-bash}"' _ "$name" >/dev/null 2>&1 &
        echo "opened a terminal on $name in $clone"
    else
        echo "no clone of $repo_spec found (CLONE in the config); to work on it: git fetch origin $name && git switch $name"
    fi
}

# --- the fuzzel menu --------------------------------------------------------------------------------

# The entries of the menu are "url TAB label TAB kind TAB ref" lines. The kind says what an entry is and decides
# its actions (Enter on an entry): pr (waits for your review), pr-mine, run (a failed one), item, and search, undo,
# new and sprint, which are the entries at the top that do something themselves.
# The ref is the number of the pull request, run or work item.

# item_entries: menu entries for work items (JSON lines of work_items on stdin)
item_entries() {
    jq -r '"\(.url)\t\(.type | sub("Product Backlog Item"; "PBI"))  #\(.id)  \(.state)  \(.title)\titem\t\(.id)"'
}

# menu_entries [items]: the entries for the picker. Without items: the search entry, waiting PRs, the failed
# runs, your own PRs, then your work items. With items: only your work items.
# The search entry has the url ado:search; cmd_menu answers it by asking what to search for.
menu_entries() {
    local prs failed items info
    items=$(work_items | item_entries)
    if [ "$1" = items ]; then
        echo "$items"
        return
    fi
    prs=$(pull_requests) || return 1
    failed=$(runs) || return 1
    failed=$(annotate_runs "$failed" "$prs")
    {
        printf 'ado:search\t? search work items...\tsearch\t\n'
        if info=$(undo_info); then printf 'ado:undo\t<< undo: %s\tundo\t\n' "$info"; fi
        printf 'ado:new\t+ new work item...\tnew\t\n'
        printf 'ado:sprint\t? sprint board...\tsprint\t\n'
        jq -r 'select(.waiting) | "\(.url)\t* review  !\(.id)  \(.title)  (\(.author))\(if (.via | length) > 0 then "  via " + (.via | join(", ")) else "" end)\tpr\t\(.id)"' <<< "$prs"
        jq -r 'select(.attention) | "\(.url)\t! failed  \(.name)  \(.branch)  #\(.number)\trun\t\(.id)"' <<< "$failed"
        jq -r 'select(.mine) | "\(.url)\t  my PR   !\(.id)  \(.title)\tpr-mine\t\(.id)"' <<< "$prs"
        echo "$items"
    } | sed '/^$/d'
}

# The things you picked last are listed first (the last five, kept in RECENT as "kind TAB ref" lines).
RECENT=${XDG_STATE_HOME:-$HOME/.local/state}/ado/recent

# record_recent KIND REF: remember that you picked this entry
record_recent() {
    local line
    line=$(printf '%s\t%s' "$1" "$2")
    mkdir -p "$(dirname "$RECENT")"
    { grep -vxF -- "$line" "$RECENT" 2>/dev/null; echo "$line"; } | tail -n 5 > "$RECENT.new" && mv "$RECENT.new" "$RECENT"
}

# reorder_recent ENTRIES: the entries with the search entry first, then those you picked last (the newest first),
# then the others as they were
reorder_recent() {
    [ -s "$RECENT" ] || { echo "$1"; return; }
    awk -F'\t' -v OFS='\t' '
        NR == FNR { rank[$1 FS $2] = NR; next }
        { key = $3 FS $4
          if ($3 == "search" || $3 == "undo" || $3 == "new" || $3 == "sprint") group = 0; else if (key in rank) group = 1; else group = 2
          print group, (group == 1 ? -rank[key] : 0), FNR, $0 }' "$RECENT" - <<< "$1" |
        sort -t$'\t' -k1,1n -k2,2n -k3,3n | cut -f4-
}

# search_entries TEXT: menu entries for the work items whose title contains TEXT
search_entries() {
    search_items "$1" | item_entries
}

# open_url URL: open it in Firefox and bring that window to the front (sway does not let a new tab take the
# focus by itself, so the page would open out of sight)
open_url() {
    setsid firefox "$1" >/dev/null 2>&1 &
    sleep 0.4
    swaymsg '[app_id="org.mozilla.firefox"] focus' >/dev/null 2>&1
}

say() { notify-send -a ado "$@"; }

# pick_menu PROMPT [MESSAGE]: choose one line of stdin in fuzzel and print its index (fails when you close it);
# MESSAGE is shown above the list
pick_menu() {
    local lines width=60 args=()
    lines=$(cat)
    [ -n "${2:-}" ] && { args=(--mesg "$2"); width=110; }
    fuzzel --dmenu --index --prompt "$1> " --width "$width" --lines "$(wc -l <<< "$lines")" "${args[@]}" <<< "$lines"
}

# confirm_menu QUESTION [MESSAGE]: a yes/no in fuzzel (MESSAGE above it), with No first so that a stray Enter does nothing
confirm_menu() {
    local answer args=()
    [ -n "${2:-}" ] && args=(--mesg "$2")
    answer=$(printf 'No\nYes\n' | fuzzel --dmenu --index --prompt "$1 " --width 100 --lines 2 "${args[@]}") || return 1
    [ "$answer" = 1 ]
}

# run_action ARGS...: run ado with ARGS and show what it printed as a notification
run_action() {
    local out
    if out=$("$SELF" "$@" 2>&1); then
        say "ado" "${out:-done}"
    else
        say -u critical "ado: failed" "${out:-no message}"
    fi
}

# show_comments NUMBER URL: the open comment threads of a pull request in fuzzel; picking one opens it
show_comments() {
    local id=$1 url=$2 pr threads list choice
    pr=$(pr_json "$id") || { say -u critical "ado" "there is no pull request $id"; return; }
    threads=$(pr_threads "$(jq -r .repository.project.id <<< "$pr")" "$(jq -r .repository.id <<< "$pr")" "$id")
    [ -n "$threads" ] || { say "ado" "no open comments on !$id"; return; }
    list=$(paste -d $'\t' <(jq -r --arg url "$url" '"\($url)?discussionId=\(.id)"' <<< "$threads") <(thread_line <<< "$threads"))
    choice=$(cut -f2 <<< "$list" | fuzzel --dmenu --index --prompt "!$id comments> " --width 120 --lines 12) || return 0
    thread_actions "$id" "$url" "$(sed -n "$((choice + 1))p" <<< "$threads")"
}

# menu_new [PARENT]: make a work item: pick its type (a Task under PARENT when there is one) and type the title
menu_new() {
    local parent=${1:-} type choice title plan types=("Task" "Bug" "Product Backlog Item" "Dev Bug") args=()
    if [ -n "$parent" ]; then
        type=Task
        args=(--parent "$parent")
    else
        choice=$(printf '%s\n' "${types[@]}" | pick_menu "new work item") || return 0
        type=${types[$choice]}
    fi
    title=$(fuzzel --dmenu --lines 0 --prompt "$type> " --width 100 < /dev/null) || return 0
    [ -n "$title" ] || return 0
    plan=$("$SELF" new --type "$type" --title "$title" "${args[@]}" --plan 2>&1) || { say -u critical "ado: cannot make it" "$plan"; return; }
    confirm_menu "Create $plan?" && run_action new --type "$type" --title "$title" "${args[@]}" --yes --open
}

# thread_actions NUMBER URL THREAD: what to do with one comment thread (THREAD is its JSON from pr_threads)
thread_actions() {
    local id=$1 url=$2 thread=$3 tid choice text view
    tid=$(jq -r .id <<< "$thread")
    view=$(thread_view <<< "$thread")      # the whole conversation stays on screen above every question below
    choice=$(printf '%s\n' "Open" "Reply" "Resolve" "Close as won't fix" "Copy text" | pick_menu "thread #$tid" "$view") || return 0
    case $choice in
        0) open_url "$url?discussionId=$tid" ;;
        1) text=$(fuzzel --dmenu --lines 0 --mesg "$view" --prompt "reply #$tid> " --width 110 < /dev/null) || return 0
           [ -n "$text" ] && confirm_menu "Post this reply?" "$view"$'\n\n'"you:"$'\n'"  $text" && run_action reply "$id" "$tid" "$text" ;;
        2) confirm_menu "Resolve thread #$tid?" "$view" && run_action resolve "$id" "$tid" ;;
        3) confirm_menu "Close thread #$tid as won't fix?" "$view" && run_action resolve "$id" "$tid" --wontfix ;;
        4) jq -r '[.comments[] | "\(.author):\n\(.text)"] | join("\n\n")' <<< "$thread" | wl-copy; say "ado" "thread copied" ;;
    esac
}

# menu_actions KIND REF URL: what you can do with the entry you picked (Open comes first)
menu_actions() {
    local kind=$1 ref=$2 url=$3 labels=("Open") keys=(open) choice key plan name states new
    case $kind in
        pr)      labels+=("Approve" "Approve with suggestions" "Wait for the author" "Reject" "Reset my vote" "Show open comments" "Copy link" "Copy checkout command")
                 keys+=(vote-approve vote-suggest vote-wait vote-reject vote-reset comments link checkout) ;;
        pr-mine) labels+=("Show open comments" "Set auto-complete" "Cancel auto-complete" "Copy link" "Copy checkout command")
                 keys+=(comments complete uncomplete link checkout) ;;
        run)     labels+=("Run it again" "Copy link")
                 keys+=(rerun link) ;;
        item)    labels+=("Start work" "Add task" "Create pull request" "Create a branch" "Change state" "Copy number" "Copy link")
                 keys+=(start addtask newpr branch state number link) ;;
        *)       open_url "$url"; return ;;
    esac
    choice=$(printf '%s\n' "${labels[@]}" | pick_menu "actions") || return 0
    key=${keys[$choice]}
    case $key in
        open)     open_url "$url" ;;
        link)     wl-copy "$url"; say "ado" "link copied" ;;
        number)   wl-copy "$ref"; say "ado" "$ref copied" ;;
        checkout) wl-copy "$("$SELF" checkout "$ref" --print)"; say "ado" "checkout command copied" ;;
        comments) show_comments "$ref" "$url" ;;
        vote-*)   confirm_menu "${labels[$choice]} !$ref?" && run_action vote "$ref" "${key#vote-}" --yes ;;
        rerun)    confirm_menu "Run it again?" && run_action rerun "$ref" --yes ;;
        complete)   confirm_menu "Complete !$ref by itself when it may (squash, delete the branch)?" && run_action complete "$ref" --yes ;;
        uncomplete) confirm_menu "Cancel auto-complete of !$ref?" && run_action complete "$ref" --cancel --yes ;;
        newpr)
            plan=$("$SELF" pr --item "$ref" --plan 2>&1) || { say -u critical "ado: no pull request" "$plan"; return; }
            confirm_menu "Create pull request: $plan?" && run_action pr --item "$ref" --yes --open ;;
        addtask)  menu_new "$ref" ;;
        start)
            plan=$("$SELF" start "$ref" --plan 2>&1) || { say -u critical "ado: cannot start" "$plan"; return; }
            confirm_menu "Start work on $ref: $plan?" && run_action start "$ref" --yes ;;
        branch)
            # --dry-run shows the name; it also fails when the work item has a branch already
            plan=$("$SELF" branch "$ref" --dry-run 2>&1) || { say -u critical "ado: no branch" "$plan"; return; }
            name=$(sed -n 's/^new branch  *//p' <<< "$plan")
            confirm_menu "Create branch $name, linked to $ref?" && run_action branch "$ref" --link --yes ;;
        state)
            states=$("$SELF" state "$ref" --list 2>&1) || { say -u critical "ado: no states" "$states"; return; }
            choice=$(pick_menu "move $ref to" <<< "$states") || return 0
            new=$(sed -n "$((choice + 1))p" <<< "$states")
            confirm_menu "Move work item $ref to $new?" && run_action state "$ref" "$new" --yes ;;
    esac
}

cmd_menu() {
    local entries choice url kind ref mode="" print=0 raw=0 arg query=""
    for arg in "$@"; do
        case $arg in
            items)   mode=items ;;
            sprint)  mode=sprint ;;
            search)  mode=search ;;
            --print) print=1 ;;
            --raw)   print=1; raw=1 ;;
            *)       [ "$mode" = search ] && query+="${query:+ }$arg" ;;
        esac
    done

    if [ "$mode" = search ]; then
        # no words given: ask for them in fuzzel (an empty list, so only the typed text counts)
        if [ -z "$query" ]; then
            [ "$print" = 1 ] && die "ado menu search --print needs the words to search for"
            query=$(fuzzel --dmenu --lines 0 --prompt 'work item> ' --width 60 < /dev/null) || exit 0
        fi
        query=$(xargs <<< "$query" 2>/dev/null || echo "$query")
        [ -n "$query" ] || exit 0
        # a number is a work item: open it without a search (the URL without a project redirects)
        if [[ $query =~ ^#?([0-9]+)$ ]]; then
            url="https://dev.azure.com/$ORG/_workitems/edit/${BASH_REMATCH[1]}"
            [ "$print" = 1 ] && { echo "$url"; return; }
            open_url "$url"
            exit 0
        fi
        entries=$(search_entries "$query") || exit 1
        [ -n "$entries" ] || entries=$'about:blank\tno work item found for: '"$query"
    elif [ "$mode" = sprint ]; then
        entries=$(sprint_entries) || exit 1
    else
        entries=$(menu_entries "$mode") || exit 1
        entries=$(reorder_recent "$entries")
    fi
    [ -n "$entries" ] || entries=$'about:blank\tnothing to show'
    if [ "$print" = 1 ]; then
        if [ "$raw" = 1 ]; then echo "$entries"; else cut -f2 <<< "$entries"; fi
        return
    fi

    # Enter asks what to do with the entry (Open is the first action)
    choice=$(cut -f2 <<< "$entries" | fuzzel --dmenu --index --prompt 'devops> ' --width 100 --lines 12) || exit 0
    IFS=$'\t' read -r url _ kind ref <<< "$(sed -n "$((choice + 1))p" <<< "$entries")"
    [ "$url" = about:blank ] && exit 0
    [ "$kind" = search ] && exec "$SELF" menu search
    [ "$kind" = sprint ] && exec "$SELF" menu sprint
    if [ "$kind" = new ]; then
        menu_new
        exit 0
    fi
    if [ "$kind" = undo ]; then
        confirm_menu "Undo: $(undo_info)?" && run_action undo --yes
        exit 0
    fi
    record_recent "$kind" "$ref"
    menu_actions "$kind" "$ref" "$url"
}

# --- refresh, notifications -------------------------------------------------------------------------

# refresh_snapshot PRS RUNS COMMENTS: what the pull requests and runs look like now, as one JSON object, for
# comparing with the last refresh. COMMENTS is {pull request number: how many comments are open}.
#   review: the pull requests waiting for you         failed: the runs that need you
#   mine:   your own pull requests, with their votes and open comments
#   nudge:  what has been waiting too long: a review for NUDGE_REVIEW_HOURS, a pull request of yours without any
#           vote for NUDGE_PR_DAYS (the key says which one, the value what to tell you)
refresh_snapshot() {
    jq -n --argjson now "$(date +%s)" --argjson hours "$NUDGE_REVIEW_HOURS" --argjson days "$NUDGE_PR_DAYS" \
          --argjson comments "$3" --slurpfile prs <(echo "$1") --slurpfile runs <(echo "$2") '
        def vname: sub("^.*\\\\"; "");
        def age: (sub("\\.[0-9]+"; "") | fromdateiso8601) as $created | $now - $created;
        {
            taken: $now,
            review: ([$prs[] | select(.waiting) | {key: (.id | tostring), value: {title, author, age: (.created | age)}}] | from_entries),
            failed: ([$runs[] | select(.attention) | {key: (.id | tostring), value: {name, branch, number}}] | from_entries),
            mine:   ([$prs[] | select(.mine) | {key: (.id | tostring), value: {
                          title, draft: .draft, age: (.created | age),
                          votes: (.votes | map({key: (.name | vname), value: .vote}) | from_entries),
                          comments: ($comments[.id | tostring] // 0)}}] | from_entries)
        }
        | .nudge = ([(.review | to_entries[] | select(.value.age >= $hours * 3600)
                      | {key: "review-\(.key)", value: "waiting \(.value.age / 3600 | floor)h for your review: !\(.key)  \(.value.title)"}),
                     (.mine | to_entries[] | select((.value.draft | not) and .value.age >= $days * 86400
                                                    and ([.value.votes[] | select(. != 0)] | length) == 0)
                      | {key: "mine-\(.key)", value: "no review yet after \(.value.age / 86400 | floor)d: !\(.key)  \(.value.title)"})]
                    | from_entries)'
}

# refresh_events OLD NEW: what is new in the snapshot NEW since the snapshot OLD, one "urgency TAB title TAB text"
# line each: a review that was asked, a failed run, a vote or a comment on a pull request of yours, a nudge
refresh_events() {
    jq -r --argjson old "$1" '
        def vtext: if . == 10 then "approved" elif . == 5 then "approved with suggestions"
                   elif . == -5 then "is waiting for the author" else "rejected" end;
        . as $new
        | ($new.review | to_entries[] | select($old.review[.key] == null)
           | "normal\tReview asked\t!\(.key)  \(.value.title)  (\(.value.author))"),
          ($new.failed | to_entries[] | select($old.failed[.key] == null)
           | "critical\tRun failed\t\(.value.name)  \(.value.branch)  #\(.value.number)"),
          ($new.mine | to_entries[] | .key as $id | .value as $now | $old.mine[$id] as $then | select($then != null)
           | (($now.votes | to_entries[] | select(.value != 0 and ($then.votes[.key] // 0) != .value)
               | "\(if .value < 0 then "critical" else "normal" end)\t\(.key) \(.value | vtext)\t!\($id)  \($now.title)"),
              (select($now.comments > $then.comments) | "normal\tNew comment\t!\($id)  \($now.title)"))),
          ($new.nudge | to_entries[] | select($old.nudge[.key] == null) | "low\tStill waiting\t\(.value)")' <<< "$2"
}

# notify_events OLD NEW: show what refresh_events finds as notifications (not with NOTIFY=0 in the config)
notify_events() {
    local urgency title text
    [ "$NOTIFY" = 0 ] && return
    refresh_events "$1" "$2" | while IFS=$'\t' read -r urgency title text; do
        notify-send -a ado -u "$urgency" "$title" "$text"
    done
}

# refresh: store the counts, or the reason they could not be looked up, for `ado status`; tell what is new since
# the last time (nothing the first time: that would be a notification for everything that is open already)
cmd_refresh() {
    local prs failed annotated review mine broken threads=0 line n open comments_json='{}' snapshot old review_old mine_idle
    local file="$CACHE/snapshot.json"
    mkdir -p "$CACHE"
    if prs=$(pull_requests) && failed=$(runs); then
        annotated=$(annotate_runs "$failed" "$prs")
        review=$(jq -s '[.[] | select(.waiting)] | length' <<< "$prs")
        mine=$(jq -s '[.[] | select(.mine)] | length' <<< "$prs")
        broken=$(jq -s '[.[] | select(.attention)] | length' <<< "$annotated")
        # the open comment threads on your own pull requests (a lookup that fails counts as none)
        while IFS= read -r line; do
            open=$(pr_threads "$(jq -r .path <<< "$line")" "$(jq -r .repo_id <<< "$line")" "$(jq -r .id <<< "$line")")
            n=$(jq -s 'length' <<< "$open")
            threads=$(( threads + n ))
            comments_json=$(jq -c --arg id "$(jq -r .id <<< "$line")" --argjson n "$(jq -s 'map(1 + .replies) | add // 0' <<< "$open")" \
                '. + {($id): $n}' <<< "$comments_json")
        done < <(jq -c 'select(.mine)' <<< "$prs")

        snapshot=$(refresh_snapshot "$prs" "$annotated" "$comments_json")
        if [ -r "$file" ] && old=$(jq -c 'select(.taken)' "$file") && [ -n "$old" ]; then
            notify_events "$old" "$snapshot"
        fi
        echo "$snapshot" > "$file.new" && mv "$file.new" "$file"

        review_old=$(jq '[.nudge | keys[] | select(startswith("review-"))] | length' <<< "$snapshot")
        mine_idle=$(jq '[.nudge | keys[] | select(startswith("mine-"))] | length' <<< "$snapshot")
        jq -n --argjson review "$review" --argjson mine "$mine" --argjson failed "$broken" --argjson comments "$threads" \
              --argjson review_old "$review_old" --argjson mine_idle "$mine_idle" --arg at "$(date +%s)" \
            '{review: $review, mine: $mine, failed: $failed, comments: $comments, review_old: $review_old,
              mine_idle: $mine_idle, at: ($at | tonumber)}' > "$CACHE/summary.json"
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
    prs|runs|items|item|branch|sprint|new|start|pr|vote|comments|reply|resolve|complete|checkout|rerun|state|undo|menu|refresh|status) ;;
    *) die "unknown command '$command' (ado --help)" ;;
esac

load_config
case $command in
    sprint)   cmd_sprint "$@" ;;
    new)      cmd_new "$@" ;;
    start)    cmd_start "$@" ;;
    pr)       cmd_pr "$@" ;;
    reply)    cmd_reply "$@" ;;
    resolve)  cmd_resolve "$@" ;;
    complete) cmd_complete "$@" ;;
    undo)     cmd_undo "$@" ;;
    vote)     cmd_vote "$@" ;;
    comments) cmd_comments "$@" ;;
    checkout) cmd_checkout "$@" ;;
    rerun)    cmd_rerun "$@" ;;
    state)    cmd_state "$@" ;;
    prs)     cmd_prs ;;
    runs)    cmd_runs "$@" ;;
    items)   cmd_items "$@" ;;
    item)    cmd_item "$@" ;;
    branch)  cmd_branch "$@" ;;
    menu)    cmd_menu "$@" ;;
    refresh) cmd_refresh ;;
    status)  cmd_status ;;
esac
