#!/bin/bash
# =============================================================================
# Provisionamento da VM Oracle Cloud (Ubuntu 24.04 ARM / Ampere A1 - Always Free)
#
# Instala e configura:
#   - Swap (folga de memória para o LLM)
#   - PostgreSQL (escutando só em localhost) com usuário dono e usuário somente leitura
#   - Ollama (LLM local) + modelo Qwen para gerar SQL
#   - Python em ambiente virtual (venv) com FastAPI
#   - Serviço systemd da API + Nginx como proxy reverso (porta 80) com limite de requisições
#   - Regras de iptables para liberar HTTP/HTTPS
#
# Uso:
#   a) Cole este arquivo no campo "cloud-init script" ao criar a instância, OU
#   b) Rode na VM:  sudo bash setup-vm.sh
#   Para outro modelo:  sudo LLM_MODEL=qwen2.5-coder:7b bash setup-vm.sh
#
# O script é idempotente: pode ser executado de novo sem quebrar nada.
# Log completo em /var/log/setup-nlp.log
# =============================================================================
set -euo pipefail
exec > >(tee -a /var/log/setup-nlp.log) 2>&1

# ----- Configurações (ajuste se quiser) -----
APP_DIR=/opt/nlp-app
APP_USER=nlpapp
DB_NAME=nlp_db
DB_OWNER=app_owner     # dono das tabelas: usado para criar/carregar dados
DB_RO=llm_ro           # somente leitura: o ÚNICO usado para executar o SQL gerado pelo LLM
LLM_MODEL="${LLM_MODEL:-qwen2.5-coder:3b}"
SWAP_GB=4
ENV_FILE="$APP_DIR/.env"

export DEBIAN_FRONTEND=noninteractive
cd /tmp   # evita avisos do psql ao trocar de usuário

echo ">> [1/8] Atualizando o sistema e instalando pacotes"
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt-get update -y
apt-get upgrade -y
apt-get install -y postgresql postgresql-contrib python3-venv python3-pip \
    nginx curl openssl iptables-persistent netfilter-persistent

echo ">> [2/8] Criando swap de ${SWAP_GB} GB"
# Por quê: com 12 GB divididos entre LLM, PostgreSQL e API, o swap evita que o
# kernel mate processos (OOM) num pico de memória ao carregar o modelo.
if ! swapon --show | grep -q /swapfile; then
    fallocate -l "${SWAP_GB}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
sysctl -w vm.swappiness=10
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf

echo ">> [3/8] Liberando portas 80 e 443 no iptables"
# Por quê: as imagens da OCI vêm com iptables bloqueando tudo, exceto SSH.
# Isso é a SEGUNDA camada; a primeira é a Security List da VCN (no console).
for PORTA in 80 443; do
    if ! iptables -C INPUT -p tcp -m state --state NEW --dport "$PORTA" -j ACCEPT 2>/dev/null; then
        # Posição 6 = antes do REJECT padrão da imagem OCI; se a cadeia for menor, insere no topo.
        iptables -I INPUT 6 -p tcp -m state --state NEW --dport "$PORTA" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT 1 -p tcp -m state --state NEW --dport "$PORTA" -j ACCEPT
    fi
done
netfilter-persistent save

echo ">> [4/8] Criando usuário de sistema e diretório da aplicação"
id -u "$APP_USER" &>/dev/null || \
    useradd --system --create-home --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
mkdir -p "$APP_DIR/app" "$APP_DIR/sql"

# Senhas: reaproveita as existentes se o script já rodou antes; senão gera novas.
# Hex evita caracteres especiais que quebrariam a URL de conexão ou o SQL.
if [[ -f "$ENV_FILE" ]]; then
    # Lê só as senhas (não usa "source" para não sobrescrever LLM_MODEL passado agora).
    DB_OWNER_PASS=$(grep '^DB_OWNER_PASS=' "$ENV_FILE" | cut -d= -f2)
    DB_RO_PASS=$(grep '^DB_RO_PASS=' "$ENV_FILE" | cut -d= -f2)
else
    DB_OWNER_PASS=$(openssl rand -hex 24)
    DB_RO_PASS=$(openssl rand -hex 24)
fi

echo ">> [5/8] Configurando PostgreSQL"
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_OWNER}') THEN
        CREATE ROLE ${DB_OWNER} LOGIN PASSWORD '${DB_OWNER_PASS}';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_RO}') THEN
        CREATE ROLE ${DB_RO} LOGIN PASSWORD '${DB_RO_PASS}';
    END IF;
END
\$\$;
-- Ajustes de memória pensando em dividir 12 GB com o LLM
ALTER SYSTEM SET shared_buffers = '1GB';
ALTER SYSTEM SET effective_cache_size = '3GB';
ALTER SYSTEM SET work_mem = '16MB';
ALTER SYSTEM SET listen_addresses = 'localhost';
SQL

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" | grep -q 1; then
    sudo -u postgres createdb -O "$DB_OWNER" "$DB_NAME"
