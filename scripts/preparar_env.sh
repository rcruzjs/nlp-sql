#!/bin/bash
# Cria o .env com senhas aleatórias, para nenhuma senha precisar ser digitada ou copiada à mão.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
    echo ".env já existe; nada a fazer. Apague-o se quiser gerar de novo."
    exit 0
fi

umask 077   # .env legível só pelo seu usuário
cat > .env <<EOF
# Gerado por scripts/preparar_env.sh. NÃO versionar (está no .gitignore).
NLP_OWNER_PASSWORD=$(openssl rand -hex 24)
LLM_RO_PASSWORD=$(openssl rand -hex 24)

# LLM: llama-swap do chat-local (Qwen3-4B na GPU), API compatível com OpenAI, sem chave.
# Alternativa pelo gateway LiteLLM: LLM_BASE_URL=http://gateway:4000/v1 e
# LLM_API_KEY=<LITELLM_MASTER_KEY do chat-local>
LLM_BASE_URL=http://llm:8080/v1
LLM_API_KEY=
LLM_MODEL=chat-4b

MAX_LINHAS=200
LIMITE_POR_MINUTO=10
EOF
echo ".env criado com permissão 600."
