# JCVD Bot — un RAG pédagogique

Un bot conversationnel qui répond dans le style de Jean-Claude Van Damme en s'appuyant sur
ses vraies citations. Le projet sert à comprendre, pas à pas, le pattern **RAG**
(*Retrieval-Augmented Generation*) : chercher des passages pertinents dans une base de textes,
puis les donner à un LLM pour qu'il s'en inspire.

**Tu ne connais pas le RAG ?** Commence par [docs/GUIDE_RAG.md](docs/GUIDE_RAG.md) : il explique les
concepts depuis zéro, avec des exemples tirés de ce projet. Ce README sert ensuite de référence.

## Installation

```bash
brew install uv          # ou : curl -LsSf https://astral.sh/uv/install.sh | sh
uv sync                  # crée .venv/, installe les dépendances et la commande `jcvd`
export ANTHROPIC_API_KEY="sk-ant-..."   # à partir de l'étape 3b, sauf avec Ollama (voir plus bas)
```

`uv run <commande>` exécute une commande dans l'environnement du projet, sans avoir à
l'activer (`source .venv/bin/activate` reste possible si tu préfères taper `jcvd` directement).

Pourquoi un environnement virtuel (`.venv/`) ? Pour que les versions des librairies de ce
projet n'entrent pas en conflit avec celles d'autres projets Python de ta machine.

Au premier lancement, le modèle d'embeddings (quelques centaines de Mo) est téléchargé automatiquement.

### Option : avec Nix

