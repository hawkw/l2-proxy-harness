#!/bin/bash

set -eu

## === Fortio Server ===

export SERVER_IMAGE="${SERVER_IMAGE:-fortio/fortio:latest}"
export SERVER_HTTP_PORT="${SERVER_HTTP_PORT:-8123}"
export SERVER_GRPC_PORT="${SERVER_GRPC_PORT:-8124}"

server_create() {
  docker create \
    --name="${RUN_ID}-server" \
    --network=host \
    "${SERVER_IMAGE}" server \
      -http-port "$SERVER_HTTP_PORT" \
      -grpc-port "$SERVER_GRPC_PORT"
}

## === Fortio Client ===

export CLIENT_IMAGE="${CLIENT_IMAGE:-fortio/fortio:latest}"

client_run_report() {
  local dir="${REPORTS_DIR:-$PWD/reports}"

  local kind="$1"
  shift
  local name="$1"
  shift

  mkdir -p "$dir"

  local qps="${REQUESTS_PER_SEC:-8}"
  local c="${CONCURRENCY:-4}"
  local n=${TOTAL_REQUESTS:-$((qps * c * 10))}

  docker run \
    --rm \
    --network=host \
    --volume="${dir}:/reports" \
    fortio/fortio load \
      -quiet \
      -labels "{\"run\":\"$RUN_ID\",\"kind\":\"$kind\",\"name\":\"$name\"}" \
      -resolve localhost \
      -json "/reports/${RUN_ID}-${kind}-${name}.json" \
      -qps "$qps"  -n "$n" -c "$c" \
      "$@"
}

client_run_proxy_report() {
  local name="$1"
  shift
  client_run_report proxy "$name" \
    -H "Host: $CLIENT_TARGET_HOST" \
    "http://127.0.0.1:$PROXY_OUTBOUND_PORT"
}

## === Linkerd Proxy ===

export PROXY_IMAGE="${PROXY_IMAGE:-olix0r/l2-proxy:harness.v1}"
export PROXY_INBOUND_PORT="${PROXY_INBOUND_PORT:-4143}"
export PROXY_INBOUND_ORIG_DST_PORT="${PROXY_INBOUND_ORIG_DST_PORT:-${SERVER_HTTP_PORT}}"
export PROXY_OUTBOUND_PORT="${PROXY_OUTBOUND_PORT:-4140}"
export PROXY_OUTBOUND_ORIG_DST_PORT="${PROXY_OUTBOUND_ORIG_DST_PORT:-${PROXY_INBOUND_PORT}}"
export PROXY_ADMIN_PORT="${PROXY_ADMIN_PORT:-4191}"
export PROXY_DST_SUFFIXES="${PROXY_DST_SUFFIXES:-test.example.com.}"

proxy_create() {
  docker create \
    --name="${RUN_ID}-proxy" \
    --network=host \
    --env LINKERD2_PROXY_LOG="${PROXY_LOG:-linkerd=info,warn}" \
    --env LINKERD2_PROXY_CONTROL_LISTEN_ADDR="127.0.0.1:$PROXY_ADMIN_PORT" \
    --env LINKERD2_PROXY_INBOUND_LISTEN_ADDR="127.0.0.1:$PROXY_INBOUND_PORT" \
    --env LINKERD2_PROXY_INBOUND_ORIG_DST_ADDR="127.0.0.1:$PROXY_INBOUND_ORIG_DST_PORT" \
    --env LINKERD2_PROXY_OUTBOUND_LISTEN_ADDR="127.0.0.1:$PROXY_OUTBOUND_PORT" \
    --env LINKERD2_PROXY_OUTBOUND_ORIG_DST_ADDR="127.0.0.1:$PROXY_OUTBOUND_ORIG_DST_PORT" \
    --env LINKERD2_PROXY_DESTINATION_SVC_ADDR="127.0.0.1:$MOCK_DST_PORT" \
    --env LINKERD2_PROXY_DESTINATION_GET_SUFFIXES="${PROXY_DST_SUFFIXES}" \
    --env LINKERD2_PROXY_DESTINATION_PROFILE_SUFFIXES="${PROXY_DST_SUFFIXES}" \
    "$PROXY_IMAGE"
}

# Wait for the proxy to become ready
proxy_await() {
  while [ "$(curl -s "127.0.0.1:${PROXY_ADMIN_PORT}/ready")" != "ready" ]; do
    sleep 0.5
  done
}

# Print the proxy's metrics
proxy_metrics() {
  curl -s "localhost:${PROXY_ADMIN_PORT}/metrics"
}


## === Mock Destination Service ===

export MOCK_DST_IMAGE="${MOCK_DST_IMAGE:-olix0r/l2-mock-dst:v1}"
export MOCK_DST_PORT="${MOCK_DST_PORT:-8086}"

mock_dst_create() {
  docker create \
    --name="${RUN_ID}-mock-dst" \
    --network=host \
    --env RUST_LOG="linkerd=debug,warn" \
    "$MOCK_DST_IMAGE" \
      --addr="127.0.0.1:${MOCK_DST_PORT}" \
      --endpoints="${MOCK_DST_ENDPOINTS:-}" \
      --overrides="${MOCK_DST_OVERRIDES:-}"
}

## === Control ===

random_id() {
  tr -dc a-z0-9 </dev/urandom |dd bs=5 count=1 2>/dev/null
}

if [ -z "${RUN_ID:-}" ]; then
  export RUN_ID
  RUN_ID=$(random_id)
fi

# Start all specified container IDs.
start() {
  for id in "$@" ; do
    docker start "$id" >/dev/null
  done
}

# Stop & remove all specified container IDs.
stop() {
    for id in "$@"; do
      docker stop "$id" >/dev/null
    done
    for id in "$@"; do
      docker rm -f "$id" >/dev/null
    done
}
