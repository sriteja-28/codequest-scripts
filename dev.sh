#!/usr/bin/env bash
# CodeQuest local development helper for macOS / Linux (bash 3.2+).
# Same commands as scripts/dev.ps1 (Windows):
#
#   ./scripts/dev.sh setup        prerequisites, .env files (random secrets), venvs, deps,
#                                 dev infrastructure, migrate, seed, judge images
#   ./scripts/dev.sh dev          infrastructure + API :8000 + judge worker + frontend :3000
#   ./scripts/dev.sh stop [name]  stop everything (data kept) or one of backend|worker|frontend
#   ./scripts/dev.sh status       containers, app processes, /api/health/
#   ./scripts/dev.sh logs [name] [-f]
#   ./scripts/dev.sh test         backend + judge tests, frontend type-check + lint
#   ./scripts/dev.sh migrate | seed | manage <args...>
#
#   Destructive (typed confirmation; YES=1 skips the prompt):
#   ./scripts/dev.sh reset-data   wipe the dev stack's Postgres/Redis/RabbitMQ data, re-seed
#   ./scripts/dev.sh cleanup-old  remove the old "infra" compose containers (volumes kept
#                                 unless INCLUDE_VOLUMES=1, separate confirmation)
#
# Scope: compose project "codequest-dev" (ports 5433/6380/5673/15673) and the processes
# this script started (.dev/pids). Services you run yourself are never touched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="$ROOT/backend"
JUDGE="$ROOT/judge"
FRONTEND="$ROOT/frontend"
COMPOSE_FILE="$ROOT/infra/docker-compose.dev.yml"
PROJECT="codequest-dev"
DEV_DIR="$ROOT/.dev"
LOG_DIR="$DEV_DIR/logs"
PID_DIR="$DEV_DIR/pids"
BACKEND_PORT=8000
FRONTEND_PORT=3000
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

step() { printf '\033[36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m%s\033[0m\n' "$*"; }
warn() { printf '    \033[33m%s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

compose() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }

confirm() { # confirm WORD "message"
  [ "${YES:-0}" = "1" ] && return 0
  printf '\n\033[33m%s\033[0m\n' "$2"
  read -r -p "Type $1 to continue (anything else cancels): " answer
  [ "$answer" = "$1" ] || die "Cancelled: nothing was changed."
}

secret() { python3 -c "import secrets,sys; print(secrets.token_hex(int(sys.argv[1])))" "$1"; }

env_get() { # env_get FILE KEY
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*$2[[:space:]]*=\(.*\)$/\1/p" "$1" | head -n1
}

env_set() { # env_set FILE KEY VALUE (portable in-place edit)
  local tmp; tmp="$(mktemp)"
  if grep -q "^[[:space:]]*$2[[:space:]]*=" "$1"; then
    awk -v k="$2" -v v="$3" 'BEGIN{FS=OFS="="} $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {print k"="v; next} {print}' "$1" >"$tmp"
  else
    cat "$1" >"$tmp"; printf '%s=%s\n' "$2" "$3" >>"$tmp"
  fi
  mv "$tmp" "$1"
}

venv_python() { # venv_python DIR name1 name2 ... -> path of first real venv python
  local dir="$1"; shift
  for name in "$@"; do
    if [ -x "$dir/$name/bin/python" ] && [ -f "$dir/$name/pyvenv.cfg" ]; then
      echo "$dir/$name/bin/python"; return 0
    fi
  done
  return 1
}
backend_python() { venv_python "$BACKEND" .venv venv leet_venv; }
judge_python()   { venv_python "$JUDGE" venv .venv; }

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

app_pid() { # prints the PID if the recorded process is still alive
  local file="$PID_DIR/$1.pid"
  [ -f "$file" ] || return 1
  local pid; pid="$(cat "$file")"
  if kill -0 "$pid" 2>/dev/null; then echo "$pid"; return 0; fi
  rm -f "$file"; return 1
}

