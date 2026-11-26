#!/bin/bash
# Cria o usuário SOMENTE LEITURA usado para executar o SQL gerado pelo LLM.
# Roda uma vez, na primeira subida do container (volume vazio), antes do 002_exemplo.sql.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
CREATE ROLE llm_ro LOGIN PASSWORD '${LLM_RO_PASSWORD}';

REVOKE ALL ON DATABASE "${POSTGRES_DB}" FROM PUBLIC;
GRANT CONNECT ON DATABASE "${POSTGRES_DB}" TO llm_ro;
GRANT USAGE ON SCHEMA public TO llm_ro;

-- Toda tabela que o dono (nlp_owner) criar depois já nasce com SELECT para o llm_ro
ALTER DEFAULT PRIVILEGES FOR ROLE "${POSTGRES_USER}" IN SCHEMA public
    GRANT SELECT ON TABLES TO llm_ro;

-- Mesmo que algo escape da validação: transações somente leitura e timeout de 10 s
ALTER ROLE llm_ro SET default_transaction_read_only = on;
ALTER ROLE llm_ro SET statement_timeout = '10s';
SQL