Si tu utilises [Nix](https://nixos.org), le dépôt fournit un environnement de développement
(`flake.nix`) avec Python et uv, aux versions figées dans `flake.lock` : rien à installer avec
Homebrew.

```bash
nix develop              # ouvre un shell avec Python et uv
uv sync                  # puis comme ci-dessus
```

Avec [direnv](https://direnv.net), ce shell s'active tout seul quand tu entres dans le dossier
(`.envrc` contient `use flake`) : lance `direnv allow` une fois.

Dans ce shell, uv crée `.venv` avec le Python fourni par Nix. Un `.venv` lié à un Python
installé ailleurs casse quand ce Python disparaît (par exemple désinstallé de Homebrew) ; uv le
recrée alors tout seul au prochain `uv run`. Les dépendances Python restent gérées par uv
(`pyproject.toml`, `uv.lock`), avec ou sans Nix.

## Les étapes

Tout passe par une seule commande, `jcvd` (`uv run jcvd --help` pour l'aide) :

```bash
uv run jcvd ingest                        # 1.  Markdown → JSON structuré
uv run jcvd index                         # 2.  JSON → index vectoriel Chroma
uv run jcvd search "J'ai peur d'échouer"  # 3a. voir les citations trouvées (sans clé API)
uv run jcvd eval                          # 3a. mesurer la qualité de la recherche
uv run jcvd ask "J'ai peur d'échouer"     # 3b. une réponse, avec des mesures
uv run jcvd chat                          # 3b. chat avec le bot dans le terminal
uv run --env-file .env jcvd telegram      # 4.  le même bot sur Telegram
```

Les étapes 1 et 2 sont à relancer seulement quand `data/citations_jcvd.md` change.

### Étape 1 — Structurer les données (`jcvd ingest`, `ingest.py`)

Lit `data/citations_jcvd.md` (89 blocs commençant par `>`), supprime les 17 doublons ou
quasi-doublons et écrit `data/citations.json` : 72 citations uniques, avec des métadonnées
calculées par mots-clés (`themes`, `tone`, `length`, `search_contexts`).

Comment les doublons sont détectés, et pourquoi ces métadonnées ne servent pas à la
recherche : [guide, section 8](docs/GUIDE_RAG.md#8-limites-et-pièges).

### Étape 2 — Vectoriser et indexer (`jcvd index`, `index.py`)

Transforme chaque citation en vecteur avec le modèle local
`paraphrase-multilingual-MiniLM-L12-v2` (384 dimensions, sans clé API) et enregistre le tout
dans Chroma, dans `data/chroma/`, avec la distance cosinus.

Ce qu'est un embedding, pourquoi ce modèle et pourquoi le cosinus plutôt que la distance
euclidienne : [guide, section 4](docs/GUIDE_RAG.md#4-les-embeddings--transformer-du-sens-en-nombres) et
[section 5](docs/GUIDE_RAG.md#5-la-base-vectorielle--retrouver-les-voisins-rapidement).

### Étape 3a — Retrouver les citations (`jcvd search`, `jcvd eval`, `retriever.py`, `evaluation.py`)

`jcvd search "question"` affiche les citations les plus proches et leur similarité. Exemple réel :

```
🔍 "Comment devenir meilleur ?"
   0.487  Ma devise, c'est toujours : se recréer. Il faut se recréer... pour recréer... a better you
   0.436  Ma devise, c'est : il faut se recréer, pour recréer !
   0.395  Mon modèle, c'est moi-même ! Je suis mon meilleur modèle parce que je connais mes erreurs...
```

Comment lire ces scores, et le rôle du seuil `SIMILARITY_THRESHOLD` (0,2 dans `config.py`) :
[guide, section 4](docs/GUIDE_RAG.md#comparer-deux-vecteurs--la-similarité-cosinus) et
[section 8](docs/GUIDE_RAG.md#8-limites-et-pièges).

`jcvd eval` rejoue les 30 questions de `data/eval_search.json` et affiche, pour chacune, le
rang de la bonne citation, puis les scores hit@3 et MRR. Lance-le avant et après toute
modification de la recherche. Ce que mesurent ces indicateurs, les scores actuels et
l'expérience qu'ils ont permis d'écarter : [guide, section 9](docs/GUIDE_RAG.md#9-mesurer-avant-daméliorer).

### Étape 3b — Générer la réponse (`jcvd chat`, `jcvd ask`, `bot.py`, `llm.py`)

À chaque message, le bot récupère les 3 citations les plus proches, les ajoute au message
envoyé au modèle de langage et lui demande de répondre dans le style de JCVD. Le détail (prompt
système, historique, appel au modèle) : [guide, section 7](docs/GUIDE_RAG.md#7-parcours-complet-dun-message-dans-le-code).

`jcvd ask "question"` donne une seule réponse suivie de mesures : nombre de mots (cible du
prompt : 60 à 120), de phrases, question finale ou non, durée, tokens. Pratique pour vérifier
qu'un changement de prompt ou de modèle a l'effet voulu.

### Choisir le modèle de langage : Claude ou Ollama

La variable `LLM_BACKEND` choisit le modèle qui écrit les réponses ; la recherche des
citations, elle, ne change pas ([guide, section 7.3](docs/GUIDE_RAG.md#73-generation--lappel-au-modèle-de-langage)) :

| | `LLM_BACKEND=claude` (défaut) | `LLM_BACKEND=ollama` |
|---|---|---|
| Où tourne le modèle | Serveurs d'Anthropic | Ta machine (ou une machine de ton réseau) |
| Coût | Payant, à l'usage | Gratuit (hors électricité) |
| Confidentialité | Les messages partent chez Anthropic | Rien ne sort de chez toi (Telegram voit toujours les messages) |
| Qualité | Suit finement le prompt | Nettement moins fidèle au prompt (voir mesures) |
| Clé API | `ANTHROPIC_API_KEY` | Aucune |

**Comment ça marche** (`src/jcvd_bot/llm.py`) : Ollama expose une API compatible avec celle
d'Anthropic. Le même client Python sert donc aux deux ; avec Ollama, on change seulement son
adresse (`OLLAMA_BASE_URL`) et on lui donne une clé factice. Les paramètres propres à Claude
(`effort` et `fallbacks`, expliqués dans le [guide, section 7.3](docs/GUIDE_RAG.md#73-generation--lappel-au-modèle-de-langage))
ne sont pas envoyés à Ollama.

**Mise en route avec Ollama**

1. Installe Ollama (<https://ollama.com>) et télécharge un modèle :
   ```bash
   ollama pull ministral-3:3b
   ```
2. Dans `.env` : `LLM_BACKEND=ollama` (et, si besoin, `OLLAMA_MODEL`, `OLLAMA_BASE_URL`).
3. Vérifie : `uv run --env-file .env jcvd ask "J'ai peur d'échouer"`.

**La fenêtre de contexte, un piège silencieux.** Un modèle local ne lit qu'une quantité
limitée de texte à la fois (sa fenêtre de contexte, réglée par Ollama). Si la conversation la
dépasse, Ollama coupe le début **sans erreur**, et le bot perd son prompt système, donc sa
personnalité. Mesures réelles avec `ministral-3:3b` :

- premier message : environ 900 tokens (prompt système + citations + question) ;
- messages suivants : le bot ne gardant que le dernier échange (`MAX_HISTORY_TURNS = 1`),
  le total reste entre **1 100 et 1 500 tokens**.

Une fenêtre de **4 096 tokens** suffit donc largement, 8 192 laisse de la marge (c'est la
valeur utilisée sur le Mac de développement). Si tu augmentes `MAX_HISTORY_TURNS`, refais la
mesure : avec 10 échanges, le total montait à 4 000–4 400 tokens et dépassait une fenêtre de
4 096. Vérifie la fenêtre dans la colonne `CONTEXT` de `ollama ps` (pendant qu'un modèle est
chargé). Pour l'agrandir, lance le serveur avec `OLLAMA_CONTEXT_LENGTH=8192 ollama serve`
(ou règle-la dans les paramètres de l'application Ollama). Pour suivre le nombre de tokens lus
à chaque message, utilise `jcvd --debug` ou `jcvd ask`.

Attention à la lecture des tokens : Ollama, comme Claude, garde en cache le début d'une
requête déjà lue. `input_tokens` ne compte alors que la partie nouvelle ; le total lu est la
somme avec `cache_read_input_tokens` (fonction `total_input_tokens` dans `llm.py`).

**Mesures réelles**, 5 mêmes questions, chacune dans une conversation neuve, avec le prompt
système actuel. Les modèles Ollama tournent sur un Mac M5 (24 Go), Claude sur les serveurs
d'Anthropic :

| Modèle | Taille | Durée par réponse | Mots (cible 60–120) | Phrases (cible 2–3) | Observations |
|---|---|---|---|---|---|
| `claude-opus-5` | — | 4,9 à 6,5 s | 101 à 110 | 2 à 3 | Respecte le budget, les longues phrases, le texte brut ; « tu comprends ? » accroché en fin de phrase (2 réponses sur 5) ; citations fondues dans le discours |
| `ministral-3:3b` | 3,0 Go | 4,8 à 8,1 s | 131 à 214 | 8 à 14 | Bon français, reformule les citations ; ajoute des didascalies en `*italique*` (« *soupir profond* »), dépasse le budget de mots |
| `gemma3:4b` | 3,3 Go | 5,0 à 6,3 s | 116 à 165 | 11 à 22 | Recopie des citations entières, tics répétés (« c'est… c'est », « Tu comprends ? » en ouverture) |

Les petits modèles locaux ne respectent vraiment ni la longueur, ni le nombre de phrases, ni
la mise en forme : c'est le prix d'un modèle de 3 à 4 milliards de paramètres. Côté coût, une
réponse de Claude lit environ 1 400 à 2 000 tokens et en écrit environ 250, soit de l'ordre de
1,5 centime de dollar par message (au tarif de `claude-opus-5` en septembre 2026 : 5 $ par
million de tokens lus, 25 $ par million écrits). Les tokenizers diffèrent d'un modèle à
l'autre : ne compare pas directement le nombre de tokens de Claude et d'Ollama.

`ministral-3:3b` est le modèle Ollama par défaut. Les deux modèles Ollama ont la taille visée
pour un Raspberry Pi 5 de 8 Go ; leur vitesse sur le Pi reste à mesurer.

**Ollama sur une autre machine.** Le bot peut tourner sur le Pi et appeler un Ollama installé
sur le Mac : `OLLAMA_BASE_URL=http://<adresse-du-mac>:11434`. Ollama n'écoute par défaut que
sur la machine locale : sur le Mac, il faut le lancer avec `OLLAMA_HOST=0.0.0.0` pour qu'il
accepte les connexions du réseau.

### Étape 4 — Brancher le bot sur Telegram (`jcvd telegram`, `telegram_app.py`)

`telegram_app.py` n'est qu'un **adaptateur** : il reçoit les messages Telegram, les passe au
même `JCVDBot` que le chat du terminal, et renvoie la réponse. Toute la logique RAG reste
dans `bot.py`.

**Mise en route**

1. Sur Telegram, écris à **@BotFather**, envoie `/newbot` et suis les instructions.
   Il te donne un **token** : c'est le mot de passe de ton bot, ne le partage pas.
2. Copie le fichier d'exemple et remplis `ANTHROPIC_API_KEY` et `TELEGRAM_BOT_TOKEN` :
   ```bash
   cp .env.example .env
   chmod 600 .env        # lisible par toi seul
   ```
3. Lance le bot :
   ```bash
   uv run --env-file .env jcvd telegram
   ```
4. Autorise-toi en suivant la procédure ci-dessous : tant que la liste est vide, le bot
   refuse tout le monde.

**Autoriser une personne (toi compris)**

1. Le bot tourne. La personne cherche ton bot sur Telegram (par son nom `@…_bot`) et lui
   envoie n'importe quel message. Le bot ne lui répond pas.
2. Dans le terminal où tourne le bot, une ligne affiche son identifiant :
   ```
   WARNING jcvd_bot.telegram_app Accès refusé à Marie Dupont (id 987654321)
   ```
3. Ajoute cet identifiant dans `TELEGRAM_ALLOWED_USERS` du fichier `.env`, séparé des autres
   par une virgule :
   ```
   TELEGRAM_ALLOWED_USERS=123456789,987654321
   ```
4. Arrête le bot (Ctrl+C) et relance-le : la liste n'est lue qu'au démarrage.

L'identifiant est un nombre fixe attribué par Telegram. Ce n'est pas le nom d'utilisateur
(`@marie`), que la personne peut changer à tout moment : c'est pour ça que la liste utilise
les identifiants. La personne peut aussi obtenir le sien auprès d'un bot tiers comme
@userinfobot, mais passer par ton propre bot évite de dépendre d'un service extérieur.

Pour retirer l'accès à quelqu'un : enlève son identifiant de la liste et relance le bot.

`uv run --env-file .env` charge les variables du fichier `.env` avant de lancer le script.
Le fichier `.env` est ignoré par git : les secrets ne doivent jamais se retrouver dans le code.

`HF_HUB_OFFLINE=1` (dans `.env`) empêche le bot de contacter le site Hugging Face à chaque
démarrage. Le modèle doit donc déjà être téléchargé : lance l'étape 2 avant (sans `.env`).

**Commandes dans Telegram** : `/start` pour la présentation, `/reset` pour effacer
l'historique de ta conversation.

**« Une autre instance du bot tourne déjà avec le même token »** : Telegram n'accepte qu'un
seul programme à la fois pour lire les messages d'un bot. Ce message apparaît si tu lances
le bot deux fois (deux terminaux, ou le Mac et le Pi en même temps). Arrête l'une des deux
instances. Les autres erreurs de communication avec Telegram passent par le même
gestionnaire (`on_error` dans `telegram_app.py`) : une coupure réseau est signalée en une
ligne, la librairie réessayant d'elle-même.

**Points de conception**

- **Long polling** : le bot demande sans arrêt à Telegram s'il a de nouveaux messages. Il ne
  fait que des connexions sortantes : aucun port à ouvrir, il marche derrière n'importe quelle box.
- **Liste blanche** (`TELEGRAM_ALLOWED_USERS`) : sans elle, n'importe qui trouvant ton bot
  dépenserait tes crédits API.
- **Un historique par conversation** : chaque personne a le sien, et ne voit jamais celui
  des autres. Sa longueur est fixée par `MAX_HISTORY_TURNS` dans `config.py`, actuellement
  1 : le bot se souvient seulement de l'échange précédent (effet sur la taille des requêtes :
  voir « La fenêtre de contexte » ci-dessus).
- **Pas de blocage** : la librairie Telegram est asynchrone, mais la recherche et l'appel au
  modèle de langage sont bloquants (plusieurs secondes). On les lance dans un thread
  (`asyncio.to_thread`) pour ne pas figer le bot pendant ce temps.
- **Messages traités un par un** (réglage par défaut de la librairie) : deux messages
  envoyés coup sur coup ne peuvent pas se mélanger dans l'historique.
- **Chiffrement** : les conversations avec un bot Telegram ne sont pas chiffrées de bout en
  bout ; Telegram voit les messages. Où part ensuite le texte : ligne « Confidentialité » du
  tableau « Choisir le modèle de langage » ci-dessus.

## Déployer sur un Raspberry Pi

Pour que le bot Telegram tourne en permanence, installe-le sur un Raspberry Pi et confie-le à
**systemd**, le gestionnaire de services de Linux : il le démarre avec le Pi et le relance
s'il plante. La procédure complète (carte SD, clé SSH, installation, secrets, service, mise à
jour) et les mesures relevées sur un Pi 5 sont dans
[docs/DEPLOIEMENT_PI.md](docs/DEPLOIEMENT_PI.md) ; les commandes pour gérer le service et lire
ses logs, dans sa [section 9](docs/DEPLOIEMENT_PI.md#9-installer-et-gérer-le-service). Si ton
Pi est géré avec Nix et home-manager, le service s'installe avec un module : voir la
[section 12](docs/DEPLOIEMENT_PI.md#12-variante-avec-nix-et-home-manager).

## Mode debug

Pour voir tout ce que fait le bot, ajoute `--debug` **avant** la commande :

```bash
uv run jcvd --debug search "J'ai peur d'échouer"
uv run jcvd --debug chat
uv run --env-file .env jcvd --debug telegram
```

Ou mets `JCVD_DEBUG=1` dans `.env` (pratique pour le bot Telegram et, plus tard, sur le Pi).

Extrait réel de `jcvd --debug search "J'ai peur d'échouer" -k 4` :

```
DEBUG   jcvd_bot.index: ← embedding_function = <...SentenceTransformerEmbeddingFunction...> (3384 ms)
DEBUG   jcvd_bot.retriever: → Retriever.search(query="J'ai peur d'échouer", k=4)
DEBUG   jcvd_bot.retriever:   retenue  0.393   quote_035 "Le grand combat, c'est contre soi-même. [...]"
DEBUG   jcvd_bot.retriever:   retenue  0.352   quote_064 'Me montrer nu de dos ne me pose pas de problème [...]'
DEBUG   jcvd_bot.retriever: ← Retriever.search = [...] (119 ms)
```

On y lit que charger le modèle d'embeddings prend 3,4 s, alors qu'une recherche prend
0,1 s, et on voit le score de chaque citation candidate.

**Comment c'est construit** (`src/jcvd_bot/logs.py`) :

- Le **décorateur `@traced`**, placé sur les fonctions du projet, journalise
  automatiquement chaque appel : `→` à l'entrée avec les arguments, `←` à la sortie avec le
  résultat et la durée, `✗` si une exception est levée. Les valeurs longues sont tronquées.
  Hors mode debug, il appelle simplement la fonction, sans coût notable.
- Des **`log.debug(...)` dans le code** détaillent ce que le décorateur ne voit pas de
  l'extérieur : chaque doublon écarté pendant l'ingestion (avec son pourcentage de
  ressemblance), chaque citation retenue ou écartée par le seuil, le message exact envoyé au
  modèle de langage, le modèle qui a répondu, les tokens consommés, les messages oubliés quand
  l'historique est trop long.
- Seuls les logs du projet (`jcvd_bot.*`) passent en debug. Les librairies tierces restent
  silencieuses : leurs logs noieraient les nôtres, et la librairie réseau `httpx` écrirait
  le token Telegram (il fait partie des URL qu'elle journalise).
- **Les secrets sont masqués** dans tout ce que `@traced` écrit : un texte au format d'un
  token Telegram (`123456789:AAH…`) ou d'une clé Anthropic (`sk-ant-…`) devient `***`.
  C'est nécessaire : l'objet `Bot` de Telegram affiche son token quand on l'imprime
  (`ExtBot[token=…]`), et un argument qui le contient l'aurait écrit dans les logs.

**Attention à la vie privée** : en mode debug, les logs contiennent le texte des messages et
le nom des personnes qui écrivent au bot. Active-le pour comprendre ou dépanner, pas en
permanence.

## Structure

```
JeanClaude/
├── pyproject.toml / uv.lock     dépendances et commande `jcvd` (gérées par uv)
├── flake.nix / flake.lock       environnement de développement Nix (optionnel : Python + uv)
├── .envrc                       active cet environnement avec direnv
├── .talismanrc                  exceptions du hook Talisman pour flake.lock et .envrc
├── .env.example                 modèle du fichier de secrets (.env, non versionné)
├── LICENSE                      licence MIT
├── data/
│   ├── citations_jcvd.md        source brute (à éditer)
│   ├── citations.json           généré par `jcvd ingest`
│   ├── eval_search.json         jeu d'évaluation de la recherche (`jcvd eval`)
│   └── chroma/                  index vectoriel, généré par `jcvd index` (non versionné)
├── deploy/
│   ├── jcvd-bot.service         service systemd pour faire tourner le bot sur un Pi
│   └── jcvd-bot.nix             le même service, en module home-manager (Pi géré avec Nix)
├── docs/
│   ├── GUIDE_RAG.md             comprendre le RAG depuis zéro
│   └── DEPLOIEMENT_PI.md        installer le bot sur un Raspberry Pi
├── src/jcvd_bot/                le code (un package Python)
│   ├── config.py                réglages : modèles, chemins, k, seuil
│   ├── ingest.py                étape 1
│   ├── index.py                 étape 2
│   ├── retriever.py             étape 3a
│   ├── evaluation.py            étape 3a, mesure de la qualité de la recherche
│   ├── bot.py                   étape 3b, le cœur du bot
│   ├── llm.py                   étape 3b, appel au modèle de langage (Claude ou Ollama)
│   ├── telegram_app.py          étape 4, l'adaptateur Telegram
│   ├── logs.py                  configuration des logs et mode debug
│   └── cli.py                   la commande `jcvd`
└── tests/                       tests automatisés (pytest)
```

Pourquoi un dossier `src/` ? Le code est un **package** installé dans l'environnement : on
l'importe partout de la même façon (`from jcvd_bot.bot import JCVDBot`), et les tests
utilisent exactement le code installé, pas un fichier trouvé par hasard dans le dossier courant.

## Développement

```bash
uv run pytest            # lance les tests (quelques secondes, sans clé API ni modèle)
uv run ruff check .      # vérifie le style et détecte des erreurs courantes
uv run ruff format .     # formate le code
```

Les tests remplacent le modèle d'embeddings et le modèle de langage (Claude ou Ollama) par
de faux objets : c'est possible parce que `JCVDBot` accepte qu'on lui passe son `retriever`
et son `client` (*injection de dépendances*). Ils vérifient le nettoyage des citations, la gestion des
historiques et le comportement du bot Telegram.

## Licence

Le code est sous licence [MIT](LICENSE) : tu peux le réutiliser, le modifier et le
redistribuer librement, en conservant la mention de copyright. Les citations de
`data/citations_jcvd.md` appartiennent à Jean-Claude Van Damme et ne sont pas couvertes par
cette licence.

## Pour aller plus loin

Les [exercices du guide](docs/GUIDE_RAG.md#10-exercices) proposent des expériences guidées : régler le
nombre de citations, filtrer par métadonnées, changer de modèle d'embeddings ou de modèle de
langage, changer de persona.
