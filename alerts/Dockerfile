# Pivot alerts app (alerts.twsiat.com): engine + web app + phone notifications.
FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1 ALERTS_DATA=/data
RUN pip install --no-cache-dir "fastapi>=0.110" "uvicorn>=0.29" "cryptography>=42" requests "pandas>=2.0" numpy pyyaml
COPY . .
RUN mkdir -p /data
EXPOSE 8080
CMD ["python", "main.py"]
