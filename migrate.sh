#!/usr/bin/env bash
# =============================================================================
#  migrate.sh — GitLab → GitHub migration (entry point)
#  Usage   : chmod +x migrate.sh && ./migrate.sh
#
#  Flow:
#    1) Code (branches, tags, commits) — always migrated via git mirror.
#    2) Wiki — detected automatically; asks before migrating if found.
#    3) Issues / MRs / labels / milestones — detected via GitLab API (if a
#       token is provided); asks before migrating if any exist.
#       (delegated to migrate.py)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

LOGFILE="migration_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

cleanup() {
    local exit_code=$?
    [[ -n "${WORKDIR:-}" ]] && rm -rf "$WORKDIR"
    if [[ $exit_code -ne 0 ]]; then
        echo
        echo -e "${RED}[ERROR]${RESET} Script exited with an error. See ${LOGFILE} for the full log."
    fi
}
trap cleanup EXIT

# ─── Helpers ─────────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

ask() {
    local var="$1" prompt="$2" default="${3:-}"
    local display_default=""
    [[ -n "$default" ]] && display_default=" ${CYAN}[${default}]${RESET}"
    echo -en "${BOLD}${prompt}${RESET}${display_default}: "
    read -r value </dev/tty 2>/dev/null || read -r value
    [[ -z "$value" && -n "$default" ]] && value="$default"
    printf -v "$var" '%s' "$value"
}

ask_secret() {
    local var="$1" prompt="$2"
    echo -en "${BOLD}${prompt}${RESET} ${YELLOW}(hidden)${RESET}: "
    read -rs value </dev/tty 2>/dev/null || read -rs value
    echo
    printf -v "$var" '%s' "$value"
}

ask_secret_required() {
    local var="$1" prompt="$2"
    local value=""
    while [[ -z "$value" ]]; do
        echo -en "${BOLD}${prompt}${RESET} ${YELLOW}(hidden, required)${RESET}: "
        read -rs value </dev/tty 2>/dev/null || read -rs value
        echo
        [[ -z "$value" ]] && warn "This token is required to continue."
    done
    printf -v "$var" '%s' "$value"
}

ask_yn() {
    local prompt="$1" default="${2:-y}"
    local hint="[Y/n]"; [[ "$default" == "n" ]] && hint="[y/N]"
    echo -en "${BOLD}${prompt}${RESET} ${CYAN}${hint}${RESET}: "
    read -r ans </dev/tty 2>/dev/null || read -r ans
    [[ -z "$ans" ]] && ans="$default"
    [[ "$ans" =~ ^[Yy] ]]
}

separator() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

check_cmd() { command -v "$1" &>/dev/null; }
require_cmd() { check_cmd "$1" || die "Command '$1' not found. Please install it and re-run the script."; }

mirror_repo() {
    # mirror_repo <clone_url> <push_url> <label>
    local clone_url="$1" push_url="$2" label="$3"
    local dir="${WORKDIR}/$(basename "$clone_url")"

    if ! git clone --mirror "$clone_url" "$dir" 2>/tmp/mirror_err.log; then
        cat /tmp/mirror_err.log >&2
        die "Cannot clone $clone_url"
    fi

    if ! ( cd "$dir" && git remote set-url origin "$push_url" && git push --mirror origin ); then
        if [[ "$label" == "wiki" ]]; then
            warn "Could not push wiki. On GitHub, the wiki repo only exists after you save"
            warn "one page via the web UI (Settings > Wikis > Create the first page)."
            warn "Skipping wiki migration — code migration is unaffected."
            return 1
        fi
        die "Push failed for $label. Check your SSH access to GitHub."
    fi

    success "${label^} migrated successfully."
    return 0
}

