#!/usr/bin/env bash
# =============================================================================
#  gitlab-to-github.sh — Full GitLab → GitHub migration
#  Usage   : chmod +x gitlab-to-github.sh && ./gitlab-to-github.sh
# =============================================================================

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Enter alternate screen buffer
tput smcup || true
clear

cleanup() {
    local exit_code=$?
    [[ -n "${WORKDIR:-}" ]] && rm -rf "$WORKDIR"
    if [[ $exit_code -ne 0 ]]; then
        echo
        echo -e "${RED}[ERROR]${RESET} Script exited with an error. Press any key to close..."
        read -n 1 -s -r < /dev/tty || true
    fi
    tput rmcup || true
}
trap cleanup EXIT

# ─── Helpers ─────────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

ask() {
    # ask <var_name> <prompt> [default]
    local var="$1" prompt="$2" default="${3:-}"
    local display_default=""
    [[ -n "$default" ]] && display_default=" ${CYAN}[${default}]${RESET}"
    echo -en "${BOLD}${prompt}${RESET}${display_default}: "
    read -r value
    [[ -z "$value" && -n "$default" ]] && value="$default"
    printf -v "$var" '%s' "$value"
}

ask_secret() {
    local var="$1" prompt="$2"
    echo -en "${BOLD}${prompt}${RESET} ${YELLOW}(hidden)${RESET}: "
    read -rs value
    echo
    printf -v "$var" '%s' "$value"
}

ask_yn() {
    # ask_yn <prompt> [default] → returns 0 (yes) or 1 (no)
    local prompt="$1" default="${2:-y}"
    local hint="[Y/n]"; [[ "$default" == "n" ]] && hint="[y/N]"
    echo -en "${BOLD}${prompt}${RESET} ${CYAN}${hint}${RESET}: "
    read -r ans
    [[ -z "$ans" ]] && ans="$default"
    [[ "$ans" =~ ^[Yy] ]]
}

separator() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

check_cmd() {
    command -v "$1" &>/dev/null
}

require_cmd() {
    check_cmd "$1" || die "Command '$1' not found. Please install it and re-run the script."
}

# ─── Banner ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
cat <<'EOF'
  ██████╗ ██╗████████╗██╗      █████╗ ██████╗     →    ██████╗ ██╗████████╗██╗  ██╗██╗   ██╗██████╗
  ██╔════╝ ██║╚══██╔══╝██║     ██╔══██╗██╔══██╗        ██╔════╝ ██║╚══██╔══╝██║  ██║██║   ██║██╔══██╗
  ██║  ███╗██║   ██║   ██║     ███████║██████╔╝        ██║  ███╗██║   ██║   ███████║██║   ██║██████╔╝
  ██║   ██║██║   ██║   ██║     ██╔══██║██╔══██╗        ██║   ██║██║   ██║   ██╔══██║██║   ██║██╔══██╗
  ╚██████╔╝██║   ██║   ███████╗██║  ██║██████╔╝        ╚██████╔╝██║   ██║   ██║  ██║╚██████╔╝██████╔╝
   ╚═════╝ ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═════╝          ╚═════╝ ╚═╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚═════╝
EOF
echo -e "${RESET}"
echo -e "  ${BOLD}Full GitLab → GitHub migration${RESET}  •  Source repository is never modified\n"
separator

# ─── 1. Dependency check ──────────────────────────────────────────────────────
info "Checking dependencies..."

MISSING=()
check_cmd git   || MISSING+=("git")
check_cmd curl  || MISSING+=("curl")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    die "Missing dependencies: ${MISSING[*]}\nPlease install them via your package manager."
fi
success "git and curl are available."


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



# Derive clone URL
GITLAB_CLONE_URL="git@${GITLAB_DOMAIN}:${GITLAB_PROJECT}.git"
REPO_NAME=$(basename "$GITLAB_PROJECT")

separator

# ─── 3. GitHub parameters ─────────────────────────────────────────────────────
echo -e "${BOLD}── GitHub Parameters ──${RESET}\n"

GITHUB_USER=""
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

ask_secret GITHUB_TOKEN "GitHub access token (scopes: repo, workflow)"

export GITHUB_TOKEN

GITHUB_CLONE_URL="git@github.com:${GITHUB_REPO}.git"

separator

# ─── 4. Summary before launch ────────────────────────────────────────────────
echo -e "${BOLD}── Summary ──${RESET}\n"
echo -e "  Source   : ${CYAN}https://${GITLAB_DOMAIN}/${GITLAB_PROJECT}${RESET}"
echo -e "  Target   : ${CYAN}https://github.com/${GITHUB_REPO}${RESET}"
echo

ask_yn "Start migration?" "y" || { info "Migration cancelled."; exit 0; }

separator

# ─── Working directory ────────────────────────────────────────────────────────
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

    # Determine if it's an org or a user account
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

# ─── 7. Mirror push to GitHub ────────────────────────────────────────────────
echo
info "Pushing entire repository to GitHub (branches, tags, commits)..."

(
    cd "$BARE_DIR" || die "Cannot access bare directory."
    git remote set-url origin "$GITHUB_CLONE_URL"
    git push --mirror origin \
        || die "Push failed. Check your SSH access to GitHub."
)

success "Code, branches and tags migrated successfully."

# ─── 8. Final summary ────────────────────────────────────────────────────────
separator
echo -e "${BOLD}${GREEN}✔  Migration complete!${RESET}\n"
echo -e "  GitHub repo: ${CYAN}https://github.com/${GITHUB_REPO}${RESET}"
echo

echo -en "${BOLD}Press any key to exit...${RESET}"
read -n 1 -s -r < /dev/tty || true
echo
