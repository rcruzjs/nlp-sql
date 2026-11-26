# NLP → SQL com LLM local

Pergunte em português, o LLM (Qwen3-4B na GPU) gera o SQL, que é validado e executado
num PostgreSQL com usuário somente leitura.

```
Navegador ──► nlp-api :8100 (FastAPI) ──► llm :8080 (llama-swap do chat-local, GPU)
                    │
                    ▼
              nlp-db :5434 (PostgreSQL "caixa de areia", usuário llm_ro)
```

## Segurança do SQL gerado (4 camadas)

| Camada | O que barra |
|---|---|
| Validação com `sqlglot` | Mais de um comando; qualquer coisa que não seja SELECT/WITH/UNION; DML escondido em CTE |
| Usuário `llm_ro` | Só tem SELECT; transações read-only por padrão |
| `statement_timeout = 10s` | Consultas pesadas ou `pg_sleep` |
| Limite por IP | 10 perguntas/min (resposta 429), para proteger a GPU num link público |

Além disso, o banco é **separado** do chat-local: o LLM nunca acessa usuários e mensagens do outro projeto.

## Pré-requisito

O **chat-local** precisa estar no ar, porque é ele que fornece o container `llm` (llama-swap):

```bash
cd ~/projetos/chat-local && docker compose up -d llm
```

## Subir

```bash
cd ~/projetos/nlp-sql
bash scripts/preparar_env.sh      # só na primeira vez: gera .env com senhas aleatórias
docker compose up -d --build
```

Abra **http://localhost:8100** no navegador do Windows.

Teste pela linha de comando:

```bash
curl -s http://127.0.0.1:8100/saude
```

```bash
curl -s -X POST http://127.0.0.1:8100/perguntar -H "Content-Type: application/json" -d '{"pergunta":"Qual o faturamento por estado em 2026?"}'
```

## Link público para portfólio (Cloudflare Tunnel)

```bash
docker compose --profile publico up -d
docker compose logs tunnel | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com'
```

- O link é **temporário** e muda a cada vez que o túnel sobe. Ótimo para demonstração.
- Para um endereço fixo (ex.: `nlp.seudominio.com`), crie um túnel nomeado na conta gratuita da Cloudflare.
- **Derrube quando não estiver demonstrando:** `docker compose stop tunnel`.

## Usar os seus próprios dados

Crie tabelas como **dono** (`nlp_owner`). O `llm_ro` ganha SELECT automaticamente (DEFAULT PRIVILEGES):

```bash
docker compose exec nlp-db psql -U nlp_owner -d nlp
```

Dica de precisão: nomes de tabelas e colunas claros em português ajudam muito o LLM.

## Trocar o modelo

No `.env`, `LLM_MODEL` aceita qualquer modelo do `config/llama-swap.yaml` do chat-local
(`chat-4b`, `chat-8b`, `chat-moe-30b`). Depois: `docker compose up -d`.

Medido neste PC (RTX 3050 6 GB, `chat-4b`): **~1 s** para gerar o SQL. A primeira pergunta leva
alguns segundos a mais, enquanto o modelo é carregado na GPU.

## Desenvolver fora do Docker (venv)

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r app/requirements.txt
```

## Comandos úteis

```bash
docker compose logs -f nlp-api
docker compose ps
docker compose down          # para (os dados ficam no volume)
docker compose down -v       # APAGA o banco (recria com os dados de exemplo na próxima subida)
```

## Nuvem (Oracle Cloud)

O mesmo `app/` roda numa VM Always Free com Ollama: veja [oracle/GUIA-ORACLE.md](oracle/GUIA-ORACLE.md).
