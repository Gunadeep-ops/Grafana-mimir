FROM python:3.12-slim
RUN pip install --no-cache-dir prometheus-client==0.21.1
WORKDIR /app
COPY app.py .
EXPOSE 8000
CMD ["python", "-u", "app.py"]
