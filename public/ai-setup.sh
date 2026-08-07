#!/bin/bash
# Adds a local AI to Station. Free, runs on your own box, nothing leaves the house.
# Run inside the Station container:   bash ai-setup.sh
set -e
say(){ printf "\n\033[1;33m==> %s\033[0m\n" "$1"; }
ok(){  printf "    \033[0;32m%s\033[0m\n" "$1"; }
die(){ printf "\n\033[0;31mSTOPPED: %s\033[0m\n" "$1" >&2; exit 1; }

MODEL="${MODEL:-llama3.2:3b}"
APP=/root/station-app
[ -d "$APP" ] || die "Can't find $APP."

say "1/4  Checking there's room to run a model"
MEM=$(free -m | awk '/^Mem:/{print $2}')
echo "    container memory: ${MEM} MB"
if [ "$MEM" -lt 3500 ]; then
  cat <<WARN

    Not enough memory. A small model needs about 4 GB.
    On the Proxmox host, give this container more and reboot it:

        pct set 103 --memory 6144 --cores 4
        pct reboot 103

    Then run this script again.
WARN
  exit 1
fi
ok "enough memory"

say "2/4  Starting Ollama alongside Station"
cd "$APP"
if ! grep -q "ollama:" docker-compose.yml; then
  cp docker-compose.yml docker-compose.yml.bak
  cat > docker-compose.yml <<'YML'
services:
  station:
    build: .
    container_name: station
    restart: unless-stopped
    ports:
      - "8099:8099"
    volumes:
      - station-data:/data
    environment:
      STATION_AI_URL: http://ollama:11434
      STATION_AI_MODEL: MODEL_NAME
    depends_on:
      - ollama

  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    volumes:
      - ollama-models:/root/.ollama

volumes:
  station-data:
  ollama-models:
YML
  sed -i "s|MODEL_NAME|$MODEL|" docker-compose.yml
  ok "compose file updated (old one saved as docker-compose.yml.bak)"
else
  ok "ollama already in the compose file"
fi

docker compose up -d --build 2>&1 | tail -3

say "3/4  Downloading the model (a few GB — this is the slow part)"
docker exec ollama ollama pull "$MODEL" || die "Model download failed. Check the container has internet."
ok "$MODEL ready"

say "4/4  Checking Station can reach it"
for i in $(seq 1 30); do
  R=$(curl -s http://127.0.0.1:8099/api/ai/status || true)
  if echo "$R" | grep -q '"ok":true'; then ok "connected"; break; fi
  [ "$i" = "30" ] && die "Station can't reach Ollama. Try: docker logs ollama"
  sleep 2
done

IP=$(hostname -I | awk '{print $1}')
cat <<DONE

===================================
  Talk is ready.   http://$IP:8099/talk.html
===================================

  Model: $MODEL   — running on your machine, nothing sent anywhere.

  Slow replies? Give the container more cores:
      pct set 103 --cores 4        (on the Proxmox host)
  Or try a smaller model:
      MODEL=qwen2.5:1.5b bash ai-setup.sh

DONE
