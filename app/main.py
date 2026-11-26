"""
API NLP -> SQL: perguntas em português viram consultas no PostgreSQL.

Fluxo de uma pergunta:
    1. Lê o esquema do banco (tabelas e colunas) para dar contexto ao LLM
    2. O LLM converte a pergunta em SQL (API compatível com OpenAI)
    3. O SQL é validado com sqlglot: um único comando, só leitura (SELECT/WITH/UNION)
    4. Executa com o usuário SOMENTE LEITURA, em transação read-only e com timeout

Por que a API "compatível com OpenAI": o mesmo código funciona com
llama-swap (GPU do chat-local), gateway LiteLLM ou Ollama (VM na nuvem).
Basta mudar LLM_BASE_URL, LLM_API_KEY e LLM_MODEL.

Por que validar se o usuário do banco já é somente leitura? Defesa em profundidade:
a validação dá um erro amigável e barra o óbvio; as permissões do PostgreSQL
garantem a segurança mesmo que a validação deixe passar algo.
"""

import os
import re
import time
from collections import defaultdict, deque

import httpx
import psycopg
import sqlglot
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field
from sqlglot import exp

LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "http://llm:8080/v1").rstrip("/")
LLM_API_KEY = os.environ.get("LLM_API_KEY", "")
LLM_MODEL = os.environ.get("LLM_MODEL", "chat-4b")
MAX_LINHAS = int(os.environ.get("MAX_LINHAS", "200"))
LIMITE_POR_MINUTO = int(os.environ.get("LIMITE_POR_MINUTO", "10"))

# Nós da árvore sintática que indicam escrita ou DDL. Comandos que o sqlglot
# não entende viram exp.Command, então também são barrados.
NOS_PROIBIDOS = (exp.Insert, exp.Update, exp.Delete, exp.Drop, exp.Create, exp.Command)

INSTRUCOES = """Você é um especialista em PostgreSQL. Converta a pergunta do usuário em UMA única consulta SQL de leitura (SELECT).

Regras:
- Use somente as tabelas e colunas do esquema abaixo.
- Responda apenas com o SQL, sem explicações e sem markdown.
- Use LIMIT {limite} quando a consulta puder retornar muitas linhas.
- Datas estão no tipo date; use EXTRACT ou date_trunc para filtrar por ano ou mês.

Esquema (tabela(coluna tipo, ...)):
{esquema}"""

app = FastAPI(title="NLP -> SQL com LLM local")

# Limite simples em memória: N perguntas por minuto por IP. Cada pergunta ocupa
# a GPU, então sem isso um link público pode ser derrubado por qualquer bot.
_historico_ip: dict[str, deque] = defaultdict(deque)


class Pergunta(BaseModel):
    pergunta: str = Field(min_length=3, max_length=500)


def ip_cliente(request: Request) -> str:
    """Atrás do Cloudflare Tunnel o IP real vem no cabeçalho CF-Connecting-IP."""
    return (
        request.headers.get("cf-connecting-ip")
        or request.headers.get("x-forwarded-for", "").split(",")[0].strip()
        or (request.client.host if request.client else "desconhecido")
    )


def checar_limite(ip: str) -> None:
    agora = time.monotonic()
    fila = _historico_ip[ip]
    while fila and agora - fila[0] > 60:
        fila.popleft()
    if len(fila) >= LIMITE_POR_MINUTO:
        raise HTTPException(429, f"Limite de {LIMITE_POR_MINUTO} perguntas por minuto atingido.")
    fila.append(agora)


def url_banco() -> str:
    """Lida só quando necessário, para o módulo poder ser importado em testes sem banco."""
    url = os.environ.get("DATABASE_URL_RO")
    if not url:
        raise HTTPException(500, "DATABASE_URL_RO não configurada.")
    return url


def carregar_esquema() -> str:
    """Monta um resumo compacto do schema public. Compacto = menos tokens = resposta mais rápida."""
    sql = """
        SELECT table_name, column_name, data_type
        FROM information_schema.columns
        WHERE table_schema = 'public'
        ORDER BY table_name, ordinal_position
    """
    with psycopg.connect(url_banco()) as conn:
        linhas = conn.execute(sql).fetchall()
    tabelas: dict[str, list[str]] = {}
    for tabela, coluna, tipo in linhas:
        tabelas.setdefault(tabela, []).append(f"{coluna} {tipo}")
    return "\n".join(f"{t}({', '.join(cols)})" for t, cols in tabelas.items())


def extrair_sql(texto: str) -> str:
    """Remove raciocínio <think> e cercas ```sql que alguns modelos devolvem mesmo pedindo que não."""
    texto = re.sub(r"<think>.*?</think>", "", texto, flags=re.S | re.I)
    bloco = re.search(r"```(?:sql)?\s*(.*?)```", texto, re.S | re.I)
    sql = bloco.group(1) if bloco else texto
    return sql.strip().rstrip(";").strip()


def validar_sql(sql: str) -> str:
    """Garante um único comando de leitura. Retorna o SQL normalizado para PostgreSQL."""
    try:
        comandos = [c for c in sqlglot.parse(sql, read="postgres") if c is not None]
    except sqlglot.errors.ParseError as erro:
        raise HTTPException(422, f"O LLM gerou um SQL inválido: {erro}") from erro
    if len(comandos) != 1:
        raise HTTPException(422, "O SQL gerado deve ter exatamente um comando.")
    arvore = comandos[0]
    if not isinstance(arvore, exp.Query) or arvore.find(*NOS_PROIBIDOS):
        raise HTTPException(422, "Apenas consultas de leitura (SELECT) são permitidas.")
    return arvore.sql(dialect="postgres")


