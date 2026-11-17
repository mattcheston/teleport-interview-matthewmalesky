# Sourced by scripts that talk to DNSimple. Resolves DNSIMPLE_TOKEN and
# DNSIMPLE_ACCOUNT the way the DigitalOcean scripts use `doctl auth token`:
# from the login the `dnsimple` CLI stores (`dnsimple auth login`, once).
#
# Order:
#   1. DNSIMPLE_TOKEN already in the environment (DNSIMPLE_ACCOUNT derived if unset)
#   2. the dnsimple CLI's active context (or DNSIMPLE_CONTEXT=<name>)
#
# The CLI reports contexts and account ids but, by design, never prints the
# token itself, so that one value is read from its credentials file: a small
# YAML file, mode 600, with a `token:` line per context. Terraform's dnsimple
# provider needs the raw token, so there is no way around this short of
# dropping Terraform for the CLI. The file's location follows Go's user config
# dir: ~/Library/Application Support on macOS, $XDG_CONFIG_HOME or ~/.config
# elsewhere. DNSIMPLE_CREDENTIALS_FILE overrides it.
#
# resolve_dnsimple_token    exports DNSIMPLE_TOKEN and DNSIMPLE_ACCOUNT; returns 1
#                           (quietly) when no source works
# dnsimple_token_help       explains what to do when it does not

dnsimple_credentials_file() {
  if [ -n "${DNSIMPLE_CREDENTIALS_FILE:-}" ]; then
    printf '%s' "$DNSIMPLE_CREDENTIALS_FILE"
  elif [ "$(uname -s)" = "Darwin" ]; then
    printf '%s' "$HOME/Library/Application Support/dnsimple/credentials.yml"
  else
    printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/dnsimple/credentials.yml"
  fi
}

dnsimple_token_help() {
  cat >&2 <<'HELP'
No DNSimple credentials found. Log in once with the DNSimple CLI
(https://developer.dnsimple.com/cli/):
  dnsimple auth login
or export DNSIMPLE_TOKEN (and DNSIMPLE_ACCOUNT) for this shell.
HELP
}

resolve_dnsimple_token() {
  if [ -z "${DNSIMPLE_TOKEN:-}" ] && command -v dnsimple >/dev/null 2>&1; then
    local ctx acct file
    # The supported interface for everything but the token.
    ctx="${DNSIMPLE_CONTEXT:-$(dnsimple auth list --format '{{range .}}{{if .Active}}{{.Name}}{{end}}{{end}}' 2>/dev/null || true)}"
    if [ -n "$ctx" ]; then
      acct="$(dnsimple auth list --format "{{range .}}{{if eq .Name \"${ctx}\"}}{{.AccountID}}{{end}}{{end}}" 2>/dev/null || true)"
      file="$(dnsimple_credentials_file)"
      if [ -r "$file" ]; then
        DNSIMPLE_TOKEN="$(awk -v ctx="$ctx" '
          /^[[:space:]]*-[[:space:]]*name:/ { cur = $NF; gsub(/"/, "", cur) }
          cur == ctx && /^[[:space:]]*token:/ { tok = $NF; gsub(/"/, "", tok) }
          END { print tok }' "$file")"
        [ -n "$DNSIMPLE_TOKEN" ] && [ -n "$acct" ] && DNSIMPLE_ACCOUNT="${DNSIMPLE_ACCOUNT:-$acct}"
      fi
    fi
  fi
  [ -n "${DNSIMPLE_TOKEN:-}" ] || return 1

  if [ -z "${DNSIMPLE_ACCOUNT:-}" ]; then
    # Token given by hand: ask the API which account it belongs to. Account
    # tokens identify their account; user tokens with one account do too.
    DNSIMPLE_ACCOUNT="$(curl -fsS -H "Authorization: Bearer ${DNSIMPLE_TOKEN}" https://api.dnsimple.com/v2/whoami 2>/dev/null \
      | grep -o '"account":{"id":[0-9]*' | grep -o '[0-9]*$' || true)"
  fi
  [ -n "${DNSIMPLE_ACCOUNT:-}" ] || return 1
  export DNSIMPLE_TOKEN DNSIMPLE_ACCOUNT
}
