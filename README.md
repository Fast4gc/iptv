# Jellyfin na VPS + Limpeza

Scripts testados em **Ubuntu 20.04/22.04/24.04** e **Debian 11/12**.

## 1. Enviar para a VPS

```powershell
scp E:\iptv\install-jellyfin.sh E:\iptv\limpar-vps.sh root@SEU-IP:/root/
```

## 2. Na VPS

```bash
chmod +x install-jellyfin.sh limpar-vps.sh
# se veio do Windows com erro $'\r': rode uma vez
sed -i 's/\r$//' install-jellyfin.sh limpar-vps.sh

# padrão (recomendado): Jellyfin via Docker
sudo ./install-jellyfin.sh

# ou nativo via apt:
sudo ./install-jellyfin.sh --nativo

# porta e pasta custom:
sudo ./install-jellyfin.sh --docker --porta 8096 --dir-media /media
```

Acesse `http://SEU-IP:8096`, crie o admin e aponte as bibliotecas para `/media/filmes`, `/media/series`.

Pastas criadas:

- `/media/{filmes,series,musicas,fotos}`
- `/srv/jellyfin/{config,cache}` (modo docker)

## 3. Limpeza leve (não trava, não apaga mídia)

```bash
# limpeza segura
sudo ./limpar-vps.sh

# incluindo prune do Docker
sudo ./limpar-vps.sh --com-docker
```

Rode 1x por semana ou via cron:

```bash
(crontab -l; echo "0 4 * * 0 /root/limpar-vps.sh >> /var/log/limpeza-vps.log 2>&1") | crontab -
```

## Notas

- O instalador cria swap de 2G automaticamente se a VPS tiver <2GB RAM e nenhum swap (causa nº1 de travamento do Jellyfin com transcode).
- Para transcode pesado, VPS com 2+ vCPU e 4GB RAM é o mínimo confortável.
- Não rode `rm -rf /var/lib/*`, `docker system prune -a` sem filtro ou `echo 3 > drop_caches` sob carga — isso sim trava a VPS.
