#!/usr/bin/env bats
# Testes do 00-fabroku-guard (guard/core-post-extract) numa pasta de build de mentira.

PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  WORK="$BATS_TEST_TMPDIR/build"
  mkdir -p "$WORK/lib" "$WORK/sub"
  echo segredo >"$BATS_TEST_TMPDIR/ENV"
}

guard() {
  "$PLUGIN_ROOT/guard/core-post-extract" meu-app "$WORK"
}

@test "remove link simbólico que aponta para fora do repositório" {
  ln -s "$BATS_TEST_TMPDIR/ENV" "$WORK/.env"
  ln -s /etc/passwd "$WORK/sub/Procfile"
  run guard
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/.env" ] && [ ! -L "$WORK/.env" ]
  [ ! -L "$WORK/sub/Procfile" ]
  [[ "$output" == *"link simbólico removido: .env"* ]]
}

@test "remove link relativo que escapa com .." {
  ln -s ../../ENV "$WORK/sub/app.json"
  run guard
  [ ! -L "$WORK/sub/app.json" ]
}

@test "mantém link simbólico que aponta para dentro do repositório" {
  ln -s lib "$WORK/lib64"
  ln -s ../lib "$WORK/sub/lib"
  run guard
  [ -L "$WORK/lib64" ] && [ -L "$WORK/sub/lib" ]
  [ -z "$output" ]
}

@test "remove CHECKS com template" {
  printf '/ {{ sh "id" }}\n' >"$WORK/CHECKS"
  run guard
  [ ! -e "$WORK/CHECKS" ]
  [[ "$output" == *"CHECKS removido"* ]]
}

@test "mantém CHECKS sem template" {
  printf 'WAIT=5\n/health ok\n' >"$WORK/CHECKS"
  run guard
  [ -f "$WORK/CHECKS" ]
}

@test "remove nginx.conf.sigil com função perigosa, inclusive quebrada em linhas" {
  printf 'server {\n  # {{\n  file\n  "/etc/shadow" }}\n}\n' >"$WORK/nginx.conf.sigil"
  run guard
  [ ! -e "$WORK/nginx.conf.sigil" ]
}

@test "remove nginx.conf.sigil com sh em pipe" {
  printf '{{ "id" | sh }}\n' >"$WORK/nginx.conf.sigil"
  run guard
  [ ! -e "$WORK/nginx.conf.sigil" ]
}

@test "mantém nginx.conf.sigil só com variáveis e controle de fluxo" {
  cat >"$WORK/nginx.conf.sigil" <<'SIGIL'
{{ range $port_map := .PROXY_PORT_MAP | split " " }}
upstream {{ $.APP }}-flower { server {{ $.DOKKU_APP_FLOWER_LISTENERS }}; }
location /flower/ { proxy_pass http://{{ $.DOKKU_APP_FLOWER_LISTENERS }}/flower/; }
{{ if $.SSL_INUSE }}ssl_certificate {{ $.APP_SSL_PATH }}/server.crt;{{ end }}
{{ end }}
SIGIL
  run guard
  [ -f "$WORK/nginx.conf.sigil" ]
  [ -z "$output" ]
}

@test "não falha sem pasta de build" {
  run "$PLUGIN_ROOT/guard/core-post-extract" meu-app ""
  [ "$status" -eq 0 ]
}
