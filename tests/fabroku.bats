#!/usr/bin/env bats
# Testes dos comandos fabroku:* com um Dokku de mentira (tests/fixtures/fake-dokku).

PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
DEPLOY_ID="0f0e0d0c-1111-4222-8333-444455556666"
OTHER_ID="0f0e0d0c-1111-4222-8333-777788889999"
# Mesmo formato da URL que o Fabroku manda (token de instalação do GitHub App).
GIT_URL="https://x-access-token:ghs_Ab12_cd-34@github.com/org/repo.git"

setup() {
  export FABROKU_DATA_ROOT="$BATS_TEST_TMPDIR/data"
  export DOKKU_ROOT="$BATS_TEST_TMPDIR/home"
  export FABROKU_DOKKU_BIN="$PLUGIN_ROOT/tests/fixtures/fake-dokku"
  export FAKE_DOKKU_CALLS="$BATS_TEST_TMPDIR/dokku-calls"
  export FAKE_DOKKU_MODE=success
  export FABROKU_DOCKER_BIN="$PLUGIN_ROOT/tests/fixtures/fake-docker"
  export FAKE_DOCKER_PS="$BATS_TEST_TMPDIR/docker-ps"
  export FAKE_DOCKER_EXITED="$BATS_TEST_TMPDIR/docker-exited"
  mkdir -p "$DOKKU_ROOT/meu-app"
  : >"$FAKE_DOKKU_CALLS"
}

