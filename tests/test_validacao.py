"""
Testes da primeira camada de segurança: a validação do SQL gerado pelo LLM.
Não precisam de banco nem de LLM.

Rodar:  pip install -r requirements-dev.txt && pytest
"""

import sys
from pathlib import Path

import pytest
from fastapi import HTTPException

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
from main import extrair_sql, validar_sql  # noqa: E402

ACEITOS = [
    "SELECT * FROM vendas LIMIT 10",
    "WITH t AS (SELECT estado, sum(valor_total) s FROM vendas v "
    "JOIN clientes c ON c.id = v.cliente_id GROUP BY estado) SELECT * FROM t",
    "SELECT nome FROM clientes UNION SELECT nome FROM produtos",
    "SELECT nome FROM produtos WHERE nome ILIKE '%mouse%'",
]

RECUSADOS = [
    "DELETE FROM vendas",
    "SELECT 1; DROP TABLE vendas",                                # dois comandos
    "WITH x AS (DELETE FROM vendas RETURNING *) SELECT * FROM x",  # DML escondido em CTE
    "INSERT INTO clientes(nome) VALUES ('x')",
    "UPDATE produtos SET preco = 0",
    "CREATE TABLE x (id int)",
    "GRANT ALL ON vendas TO public",
    "COPY vendas TO '/tmp/x'",
]


@pytest.mark.parametrize("sql", ACEITOS)
def test_aceita_consultas_de_leitura(sql):
    assert validar_sql(sql)


@pytest.mark.parametrize("sql", RECUSADOS)
def test_recusa_escrita_ddl_e_multiplos_comandos(sql):
    with pytest.raises(HTTPException) as erro:
        validar_sql(sql)
    assert erro.value.status_code == 422


@pytest.mark.parametrize("bruto, esperado", [
    ("```sql\nSELECT 1;\n```", "SELECT 1"),
    ("<think>raciocínio</think>\nSELECT 2", "SELECT 2"),
    ("  SELECT 3 ;  ", "SELECT 3"),
])
def test_extrai_sql_da_resposta_do_llm(bruto, esperado):
    assert extrair_sql(bruto) == esperado