start_app() { # start_app NAME WORKDIR CMD...
  local name="$1" dir="$2"; shift 2
  mkdir -p "$LOG_DIR" "$PID_DIR"
  if pid="$(app_pid "$name")"; then ok "$name already running (PID $pid)"; return; fi
  # setsid (Linux) / own process group so `stop` can end the whole tree.
  ( cd "$dir" && if command -v setsid >/dev/null; then exec setsid "$@"; else exec "$@"; fi ) \
    >"$LOG_DIR/$name.log" 2>&1 &
  echo $! >"$PID_DIR/$name.pid"
  ok "$name started (PID $!), log: .dev/logs/$name.log"
}

stop_app() {
  local name="$1" pid
  if ! pid="$(app_pid "$name")"; then ok "$name not running"; return; fi
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  rm -f "$PID_DIR/$name.pid"
  ok "$name stopped"
}

wait_http() { # wait_http URL TIMEOUT LABEL
  local deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    code="$(curl -s -o /dev/null -m 30 -w '%{http_code}' "$1" || true)"
    if [ -n "$code" ] && [ "$code" != "000" ] && [ "$code" -lt 500 ]; then ok "$3 is up ($1)"; return 0; fi
    sleep 2
  done
  warn "$3 did not answer within $2 s; see ./scripts/dev.sh logs"
}

prereqs() {
  step "Checking prerequisites"
  command -v python3 >/dev/null || die "Python 3.10+ not found."
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || die "Python 3.10+ required."
  ok "Python $(python3 -c 'import platform; print(platform.python_version())')"
  command -v node >/dev/null || die "Node.js 20+ not found."
  [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 20 ] || die "Node.js 20+ required."
  ok "Node $(node --version)"
  command -v docker >/dev/null || die "Docker not found."
  docker info >/dev/null 2>&1 || die "Docker is installed but not running."
  ok "Docker $(docker version --format '{{.Server.Version}}')"
  command -v curl >/dev/null || die "curl not found."
}

env_files() {
  step "Environment files"
  local benv="$BACKEND/.env" jenv="$JUDGE/.env" fenv="$FRONTEND/.env.local" key
  key="$(env_get "$benv" JUDGE_INTERNAL_API_KEY)"
  if [ ! -f "$benv" ]; then
    cp "$BACKEND/.env.example" "$benv"
    env_set "$benv" SECRET_KEY "$(secret 32)"
    key="$(secret 24)"; env_set "$benv" JUDGE_INTERNAL_API_KEY "$key"
    ok "created backend/.env (random secrets)"
  else ok "backend/.env exists (kept)"; fi
  if [ ! -f "$jenv" ]; then
    cp "$JUDGE/.env.example" "$jenv"; [ -n "$key" ] && env_set "$jenv" JUDGE_INTERNAL_API_KEY "$key"
    ok "created judge/.env (judge key shared with backend)"
  else
    ok "judge/.env exists (kept)"
    [ -n "$key" ] && [ "$(env_get "$jenv" JUDGE_INTERNAL_API_KEY)" != "$key" ] && \
      warn "JUDGE_INTERNAL_API_KEY differs between backend/.env and judge/.env"
  fi
  if [ ! -f "$fenv" ]; then cp "$FRONTEND/.env.local.example" "$fenv"; ok "created frontend/.env.local"
  else ok "frontend/.env.local exists (kept)"; fi
}

ensure_venv() { # ensure_venv DIR NEWNAME names...
  local dir="$1" new="$2"; shift 2
  local py; if py="$(venv_python "$dir" "$@")"; then echo "$py"; return; fi
  python3 -m venv "$dir/$new" >&2
  echo "$dir/$new/bin/python"
}

infra_up() {
  step "Starting dev infrastructure ($PROJECT)"
  compose up -d --wait
  ok "postgres 127.0.0.1:5433  redis 127.0.0.1:6380  rabbitmq 127.0.0.1:5673 (UI http://localhost:15673)"
}