teardown() {
  # Nenhum build de teste fica rodando depois do teste.
  local pid_file
  for pid_file in "$FABROKU_DATA_ROOT"/deploys/*/pid; do
    [[ -f "$pid_file" ]] && kill -KILL -- "-$(cat "$pid_file")" 2>/dev/null
  done
  return 0
}

fabroku() {
  local cmd="$1"
  shift
  "$PLUGIN_ROOT/subcommands/$cmd" "fabroku:$cmd" "$@"
}

json_field() {
  python3 -c 'import json, sys; v = json.loads(sys.argv[1])[sys.argv[2]]; print(json.dumps(v) if isinstance(v, bool) or v is None else v)' "$1" "$2"
}

wait_state() {
  local id="$1" expected="$2" state
  for _ in $(seq 100); do
    state="$(json_field "$(fabroku deploy-status "$id")" state)"
    [[ "$state" == "$expected" ]] && return 0
    sleep 0.1
  done
  echo "estado final: $state (esperado $expected)" >&2
  return 1
}

read_full_log() {
  local id="$1" max="${2:-65536}" offset=0 out="" response chunk
  while true; do
    response="$(fabroku deploy-log "$id" "$offset" "$max")"
    chunk="$(json_field "$response" chunk)"
    out+="$(printf '%s' "$chunk" | base64 -d)"
    offset="$(json_field "$response" next_offset)"
    [[ "$(json_field "$response" eof)" == "true" ]] && break
    sleep 0.05
  done
  printf '%s' "$out"
}

@test "version bate com plugin.toml" {
  run fabroku version
  [ "$status" -eq 0 ]
  expected="$(sed -n 's/^version = "\(.*\)"/\1/p' "$PLUGIN_ROOT/plugin.toml")"
  [ "$output" = "{\"version\":\"$expected\"}" ]
}

@test "deploy rejeita argumentos invalidos sem iniciar build" {
  run fabroku deploy app-inexistente "$GIT_URL" main "$DEPLOY_ID"
  [ "$status" -eq 1 ]
  [ "$(json_field "$output" error)" = "app_not_found" ]

  run fabroku deploy meu-app "$GIT_URL" main NAO-E-UUID
  [ "$(json_field "$output" error)" = "invalid_deploy_id" ]

  run fabroku deploy meu-app 'https://github.com/org/repo.git;rm' main "$DEPLOY_ID"
  [ "$(json_field "$output" error)" = "invalid_git_url" ]

  run fabroku deploy meu-app git@github.com:org/repo.git main "$DEPLOY_ID"
  [ "$(json_field "$output" error)" = "invalid_git_url" ]

  run fabroku deploy meu-app "$GIT_URL" '../main' "$DEPLOY_ID"
  [ "$(json_field "$output" error)" = "invalid_branch" ]

  run fabroku deploy meu-app "$GIT_URL" main
  [ "$(json_field "$output" error)" = "usage" ]

  [ ! -s "$FAKE_DOKKU_CALLS" ]
}

@test "deploy retorna na hora e o build termina com sucesso em segundo plano" {
  run fabroku deploy meu-app "$GIT_URL" main "$DEPLOY_ID"
  [ "$status" -eq 0 ]
  [ "$output" = "{\"id\":\"$DEPLOY_ID\",\"state\":\"running\"}" ]

  wait_state "$DEPLOY_ID" succeeded
  status_json="$(fabroku deploy-status "$DEPLOY_ID")"
  [ "$(json_field "$status_json" exit_code)" = "0" ]
  [ "$(json_field "$status_json" app)" = "meu-app" ]
  [ "$(json_field "$status_json" finished_at)" != "null" ]

  log="$(read_full_log "$DEPLOY_ID")"
  [[ "$log" == *"Syncing main to meu-app"* ]]
  [[ "$log" == *"Application deployed"* ]]
  grep -qx "git:sync --build meu-app $GIT_URL main" "$FAKE_DOKKU_CALLS"
}

@test "build com erro termina como failed com o exit code" {
  export FAKE_DOKKU_MODE=fail
  fabroku deploy meu-app "$GIT_URL" main "$DEPLOY_ID"

  wait_state "$DEPLOY_ID" failed
  [ "$(json_field "$(fabroku deploy-status "$DEPLOY_ID")" exit_code)" = "1" ]
  [[ "$(read_full_log "$DEPLOY_ID")" == *"App build failed"* ]]
}

@test "log lido em pedacos pequenos volta inteiro" {
  fabroku deploy meu-app "$GIT_URL" main "$DEPLOY_ID"
  wait_state "$DEPLOY_ID" succeeded

  [ "$(read_full_log "$DEPLOY_ID" 7)" = "$(cat "$FABROKU_DATA_ROOT/deploys/$DEPLOY_ID/output.log")" ]

  size="$(stat -c %s "$FABROKU_DATA_ROOT/deploys/$DEPLOY_ID/output.log")"
  response="$(fabroku deploy-log "$DEPLOY_ID" "$((size + 10))")"
  [ "$(json_field "$response" chunk)" = "" ]
  [ "$(json_field "$response" eof)" = "true" ]
}

@test "follow manda o log inteiro e sai quando o build termina" {
  fabroku deploy meu-app "$GIT_URL" main "$DEPLOY_ID"
  out="$BATS_TEST_TMPDIR/follow.out"
  timeout 10 "$PLUGIN_ROOT/subcommands/deploy-follow" fabroku:deploy-follow "$DEPLOY_ID" >"$out"

  [ "$(json_field "$(fabroku deploy-status "$DEPLOY_ID")" state)" = "succeeded" ]
  cmp "$out" "$FABROKU_DATA_ROOT/deploys/$DEPLOY_ID/output.log"
  grep -q "Application deployed" "$out"
}

@test "follow a partir de um offset manda so o resto" {
  fabroku deploy meu-app "$GIT_URL" main "$DEPLOY_ID"
  wait_state "$DEPLOY_ID" succeeded
  log="$FABROKU_DATA_ROOT/deploys/$DEPLOY_ID/output.log"

  [ "$(fabroku deploy-follow "$DEPLOY_ID" 10)" = "$(tail -c +11 "$log")" ]
  [ "$(fabroku deploy-follow "$DEPLOY_ID" 999999)" = "" ]
}

@test "follow sai quando o deploy e cancelado" {
  export FAKE_DOKKU_MODE=slow
  fabroku deploy meu-app "$GIT_URL" main "$DEPLOY_ID"
  out="$BATS_TEST_TMPDIR/follow.out"
  timeout 20 "$PLUGIN_ROOT/subcommands/deploy-follow" fabroku:deploy-follow "$DEPLOY_ID" >"$out" &
  follow=$!
  sleep 0.5

  fabroku deploy-cancel "$DEPLOY_ID"
  wait "$follow"
  grep -q "build line 1" "$out"
}

@test "segundo deploy no mesmo app volta app_busy; trava some quando o build termina" {
  export FAKE_DOKKU_MODE=slow
  fabroku deploy meu-app "$GIT_URL" main "$DEPLOY_ID"

  run fabroku deploy meu-app "$GIT_URL" main "$OTHER_ID"
  [ "$status" -eq 1 ]
  [ "$(json_field "$output" error)" = "app_busy" ]
  [ ! -e "$FABROKU_DATA_ROOT/deploys/$OTHER_ID" ]

  fabroku deploy-cancel "$DEPLOY_ID"
  export FAKE_DOKKU_MODE=success
  run fabroku deploy meu-app "$GIT_URL" main "$OTHER_ID"
  [ "$status" -eq 0 ]
  wait_state "$OTHER_ID" succeeded
}

@test "id repetido volta deploy_exists" {
  fabroku deploy meu-app "$GIT_URL" main "$DEPLOY_ID"
  wait_state "$DEPLOY_ID" succeeded

  run fabroku deploy meu-app "$GIT_URL" main "$DEPLOY_ID"
  [ "$(json_field "$output" error)" = "deploy_exists" ]
}

@test "cancelar para o build, marca cancelled e roda dokku cleanup" {
  export FAKE_DOKKU_MODE=slow
  fabroku deploy meu-app "$GIT_URL" main "$DEPLOY_ID"
  sleep 0.3

  run fabroku deploy-cancel "$DEPLOY_ID"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" state)" = "cancelled" ]
  grep -qx "cleanup meu-app" "$FAKE_DOKKU_CALLS"

  pid="$(cat "$FABROKU_DATA_ROOT/deploys/$DEPLOY_ID/pid")"
  ! kill -0 "$pid" 2>/dev/null
  run pgrep -f "fake-dokku git:sync"
  [ "$status" -ne 0 ]
}

@test "cancelar para container de build que sobrou antes do cleanup, sem tocar no app no ar" {
  export FAKE_DOKKU_MODE=slow
  fabroku deploy meu-app "$GIT_URL" main "$DEPLOY_ID"
  sleep 0.3
  printf '%s\n' "abc123 festive_pike" "def456 meu-app.web.1" >"$FAKE_DOCKER_PS"

  run fabroku deploy-cancel "$DEPLOY_ID" 1
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" state)" = "cancelled" ]
  stop_line="$(grep -n "docker stop -t 5 abc123$" "$FAKE_DOKKU_CALLS" | cut -d: -f1)"
  rm_line="$(grep -n "^docker rm abc123$" "$FAKE_DOKKU_CALLS" | cut -d: -f1)"
  [ "$stop_line" -lt "$rm_line" ]
  ! grep -q "def456" "$FAKE_DOKKU_CALLS"
}

@test "cleanup remove containers parados mesmo sem o dokku cleanup" {
  printf '%s\n' "aaa111 festive_pike" "bbb222 distracted_mclean" >"$FAKE_DOCKER_EXITED"

  run fabroku cleanup meu-app
  [ "$status" -eq 0 ]
  [ "$output" = '{"app":"meu-app","removed":2}' ]
  grep -qx "docker rm aaa111 bbb222" "$FAKE_DOKKU_CALLS"

  run fabroku cleanup meu-app
  [ "$output" = '{"app":"meu-app","removed":0}' ]

  run fabroku cleanup app-inexistente
  [ "$(json_field "$output" error)" = "app_not_found" ]
}

@test "build que ignora SIGTERM leva SIGKILL depois do prazo" {
  export FAKE_DOKKU_MODE=stubborn
  fabroku deploy meu-app "$GIT_URL" main "$DEPLOY_ID"
  sleep 0.3

  run fabroku deploy-cancel "$DEPLOY_ID" 1
  [ "$(json_field "$output" state)" = "cancelled" ]
  [ "$(json_field "$output" exit_code)" = "137" ]
  run pgrep -f "fake-dokku git:sync"
  [ "$status" -ne 0 ]
}

@test "cancelar deploy ja terminado so devolve o estado" {
  fabroku deploy meu-app "$GIT_URL" main "$DEPLOY_ID"
  wait_state "$DEPLOY_ID" succeeded

  run fabroku deploy-cancel "$DEPLOY_ID"
  [ "$(json_field "$output" state)" = "succeeded" ]
  ! grep -q cleanup "$FAKE_DOKKU_CALLS"
}

@test "runner que sumiu sem exit_code vira lost" {
  dir="$FABROKU_DATA_ROOT/deploys/$DEPLOY_ID"
  mkdir -p "$dir"
  echo meu-app >"$dir/app"
  sleep 0 &
  dead_pid=$!
  wait "$dead_pid"
  echo "$dead_pid" >"$dir/pid"

  run fabroku deploy-status "$DEPLOY_ID"
  [ "$(json_field "$output" state)" = "lost" ]
  [ "$(json_field "$output" exit_code)" = "null" ]
}

@test "deploy desconhecido volta deploy_not_found" {
  run fabroku deploy-status "$DEPLOY_ID"
  [ "$status" -eq 1 ]
  [ "$(json_field "$output" error)" = "deploy_not_found" ]
}

@test "gc apaga so deploys finalizados mais velhos que o prazo" {
  fabroku deploy meu-app "$GIT_URL" main "$DEPLOY_ID"
  wait_state "$DEPLOY_ID" succeeded
  touch -d '10 days ago' "$FABROKU_DATA_ROOT/deploys/$DEPLOY_ID"

  export FAKE_DOKKU_MODE=slow
  fabroku deploy meu-app "$GIT_URL" main "$OTHER_ID"
  touch -d '10 days ago' "$FABROKU_DATA_ROOT/deploys/$OTHER_ID"

  run fabroku gc 7
  [ "$output" = '{"removed":1}' ]
  [ ! -e "$FABROKU_DATA_ROOT/deploys/$DEPLOY_ID" ]
  [ -d "$FABROKU_DATA_ROOT/deploys/$OTHER_ID" ]
}
