# Guia: NLP → SQL com LLM local na Oracle Cloud (Always Free)

## Arquitetura

```
Internet ──► Nginx :80 (limite 10 req/min por IP)
                │
                ▼
           FastAPI :8000 (localhost) ──► Ollama :11434 (localhost) — Qwen gera o SQL
                │
                ▼
           PostgreSQL :5432 (localhost) — usuário llm_ro: só SELECT, read-only, timeout 10s
```

Só o Nginx fica exposto. LLM, API e banco escutam apenas em `127.0.0.1`.

## Estrutura

| Arquivo | O que faz |
|---|---|
| `oracle/setup-vm.sh` | Provisiona a VM inteira (swap, firewall, PostgreSQL, Ollama, venv, systemd, Nginx) |
| `app/main.py` | API: pergunta → esquema → LLM → validação → execução |
| `app/requirements.txt` | Dependências Python |
| `sql/exemplo.sql` | Base de exemplo (clientes, produtos, vendas) |

---

## Passo 1: conta na Oracle Cloud

1. Crie a conta em **cloud.oracle.com** (o cartão é só para verificação).
2. **Home Region**: São Paulo ou Vinhedo. **Não dá para trocar depois.**
3. Recomendado: *Billing → Budgets → Create Budget* com alerta de US$ 1, para ser avisado se algo sair do Always Free.

## Passo 2: chave SSH (no WSL)

Use **RSA 4096**. O console da OCI pode recusar ed25519 com o erro *"Invalid format for ssh public key"*.

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/oci_key
```

Para não ter problema ao colar, copie a chave **pública** para o Windows e use **"Upload public key files (.pub)"** no console:

```bash
cp ~/.ssh/oci_key.pub /mnt/c/Users/$USER/Downloads/
```

## Passo 3: criar a VM

*Menu ☰ → Compute → Instances → Create Instance*

| Campo | Valor |
|---|---|
| Image | **Canonical Ubuntu 24.04** (aarch64) |
| Shape | Ampere → `VM.Standard.A1.Flex` → **2 OCPUs / 12 GB** (limite gratuito atual) |
| Networking | VCN nova, **subnet pública**, atribuir IP público |
| SSH keys | Colar a chave pública |
| Boot volume | 100 GB (cabe nos 200 GB gratuitos) |
| **Advanced options → Management → cloud-init script** | Colar o conteúdo de `oracle/setup-vm.sh` |

> **"Out of capacity"?** Tente outro *Availability Domain*, tente de madrugada, ou faça upgrade para **Pay As You Go**, que mantém o Always Free gratuito e dá prioridade. Com o budget do Passo 1 ativo.

## Passo 4: liberar a porta 80 na Security List

*Networking → Virtual Cloud Networks → sua VCN → Subnet → Security List → Add Ingress Rules*

- Source CIDR: `0.0.0.0/0` · Protocol: TCP · Destination port: `80` (adicione `443` quando for usar HTTPS)

(O iptables dentro da VM o script já libera.)

## Passo 5: acompanhar o provisionamento

```powershell
ssh -i $HOME\.ssh\oci_key ubuntu@SEU_IP
```

```bash
cloud-init status --wait
tail -n 30 /var/log/setup-nlp.log
```

Leva de 5 a 15 minutos (o download do modelo é a parte demorada). Se você não usou o campo cloud-init, envie `oracle/setup-vm.sh` e rode `sudo bash setup-vm.sh`.

## Passo 6: enviar o código e carregar a base de exemplo

No Windows, dentro da pasta do projeto:

```powershell
scp -i $HOME\.ssh\oci_key -r app sql ubuntu@SEU_IP:~/
```

Na VM:

```bash
sudo cp -r ~/app ~/sql /opt/nlp-app/
sudo chown -R nlpapp:nlpapp /opt/nlp-app
sudo -u nlpapp /opt/nlp-app/venv/bin/pip install -r /opt/nlp-app/app/requirements.txt
sudo -u nlpapp bash -c 'set -a; source /opt/nlp-app/.env; psql "$DATABASE_URL_OWNER" -f /opt/nlp-app/sql/exemplo.sql'
sudo systemctl restart nlp-api
```

## Passo 7: testar

```bash
curl -s http://127.0.0.1:8000/saude
```

No navegador: `http://SEU_IP/`. Pela API:

```bash
curl -s -X POST http://SEU_IP/perguntar -H "Content-Type: application/json" -d '{"pergunta":"Qual o faturamento por estado em 2026?"}'
```

---

## Escolha do modelo (2 OCPUs ARM, só CPU)

| Modelo | RAM aprox. | Velocidade (estimativa) | Quando usar |
|---|---|---|---|
| `qwen2.5-coder:1.5b` | ~1 GB | Rápido | Perguntas simples, menor latência |
| **`qwen2.5-coder:3b`** (padrão) | ~2 GB | Médio | **Melhor equilíbrio** para text-to-SQL |
| `qwen2.5-coder:7b` | ~5 GB | Lento (pode passar de 30 s) | Mais precisão em JOINs complexos |

Para trocar o modelo:

```bash
sudo LLM_MODEL=qwen2.5-coder:7b bash setup-vm.sh
```

Por que a família **coder**: ela foi treinada com muito código e SQL, e costuma acertar mais sintaxe e JOINs que o modelo de chat do mesmo tamanho. Se houver uma versão mais nova do Qwen coder no Ollama, teste: basta trocar o nome.

## Comandos úteis

```bash
sudo journalctl -u nlp-api -f       # logs da API
sudo journalctl -u ollama -f        # logs do LLM
ollama ps                           # modelo carregado e uso de memória
free -h                             # memória e swap
```

## Próximos passos sugeridos

1. **Domínio + HTTPS**: `sudo apt install certbot python3-certbot-nginx` e depois `sudo certbot --nginx -d seudominio.com`.
2. **Melhorar a precisão**: enviar ao LLM os `COMMENT ON COLUMN`, chaves estrangeiras e exemplos de perguntas e SQL (few-shot).
3. **Cache de esquema e respostas**: evitar chamar o LLM para perguntas repetidas.
4. **Backup**: `pg_dump` agendado no cron para o Object Storage (tem cota gratuita; confira o limite atual).
