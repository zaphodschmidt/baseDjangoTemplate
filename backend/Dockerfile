FROM python:3.12-slim-bookworm

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Dependencies before source, so an edit to the code does not invalidate the
# install layer.
COPY requirements.txt .
RUN uv pip install --system --no-cache -r requirements.txt

COPY . .
RUN chmod +x /app/entrypoint.sh

EXPOSE 8000

# The default command serves directly. docker-compose.prod.yml overrides the
# entrypoint to migrate and collect static first; docker-compose.override.yml
# replaces the command with runserver for local development.
CMD ["gunicorn", "config.wsgi:application", "--bind", "0.0.0.0:8000"]
