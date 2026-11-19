#!/usr/bin/env bats
# Testes do build em duas etapas para frontend estático (core-post-extract) numa pasta de mentira.

PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  WORK="$BATS_TEST_TMPDIR/build"
  mkdir -p "$WORK" "$BATS_TEST_TMPDIR/bin"
  # dokku de mentira: config:export devolve FAKE_CONFIG_JSON
  cat >"$BATS_TEST_TMPDIR/bin/dokku" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "config:export" ]] && { echo "${FAKE_CONFIG_JSON:-{\}}"; exit 0; }
exit 1
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/dokku"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export FAKE_CONFIG_JSON='{"VITE_API_URL":"https://api.exemplo","DOKKU_APP_TYPE":"herokuish","GIT_REV":"abc"}'
}

frontend() {
  echo '{"name":"site","scripts":{"build":"vite build"}}' >"$WORK/package.json"
  printf 'https://github.com/heroku/heroku-buildpack-nodejs\nhttps://github.com/dokku/buildpack-nginx\n' >"$WORK/.buildpacks"
}

hook() {
  "$PLUGIN_ROOT/core-post-extract" meu-app "$WORK"
}

@test "frontend da receita nginx: gera Dockerfile em duas etapas e tira o .buildpacks" {
  frontend
  run hook
  [ "$status" -eq 0 ]
  [ -f "$WORK/Dockerfile" ] && [ -f "$WORK/.fabroku-nginx.conf" ]
  [ ! -e "$WORK/.buildpacks" ]
  grep -q '^FROM node:22-alpine AS build' "$WORK/Dockerfile"
  grep -q '^FROM nginx:1.27-alpine' "$WORK/Dockerfile"
  grep -q '^EXPOSE 5000' "$WORK/Dockerfile"
  grep -q 'listen 5000;' "$WORK/.fabroku-nginx.conf"
  [[ "$output" == *"build em duas etapas"* ]]
}

@test "variáveis do app vão para o build, menos DOKKU_* e GIT_REV" {
  frontend
  run hook
  grep -q "^VITE_API_URL=" "$WORK/.fabroku-build.env"
  ! grep -qE '^(DOKKU_APP_TYPE|GIT_REV)=' "$WORK/.fabroku-build.env"
}

@test "valor com aspas e espaços chega intacto ao shell do build" {
  frontend
  export FAKE_CONFIG_JSON='{"VITE_MSG":"oi '"'"'mundo'"'"' $HOME; x"}'
  run hook
  run sh -c "set -a; . '$WORK/.fabroku-build.env'; printf '%s' \"\$VITE_MSG\""
  [ "$output" = "oi 'mundo' \$HOME; x" ]
}

@test "usa a pasta root do static.json e a versão do Node do engines" {
  frontend
  echo '{"name":"site","engines":{"node":">=18.0.0"},"scripts":{"build":"vite build"}}' >"$WORK/package.json"
  echo '{"root":"public_html/"}' >"$WORK/static.json"
  run hook
  grep -q '^FROM node:18-alpine' "$WORK/Dockerfile"
  grep -q 'for d in public_html dist build out' "$WORK/Dockerfile"
}

@test "mantém Dockerfile do próprio aluno" {
  frontend
  echo 'FROM scratch' >"$WORK/Dockerfile"
  run hook
  [ "$(cat "$WORK/Dockerfile")" = 'FROM scratch' ]
  [ -f "$WORK/.buildpacks" ]
}

@test "não mexe em backend (buildpack python)" {
  frontend
  printf 'https://github.com/heroku/heroku-buildpack-python\nhttps://github.com/dokku/buildpack-nginx\n' >"$WORK/.buildpacks"
  run hook
  [ ! -e "$WORK/Dockerfile" ] && [ -f "$WORK/.buildpacks" ]
}

@test "não mexe em app Node sem a receita estática" {
  echo '{"name":"api","scripts":{"build":"tsc","start":"node dist/server.js"}}' >"$WORK/package.json"
  printf 'https://github.com/heroku/heroku-buildpack-nodejs\n' >"$WORK/.buildpacks"
  run hook
  [ ! -e "$WORK/Dockerfile" ]
}

@test "não mexe sem script de build" {
  frontend
  echo '{"name":"site","scripts":{}}' >"$WORK/package.json"
  run hook
  [ ! -e "$WORK/Dockerfile" ]
}

@test "FABROKU_STATIC_BUILD=0 desliga" {
  frontend
  export FAKE_CONFIG_JSON='{"FABROKU_STATIC_BUILD":"0"}'
  run hook
  [ ! -e "$WORK/Dockerfile" ] && [ -f "$WORK/.buildpacks" ]
  [[ "$output" == *"desligado"* ]]
}

@test "BUILDPACK_URL configurado mantém buildpacks" {
  frontend
  export FAKE_CONFIG_JSON='{"BUILDPACK_URL":"https://github.com/heroku/heroku-buildpack-nodejs"}'
  run hook
  [ ! -e "$WORK/Dockerfile" ]
}

@test "root com caminho perigoso é ignorado" {
  frontend
  echo '{"root":"../../etc"}' >"$WORK/static.json"
  run hook
  grep 'for d in' "$WORK/Dockerfile" | grep -qv 'etc'
  grep -q 'for d in  *dist build out' "$WORK/Dockerfile"
}
