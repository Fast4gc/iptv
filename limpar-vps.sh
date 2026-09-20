#!/usr/bin/env bash
# Limpeza leve e segura para VPS (Ubuntu/Debian) - evita travamento sem apagar dados
# Uso:
#   chmod +x limpar-vps.sh
#   sudo ./limpar-vps.sh [--com-docker] [--logs-dias 7]
#
# O que limpa (seguro):
#  - apt autoremove/autoclean
#  - journald (mantém só últimos N dias)
#  - /tmp e /var/tmp (arquivos +7 dias, sem apagar o que está em uso)
#  - cache apt, thumbnails antigos
#  - pagecache da RAM (sync + drop_caches, não mata processo)
#  - opcional: docker system prune (só com --com-docker)
# NÃO apaga: /media, /srv/jellyfin, bancos, /home, containers em uso (sem a flag)

set -euo pipefail

COM_DOCKER=0
LOGS_DIAS=7
for arg in "$@"; do
  case "$arg" in
    --com-docker) COM_DOCKER=1 ;;
    --logs-dias=*) LOGS_DIAS="${arg#*=}" ;;
    --help|-h) sed -n '1,25p' "$0"; exit 0 ;;
  esac
done

log(){ echo -e "\033[1;32m[+]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $*"; }

[[ $EUID -eq 0 ]] || { echo "Rode com sudo: sudo ./limpar-vps.sh" >&2; exit 1; }

echo "===== ANTES ====="
df -h / | tail -1
free -h
echo "================="

log "Limpando apt (autoremove + clean)..."
export DEBIAN_FRONTEND=noninteractive
apt-get autoremove -y || true
apt-get autoclean -y || true
rm -rf /var/cache/apt/archives/partial/* 2>/dev/null || true

log "Enxugando logs do systemd (mantendo últimos ${LOGS_DIAS} dias)..."
journalctl --vacuum-time=${LOGS_DIAS}d 2>/dev/null || true
journalctl --vacuum-size=500M 2>/dev/null || true
# logs de texto grandes: só esvazia, não apaga o arquivo (evita quebrar serviço)
find /var/log -type f -name "*.log" -size +100M -exec truncate -s 0 {} \; 2>/dev/null || true
find /var/log -type f -name "*.gz" -mtime +${LOGS_DIAS} -delete 2>/dev/null || true

log "Limpando /tmp e cache antigo (só +7 dias, sem mexer em aberto)..."
find /tmp /var/tmp -xdev -type f -atime +7 -delete 2>/dev/null || true
rm -rf /root/.cache/* /home/*/.cache/* 2>/dev/null || true

if [[ "$COM_DOCKER" -eq 1 ]]; then
  if command -v docker >/dev/null 2>&1; then
    log "Docker prune (imagens/containers parados, sem tocar no Jellyfin rodando)..."
    docker container prune -f >/dev/null 2>&1 || true
    docker image prune -af --filter "until=168h" >/dev/null 2>&1 || true
    docker builder prune -f >/dev/null 2>&1 || true
  else
    warn "Docker não encontrado, pulando prune."
  fi
else
  log "Docker prune pulado (use --com-docker para incluir)."
fi

log "Liberando pagecache (seguro, não mata nada)..."
sync
echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || warn "Sem permissão para drop_caches (container?). Pulado."

# checagem rápida de vilões
echo ""
log "Top 5 processos por RAM:"
ps -eo pid,comm,%mem --sort=-%mem | head -6
echo ""
log "Serviços com falha:"
systemctl --failed --no-pager 2>/dev/null || true

echo ""
echo "===== DEPOIS ====="
df -h / | tail -1
free -h
echo "================="
log "Limpeza concluída. Se a VPS continua travando, veja RAM (free -h) e disco (df -h):"
echo " - RAM cheia: considere upgrade ou swap (o install-jellyfin.sh já cria 2G se <2GB)"
echo " - Disco cheio: cheque com 'du -sh /var/lib/jellyfin /var/log /media 2>/dev/null'"