def gerar_sql(pergunta: str, esquema: str) -> str:
    cabecalhos = {"Authorization": f"Bearer {LLM_API_KEY}"} if LLM_API_KEY else {}
    corpo = {
        "model": LLM_MODEL,
        "messages": [
            {"role": "system", "content": INSTRUCOES.format(esquema=esquema, limite=MAX_LINHAS)},
            {"role": "user", "content": pergunta},
        ],
        # temperature 0: queremos o SQL mais provável, não criatividade
        "temperature": 0,
        "max_tokens": 512,
    }
    try:
        resposta = httpx.post(f"{LLM_BASE_URL}/chat/completions", json=corpo,
                              headers=cabecalhos, timeout=150)
        resposta.raise_for_status()
        conteudo = resposta.json()["choices"][0]["message"]["content"] or ""
    except (httpx.HTTPError, KeyError, IndexError) as erro:
        raise HTTPException(503, f"Falha ao consultar o LLM: {erro}") from erro
    return extrair_sql(conteudo)


def executar(sql: str) -> tuple[list[str], list[tuple]]:
    with psycopg.connect(url_banco()) as conn:
        conn.read_only = True  # terceira camada, além do papel e da validação
        with conn.cursor() as cur:
            cur.execute(sql)
            colunas = [d.name for d in cur.description or []]
            linhas = cur.fetchmany(MAX_LINHAS)
    return colunas, linhas


@app.get("/saude")
def saude():
    """Verifica se banco e LLM estão de pé."""
    status = {"banco": "ok", "llm": "ok", "modelo": LLM_MODEL}
    try:
        with psycopg.connect(url_banco(), connect_timeout=3) as conn:
            conn.execute("SELECT 1")
    except Exception as erro:  # noqa: BLE001 - queremos reportar qualquer falha
        status["banco"] = f"erro: {erro}"
    cabecalhos = {"Authorization": f"Bearer {LLM_API_KEY}"} if LLM_API_KEY else {}
    try:
        httpx.get(f"{LLM_BASE_URL}/models", headers=cabecalhos, timeout=5).raise_for_status()
    except httpx.HTTPError as erro:
        status["llm"] = f"erro: {erro}"
    return status


@app.post("/perguntar")
def perguntar(dados: Pergunta, request: Request):
    checar_limite(ip_cliente(request))
    esquema = carregar_esquema()
    if not esquema:
        raise HTTPException(400, "O banco não tem tabelas visíveis para o usuário somente leitura.")
    inicio = time.perf_counter()
    sql = validar_sql(gerar_sql(dados.pergunta, esquema))
    tempo_llm = time.perf_counter() - inicio
    try:
        colunas, linhas = executar(sql)
    except psycopg.Error as erro:
        raise HTTPException(422, {"erro": str(erro).strip(), "sql": sql}) from erro
    return {
        "pergunta": dados.pergunta,
        "sql": sql,
        "colunas": colunas,
        "linhas": linhas,
        "tempo_llm_s": round(tempo_llm, 2),
    }


@app.get("/", response_class=HTMLResponse)
def pagina():
    """Página simples para testar no navegador."""
    return """<!doctype html>
<html lang="pt-br"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pergunte ao banco</title>
<style>
 body{font-family:system-ui,sans-serif;max-width:900px;margin:2rem auto;padding:0 1rem}
 textarea{width:100%;height:4rem;font-size:1rem;box-sizing:border-box} button{padding:.5rem 1.2rem;font-size:1rem}
 pre{background:#f3f3f3;padding:.8rem;overflow:auto;white-space:pre-wrap} table{border-collapse:collapse;width:100%}
 td,th{border:1px solid #ccc;padding:.3rem .5rem;text-align:left} .r{overflow-x:auto}
</style></head><body>
<h1>Pergunte ao banco em português</h1>
<textarea id="p">Quais os 5 produtos com maior faturamento?</textarea>
<p><button id="b">Perguntar</button> <span id="s"></span></p>
<pre id="q"></pre><div class="r" id="r"></div>
<script>
const esc = v => String(v ?? "").replace(/[&<>]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]));
document.getElementById("b").onclick = async () => {
  const s = document.getElementById("s"), q = document.getElementById("q"), r = document.getElementById("r");
  s.textContent = "Gerando SQL no LLM local..."; q.textContent = ""; r.innerHTML = "";
  const t0 = performance.now();
  const resp = await fetch("/perguntar", {method:"POST", headers:{"Content-Type":"application/json"},
    body: JSON.stringify({pergunta: document.getElementById("p").value})});
  const d = await resp.json();
  s.textContent = `${((performance.now()-t0)/1000).toFixed(1)} s`;
  if (!resp.ok) { q.textContent = JSON.stringify(d.detail, null, 2); return; }
  q.textContent = d.sql;
  r.innerHTML = "<table><tr>" + d.colunas.map(c => `<th>${esc(c)}</th>`).join("") + "</tr>" +
    d.linhas.map(l => "<tr>" + l.map(v => `<td>${esc(v)}</td>`).join("") + "</tr>").join("") + "</table>";
};
</script></body></html>"""
