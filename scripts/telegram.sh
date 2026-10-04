#!/usr/bin/env bash
# scripts/telegram.sh — project mode's Telegram notifications: set up, test.
#
#   lca agent telegram setup [--chat ID]   find your chat id, store it
#   lca agent telegram test                send one test message
#   lca agent telegram status              what is configured (no secrets)
#
# The bot token is yours: put it in ~/.telegram.env as
# TELEGRAM_BOT_TOKEN=123456789:AA... (mode 600). setup reads the bot's recent
# updates ONCE, finds the private chat that messaged it, and writes
# TELEGRAM_CHAT_ID to the same file. After that nothing ever reads what is
# sent to the bot: project mode only sends, and only to that chat.
# The token is never printed, never put on a command line, never committed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

usage() {
  cat <<EOF
Usage: lca agent telegram setup [--chat ID] | test | status

Project mode can report its progress to Telegram: one message per project,
edited in place (a progress bar, steps done, the current step, the time),
and a message for each step passed, question answered, step failed or
retried, and the project finishing or stopping. Progress text only.

  1. Make a bot with @BotFather, put its token in $(telegram_env_file):
       TELEGRAM_BOT_TOKEN=123456789:AA...      (chmod 600)
  2. Send your bot any message from your own Telegram account.
  3. lca agent telegram setup     finds your chat id and stores it there
  4. AGENT_PROJECT_TELEGRAM=true in ${ENV_FILE}  (now: ${AGENT_PROJECT_TELEGRAM})
  5. lca agent telegram test
EOF
}

need_token() {
  local f t
  f="$(telegram_env_file)"
  [[ -r "${f}" ]] || die "No ${f}. Put your bot's token in it: TELEGRAM_BOT_TOKEN=123456789:AA... (then chmod 600 ${f})."
  t="$(telegram_cred TELEGRAM_BOT_TOKEN || true)"
  telegram_token_looks_real "${t}" \
    || die "${f} has no usable TELEGRAM_BOT_TOKEN: a bot token is digits, a colon and a long tail (123456789:AA...), as @BotFather gives it. Not printing what is there."
}

# set_chat_id ID — write it into the env file, replacing any earlier one,
# keeping everything else and the file's mode.
set_chat_id() {
  local f tmp
  f="$(telegram_env_file)"
  tmp="$(mktemp "${f}.XXXXXX")"
  chmod 600 "${tmp}"
  { grep -vE '^[[:space:]]*(export[[:space:]]+)?TELEGRAM_CHAT_ID=' "${f}" || true
    printf 'TELEGRAM_CHAT_ID=%s\n' "$1"; } > "${tmp}"
  mv -f "${tmp}" "${f}"
}

cmd_setup() {
  local want="${1:-}" reply chats n
  need_token
  if [[ -n "${want}" ]]; then
    [[ "${want}" =~ ^-?[0-9]+$ ]] || die "--chat needs a numeric chat id."
    set_chat_id "${want}"
    ok "Chat id ${want} stored in $(telegram_env_file)."
    return 0
  fi
  reply="$(telegram_api getUpdates '{"allowed_updates":["message"]}')" \
    || die "Could not reach Telegram (api.telegram.org). Is this box offline (lca status)?"
  jq -e '.ok == true' <<<"${reply}" >/dev/null 2>&1 \
    || die "Telegram refused the token ($(jq -r '.description // "no reason given"' <<<"${reply}" 2>/dev/null)). Check it with @BotFather."
  # Private chats only: a group the bot sits in is not "you".
  chats="$(jq -r '[.result[] | (.message // .edited_message // empty) | select(.chat.type == "private")
                   | {id: .chat.id, name: ((.from.first_name // "") + (if .from.username then " (@" + .from.username + ")" else "" end))}]
                  | unique_by(.id) | .[] | "\(.id)\t\(.name)"' <<<"${reply}")"
  n="$(grep -c . <<<"${chats}" || true)"
  case "${n}" in
    0) die "Nobody has messaged the bot recently. Send it any message from your Telegram account, then run this again." ;;
    1) set_chat_id "${chats%%$'\t'*}"
       ok "Chat id ${chats%%$'\t'*} (${chats#*$'\t'}) stored in $(telegram_env_file)." ;;
    *) printf '%s\n' "${chats}" | sed 's/^/  /'
       die "Several people messaged the bot; pick yours: lca agent telegram setup --chat ID" ;;
  esac
}

cmd_test() {
  local id
  if [[ "${AGENT_PROJECT_TELEGRAM}" != "true" ]]; then
    info "Telegram notifications are off (AGENT_PROJECT_TELEGRAM=${AGENT_PROJECT_TELEGRAM} in ${ENV_FILE}); nothing sent."
    return 0
  fi
  need_token
  [[ "$(telegram_cred TELEGRAM_CHAT_ID || true)" =~ ^-?[0-9]+$ ]] \
    || die "No TELEGRAM_CHAT_ID yet. Message your bot, then: lca agent telegram setup"
  id="$(telegram_send "local-code-agent on $(hostname): Telegram notifications for project mode work.")" \
    || die "Telegram did not take the message. Is this box offline (lca status), or is the chat id wrong?"
  ok "Sent (message ${id})."
}

cmd_status() {
  local t c
  t="$(telegram_cred TELEGRAM_BOT_TOKEN 2>/dev/null || true)"
  c="$(telegram_cred TELEGRAM_CHAT_ID 2>/dev/null || true)"
  printf 'Switch:   AGENT_PROJECT_TELEGRAM=%s\n' "${AGENT_PROJECT_TELEGRAM}"
  printf 'Token:    %s\n' "$(if telegram_token_looks_real "${t}"; then echo 'present'; elif [[ -n "${t}" ]]; then echo 'present but not a bot token'; else echo 'missing'; fi)"
  printf 'Chat id:  %s\n' "${c:-missing}"
  printf 'Ready:    %s\n' "$(telegram_ready && echo yes || echo no)"
}

main() {
  case "${1:-}" in
    setup)  shift; [[ "${1:-}" != "--chat" ]] || { cmd_setup "${2:-}"; return; }; cmd_setup ;;
    test)   cmd_test ;;
    status) cmd_status ;;
    -h|--help|"") usage ;;
    *) usage >&2; die "Unknown: $1" ;;
  esac
}

main "$@"
