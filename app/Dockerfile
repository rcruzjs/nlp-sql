# Imagem da API NLP -> SQL.
# Dentro do container não usamos venv: o próprio container já isola as dependências.
# Para rodar fora do Docker, crie um venv (veja o README).
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# Usuário sem privilégios: se a API for comprometida, o atacante não é root no container.
RUN useradd --system --uid 10001 app
USER app

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
