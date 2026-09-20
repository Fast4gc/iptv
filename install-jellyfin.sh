#!/usr/bin/env bash
# Instalador + Configurador Jellyfin para VPS Ubuntu/Debian
# Uso:
#   chmod +x install-jellyfin.sh
#   sudo ./install-jellyfin.sh [--docker|--nativo] [--porta 8096] [--dir-media /media]
#
# O que faz:
#  1. Detecta Ubuntu/Debian
#  2. Instala dependências, ffmpeg, curl, etc.
#  3. Instala Jellyfin (via Docker por padrão, mais isolado e fácil de manter)
#     ou --nativo via repositório oficial
#  4. Cria pastas de mídia, ajusta permissão
#  5. Libera firewall (ufw) 8096/8920, habilita serviço na inicialização
#  6. Cria swap de 2G se RAM < 2GB e não houver swap (evita travamento/OOM)

set -euo pipefail

MODO="--docker"
PORTA="8096"
DIR_MEDIA="/media"
DIR_BASE="/srv/jellyfin"

for arg in "$@"; do
  case "$arg" in
    --docker|--nativo) MODO="$arg" ;;
    --porta=*) PORTA="${arg#*=}" ;;
    --porta) shift ;;
    --dir-media=*) DIR_MEDIA="${arg#*=}" ;;
    --dir-base=*) DIR_BASE="${arg#*=}" ;;
    --help|-h)
      sed -n '1,20p' "$0"
      exit 0
      ;;
  esac
done
# suporte a --porta 8096 separado
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  if [[ "${args[i]}" == "--porta" && $((i+1)) -lt ${#args[@]} ]]; then
    PORTA="${args[i+1]}"
  fi
done

log(){ echo -e "\033[1;32m[+]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $*"; }
err(){ echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Rode com sudo: sudo ./install-jellyfin.sh"
[[ "$PORTA" =~ ^[0-9]+$ ]] || err "Porta inválida: $PORTA"

if [[ ! -f /etc/os-release ]]; then err "SO não identificado (/etc/os-release ausente)."; fi
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" ]] || warn "SO detectado: ${PRETTY_NAME:-desconhecido}. Script testado em Ubuntu/Debian, continuando..."

export DEBIAN_FRONTEND=noninteractive

log "Atualizando apt..."
apt-get update -y
apt-get install -y curl wget gnupg2 lsb-release ca-certificates apt-transport-https software-properties-common ffmpeg htop iotop 2>/dev/null || \
apt-get install -y curl wget gnupg lsb-release ca-certificates apt-transport-https software-properties-common ffmpeg htop

log "Criando pastas de mídia: $DIR_MEDIA/{filmes,series,musicas,fotos} e $DIR_BASE/{config,cache}"
mkdir -p "$DIR_MEDIA"/{filmes,series,musicas,fotos} "$DIR_BASE"/{config,cache}
# usuário jellyfin será criado no modo nativo; no docker usamos o UID/GID atuais
chmod 755 "$DIR_MEDIA" "$DIR_BASE"

# Swap emergencial para VPS pequena (evita OOM/travamento)
MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
SWAP_MB=$(free -m | awk '/^Swap:/{print $2}')
if [[ "$MEM_MB" -lt 2048 && "$SWAP_MB" -eq 0 ]]; then
  log "RAM pequena (${MEM_MB}MB) sem swap. Criando swapfile de 2G..."
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
  sysctl -w vm.swappiness=10 >/dev/null || true
else
  log "Memória: ${MEM_MB}MB RAM / ${SWAP_MB}MB swap — ok."
fi

instalar_docker(){
  if command -v docker >/dev/null 2>&1; then
    log "Docker já instalado: $(docker --version)"
    return
  fi
  log "Instalando Docker (repo oficial)..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  CODENAME=$(lsb_release -cs)
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
}

if [[ "$MODO" == "--docker" ]]; then
  instalar_docker
  log "Subindo Jellyfin via Docker na porta $PORTA..."
  docker run -d \
    --name jellyfin \
    --restart unless-stopped \
    -p ${PORTA}:8096 \
    -v "${DIR_BASE}/config:/config" \
    -v "${DIR_BASE}/cache:/cache" \
    -v "${DIR_MEDIA}:/media:ro" \
    --device /dev/dri:/dev/dri 2>/dev/null || \
  docker run -d \
    --name jellyfin \
    --restart unless-stopped \
    -p ${PORTA}:8096 \
    -v "${DIR_BASE}/config:/config" \
    -v "${DIR_BASE}/cache:/cache" \
    -v "${DIR_MEDIA}:/media:ro" \
    jellyfin/jellyfin:latest

  # se container já existia, apenas garante que está rodando
  docker start jellyfin >/dev/null 2>&1 || true
  systemctl enable docker >/dev/null 2>&1 || true
else
  log "Instalando Jellyfin nativo (repo oficial)..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg
  CODENAME=$(lsb_release -cs)
  # Jellyfin usa o codename do Ubuntu/Debian; bookworm/bullseye/jammy/noble são suportados
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/jellyfin.gpg] https://repo.jellyfin.org/${ID} ${CODENAME} main" > /etc/apt/sources.list.d/jellyfin.list
  apt-get update -y
  apt-get install -y jellyfin
  mkdir -p /var/lib/jellyfin /var/cache/jellyfin
  # aponta biblioteca padrão para DIR_MEDIA via symlink de exemplo
  [[ -e /var/lib/jellyfin/media ]] || ln -s "$DIR_MEDIA" /var/lib/jellyfin/media || true
  chown -R jellyfin:jellyfin "$DIR_MEDIA" "$DIR_BASE" /var/lib/jellyfin /var/cache/jellyfin 2>/dev/null || chown -R jellyfin: "$DIR_MEDIA" 2>/dev/null || true
  # porta custom: edita network.xml se diferente de 8096
  if [[ "$PORTA" != "8096" ]]; then
    warn "Porta custom $PORTA no modo nativo: ajuste em Admin > Rede após o primeiro acesso, ou edite /etc/jellyfin/network.xml"
  fi
  systemctl enable --now jellyfin
  systemctl restart jellyfin || true
fi

# Firewall
if command -v ufw >/dev/null 2>&1; then
  log "Liberando firewall: $PORTA/tcp, 8920/tcp..."
  ufw allow ${PORTA}/tcp >/dev/null 2>&1 || true
  ufw allow 8920/tcp >/dev/null 2>&1 || true
else
  apt-get install -y ufw >/dev/null 2>&1 || true
  ufw allow ${PORTA}/tcp >/dev/null 2>&1 || true
  ufw allow 8920/tcp >/dev/null 2>&1 || true
fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
log "Pronto! Acesse: http://${IP:-SEU-IP}:${PORTA}"
echo ""
echo "Próximos passos:"
echo " 1. Abra http://${IP:-SEU-IP}:${PORTA} e crie o usuário admin"
echo " 2. Adicione bibliotecas apontando para /media/filmes, /media/series, etc."
echo " 3. Coloque seus arquivos em $DIR_MEDIA (ex: $DIR_MEDIA/filmes/MeuFilme.mkv)"
echo " 4. Rode 'sudo ./limpar-vps.sh' para manutenção sem travar a VPS"
