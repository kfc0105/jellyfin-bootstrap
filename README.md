# Jellyfin stack bootstrap

This folder starts a home media server and the apps that feed it:

- **Jellyfin** plays your movies and shows.
- **Radarr** and **Sonarr** keep movie and series folders organized.
- **Bazarr** handles subtitles.
- **Seerr** is the request page.
- **qBittorrent** downloads files, and **Prowlarr** keeps indexer settings in one place.
- **Gluetun** puts qBittorrent and Prowlarr on a ProtonVPN WireGuard tunnel.

How the pieces connect, and the security notes, are in [docs/TECHNICAL.md](docs/TECHNICAL.md).

You need a computer that can run Docker, and a ProtonVPN account if you want downloads to go through the VPN. Jellyfin itself starts without the VPN.

## 1. Install Docker

On Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2
sudo usermod -aG docker "$USER"
```

Log out and back in so the group change applies. Then check:

```bash
docker info
docker compose version
```

Both commands should print information instead of a permission error.

## 2. Start the stack

From this folder:

```bash
./bootstrap.sh
```

The script creates `config/` and `media/`, writes `.env`, generates a qBittorrent password, and starts Jellyfin, Sonarr, Radarr, Bazarr, and Seerr.

Leave the WireGuard line empty for this first start. qBittorrent and Prowlarr stay off until that key is set.

## 3. Add the ProtonVPN key

1. Open <https://account.proton.me/u/0/vpn/WireGuard> and create a WireGuard config.
2. Copy the `PrivateKey` value.
3. Put it in `.env`:

```bash
WIREGUARD_PRIVATE_KEY=paste-the-private-key-here
```

4. Run `./bootstrap.sh` again.

One key works for every Proton server. `VPN_SERVER_COUNTRIES` in `.env` chooses the country (the default is `United States`).

The script prints the qBittorrent username and password. They are also stored in `.env`.

## 4. Open the web pages

Use the addresses `./bootstrap.sh` prints. From the server itself they look like this:

| App | Address |
| --- | --- |
| Jellyfin | http://127.0.0.1:8096 |
| Sonarr | http://127.0.0.1:8989 |
| Radarr | http://127.0.0.1:7878 |
| Bazarr | http://127.0.0.1:6767 |
| Seerr | http://127.0.0.1:5055 |
| qBittorrent | http://127.0.0.1:8090 |
| Prowlarr | http://127.0.0.1:9696 |

From another computer on your home network, replace `127.0.0.1` with this server's LAN address.

Finish each app's first-run wizard.

In Jellyfin:

1. Create the admin user and a long password.
2. Add a movie library at `/media/movies`.
3. Add a show library at `/media/series`.

Those paths are inside the container. On the server, the same folders are `media/movies` and `media/series` next to this README.

## 5. Connect the apps

After the VPN profile is up and the wizards are finished:

```bash
./scripts/wire-apps.sh
```

That registers Sonarr and Radarr in Prowlarr, and adds qBittorrent as their download client. It does not add indexers. Add those in Prowlarr yourself. Prowlarr can then sync them to Sonarr and Radarr.

Put movie files in `media/movies` and episode files in `media/series`. Downloads land in `media/downloads`, and Sonarr or Radarr move finished files into the library folders.

In Seerr, connect Jellyfin, Sonarr, and Radarr with the API keys shown in each app's settings. Seerr's own wizard is where that connection is made.

## 6. Day to day

Start or refresh everything:

```bash
./bootstrap.sh
```

Watch the tunnel:

```bash
docker compose --profile vpn logs gluetun
```

Stop everything, including the VPN containers:

```bash
docker compose --profile vpn down
```

## If this fails

**The script says there is no WireGuard key.** Jellyfin and the library apps are still running. Paste the key into `.env` and run `./bootstrap.sh` again.

**A port is already in use.** Another program is using 8096, 8989, or one of the other ports. Stop that program, or change the matching `*_PORT` value in `.env`, then run `./bootstrap.sh` again. qBittorrent is special: `QBITTORRENT_PORT` is both the published port and the port it listens on. Keep those as one number.

**qBittorrent or Prowlarr will not load.** They share the VPN container's network. Until the tunnel has an address, those pages do not answer. Give it a minute, then check `docker compose --profile vpn logs gluetun`. A WireGuard key that is already connected somewhere else gets dropped by Proton when this server connects.

**Jellyfin cannot see new files.** Confirm the files are under `media/movies` or `media/series`, then use Jellyfin's "Scan Media Library" on that library.