judge_images() {
  step "Judge language images"
  for pair in codequest-python:python codequest-cpp:cpp codequest-java:java codequest-js:javascript; do
    name="${pair%%:*}"; dir="${pair##*:}"
    if docker image inspect "$name" >/dev/null 2>&1 && [ "${REBUILD:-0}" != "1" ]; then ok "$name present"; continue; fi
    ok "building $name"; docker build -t "$name" "$JUDGE/languages/$dir"
  done
}

cmd_migrate() { step "Applying migrations (dev database)"; (cd "$BACKEND" && "$(backend_python)" manage.py migrate --noinput); }
cmd_seed()    { step "Seeding sample data"; (cd "$BACKEND" && "$(backend_python)" manage.py seed_data); }

cmd_setup() {
  prereqs; env_files
  step "Backend virtualenv + dependencies"
  local py; py="$(ensure_venv "$BACKEND" .venv .venv venv leet_venv)"
  (cd "$BACKEND" && "$py" -m pip install --disable-pip-version-check -q -r requirements.txt)
  step "Judge virtualenv + dependencies"
  local jpy; jpy="$(ensure_venv "$JUDGE" venv venv .venv)"
  (cd "$JUDGE" && "$jpy" -m pip install --disable-pip-version-check -q -r requirements.txt -r requirements-dev.txt)
  step "Frontend dependencies"
  if [ ! -d "$FRONTEND/node_modules" ] || [ "${REINSTALL:-0}" = "1" ]; then (cd "$FRONTEND" && npm ci --no-audit --no-fund)
  else ok "node_modules present (REINSTALL=1 for a clean npm ci)"; fi
  infra_up; cmd_migrate; cmd_seed
  [ "${SKIP_IMAGES:-0}" = "1" ] || judge_images
  step "Setup complete. Start everything with: ./scripts/dev.sh dev"
}

cmd_dev() {
  [ -f "$BACKEND/.env" ] || die "backend/.env missing. Run: ./scripts/dev.sh setup"
  local py; py="$(backend_python)" || die "backend virtualenv missing. Run setup."
  infra_up
  if ! app_pid backend >/dev/null && port_open "$BACKEND_PORT"; then die "Port $BACKEND_PORT is in use by another process."; fi
  if [ "${NO_FRONTEND:-0}" != "1" ] && ! app_pid frontend >/dev/null && port_open "$FRONTEND_PORT"; then
    die "Port $FRONTEND_PORT is in use by another process."
  fi
  step "Starting app processes"
  start_app backend "$BACKEND" env PYTHONUNBUFFERED=1 "$py" -m uvicorn config.asgi:application \
    --host 127.0.0.1 --port "$BACKEND_PORT" --reload --reload-dir apps --reload-dir config
  if [ "${NO_WORKER:-0}" != "1" ]; then
    if jpy="$(judge_python)"; then start_app worker "$JUDGE" env PYTHONUNBUFFERED=1 "$jpy" worker.py
    else warn "judge virtualenv missing: submissions will stay queued"; fi
  fi
  [ "${NO_FRONTEND:-0}" = "1" ] || start_app frontend "$FRONTEND" env NEXT_TELEMETRY_DISABLED=1 npm run dev -- --port "$FRONTEND_PORT"
  wait_http "http://localhost:$BACKEND_PORT/api/health/?live=1" 90 Backend
  [ "${NO_FRONTEND:-0}" = "1" ] || wait_http "http://localhost:$FRONTEND_PORT/" 180 Frontend
  step "Ready"
  echo "    App           http://localhost:$FRONTEND_PORT"
  echo "    API           http://localhost:$BACKEND_PORT/api/   (health: /api/health/)"
  echo "    Django admin  http://localhost:$BACKEND_PORT/django-admin/"
  echo "    RabbitMQ UI   http://localhost:15673  (codequest / codequest_dev)"
}

