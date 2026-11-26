-- Base de exemplo para testar o NLP -> SQL: clientes, produtos e vendas.
-- Executar como o DONO do banco (nlp_owner no Docker, app_owner na VM Oracle),
-- para o llm_ro herdar o SELECT via DEFAULT PRIVILEGES.
-- Nomes de colunas claros em português ajudam MUITO o LLM a acertar o SQL.

DROP TABLE IF EXISTS vendas, produtos, clientes;

CREATE TABLE clientes (
    id          serial PRIMARY KEY,
    nome        text NOT NULL,
    cidade      text NOT NULL,
    estado      char(2) NOT NULL,
    criado_em   date NOT NULL
);

CREATE TABLE produtos (
    id          serial PRIMARY KEY,
    nome        text NOT NULL,
    categoria   text NOT NULL,
    preco       numeric(10,2) NOT NULL
);

CREATE TABLE vendas (
    id          serial PRIMARY KEY,
    cliente_id  int NOT NULL REFERENCES clientes(id),
    produto_id  int NOT NULL REFERENCES produtos(id),
    quantidade  int NOT NULL CHECK (quantidade > 0),
    valor_total numeric(12,2) NOT NULL,
    data_venda  date NOT NULL
);

-- Comentários também podem ser lidos e enviados ao LLM como contexto extra no futuro.
COMMENT ON COLUMN vendas.valor_total IS 'quantidade * preço do produto na data da venda';

INSERT INTO clientes (nome, cidade, estado, criado_em) VALUES
    ('Ana Souza',      'São Paulo',      'SP', '2025-01-10'),
    ('Bruno Lima',     'Rio de Janeiro', 'RJ', '2025-02-03'),
    ('Carla Mendes',   'Belo Horizonte', 'MG', '2025-03-15'),
    ('Diego Rocha',    'Curitiba',       'PR', '2025-04-22'),
    ('Elisa Martins',  'Porto Alegre',   'RS', '2025-05-30'),
    ('Fábio Costa',    'Salvador',       'BA', '2025-06-12'),
    ('Gabriela Alves', 'Recife',         'PE', '2025-07-01'),
    ('Henrique Dias',  'Campinas',       'SP', '2025-08-19');

INSERT INTO produtos (nome, categoria, preco) VALUES
    ('Notebook 14"',        'Informática', 3899.00),
    ('Mouse sem fio',       'Informática',   89.90),
    ('Teclado mecânico',    'Informática',  349.00),
    ('Monitor 27"',         'Informática', 1499.00),
    ('Fone Bluetooth',      'Áudio',        299.00),
    ('Caixa de som',        'Áudio',        459.00),
    ('Cadeira ergonômica',  'Móveis',      1290.00),
    ('Mesa digitalizadora', 'Informática',  699.00);

-- 500 vendas aleatórias ao longo de 2025-2026 (setseed = resultado reproduzível)
SELECT setseed(0.42);
INSERT INTO vendas (cliente_id, produto_id, quantidade, valor_total, data_venda)
SELECT c.id, p.id, q.qtd, q.qtd * p.preco,
       date '2025-01-01' + (random() * 690)::int
FROM generate_series(1, 500) AS g
CROSS JOIN LATERAL (SELECT 1 + (random() * 3)::int AS qtd, g AS ref) AS q
CROSS JOIN LATERAL (SELECT id FROM clientes ORDER BY random() + g * 0 LIMIT 1) AS c
CROSS JOIN LATERAL (SELECT id, preco FROM produtos ORDER BY random() + g * 0 LIMIT 1) AS p;

CREATE INDEX ON vendas (data_venda);
CREATE INDEX ON vendas (cliente_id);
CREATE INDEX ON vendas (produto_id);
