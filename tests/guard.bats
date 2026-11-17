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

@test "remove nginx.conf.sigil com } dentro de string (não fecha a ação)" {
  printf '{{ sh "echo }" }}\n' >"$WORK/nginx.conf.sigil"
  run guard
  [ ! -e "$WORK/nginx.conf.sigil" ]
}

@test "remove nginx.conf.sigil com }} e {{ escondidos em strings" {
  printf '{{ print "}}" | sh | print "{{" }}\n' >"$WORK/nginx.conf.sigil"
  run guard
  [ ! -e "$WORK/nginx.conf.sigil" ]
}

@test "remove nginx.conf.sigil com } em string crua e em caractere" {
  printf '{{ file `/etc/passwd}` }}\n' >"$WORK/nginx.conf.sigil"
  run guard
  [ ! -e "$WORK/nginx.conf.sigil" ]
  printf "{{ print '}' | sh }}\n" >"$WORK/nginx.conf.sigil"
  run guard
  [ ! -e "$WORK/nginx.conf.sigil" ]
}

@test "remove nginx.conf.sigil com ação que não fecha" {
  printf 'server {}\n{{ sh "id"\n' >"$WORK/nginx.conf.sigil"
  run guard
  [ ! -e "$WORK/nginx.conf.sigil" ]
}

@test "mantém nginx.conf.sigil com nome de função só dentro de string ou fora de ação" {
  cat >"$WORK/nginx.conf.sigil" <<'SIGIL'
include {{ $.DOKKU_ROOT }}/{{ $.APP }}/nginx.conf.d/*.conf;
add_header X-Note "{{ $.APP }} sh file";
{{ if eq $.APP "sh" }}# text{{ end }}
location / { return 200 "}}"; }
SIGIL
  run guard
  [ -f "$WORK/nginx.conf.sigil" ]
  [ -z "$output" ]
}

@test "remove CHECKS e nginx.conf.sigil quando o app define SIGIL_DELIMS" {
  mkdir -p "$BATS_TEST_TMPDIR/plugins/config"
  echo 'config_get() { [[ "$1" == "meu-app" && "$2" == "SIGIL_DELIMS" ]] && echo "[[,]]"; return 0; }' >"$BATS_TEST_TMPDIR/plugins/config/functions"
  printf 'WAIT=5\n' >"$WORK/CHECKS"
  printf 'server {}\n' >"$WORK/nginx.conf.sigil"
  PLUGIN_AVAILABLE_PATH="$BATS_TEST_TMPDIR/plugins" run guard
  [ ! -e "$WORK/CHECKS" ] && [ ! -e "$WORK/nginx.conf.sigil" ]
  [[ "$output" == *"SIGIL_DELIMS"* ]]
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
