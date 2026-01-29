#!/bin/bash

set -e

BIN="${SELKIES_CONTROL_BIN:-/usr/local/bin/warplay-linux-control}"
if [ ! -x "${BIN}" ]; then
  echo "[warplay-control] binary not found/executable at ${BIN}; skipping"
  exit 0
fi

CONTROL_SIGNALING_PORT="${SELKIES_CONTROL_SIGNALING_PORT:-8787}"
CONTROL_PORT="${SELKIES_CONTROL_PORT:-8081}"
CONTROL_BIND="${SELKIES_CONTROL_BIND:-0.0.0.0}"

STUN_URL="${SELKIES_CONTROL_STUN_URL:-stun:${SELKIES_STUN_HOST:-${SELKIES_TURN_HOST:-stun.l.google.com}}:${SELKIES_STUN_PORT:-${SELKIES_TURN_PORT:-19302}}}"

TURN_HOST="${SELKIES_TURN_HOST:-}"
TURN_PORT="${SELKIES_TURN_PORT:-}"
TURN_PROTOCOL="${SELKIES_TURN_PROTOCOL:-udp}"
TURN_TLS="$(echo "${SELKIES_TURN_TLS:-false}" | tr '[:upper:]' '[:lower:]')"
TURN_SCHEME="turn"
if [ "${TURN_TLS}" = "true" ]; then
  TURN_SCHEME="turns"
fi
TURN_URL_DEFAULT=""
if [ -n "${TURN_HOST}" ] && [ -n "${TURN_PORT}" ]; then
  TURN_URL_DEFAULT="${TURN_SCHEME}:${TURN_HOST}:${TURN_PORT}?transport=${TURN_PROTOCOL}"
fi
TURN_URL="${SELKIES_CONTROL_TURN_URL:-${TURN_URL_DEFAULT}}"
TURN_USERNAME="${SELKIES_CONTROL_TURN_USERNAME:-${SELKIES_TURN_USERNAME:-}}"
TURN_CREDENTIAL="${SELKIES_CONTROL_TURN_CREDENTIAL:-${SELKIES_TURN_PASSWORD:-}}"

ARGS=(--bind "${CONTROL_BIND}" --signaling-port "${CONTROL_SIGNALING_PORT}" --control-port "${CONTROL_PORT}")
if [ -n "${STUN_URL}" ]; then
  ARGS+=(--stun-url "${STUN_URL}")
fi
if [ -n "${TURN_URL}" ]; then
  ARGS+=(--turn-url "${TURN_URL}")
fi
if [ -n "${TURN_USERNAME}" ]; then
  ARGS+=(--turn-username "${TURN_USERNAME}")
fi
if [ -n "${TURN_CREDENTIAL}" ]; then
  ARGS+=(--turn-credential "${TURN_CREDENTIAL}")
fi

echo "[warplay-control] starting: ${BIN} ${ARGS[*]}"
exec "${BIN}" "${ARGS[@]}"