# gitlab_check_count <endpoint> -> echoes total item count via the X-Total header.
# Returns 1 (and echoes nothing) if the API call fails (bad token, no access, etc).
gitlab_check_count() {
    local endpoint="$1"
    local resp status total
    resp=$(curl -s -D - -o /dev/null \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "https://${GITLAB_DOMAIN}/api/v4/projects/${GITLAB_PROJECT_ENC}/${endpoint}?per_page=1&scope=all")
    status=$(echo "$resp" | head -1 | awk '{print $2}')
    [[ "$status" == "200" ]] || return 1
    total=$(echo "$resp" | grep -i '^x-total:' | awk '{print $2}' | tr -d '\r')
    echo "${total:-0}"
}

# ─── Banner ───────────────────────────────────────────────────────────────────
echo -e "  ${BOLD}GitLab → GitHub migration${RESET}  •  Source repository is never modified\n"
echo -e "  Code is always migrated. The script detects wikis, issues and merge"
echo -e "  requests on its own, and asks before migrating each of them.\n"
separator

# ─── 1. Dependency check ──────────────────────────────────────────────────────
info "Checking dependencies..."

MISSING=()
check_cmd git      || MISSING+=("git")
check_cmd curl     || MISSING+=("curl")
check_cmd python3  || MISSING+=("python3")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    die "Missing dependencies: ${MISSING[*]}\nPlease install them via your package manager."
fi
success "git, curl and python3 are available."

separator

# ─── 2. GitLab parameters ─────────────────────────────────────────────────────
echo -e "${BOLD}── GitLab Parameters ──${RESET}\n"

GITLAB_DOMAIN=""
GITLAB_PROJECT=""

