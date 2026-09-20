#!/usr/bin/env bash
# Instalador tudo-em-um: Jellyfin + limpeza opcional
# Uso local:
#   chmod +x instalar-tudo.sh
#   sudo ./instalar-tudo.sh
#
# Uso via wget (após dar push no GitHub, troque a URL):
#   wget -qO instalar-tudo.sh https://raw.githubusercontent.com/SEU-USUARIO/SEU-REPO/main/instalar-tudo.sh
#   chmod +x instalar-tudo.sh
#   sudo ./instalar-tudo.sh
#
# Ou direto em uma linha:
#   wget -qO- https://raw.githubusercontent.com/SEU-USUARIO/SEU-REPO/main/instalar-tudo.sh | sudo bash

set -euo pipefail

PORTA="8096"
DIR_MEDIA="/media"
DIR_BASE="/srv/jellyfin"
LOGS_DIAS=7

log(){ echo -e "\033[1;32m[+]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $*"; }
err(){ echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

# pergunta S/n com default. Uso: if perguntar "Texto?" "S"; then ...
perguntar(){
  local texto="$1" default="${2:-N}" resp
  local hint="[s/N]"
  [[ "$default" == "S" ]] && hint="[S/n]"
  if [[ ! -t 0 ]]; then
    # sem TTY (ex: wget | bash): usa o default
    [[ "$default" == "S" ]]
    return
  fi
  read -r -p "$texto $hint: " resp || resp=""
  resp="${resp:-$default}"
  [[ "$resp" =~ ^[sSyY] ]]
}

[[ $EUID -eq 0 ]] || err "Rode com sudo: sudo ./instalar-tudo.sh"
source /etc/os-release 2>/dev/null || err "SO não identificado."
[[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" ]] || warn "SO: ${PRETTY_NAME:-desconhecido}. Testado em Ubuntu/Debian, continuando..."
export DEBIAN_FRONTEND=noninteractive

fazer_swap(){
  local mem swap
  mem=$(free -m | awk '/^Mem:/{print $2}')
  swap=$(free -m | awk '/^Swap:/{print $2}')
  if [[ "$mem" -lt 2048 && "$swap" -eq 0 ]]; then
    log "RAM pequena (${mem}MB) sem swap. Criando swapfile 2G..."
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile
    grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
  fi
}

instalar_docker(){
  command -v docker >/dev/null 2>&1 && { log "Docker já instalado."; return; }
  log "Instalando Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
}

instalar_jellyfin(){
  local modo="$1"
  log "Atualizando apt + dependências..."
  apt-get update -y
  apt-get install -y curl wget gnupg lsb-release ca-certificates apt-transport-https software-properties-common ffmpeg htop ufw 2>/dev/null || \
  apt-get install -y curl wget gnupg2 lsb-release ca-certificates apt-transport-https ffmpeg htop ufw

  mkdir -p "$DIR_MEDIA"/{filmes,series,musicas,fotos} "$DIR_BASE"/{config,cache}
  chmod 755 "$DIR_MEDIA" "$DIR_BASE"
  fazer_swap

  if [[ "$modo" == "docker" ]]; then
    instalar_docker
    log "Subindo Jellyfin (Docker) na porta $PORTA..."
    if docker ps -a --format '{{.Names}}' | grep -qx jellyfin; then
      docker start jellyfin >/dev/null 2>&1 || true
    else
      docker run -d --name jellyfin --restart unless-stopped \
        -p ${PORTA}:8096 \
        -v "${DIR_BASE}/config:/config" -v "${DIR_BASE}/cache:/cache" \
        -v "${DIR_MEDIA}:/media:ro" \
        jellyfin/jellyfin:latest
    fi
  else
    log "Instalando Jellyfin nativo..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/jellyfin.gpg] https://repo.jellyfin.org/${ID} $(lsb_release -cs) main" > /etc/apt/sources.list.d/jellyfin.list
    apt-get update -y
    apt-get install -y jellyfin
    [[ -e /var/lib/jellyfin/media ]] || ln -s "$DIR_MEDIA" /var/lib/jellyfin/media || true
    chown -R jellyfin:jellyfin "$DIR_MEDIA" 2>/dev/null || true
    systemctl enable --now jellyfin
  fi

  ufw allow ${PORTA}/tcp >/dev/null 2>&1 || true
  ufw allow 8920/tcp >/dev/null 2>&1 || true
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  log "Jellyfin pronto: http://${ip:-SEU-IP}:${PORTA}"
}

limpar_vps(){
  local com_docker="$1"
  echo "===== ANTES ====="; df -h / | tail -1; free -h; echo "================="
  log "apt autoremove/autoclean..."
  apt-get autoremove -y || true; apt-get autoclean -y || true
  log "Logs (mantendo ${LOGS_DIAS} dias)..."
  journalctl --vacuum-time=${LOGS_DIAS}d 2>/dev/null || true
  journalctl --vacuum-size=500M 2>/dev/null || true
  find /var/log -type f -name "*.log" -size +100M -exec truncate -s 0 {} \; 2>/dev/null || true
  log "Tmp/cache antigo..."
  find /tmp /var/tmp -xdev -type f -atime +7 -delete 2>/dev/null || true
  rm -rf /root/.cache/* /home/*/.cache/* 2>/dev/null || true
  if [[ "$com_docker" == "sim" ]] && command -v docker >/dev/null 2>&1; then
    log "Docker prune (só parados)..."
    docker container prune -f >/dev/null 2>&1 || true
    docker image prune -af --filter "until=168h" >/dev/null 2>&1 || true
  fi
  sync; echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
  echo "===== DEPOIS ====="; df -h / | tail -1; free -h
  log "Limpeza concluída."
}

# ============ FLUXO ============
echo "=== Instalador Jellyfin + Limpeza ==="
echo ""

if perguntar "1) Instalar/configurar o Jellyfin?" "S"; then
  echo "Modo: [1] Docker (recomendado)  [2] Nativo apt"
  read -r -p "Escolha [1]: " escolha || escolha=""
  escolha="${escolha:-1}"
  if [[ "$escolha" == "2" ]]; then
    instalar_jellyfin "nativo"
  else
    instalar_jellyfin "docker"
  fi
else
  log "Instalação do Jellyfin pulada."
fi

echo ""
if perguntar "2) Fazer limpeza da VPS agora? (libera disco/RAM sem apagar midia)" "N"; then
  if perguntar "   Incluir prune do Docker (só imagens paradas)?" "N"; then
    limpar_vps "sim"
  else
    limpar_vps "nao"
  fi
else
  log "Limpeza pulada."
fi

echo ""
log "Concluído."
