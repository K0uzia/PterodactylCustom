# ptero-stack — Pterodactyl sur Ubuntu 22.04

Scripts pour **installer, configurer, mettre à jour, sauvegarder et désinstaller** via un **menu interactif** :

- **Panel** Pterodactyl (Nginx, PHP, MariaDB, Redis)
- **Wings** + Docker (même VM)
- **Cloudflare Tunnel** (`cloudflared`) — collez la commande d’install (token inclus)
- **playit.gg** (agent natif via [packages.playit.gg](https://packages.playit.gg))

## Démarrage rapide

```bash
# Sur la VM
sudo git clone <URL_DE_CE_REPO> /opt/ptero-stack
cd /opt/ptero-stack
sudo chmod +x ptero-stack.sh
sudo ./ptero-stack.sh deploy-self

# Menu interactif (recommandé)
sudo ptero-stack
```

Sans argument, le script affiche le **menu de gestion**.

## Menu

```
1) Installation complète (guidée)
2) Mettre à jour (backup + panel/wings/CF/playit)
3) Modifier / reconfigurer
4) Sauvegarde
5) État des services
6) Installer un composant seul
7) Déployer ce script dans /opt/ptero-stack
8) Désinstaller (soft)
9) Désinstaller (purge totale)
0) Quitter
```

### Installation guidée (option 1)

Le script demande et enregistre automatiquement :

| Info | Action |
|------|--------|
| Domaine panel | → `config/stack.env` + Nginx + `APP_URL` |
| Timezone, chemins, DB | → `stack.env` (mot de passe généré si vide) |
| Compte admin | → `php artisan p:user:make` non-interactif |
| SMTP (optionnel) | → `.env` Panel |
| Commande Cloudflare | extrait le token de `cloudflared service install eyJ…` |
| config.yml Wings | collage multi-lignes jusqu’à `END` → `/etc/pterodactyl/config.yml` |
| `.env` Panel | copie depuis `.env.example` puis injection auto |

playit : install via `packages.playit.gg`, puis claim agent (lien affiché).

### Modifier (option 3)

Sous-menu pour changer domaine/DB, réappliquer Nginx, retaper la commande Cloudflare, coller un nouveau `config.yml`, ou créer un admin.

## Cloudflare — coller la commande complète

Dans Zero Trust → Tunnels, Cloudflare affiche par exemple :

```bash
sudo cloudflared service install eyJhIjoiXXXXXXXX....
```

Collez **toute la ligne** (ou le token seul) : le script extrait le token et lance `cloudflared service install`.

Public hostname attendu : `PANEL_DOMAIN` → `http://127.0.0.1:80`.

## Wings — coller le YAML

Après création du node dans le panel :

1. Admin → Nodes → Configuration  
2. Collez le YAML dans le script  
3. Terminez par une ligne : `END`

FQDN recommandé sur la même VM : `127.0.0.1`, ports `8080` / `2022`.

## Commandes CLI (sans menu)

```bash
sudo ptero-stack menu
sudo ptero-stack install          # = wizard guidé
sudo ptero-stack update
sudo ptero-stack backup
sudo ptero-stack status
sudo ptero-stack configure tunnel
sudo ptero-stack uninstall [--purge]
sudo ptero-stack deploy-self
```

## Architecture

```
Internet
  ├─ Admins ──HTTPS──► Cloudflare Tunnel ──► Panel (127.0.0.1:80)
  └─ Joueurs ─TCP/UDP─► playit.gg ──► ports Wings sur la VM
```

## playit

À l’inscription : agent **Linux / PC** (pas Docker, pas third-party).  
Tunnels vers `127.0.0.1:<port_allocation_Pterodactyl>`.

## Structure

```
ptero-stack.sh
lib/common.sh | panel.sh | wings.sh | cloudflare.sh | playit.sh
lib/backup.sh | wizard.sh | menu.sh
config/stack.env.example
templates/nginx-pterodactyl.conf | pteroq.service
README.md
```

Mise à jour des scripts : `cd /opt/ptero-stack && sudo git pull` puis `sudo ptero-stack`.