while [[ -z "$GITLAB_DOMAIN" || -z "$GITLAB_PROJECT" ]]; do
    ask GITLAB_URL "GitLab source project URL (HTTPS or SSH)"
    if [[ "$GITLAB_URL" =~ ^https?://([^/]+)/(.*)$ ]]; then
        GITLAB_DOMAIN="${BASH_REMATCH[1]}"
        GITLAB_PROJECT="${BASH_REMATCH[2]%.git}"
        GITLAB_PROJECT="${GITLAB_PROJECT%/}"
    elif [[ "$GITLAB_URL" =~ ^git@([^:]+):(.*)$ ]]; then
        GITLAB_DOMAIN="${BASH_REMATCH[1]}"
        GITLAB_PROJECT="${BASH_REMATCH[2]%.git}"
        GITLAB_PROJECT="${GITLAB_PROJECT%/}"
    else
        warn "Invalid URL format. Please provide a valid HTTPS or SSH URL."
    fi
done

success "Detected: Domain = ${GITLAB_DOMAIN} | Project = ${GITLAB_PROJECT}"

GITLAB_CLONE_URL="git@${GITLAB_DOMAIN}:${GITLAB_PROJECT}.git"
GITLAB_WIKI_CLONE_URL="git@${GITLAB_DOMAIN}:${GITLAB_PROJECT}.wiki.git"
GITLAB_PROJECT_ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$GITLAB_PROJECT")
REPO_NAME=$(basename "$GITLAB_PROJECT")
GITLAB_TOKEN=""

separator

# ─── 3. GitHub parameters ─────────────────────────────────────────────────────
echo -e "${BOLD}── GitHub Parameters ──${RESET}\n"

GITHUB_REPO=""
while [[ -z "$GITHUB_REPO" ]]; do
    ask GITHUB_URL "GitHub target repo URL (HTTPS or SSH)"
    if [[ "$GITHUB_URL" =~ ^https?://([^/]+)/(.*)$ ]]; then
        GITHUB_REPO="${BASH_REMATCH[2]%.git}"
        GITHUB_REPO="${GITHUB_REPO%/}"
    elif [[ "$GITHUB_URL" =~ ^git@([^:]+):(.*)$ ]]; then
        GITHUB_REPO="${BASH_REMATCH[2]%.git}"
        GITHUB_REPO="${GITHUB_REPO%/}"
    else
        warn "Invalid URL format. Please provide a valid HTTPS or SSH URL."
    fi
done

GITHUB_USER="${GITHUB_REPO%/*}"
success "Detected: User/Org = ${GITHUB_USER} | Repo = ${GITHUB_REPO}"

ask_secret_required GITHUB_TOKEN "GitHub access token (scopes: repo, workflow)"
export GITHUB_TOKEN

GITHUB_CLONE_URL="git@github.com:${GITHUB_REPO}.git"
GITHUB_WIKI_CLONE_URL="git@github.com:${GITHUB_REPO}.wiki.git"

separator

# ─── 4. Summary before launch ────────────────────────────────────────────────
echo -e "${BOLD}── Summary ──${RESET}\n"
echo -e "  Source   : ${CYAN}https://${GITLAB_DOMAIN}/${GITLAB_PROJECT}${RESET}"
echo -e "  Target   : ${CYAN}https://github.com/${GITHUB_REPO}${RESET}"
echo

ask_yn "Start migration?" "y" || { info "Migration cancelled."; exit 0; }

separator

WORKDIR=$(mktemp -d "/tmp/gl2gh_XXXXXX")
info "Working directory: $WORKDIR"

# ─── 5. Mirror clone from GitLab ─────────────────────────────────────────────
echo
info "Cloning GitLab repository in mirror mode..."
BARE_DIR="${WORKDIR}/${REPO_NAME}.git"
git clone --mirror "$GITLAB_CLONE_URL" "$BARE_DIR" \
    || die "Cannot clone $GITLAB_CLONE_URL\nCheck the URL and your SSH access."
success "Clone successful."

# ─── 6. Check / create GitHub repo ───────────────────────────────────────────
echo
info "Checking target GitHub repository..."

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/${GITHUB_REPO}")

if [[ "$HTTP_STATUS" == "404" ]]; then
    warn "GitHub repository not found. Creating it..."
    GH_OWNER=$(echo "$GITHUB_REPO" | cut -d/ -f1)
    GH_REPONAME=$(echo "$GITHUB_REPO" | cut -d/ -f2)

    ORG_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        "https://api.github.com/orgs/${GH_OWNER}")

    if [[ "$ORG_STATUS" == "200" ]]; then
        ENDPOINT="https://api.github.com/orgs/${GH_OWNER}/repos"
    else
        ENDPOINT="https://api.github.com/user/repos"
    fi

    VISIBILITY="private"
    ask_yn "Create the repository as public?" "n" && VISIBILITY="public"

    CREATE_RESP=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${GH_REPONAME}\",\"private\":$([ "$VISIBILITY" == "private" ] && echo true || echo false)}" \
        "$ENDPOINT")

    CREATE_STATUS=$(echo "$CREATE_RESP" | tail -1)
    [[ "$CREATE_STATUS" =~ ^20 ]] || die "Cannot create GitHub repository (HTTP $CREATE_STATUS)."
    success "GitHub repository created (${VISIBILITY})."
elif [[ "$HTTP_STATUS" == "200" ]]; then
    success "Existing GitHub repository found."
else
    die "GitHub API error (HTTP $HTTP_STATUS). Check your token."
fi

# ─── 7. Mirror push to GitHub (always) ───────────────────────────────────────
echo
info "Pushing entire repository to GitHub (branches, tags, commits)..."
(
    cd "$BARE_DIR"
    git remote set-url origin "$GITHUB_CLONE_URL"
    git push --mirror origin
)
if [[ $? -ne 0 ]]; then
    die "Push failed. Check your SSH access to GitHub."
fi
success "Code, branches and tags migrated successfully."

# ─── 8. Wiki — detect, then ask ──────────────────────────────────────────────
echo
info "Checking for a wiki..."
WIKI_REFS=$(git ls-remote "$GITLAB_WIKI_CLONE_URL" 2>/dev/null || true)
if [[ -n "$WIKI_REFS" ]]; then
    success "A wiki was found on GitLab."
    if ask_yn "Migrate it too?" "y"; then
        mirror_repo "$GITLAB_WIKI_CLONE_URL" "$GITHUB_WIKI_CLONE_URL" "wiki" || true
    else
        info "Skipping wiki migration."
    fi
else
    info "No wiki found — nothing to migrate there."
fi

# ─── 9. Issues / MRs / labels / milestones — ask, then detect, then ask ─────
MR_FALLBACK="report"
echo
if ask_yn "Check for issues and merge requests to migrate too? (requires a GitLab API token)" "y"; then
    ask_secret_required GITLAB_TOKEN "GitLab personal access token (scope: read_api)"

    info "Checking for issues and merge requests on GitLab..."
    ISSUES_COUNT=$(gitlab_check_count "issues") || { warn "Could not query issues (check token/permissions)."; ISSUES_COUNT=0; }
    MRS_COUNT=$(gitlab_check_count "merge_requests") || { warn "Could not query merge requests (check token/permissions)."; MRS_COUNT=0; }

    if [[ "${ISSUES_COUNT:-0}" -gt 0 || "${MRS_COUNT:-0}" -gt 0 ]]; then
        success "Found ${ISSUES_COUNT:-0} issue(s) and ${MRS_COUNT:-0} merge request(s) on GitLab."
        if ask_yn "Migrate issues, merge requests, labels and milestones too?" "y"; then

            echo
            echo -e "${BOLD}── Merge Request Fallback ──${RESET}\n"
            echo -e "  Some MRs can't become real PRs (source branch deleted after merge)."
            echo -e "  ${CYAN}1${RESET}) Consolidated report  — one MIGRATION_REPORT.md, issue tracker stays clean (recommended)"
            echo -e "  ${CYAN}2${RESET}) GitHub issue per MR  — full history preserved as issues, but adds fake tickets"
            echo -e "  ${CYAN}3${RESET}) Do nothing           — skip them entirely, only real PRs get created"
            echo
            MR_FALLBACK_CHOICE=""
            while [[ ! "$MR_FALLBACK_CHOICE" =~ ^[123]$ ]]; do
                ask MR_FALLBACK_CHOICE "Choose (1/2/3)" "1"
            done
            case "$MR_FALLBACK_CHOICE" in
                2) MR_FALLBACK="issue" ;;
                3) MR_FALLBACK="skip" ;;
            esac

            echo
            info "Migrating labels, milestones, issues and merge requests..."
            info "This runs via migrate.py and talks to both APIs — it can take a while on large projects."
            PYTHON_SCRIPT="${SCRIPT_DIR}/migrate.py"
            if [[ ! -f "$PYTHON_SCRIPT" ]]; then
                PYTHON_SCRIPT="${WORKDIR}/migrate.py"
                curl -sSL "https://raw.githubusercontent.com/talvinckb/gitlab-to-github/main/migrate.py" -o "$PYTHON_SCRIPT"
            fi
            python3 "$PYTHON_SCRIPT" \
                --gitlab-domain "$GITLAB_DOMAIN" \
                --gitlab-project "$GITLAB_PROJECT" \
                --gitlab-token "$GITLAB_TOKEN" \
                --github-repo "$GITHUB_REPO" \
                --github-token "$GITHUB_TOKEN" \
                --mr-fallback "$MR_FALLBACK" \
                || die "migrate.py exited with an error — see above for details."
            success "Issues, merge requests, labels and milestones migrated."
        else
            info "Skipping issues/merge-requests migration."
        fi
    else
        info "No issues or merge requests found — nothing extra to migrate there."
    fi
fi

# ─── 10. Final summary ────────────────────────────────────────────────────────
separator
echo -e "${BOLD}${GREEN}✔  Migration complete!${RESET}\n"
echo -e "  GitHub repo: ${CYAN}https://github.com/${GITHUB_REPO}${RESET}"
echo -e "  Full log   : ${CYAN}${LOGFILE}${RESET}"
echo