cmd_stop() {
  if [ $# -gt 0 ]; then for n in "$@"; do case "$n" in backend|worker|frontend) stop_app "$n";; *) die "unknown component $n";; esac; done; return; fi
  step "Stopping app processes"; for n in frontend worker backend; do stop_app "$n"; done
  step "Stopping dev containers (data kept)"; compose stop
}

cmd_status() {
  step "Containers ($PROJECT)"; compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
  step "App processes"
  for n in backend worker frontend; do if pid="$(app_pid "$n")"; then ok "$n running (PID $pid)"; else warn "$n not running"; fi; done
  step "Health"; curl -s -m 5 "http://localhost:$BACKEND_PORT/api/health/" || warn "API not reachable"; echo
}

cmd_logs() {
  local follow=0 names=()
  for a in "$@"; do if [ "$a" = "-f" ] || [ "$a" = "--follow" ]; then follow=1; else names+=("$a"); fi; done
  [ ${#names[@]} -gt 0 ] || names=(backend worker frontend)
  for n in "${names[@]}"; do
    f="$LOG_DIR/$n.log"; [ -f "$f" ] || { warn "no log yet for $n"; continue; }
    step "$n ($f)"
    if [ $follow = 1 ] && [ ${#names[@]} = 1 ]; then tail -n 40 -f "$f"; else tail -n 25 "$f"; fi
  done
}

cmd_test() {
  local failed=()
  step "Backend tests"; (cd "$BACKEND" && env -u DJANGO_SETTINGS_MODULE "$(backend_python)" -m pytest -q) || failed+=(backend)
  step "Judge tests"; if jpy="$(judge_python)"; then (cd "$JUDGE" && "$jpy" -m pytest -q) || failed+=(judge); else failed+=("judge(missing venv)"); fi
  step "Frontend type-check + lint"
  (cd "$FRONTEND" && npx --no-install tsc --noEmit) || failed+=(frontend-tsc)
  (cd "$FRONTEND" && npm run --silent lint) || failed+=(frontend-lint)
  if [ ${#failed[@]} -eq 0 ]; then step "All checks passed"; else die "FAILED: ${failed[*]}"; fi
}

cmd_reset_data() {
  confirm RESET "This deletes ALL data of the dev stack (compose project '$PROJECT'), then re-seeds it. Nothing else is touched."
  for n in frontend worker backend; do stop_app "$n"; done
  compose down -v --remove-orphans
  infra_up; cmd_migrate; cmd_seed
  step "Dev data reset complete"
}

cmd_cleanup_old() {
  step "Looking for the old 'infra' compose stack"
  local found=()
  for c in codequest_postgres codequest_redis codequest_rabbitmq; do
    [ "$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$c" 2>/dev/null || true)" = "infra" ] && found+=("$c")
  done
  if [ ${#found[@]} -gt 0 ]; then
    docker ps -a --filter label=com.docker.compose.project=infra --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
    confirm REMOVE "Remove these old containers? Their data volumes are kept."
    for c in "${found[@]}"; do docker rm -f "$c" >/dev/null && ok "removed container $c"; done
  else ok "no old containers found"; fi
  if [ "${INCLUDE_VOLUMES:-0}" != "1" ]; then ok "volumes kept (INCLUDE_VOLUMES=1 to delete them)"; return; fi
  local vols=()
  for v in infra_postgres_data infra_redis_data infra_rabbitmq_data; do
    [ "$(docker volume inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$v" 2>/dev/null || true)" = "infra" ] && vols+=("$v")
  done
  [ ${#vols[@]} -gt 0 ] || { ok "no old volumes found"; return; }
  confirm DELETE-VOLUMES "PERMANENTLY delete these volumes and all data in them: ${vols[*]}"
  for v in "${vols[@]}"; do docker volume rm "$v" >/dev/null && ok "deleted volume $v"; done
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  setup) cmd_setup ;;
  dev|start) cmd_dev ;;
  stop) cmd_stop "$@" ;;
  status) cmd_status ;;
  logs) cmd_logs "$@" ;;
  test) cmd_test ;;
  migrate) cmd_migrate ;;
  seed) cmd_seed ;;
  manage) (cd "$BACKEND" && "$(backend_python)" manage.py "$@") ;;
  reset-data) cmd_reset_data ;;
  cleanup-old) cmd_cleanup_old ;;
  *) sed -n '2,22p' "$0" ;;
esac
