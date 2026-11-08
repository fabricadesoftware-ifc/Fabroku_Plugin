# 🔌 Fabroku Plugin

Plugin [Dokku](https://dokku.com/) usado pelo [Fabroku PaaS](https://fabroku.fabricadesoftware.ifc.edu.br/) para rodar deploys **desacoplados da conexão SSH**: o build continua no servidor mesmo se o worker do Fabroku cair, for reiniciado ou o deploy for cancelado, e o log fica completo para o Fabroku ler por partes.

O desenho, a motivação e as decisões estão em [`docs/PLANO.md`](docs/PLANO.md).

## Comandos

Todas as respostas são JSON numa linha. Erros saem com exit code 1 e `{"error":"<código>","message":"..."}`.

| Comando | Para quê |
|---|---|
| `fabroku:version` | Versão instalada |
| `fabroku:deploy <app> <git-url> <branch> <deploy-id>` | Inicia o build em segundo plano e retorna na hora |
| `fabroku:deploy-log <deploy-id> <offset> [max-bytes]` | Lê o log a partir de um byte (base64), com o estado e `eof` |
| `fabroku:deploy-follow <deploy-id> [offset]` | Manda o log cru a partir de um byte e segue até o build terminar (uma conexão por deploy) |
| `fabroku:deploy-status <deploy-id>` | Estado: `running`, `succeeded`, `failed`, `cancelled` ou `lost` |
| `fabroku:deploy-cancel <deploy-id> [segundos]` | SIGTERM no build, SIGKILL após o prazo (padrão 10 s), para containers do build que sobraram e remove os parados |
| `fabroku:cleanup <app>` | Remove containers parados do app, mesmo com `DOKKU_SKIP_CLEANUP` ligado (o `dokku cleanup` não faz nada nesse caso) |
| `fabroku:gc [dias]` | Apaga deploys finalizados há mais de N dias (padrão 7) |

## Instalação

Precisa de Dokku 0.38+ (testado no 0.38.27, Debian 13).

```bash
sudo dokku plugin:install https://github.com/fabricadesoftware-ifc/Fabroku_Plugin.git --name fabroku
dokku fabroku:version
```

Limpeza diária dos registros antigos (cron do root):

```cron
30 3 * * * dokku fabroku:gc 7 >/dev/null
```

Depois, no backend do Fabroku: `DOKKU_REMOTE_DEPLOY_PLUGIN=true`.

Atualizar: `sudo dokku plugin:update fabroku`.

## Proteção do servidor (00-fabroku-guard)

O Dokku confia em quem faz push, mas no Fabroku o repositório é do aluno. Sem proteção, o Dokku
executaria ou leria partes do repositório **no servidor**: `CHECKS` e `nginx.conf.sigil` passam
pelo `sigil` (que tem `{{ sh }}`, `{{ file }}`, `{{ httpget }}`), e `.env`, `app.json`, `Procfile`
etc. são copiados seguindo links simbólicos (ex.: `.env -> /var/lib/dokku/config/<outro-app>/ENV`).

O `install` instala o plugin `00-fabroku-guard` (pasta `guard/`). O `core-post-extract` dele roda
antes dos plugins do Dokku e, na pasta de build, **remove**:

- links simbólicos que apontam para fora do repositório;
- `CHECKS` com qualquer `{{ }}`;
- `nginx.conf.sigil` que usa funções do sigil que acessam o servidor (variáveis como `{{ $.APP }}` passam).

Ele remove em vez de falhar porque o `plugn` roda todos os hooks mesmo quando um sai com erro.
Use também `dokku nginx:set --global disable-custom-config true`, liberando só apps nossos.

## Estrutura

```
plugin.toml         metadados do plugin Dokku
commands            ajuda (dokku help, dokku fabroku:help)
install             trigger do Dokku: cria /var/lib/dokku/data/fabroku
internal-functions  validação, estado e JSON compartilhados
subcommands/        um executável por comando fabroku:*
libexec/run-deploy  roda o git:sync --build fora da sessão SSH
guard/              plugin 00-fabroku-guard, instalado junto pelo install (ver abaixo)
tests/              testes bats com um Dokku de mentira
docs/PLANO.md       desenho e decisões
```

## Testes

Precisa de `bats` e `shellcheck` (Linux ou WSL):

```bash
shellcheck -s bash commands install internal-functions libexec/run-deploy guard/core-post-extract subcommands/* tests/fixtures/fake-dokku
bats tests
```

## Licença

MIT — veja [LICENSE](LICENSE).