fi

# Defesa em profundidade para o SQL gerado pelo LLM:
#   - só SELECT, inclusive em tabelas criadas no futuro (DEFAULT PRIVILEGES)
#   - transações somente leitura por padrão
#   - timeout para consultas pesadas não travarem o servidor
sudo -u postgres psql -d "$DB_NAME" -v ON_ERROR_STOP=1 <<SQL
REVOKE ALL ON DATABASE ${DB_NAME} FROM PUBLIC;
GRANT CONNECT ON DATABASE ${DB_NAME} TO ${DB_OWNER}, ${DB_RO};
GRANT USAGE ON SCHEMA public TO ${DB_RO};
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${DB_RO};
ALTER DEFAULT PRIVILEGES FOR ROLE ${DB_OWNER} IN SCHEMA public GRANT SELECT ON TABLES TO ${DB_RO};
ALTER ROLE ${DB_RO} SET default_transaction_read_only = on;
ALTER ROLE ${DB_RO} SET statement_timeout = '10s';
SQL
systemctl restart postgresql

echo ">> [6/8] Instalando Ollama e baixando o modelo ${LLM_MODEL}"
if ! command -v ollama &>/dev/null; then
    curl -fsSL https://ollama.com/install.sh | sh
fi
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
[Service]
# Só localhost: o LLM NÃO fica exposto na internet, apenas a API o acessa.
Environment="OLLAMA_HOST=127.0.0.1:11434"
# Com 2 OCPUs, processar uma requisição por vez é mais rápido que dividir a CPU.
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
# Mantém o modelo na memória por 30 min (evita recarregar a cada pergunta).
Environment="OLLAMA_KEEP_ALIVE=30m"
EOF
systemctl daemon-reload
systemctl enable ollama
systemctl restart ollama
for _ in $(seq 1 30); do
    curl -sf http://127.0.0.1:11434/api/version >/dev/null && break
    sleep 2
done
ollama pull "$LLM_MODEL"

echo ">> [7/8] Criando ambiente virtual Python e arquivo .env"
[[ -d "$APP_DIR/venv" ]] || python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip
"$APP_DIR/venv/bin/pip" install fastapi "uvicorn[standard]" "psycopg[binary]" httpx sqlglot

cat > "$ENV_FILE" <<EOF
DB_OWNER_PASS=${DB_OWNER_PASS}
DB_RO_PASS=${DB_RO_PASS}
DATABASE_URL_OWNER=postgresql://${DB_OWNER}:${DB_OWNER_PASS}@127.0.0.1:5432/${DB_NAME}
DATABASE_URL_RO=postgresql://${DB_RO}:${DB_RO_PASS}@127.0.0.1:5432/${DB_NAME}
# Ollama expõe a API compatível com OpenAI em /v1 (a mesma usada localmente com o LiteLLM)
LLM_BASE_URL=http://127.0.0.1:11434/v1
LLM_API_KEY=ollama
LLM_MODEL=${LLM_MODEL}
MAX_LINHAS=200
EOF
chmod 600 "$ENV_FILE"
chown -R "$APP_USER:$APP_USER" "$APP_DIR"

cat > /etc/systemd/system/nlp-api.service <<EOF
[Unit]
Description=API NLP -> SQL (FastAPI)
After=network.target postgresql.service ollama.service

[Service]
User=${APP_USER}
WorkingDirectory=${APP_DIR}/app
EnvironmentFile=${ENV_FILE}
ExecStart=${APP_DIR}/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000 --workers 1
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable nlp-api
# Só inicia se o código já foi enviado (no cloud-init ele ainda não existe).
if [[ -f "$APP_DIR/app/main.py" ]]; then
    systemctl restart nlp-api
fi

echo ">> [8/8] Configurando Nginx"
cat > /etc/nginx/sites-available/nlp-api <<'EOF'
# Limite: 10 perguntas/min por IP. Cada pergunta usa a CPU inteira no LLM,
# então sem isso qualquer bot derruba o servidor.
limit_req_zone $binary_remote_addr zone=api:10m rate=10r/m;

server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 1m;

    location /perguntar {
        limit_req zone=api burst=5 nodelay;
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        # LLM em CPU pode demorar: dá tempo para a resposta chegar.
        proxy_read_timeout 180s;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
EOF
ln -sf /etc/nginx/sites-available/nlp-api /etc/nginx/sites-enabled/nlp-api
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

echo ""
echo "=============================================================="
echo " Provisionamento concluído."
echo " Modelo LLM:  ${LLM_MODEL}"
echo " Credenciais: ${ENV_FILE} (somente root/${APP_USER} leem)"
echo " Próximo passo: enviar a pasta app/ e sql/ (veja GUIA.md)"
echo "=============================================================="
