FROM python:3.11-slim As builder

WORKDIR /install

COPY requirements.txt .

RUN pip install --no-cache-dir \
 -- prefix=/install \
 -r requirements.txt

FROM python:3.11-slim

RUN useradd --create-home --shell /usr/sbin/nologin appuser

WORKDIR /app

COPY --from=builder /install /usr/local

COPY app ./app

RUN chown -R appuser:appuser /app

USER appuser

EXPOSE 8080

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]