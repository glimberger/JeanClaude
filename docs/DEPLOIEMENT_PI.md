# Déployer le bot sur un Raspberry Pi

Ce document décrit l'installation du bot Telegram sur un Raspberry Pi pour qu'il tourne en
permanence, telle qu'elle a été faite pour ce projet. Tous les chiffres ont été mesurés sur
un **Raspberry Pi 5 avec 8 Go de RAM** et une carte microSD de 128 Go, avec Claude comme
modèle de langage.

On installe le Pi **sans écran ni clavier** : tout se fait depuis ton ordinateur, par **SSH**
(un accès en ligne de commande à distance, chiffré).

---

## 1. Matériel

- Un Raspberry Pi 5 (8 Go conseillés : le bot utilise environ 1,1 Go de mémoire).
- Une carte microSD (au moins 16 Go ; sur ce Pi, système et projet compris, 5,7 Go sont
  utilisés après avoir vidé le cache de `uv`, voir l'étape 6).
- L'alimentation officielle 27 W (USB-C, 5 V / 5 A). Avec un chargeur plus faible, le Pi 5
  limite le courant de ses ports USB et peut ralentir.
- Un câble Ethernet si possible : plus fiable que le Wi-Fi pour un bot allumé en permanence.

---

## 2. Préparer la carte SD

Tout se fait avec **Raspberry Pi Imager**, qui efface et prépare la carte lui-même (inutile
de la formater avant) :

```bash
brew install --cask raspberry-pi-imager   # sur Mac ; sinon : raspberrypi.com/software
```

Dans Imager, choisis :

- **Appareil** : Raspberry Pi 5 ;
- **Système** : *Raspberry Pi OS (other)* → **Raspberry Pi OS Lite (64-bit)**. « Lite » = sans
  bureau graphique, inutile ici, ce qui laisse la mémoire au bot. « 64-bit » est obligatoire :
  PyTorch n'existe pas pour les systèmes ARM 32 bits ;
- **Stockage** : ta carte (vérifie bien que ce n'est pas un autre disque).

Puis **Modifier les réglages** :

- **Nom d'hôte** : par exemple `agent-pi`. Le Pi sera joignable à l'adresse `agent-pi.local` ;
- **Nom d'utilisateur** et mot de passe ;
- **Wi-Fi** (nom du réseau, mot de passe, pays `FR`), sauf si tu branches un câble Ethernet ;
- **Fuseau horaire** et clavier ;
- **Services** : active SSH avec **« Autoriser uniquement l'authentification par clé
  publique »**, et colle la clé publique créée à l'étape suivante.

---

## 3. Une clé SSH dédiée au Pi

Une **clé SSH** est une paire de fichiers : une clé privée, qui reste sur ton ordinateur, et
une clé publique, que tu donnes au Pi. Le Pi n'accepte que la personne qui détient la clé
privée : pas de mot de passe à deviner. Une clé **dédiée** au Pi se révoque sans toucher à
tes autres accès (GitHub, serveurs…).

Dans ton terminal (la commande demande une phrase de passe, qui chiffre la clé privée sur
ton disque) :

```bash
ssh-keygen -t ed25519 -f ~/.ssh/agent-pi -C "agent-pi"
ssh-add --apple-use-keychain ~/.ssh/agent-pi   # sur Mac : phrase de passe gardée dans le trousseau
cat ~/.ssh/agent-pi.pub                        # la clé publique, à coller dans Imager
```

Ajoute ensuite une entrée dans `~/.ssh/config`, pour te connecter avec un simple
`ssh agent-pi` :

```
Host agent-pi
  HostName agent-pi.local
  User <ton-utilisateur>
  IdentityFile ~/.ssh/agent-pi
  IdentitiesOnly yes
  AddKeysToAgent yes
  UseKeychain yes
```

`IdentitiesOnly yes` fait que seule cette clé est présentée au Pi. `HostName` doit
correspondre au nom d'hôte **réellement** configuré dans Imager, suivi de `.local`.

---

## 4. Premier démarrage et connexion

Insère la carte, branche l'alimentation, et attends **2 à 5 minutes** : au premier démarrage,
le Pi agrandit sa partition puis redémarre. Ensuite :

```bash
ssh -o StrictHostKeyChecking=accept-new agent-pi
```

À la première connexion, SSH enregistre l'« empreinte » du Pi (un identifiant qui prouve que
c'est bien lui). `accept-new` l'accepte cette fois-ci, et SSH refusera la connexion si elle
change un jour, ce qui pourrait signaler une usurpation.

**Si le nom `agent-pi.local` est introuvable** :

- le Pi n'a peut-être pas fini de démarrer, ou n'est pas sur le réseau (erreur de mot de
  passe Wi-Fi : le câble Ethernet évite ce problème) ;
- il a peut-être un autre nom : sur ce projet, Imager avait enregistré `ai-pi` au lieu du nom
  voulu. La page d'administration de ta box (souvent <http://192.168.1.1>) liste les appareils
  connectés et leur nom. Mets le bon nom dans `HostName`, puis renomme le Pi à l'étape 5 si
  tu veux.

---

## 5. Mettre le système à jour

Sur les versions récentes de Raspberry Pi OS (celle utilisée ici est basée sur Debian 13,
« trixie »), `sudo` demande le mot de passe de l'utilisateur. Lance donc ces commandes depuis
**ton terminal**, avec `ssh -t` : le `-t` ouvre une session interactive où `sudo` peut te
demander ce mot de passe.

```bash
ssh -t agent-pi '
sudo apt update && sudo apt full-upgrade -y &&
sudo apt install -y git &&
sudo loginctl enable-linger $USER'
```

- `apt update && apt full-upgrade` : met à jour tous les paquets (correctifs de sécurité) ;
- `apt install git` : pour récupérer le projet ;
- `loginctl enable-linger` : autorise tes services **utilisateur** (voir étape 9) à démarrer
  avec le Pi, sans que tu sois connecté. C'est la dernière commande qui demande `sudo`.

**Renommer le Pi** (facultatif), dans la même session :

```bash
sudo hostnamectl set-hostname agent-pi
sudo sed -i "s/^127\.0\.1\.1\s.*/127.0.1.1\tagent-pi/" /etc/hosts
sudo systemctl restart avahi-daemon
```

La 2e ligne met à jour le fichier où le Pi associe son propre nom à son adresse (sans elle,
`sudo` afficherait « unable to resolve host »). **Avahi** est le service qui annonce le nom
`xxx.local` sur le réseau : on le relance pour qu'il annonce le nouveau nom. Pense à mettre à
jour `HostName` dans `~/.ssh/config`.

---

## 6. Installer uv et le projet

`uv` s'installe dans ton dossier personnel, sans `sudo`, puis installe lui-même le Python
dont le projet a besoin :

```bash
ssh agent-pi
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.local/bin/env        # ajoute ~/.local/bin au PATH dans cette session

mkdir -p ~/projects && cd ~/projects
git clone https://github.com/glimberger/JeanClaude.git
cd JeanClaude
uv sync                        # environnement Python et dépendances (~1,3 Go)
uv run jcvd ingest && uv run jcvd index
uv run jcvd eval               # doit donner les mêmes scores que sur ton ordinateur
```

Le dépôt étant public, le Pi le clone en HTTPS : il n'a besoin d'aucun accès à ton compte
GitHub. `jcvd index` télécharge le modèle d'embeddings (quelques centaines de Mo) à son
premier lancement : **47 s** au total sur le Pi. `jcvd eval` y donne exactement les mêmes
scores que sur le Mac de développement.

### PyTorch : la version CPU, pas la version CUDA

Sur Linux ARM, le PyTorch du dépôt de paquets par défaut (PyPI) est compilé pour les cartes
graphiques NVIDIA (**CUDA**) et embarque plusieurs Go de bibliothèques inutiles sur un Pi.
`pyproject.toml` indique donc à `uv` de prendre, **sur Linux uniquement**, la version « CPU »
publiée par PyTorch (section `[tool.uv.sources]`). Mesuré sur le Pi :

| | PyTorch CUDA | PyTorch CPU (choix du projet) |
|---|---|---|
| Taille de `.venv` | 5,6 Go | **1,3 Go** |
| Mémoire maximale (chargement + recherches) | 1 497 Mo | **1 155 Mo** |
| Une recherche | 60 ms | 60 ms |

Sur Mac, la question ne se pose pas : le PyTorch par défaut n'y contient pas CUDA.

### Place occupée

Mesuré sur le Pi : le dossier du projet occupe 1,3 Go (presque tout pour `.venv`), le modèle
d'embeddings 458 Mo (dans `~/.cache/huggingface`), et le **cache de `uv`** 5,0 Go. Ce cache
garde une copie des paquets téléchargés, pour réinstaller sans rien retélécharger ; ici, il
contenait encore la version CUDA de PyTorch installée lors d'un premier essai. Tu peux le vider
sans risque (ici, 5,0 Go libérés : la carte est passée de 11 Go à 5,7 Go utilisés) :

```bash
systemctl --user stop jcvd-bot     # si le service est déjà installé (étape 9)
uv cache clean                     # la prochaine réinstallation complète retéléchargera les paquets
systemctl --user start jcvd-bot
```

Arrête d'abord le bot : `uv run`, qui le fait tourner, verrouille le cache pour qu'on ne
supprime pas des fichiers en cours d'utilisation. Sinon, `uv cache clean` attend
indéfiniment que ce verrou se libère.

### Déplacer le projet ? Recrée `.venv`

`.venv` contient des **chemins absolus** (vers le Python de l'environnement et vers le
projet). Si tu déplaces le dossier du projet, supprime-le et recrée-le :

```bash
rm -rf .venv && uv sync        # 2 s : les paquets sont déjà dans le cache de uv
```

---

## 7. Copier les secrets

Le fichier `.env` (clés et token, voir [`.env.example`](../.env.example)) n'est pas sur
GitHub, et c'est voulu. Copie-le depuis ton ordinateur :

```bash
ssh agent-pi 'umask 077; cat > ~/projects/JeanClaude/.env' < .env
```

`umask 077` fait que le fichier est créé directement avec des droits réservés à ton
utilisateur (`-rw-------`), sans instant où il serait lisible par d'autres. `HF_HUB_OFFLINE=1`
convient au Pi, puisque le modèle d'embeddings y est déjà téléchargé.

**Arrête le bot sur ton ordinateur** s'il tourne : Telegram n'accepte qu'un programme à la
fois par bot (voir le README, [erreur « Une autre instance du bot
tourne déjà »](../README.md#étape-4--brancher-le-bot-sur-telegram-jcvd-telegram-telegram_apppy)).

Test de bout en bout, depuis le Pi :

```bash
uv run --env-file .env jcvd ask "J'ai peur d'échouer"
```

Mesuré : **6,8 s** pour la réponse complète (recherche des citations comprise), comme sur le
Mac. C'est Claude qui fait l'essentiel du travail, pas le Pi.

---

## 8. Pourquoi un service

Lancer `jcvd telegram` dans un terminal ne suffit pas : le bot s'arrête dès que tu fermes la
session, et il ne redémarre ni après une coupure de courant ni après un plantage. On le confie
donc à **systemd**, le gestionnaire de services de Linux, qui démarre les programmes au boot,
les relance s'ils plantent et collecte leurs logs.

Le fichier [`deploy/jcvd-bot.service`](../deploy/jcvd-bot.service) décrit le service
(chaque ligne y est commentée). C'est un **service utilisateur** : il tourne sous ton compte,
sans droits administrateur, et se gère sans `sudo`. Il :

- lance `uv run --frozen --env-file .env jcvd telegram` depuis le dossier du projet
  (`--frozen` : utilise `uv.lock` tel quel, sans jamais le modifier) ;
- relance le bot 10 s après un plantage (`Restart=on-failure`). Si le réseau n'est pas prêt
  au démarrage, le bot s'arrête faute de joindre Telegram, et c'est cette relance qui fait la
  suite ;
- démarre avec le Pi, grâce au réglage « linger » de l'étape 5.

---

## 9. Installer et gérer le service

Si ton Pi est géré avec Nix et home-manager, installe plutôt le service avec le module de la
[section 12](#12-variante-avec-nix-et-home-manager) ; les commandes utiles ci-dessous restent
les mêmes.

```bash
ssh agent-pi
systemctl --user enable --now ~/projects/JeanClaude/deploy/jcvd-bot.service
```

`enable` crée un lien vers le fichier du dépôt (il sera donc à jour après un `git pull`) et
active le démarrage au boot ; `--now` le démarre tout de suite.

Commandes utiles :

```bash
systemctl --user status jcvd-bot       # état du service
systemctl --user restart jcvd-bot      # redémarrer le bot
systemctl --user stop jcvd-bot         # l'arrêter (par exemple pour tester sur ton ordinateur)
journalctl --user-unit jcvd-bot -f     # suivre les logs en direct (Ctrl+C pour quitter)
```

**Attention à la commande des logs** : `journalctl --user -u jcvd-bot` ne trouve rien ici,
car les logs des services utilisateur arrivent dans le journal du système. `--user-unit` les
y retrouve ; ton compte y a accès parce qu'il fait partie du groupe `adm`.

Le service ajoute deux variables : `PYTHONUNBUFFERED=1` (les logs arrivent tout de suite dans
le journal, au lieu d'attendre en mémoire tampon) et `TQDM_DISABLE=1` (pas de barre de
progression au chargement du modèle, qui apparaîtrait comme une ligne illisible
`[146B blob data]`).

Pour le mode debug, ajoute `JCVD_DEBUG=1` dans `.env` puis redémarre le service (voir le
README, [Mode debug](../README.md#mode-debug)).

---

## 10. Mettre à jour le bot

```bash
ssh agent-pi
cd ~/projects/JeanClaude
git pull
uv run jcvd ingest && uv run jcvd index   # seulement si les citations ont changé
systemctl --user restart jcvd-bot
```

`uv run` remet l'environnement à jour tout seul si `uv.lock` a changé.

---

## 11. Mesures sur le Pi

| | Raspberry Pi 5 (8 Go) |
|---|---|
| Du boot au bot prêt | 26 s (service lancé 8 s après le boot, prêt 18 s plus tard) |
| Chargement du modèle d'embeddings | 10,5 à 16,5 s selon les essais |
| Une recherche de citations | 60 ms (6 ms sur un Mac M5) |
| Réponse complète avec Claude | 6,8 s |
| Mémoire du bot en service | environ 1,1 Go (6,7 Go restent libres) |
| Environnement Python (`.venv`) | 1,3 Go (+ 458 Mo pour le modèle d'embeddings) |
| Température | 47 à 49 °C, aucun ralentissement (`vcgencmd get_throttled` = `0x0`) |

Avec Ollama sur le Pi (`LLM_BACKEND=ollama`), la réponse serait générée par le Pi lui-même :
ce cas n'a pas encore été mesuré. Les modèles testés sur Mac et leurs limites sont décrits
dans le README, [Choisir le modèle de
langage](../README.md#choisir-le-modèle-de-langage--claude-ou-ollama).

---

## 12. Variante avec Nix et home-manager

Cette section ne te concerne que si tu gères déjà ton Pi avec **Nix** (un gestionnaire de
paquets qui décrit un environnement dans des fichiers texte) et **home-manager** (l'outil Nix
qui décrit l'environnement d'un utilisateur : programmes, fichiers de configuration,
services). C'est le cas du Pi de ce projet.

Au lieu d'activer `deploy/jcvd-bot.service` à la main (étape 9), tu déclares le service dans
ta configuration home-manager. Le fichier [`deploy/jcvd-bot.nix`](../deploy/jcvd-bot.nix)
est un **module** home-manager : il décrit le même service que `deploy/jcvd-bot.service`,
et home-manager se charge de l'écrire, de l'activer au démarrage et de le relancer quand sa
définition change.

Le module ne remplace que la partie systemd. Le bot tourne toujours depuis le dépôt cloné,
avec son `.venv` et son `.env` : les étapes 1 à 7 restent nécessaires, réglage « linger » de
l'étape 5 compris.

### Importer le module

Dans le `flake.nix` de ta configuration, ajoute le dépôt en entrée. `flake = false` : on veut
seulement ses fichiers, pas un flake.

```nix
inputs.jeanclaude = {
  url = "github:glimberger/JeanClaude";
  flake = false;
};
```

Puis, dans les modules de la configuration home-manager du Pi :

```nix
modules = [
  # … tes autres modules
  "${jeanclaude}/deploy/jcvd-bot.nix"
];
```

Et dans la configuration du Pi :

```nix
services.jcvd-bot.enable = true;
```

| Option | Par défaut | Rôle |
|---|---|---|
| `services.jcvd-bot.enable` | `false` | active le service |
| `services.jcvd-bot.directory` | `%h/projects/JeanClaude` | dossier du dépôt cloné (`%h` : ton dossier personnel) |
| `services.jcvd-bot.package` | `pkgs.uv` | le `uv` qui lance le bot |

### Passer du service manuel au module

Si tu as suivi l'étape 9, désactive d'abord l'ancien service : son lien dans
`~/.config/systemd/user/` gênerait home-manager, qui veut y écrire son propre fichier.

```bash
systemctl --user disable --now jcvd-bot
home-manager switch --flake <ta-configuration>
```

Le bot est arrêté entre ces deux commandes. Pour réduire cette coupure, construis d'abord la
configuration (`home-manager build --flake <ta-configuration>`) : le `switch` n'a plus alors
qu'à l'activer. Mesuré sur ce Pi : **5 s** de coupure.

Les commandes de l'étape 9 (`status`, `restart`, logs) et la mise à jour du bot (étape 10)
ne changent pas.

### Mettre à jour le module

Ta configuration fige la version du dépôt dans son `flake.lock`. Après une modification de
`deploy/jcvd-bot.nix`, un `git pull` du projet ne suffit pas : mets à jour l'entrée dans ta
configuration, puis applique-la.

```bash
nix flake update jeanclaude
home-manager switch --flake <ta-configuration>
```
