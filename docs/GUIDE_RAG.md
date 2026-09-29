# Comprendre le RAG avec le bot JCVD

Ce guide s'adresse à un·e développeur·se qui n'a jamais construit de RAG. Il suppose que tu
sais programmer en Python et que tu sais vaguement ce qu'est un LLM (un modèle comme Claude
qui génère du texte). Rien d'autre.

Tous les chiffres et exemples ci-dessous ont été obtenus en exécutant le code du projet.
Tu peux les reproduire.

---

## 1. Le problème de départ

On veut un bot qui parle comme Jean-Claude Van Damme. Première idée : demander à Claude
« fais comme JCVD ». Ça marche un peu, mais Claude va produire une imitation générique,
et on n'a aucun contrôle sur ce qui est « vraiment » JCVD.

Deuxième idée : donner à Claude de vraies citations en exemple. C'est mieux. Mais lesquelles ?
Si l'utilisateur parle d'amour, les citations sur l'air ou les cacahuètes aident peu. Il faut
donc, **à chaque message**, choisir les citations qui correspondent au sujet.

C'est exactement ce que fait un RAG.

> **Remarque honnête.** Avec 72 citations, on pourrait tout simplement les mettre *toutes*
> dans le prompt : ça tiendrait largement dans le contexte de Claude. Le RAG devient
> indispensable quand la base est grande (des milliers de documents, une documentation
> interne, des tickets…). Ici, le petit corpus sert à apprendre le mécanisme sur un exemple
> que tu peux entièrement lire et vérifier.

---

## 2. Le RAG en une phrase

**RAG** = *Retrieval-Augmented Generation* : avant de demander à un LLM de répondre, on
**cherche** (*retrieval*) les documents pertinents dans une base, on les **ajoute** au prompt
(*augmentation*), puis le LLM **génère** sa réponse en s'appuyant dessus (*generation*).

```
                    ┌──────────────────────────┐
  "J'ai peur        │ 1. RETRIEVAL             │   3 citations
   d'échouer"  ───► │ chercher les citations   │ ───────────────┐
                    │ les plus proches         │                │
                    └──────────────────────────┘                ▼
                                                  ┌──────────────────────────┐
                                                  │ 2. AUGMENTATION          │
                                                  │ prompt = persona         │
                                                  │        + citations       │
                                                  │        + message         │
                                                  └────────────┬─────────────┘
                                                               ▼
                                                  ┌──────────────────────────┐
                                                  │ 3. GENERATION (LLM)      │
                                                  │ réponse dans le style    │
                                                  │ de JCVD                  │
                                                  └──────────────────────────┘
```

Les étapes 2 et 3 sont simples : c'est de la construction de chaîne de caractères et un appel
d'API. Toute la difficulté est dans l'étape 1 : **comment trouver les textes « proches » d'une
question ?** C'est l'objet des deux sections suivantes.

---

## 3. Pourquoi la recherche par mots-clés ne suffit pas

L'approche naïve : garder les citations qui contiennent les mots de la question.

Pour « Comment devenir meilleur ? », en cherchant le mot « meilleur », on obtient :

```
"Le Cycle... le cycle du cosmos dans la vie... [...] je suis le meilleur... Mais en vérité,
 il n'y a pas de meilleur !"
"Mon modèle, c'est moi-même ! Je suis mon meilleur modèle [...]"
"Ma femme n'est pas ma meilleure partenaire sexuelle, mais elle fait très bien le ménage."
```

Deux problèmes :

- **Faux positif** : la troisième citation contient le mot, mais n'a rien à voir avec le sujet.
- **Faux négatif** : la citation idéale, « Ma devise, c'est : il faut se recréer, pour
  recréer ! », ne contient aucun mot de la question. Elle est invisible.

Les mots ne sont qu'un indice du sens. Il faut une façon de comparer **le sens** de deux textes.

---

## 4. Les embeddings : transformer du sens en nombres

### L'intuition

Imagine une carte où chaque phrase serait un point, placée de sorte que les phrases qui
parlent de la même chose soient voisines. « Comment devenir meilleur ? » serait près de
« Comment progresser ? », et loin de « La bourse a chuté ».

Un **embedding** est la position d'un texte sur une telle carte. Sauf qu'au lieu de 2
coordonnées (x, y), il en a des centaines : ici **384**. Un modèle de machine learning,
entraîné sur d'énormes quantités de textes, a appris à placer les phrases de sens proche à des
positions proches.

Concrètement, c'est une liste de nombres :

```python
>>> model.encode("Je suis aware.")
[0.245, -0.284, 0.076, 0.054, 0.083, 0.099, ...]   # 384 nombres au total
```

Chaque nombre pris isolément ne veut rien dire pour un humain. Seules les **comparaisons**
entre vecteurs ont un sens.

Le nombre de dimensions (384) n'est pas un réglage : il est fixé par le modèle choisi.
D'autres modèles produisent 768, 1024 ou 3072 dimensions.

### Comparer deux vecteurs : la similarité cosinus

On mesure si deux vecteurs « pointent dans la même direction » avec la **similarité
cosinus** : proche de 1, même sens ; proche de 0, aucun rapport. Son calcul, et pourquoi on
la préfère à la distance euclidienne, sont détaillés juste après.

Scores réels avec le modèle du projet :

| Phrase A | Phrase B | Similarité |
|---|---|---|
| J'ai peur d'échouer | I'm afraid of failing | **0,971** |
| Comment devenir meilleur ? | Comment devenir plus fort ? | 0,679 |
| Comment devenir meilleur ? | Ma devise, c'est : il faut se recréer, pour recréer ! | 0,436 |
| Comment devenir meilleur ? | Si tu parles à ton eau de Javel […], elle est moins concentrée. | 0,140 |
| Le chat dort sur le canapé | La bourse a chuté de 3 % | 0,067 |

Trois choses à retenir :

1. **Le sens compte, pas les mots.** « se recréer » est reconnu comme proche de « devenir
   meilleur » sans aucun mot commun.
2. **Le modèle est multilingue.** Une phrase et sa traduction anglaise sont presque identiques
   (0,97). C'est utile ici, car JCVD mélange le français et l'anglais.
3. **Les scores absolus dépendent du modèle.** Ici, une citation pertinente obtient
   typiquement entre 0,3 et 0,6, pas 0,9 (conséquence pour le seuil : voir section 8).

### Distance euclidienne ou cosinus : quelle différence ?

Il existe deux façons courantes de dire si deux vecteurs sont « proches ». Pour les
comprendre, oublions les 384 dimensions et plaçons trois vecteurs sur un plan à 2 dimensions,
tous partant de l'origine O :

```
  y
  │
  ● C = (0, 1)
  │
  │
  O────●───────────●──── x
       A = (1, 0)  B = (3, 0)
```

A et B pointent **dans la même direction** ; B est simplement trois fois plus long. C pointe
dans une direction perpendiculaire.

**La distance euclidienne** (appelée aussi distance L2) est la distance « à vol d'oiseau »
entre les pointes des deux flèches. On la calcule comme en géométrie au collège : racine
carrée de la somme des carrés des écarts, coordonnée par coordonnée.

- A ↔ B : √((3 − 1)² + (0 − 0)²) = **2**
- A ↔ C : √((0 − 1)² + (1 − 0)²) = √2 ≈ **1,41**

Selon elle, A est plus proche de C que de B.

**La similarité cosinus** ne regarde que **l'angle** entre les deux flèches, pas leur
longueur. C'est le cosinus de cet angle : 1 si elles pointent dans la même direction
(angle de 0°), 0 si elles sont perpendiculaires (90°), −1 si elles sont opposées (180°).
On la calcule avec le produit scalaire divisé par le produit des longueurs.

- A ↔ B : angle de 0°, similarité **1**
- A ↔ C : angle de 90°, similarité **0**

Selon elle, A et B sont identiques, et A n'a rien à voir avec C. La **distance cosinus**
est simplement `1 − similarité` : 0 pour des vecteurs de même direction, 2 au maximum.

Tu peux vérifier ces chiffres toi-même :

```python
import numpy as np

A, B, C = np.array([1, 0]), np.array([3, 0]), np.array([0, 1])

def euclidienne(u, v):
    return np.linalg.norm(u - v)

def cosinus(u, v):
    return u @ v / (np.linalg.norm(u) * np.linalg.norm(v))

print(euclidienne(A, B), euclidienne(A, C))  # 2.0  1.414...
print(cosinus(A, B), cosinus(A, C))          # 1.0  0.0
```

**Pourquoi le cosinus convient mieux au texte.** Dans un embedding, c'est la **direction**
qui porte le sens (de quoi parle le texte). La **longueur** varie pour d'autres raisons
(longueur du texte, mots très fréquents…) qui n'ont rien à voir avec le sujet. La distance
euclidienne mélange les deux ; le cosinus ne garde que la direction. Avec notre modèle, la
longueur des vecteurs de citations varie de **2,94 à 4,87** : ce n'est pas un détail
négligeable.

Sur notre jeu d'évaluation (voir section 9), mesuré avec les deux distances (la ligne
« Cosinus » correspond à la recherche actuelle) :

| Distance | facile hit@3 (MRR) | difficile hit@3 (MRR) |
|---|---|---|
| Cosinus (choix du projet) | 16/16 (1,00) | 11/14 (0,64) |
| Euclidienne | 16/16 (0,94) | 10/14 (0,62) |

L'écart est faible, mais il va dans le sens attendu.

**Le cas des vecteurs normalisés.** Beaucoup de modèles d'embeddings « normalisent » leurs
vecteurs : ils les ramènent tous à une longueur de 1. Dans ce cas, les deux distances
donnent exactement le même classement, car pour des vecteurs de longueur 1, le carré de la
distance euclidienne vaut `2 − 2 × cosinus`. Notre modèle ne normalise pas ses vecteurs :
le choix de la distance compte donc.

### Dans le projet

Le modèle est `paraphrase-multilingual-MiniLM-L12-v2`, de la librairie sentence-transformers.
Il tourne **en local** sur ta machine : pas de clé API, pas de coût. On ne peut pas utiliser
Claude pour cette étape, car Anthropic ne propose pas d'API d'embeddings.

Il est déclaré dans `src/jcvd_bot/config.py` :

```python
EMBEDDING_MODEL = "paraphrase-multilingual-MiniLM-L12-v2"
```

---

## 5. La base vectorielle : retrouver les voisins rapidement

On a maintenant un moyen de comparer une question à une citation. Pour trouver les 3
citations les plus proches, il suffirait de calculer la similarité avec les 72 citations et de
trier. Avec 72 textes, c'est instantané.

Une **base de données vectorielle** fait ce travail pour toi, et le fait efficacement même
avec des millions de vecteurs (grâce à des index spécialisés). Elle stocke :

- le vecteur de chaque document ;
- le texte d'origine ;
- des métadonnées (ici : thèmes, ton, longueur).

Le projet utilise **Chroma**, qui tourne en local et enregistre tout dans
`data/chroma/`.

Extrait de `src/jcvd_bot/index.py` :

```python
collection = client.create_collection(
    name=COLLECTION_NAME,
    embedding_function=embedding_function(),
    configuration={"hnsw": {"space": "cosine"}},
)
collection.add(ids=[...], documents=[...], metadatas=[...])
```

Deux détails importants :

- `embedding_function` : on donne le modèle à Chroma, qui calcule lui-même les vecteurs à
  l'ajout des documents **et** à chaque recherche. Ça garantit que documents et questions
  passent par le même modèle, ce qui est indispensable : deux modèles différents placent les
  textes sur deux « cartes » différentes, et comparer leurs vecteurs n'aurait aucun sens.
- `"space": "cosine"` : par défaut, Chroma mesure une distance euclidienne, et renvoie
  même son **carré** (pour la meilleure citation de « Comment devenir meilleur ? » : 14,67,
  soit 3,83²). On lui demande la distance cosinus (voir section 4) : elle convient mieux au
  texte, et `similarité = 1 − distance` devient juste. Avec la distance euclidienne, ce calcul
  donnerait des valeurs négatives sans signification, et le seuil de 0,2 éliminerait tout.

---

## 6. Deux moments distincts : indexation et interrogation

Un RAG se découpe en deux phases qu'il ne faut pas confondre.

**Indexation (hors ligne, une fois)** : on prépare la base.

```
citations_jcvd.md ──► jcvd ingest ──► citations.json ──► jcvd index ──► data/chroma/
   (89 blocs)          (nettoyage)      (72 citations)   (vectorisation)     (index)
```

On ne la relance que si les citations changent. Vectoriser des millions de documents peut
prendre des heures : on ne veut pas le faire à chaque question.

**Interrogation (en ligne, à chaque message)** : on utilise la base.

```
message ──► vectoriser ──► 3 plus proches voisins ──► prompt augmenté ──► LLM ──► réponse
```

---

## 7. Parcours complet d'un message dans le code

Suivons le message « J'ai peur d'échouer » à travers `src/jcvd_bot/bot.py`.

### 7.1 Retrieval — `Retriever.search()` (`retriever.py`)

```python
results = self.collection.query(query_texts=[query], n_results=k, ...)
```

Chroma vectorise la question, trouve les 3 citations les plus proches, et renvoie leurs
distances. On les convertit en similarités et on écarte celles sous le seuil
(`SIMILARITY_THRESHOLD = 0.2`).

### 7.2 Augmentation — `JCVDBot.respond()` (`bot.py`)

Les citations trouvées sont insérées dans le message envoyé à Claude. Voici ce que Claude
reçoit réellement comme message utilisateur :

```
<citations>
- "Le grand combat, c'est contre soi-même. La victoire, c'est d'avoir compris ce que l'on veut... et d'y croire."
- "Me montrer nu de dos ne me pose pas de problème mais, de face, c'est une autre histoire, je ne voudrais pas perdre tout mes fans."
- "Mon modèle, c'est moi-même ! Je suis mon meilleur modèle parce que je connais mes erreurs, [...]"
</citations>

Message de l'utilisateur : J'ai peur d'échouer
```

Regarde la deuxième citation : elle n'a pas grand rapport avec l'échec. Le retrieval n'est pas
parfait (voir section 8). C'est acceptable ici, car Claude choisit lui-même ce qu'il utilise.

En plus de ce message, Claude reçoit :

- **Le prompt système** (`SYSTEM_PROMPT`), qui décrit la persona : ses thèmes, sa façon de
  parler, et la consigne de ne pas inventer de fausses citations. Il est identique à chaque
  appel ; c'est pour ça que les citations, qui changent, n'y sont pas.

  Un exemple de réglage : une première version disait seulement que JCVD pose des
  « questions à l'interlocuteur ("Tu comprends ?") ». Le modèle en déduisait qu'il fallait
  finir chaque réponse par une question, un tic fréquent des LLM. Le prompt précise
  maintenant que JCVD n'interroge pas son interlocuteur : sa seule question est une
  vérification rhétorique (« Tu comprends ? »), facultative, et beaucoup de réponses se
  terminent sur une affirmation. Il explique aussi **pourquoi** (JCVD partage sa vision, il
  ne mène pas d'interview) : un modèle suit mieux une consigne dont il comprend la raison.

  Autre piège : les consignes contradictoires. Pour que JCVD parle en longues phrases
  sinueuses, il a fallu aussi retirer la fin du prompt, qui demandait « quelques paragraphes
  courts ». Le modèle aurait dû arbitrer entre les deux. Mais « des phrases plus longues »
  risquait aussi d'allonger les réponses, ce qu'on ne voulait pas. La version actuelle fixe
  donc un **budget** explicite (environ 60 à 120 mots, un paragraphe) et dit comment le
  répartir : deux ou trois longues phrases plutôt que beaucoup de courtes. Une fourchette
  chiffrée est une consigne qu'un modèle suit bien, alors que « court » ou « long » est
  interprété librement.
- **L'historique** de la conversation. L'API de Claude n'a aucune mémoire entre deux appels :
  pour avoir une vraie conversation, on renvoie tous les échanges précédents à chaque fois.
  On y stocke les messages *sans* les citations, pour ne pas gonfler le contexte.

### 7.3 Generation — l'appel au modèle de langage

L'appel est isolé dans `src/jcvd_bot/llm.py`. Avec Claude :

```python
client.beta.messages.create(
    model="claude-opus-5",
    system=SYSTEM_PROMPT,
    messages=history + [{"role": "user", "content": augmented}],
    output_config={"effort": "low"},
    ...
)
```

Deux paramètres sont propres à Claude :

- `effort: "low"` limite la réflexion du modèle avant de répondre : pour une conversation,
  c'est plus rapide et moins cher sans perte notable ;
- `fallbacks="default"` (dans le code complet) fait basculer l'API sur un autre modèle si
  Claude refuse une requête pour raison de sécurité.

**Le modèle de langage est interchangeable.** Rien dans les étapes précédentes (ingestion,
embeddings, recherche) ne dépend de lui : les citations sont trouvées de la même façon, puis
données à n'importe quel modèle capable de suivre un prompt. Avec `LLM_BACKEND=ollama`, le
même code appelle un modèle open source qui tourne sur ta machine. Il est gratuit et les
messages ne quittent pas ta machine, mais un petit modèle suit bien moins fidèlement le prompt
(voir les [mesures dans le README](../README.md#choisir-le-modèle-de-langage--claude-ou-ollama)). Autrement dit, le RAG apporte les **connaissances**
(les citations), et le modèle de langage la **qualité d'écriture**.

---

## 8. Limites et pièges

Ces points ne sont pas théoriques : chacun s'est présenté pendant la construction du projet.

**Le retrieval ramène parfois des textes hors sujet**, comme la citation sur la nudité vue
en 7.2. Causes : un petit modèle d'embeddings, un
corpus de 72 textes très courts, et une question qui ne ressemble à aucune citation. Pistes
d'amélioration : un meilleur modèle, un seuil plus strict, ou combiner avec une recherche
par mots-clés (« recherche hybride »).

**Un seuil de similarité dépend du modèle.** Une première version du projet utilisait un
seuil de 0,65 : avec ce modèle, il aurait éliminé toutes les citations.

**Vérifie que tes embeddings sont de vrais embeddings.** Une première version « simulait »
les embeddings avec un hachage du texte (SHA-256). Le code tournait sans erreur, mais la
recherche renvoyait des citations au hasard : un hachage ne contient aucun sens. Leçon :
teste toujours ton retrieval seul (`uv run jcvd search "..."`) avant de brancher le LLM.
Si les résultats ne sont pas sensés, le LLM ne pourra pas rattraper le coup.

**La qualité des données compte autant que le modèle.** Le fichier source contenait 17
doublons ou quasi-doublons. Sans nettoyage, la même citation aurait pu remonter deux fois et
occuper deux des trois places. Le parser les élimine en comparant des textes normalisés
(sans accents ni ponctuation) et en fusionnant les versions similaires à plus de 90 %.

**Les métadonnées par mots-clés sont grossières.** Les champs `themes` et `tone` sont calculés
avec des règles simples. Ils ne servent pas à la recherche ; ils seraient utiles pour filtrer
(voir exercice 4).

---

## 9. Mesurer avant d'améliorer

Comment savoir si une modification améliore la recherche ? Essayer trois questions « à l'œil »
ne suffit pas : on retient les exemples qui arrangent. Il faut une **évaluation** : des
questions fixées à l'avance, la réponse attendue pour chacune, et un score.

### Le jeu d'évaluation

`data/eval_search.json` contient 30 questions. Pour chacune, on liste les citations qui y
répondent, repérées par un fragment de leur texte (un identifiant comme `quote_035` change
dès qu'on modifie le fichier source). `uv run jcvd eval` calcule deux indicateurs :

- **hit@3** : la bonne citation est-elle parmi les 3 que le bot reçoit réellement ?
- **MRR** (*Mean Reciprocal Rank*, rang réciproque moyen) : 1 si la bonne citation est 1re,
  0,5 si 2e, 0,33 si 3e… 0 si elle n'est pas dans le top 10. Il récompense une citation bien placée.

### Premier piège : une évaluation trop facile

La première version du jeu ne contenait que des questions qui reprenaient des mots des
citations (« Est-ce que tu as déjà pris de la drogue ? » pour « La drogue, faut pas
toucher… »). Résultat : 16/16, toujours au rang 1. Ce score parfait ne prouvait rien :
écrites par quelqu'un qui connaît les citations, ces questions étaient trop faciles.

On a donc ajouté 14 questions **indirectes**, comme les poserait un vrai utilisateur
(« Tu crois aux horoscopes ? » pour la citation sur la voyante). Les questions sont
étiquetées `facile` ou `difficile`. Les scores de la recherche actuelle sont dans la ligne
« Référence » du tableau ci-dessous.

### Une expérience : enrichir les citations

Idée testée : une question et une citation ne se ressemblent pas, même quand l'une répond à
l'autre. On a donc demandé à un LLM (`ministral-3:3b`, via Ollama) d'inventer, pour chaque
citation, 3 questions auxquelles elle répondrait, pour les indexer avec elle. Deux variantes :

- **A** : un vecteur par citation, calculé sur « citation + ses questions » ;
- **B** : un vecteur pour la citation et un par question, tous reliés à la citation.

| Variante | facile hit@3 (MRR) | difficile hit@3 (MRR) |
|---|---|---|
| Référence (citations seules) | 16/16 (1,00) | 11/14 (0,64) |
| A | 15/16 (0,91) | 11/14 (0,77) |
| B | 16/16 (0,97) | 10/14 (0,54) |

Aucune variante n'est nettement meilleure, et **l'enrichissement n'a pas été intégré**. La
variante A place mieux les bonnes citations sur les questions difficiles, mais n'en trouve
pas une de plus, et elle fait échouer « Quel est ton film préféré ? » (rang 1 → hors du top
10). Les questions générées pour d'autres citations parlent de « films » et attirent cette
requête, tandis que « Forrest Gump » est dilué dans un texte plus long : le texte ajouté
apporte du signal, mais aussi du bruit.

Leçons à retenir :

- **Mesure avant et après.** Sans évaluation, cette idée séduisante aurait été intégrée et
  aurait dégradé certaines réponses sans que personne ne le voie.
- **Un petit jeu d'évaluation est bruité** : avec 14 questions difficiles, une question vaut
  7 points. Ne conclus pas sur un écart d'une ou deux questions.
- **N'ajuste pas ta méthode en regardant le jeu d'évaluation** (par exemple en réécrivant la
  consigne de génération jusqu'à faire passer « horoscopes ») : le score augmenterait sans que
  la recherche soit meilleure pour de vraies questions.
- **Un petit LLM suit mal les consignes de format** : ici, il numérotait et mettait en
  italique ses questions malgré la consigne, et il a fallu un découpage tolérant.

## 10. Exercices

Chaque exercice se fait en quelques minutes et fait comprendre un point précis.

1. **Explorer le retrieval.** Pose tes propres questions avec
   `uv run jcvd search "ta question"` (ajoute `-k 10` pour voir plus de résultats). Trouve une
   question pour laquelle les résultats sont mauvais, et essaie d'expliquer pourquoi.

2. **Jouer avec `k`.** Dans `src/jcvd_bot/config.py`, passe `RETRIEVE_K` à 1, puis à 10, et discute avec
   le bot. Avec 1, les réponses collent-elles plus à une citation ? Avec 10, sont-elles plus
   variées ou plus floues ?

3. **Désactiver le retrieval.** Dans `src/jcvd_bot/bot.py`, remplace `citations = self.retriever.search(user_message)`
   par `citations = []`. Compare les réponses : c'est l'apport concret du RAG.

4. **Filtrer par métadonnées.** Dans `src/jcvd_bot/retriever.py`, ajoute `where={"tone": "questionnant"}`
   à l'appel `collection.query(...)`. Seules les citations de ce ton seront candidates.

5. **Changer de modèle d'embeddings.** Note le score de `uv run jcvd eval`, remplace
   `EMBEDDING_MODEL` par `all-MiniLM-L6-v2` (un modèle entraîné surtout en anglais), relance
   `jcvd index` puis `jcvd eval`. De combien le score baisse-t-il sur les questions en français ?
   Remets ensuite le modèle d'origine et relance `jcvd index`. Pour aller plus loin, essaie un
   modèle plus puissant (par exemple via l'API Voyage AI) : le score monte-t-il ?

6. **Comparer deux modèles de langage.** Pose les mêmes questions avec
   `uv run jcvd ask "..."`, une fois avec Claude, une fois avec `LLM_BACKEND=ollama`. Compare
   les mesures affichées (mots, phrases, question finale) et le style. Quelles consignes du
   prompt le petit modèle respecte-t-il, lesquelles ignore-t-il ?

7. **Changer de persona.** Remplace `data/citations_jcvd.md` par les citations d'une autre
   personne, adapte `SYSTEM_PROMPT`, et relance les étapes 1 et 2. Le reste du code ne change pas.

---

## 11. Glossaire

- **LLM** (*Large Language Model*) : modèle qui génère du texte, ici Claude ou un modèle
  open source exécuté par Ollama.
- **RAG** (*Retrieval-Augmented Generation*) : chercher des documents pertinents puis les
  fournir au LLM avant qu'il réponde.
- **Embedding** : liste de nombres qui représente le sens d'un texte.
- **Dimension** : nombre de valeurs dans un embedding (384 ici), fixé par le modèle.
- **Similarité cosinus** : cosinus de l'angle entre deux vecteurs ; 1 pour la même direction
  (même sens), 0 pour des directions sans rapport. Ne dépend pas de la longueur des vecteurs.
- **Distance cosinus** : `1 − similarité cosinus` ; 0 pour des vecteurs de même direction.
- **Distance euclidienne (L2)** : distance « à vol d'oiseau » entre les pointes de deux
  vecteurs ; tient compte à la fois de leur direction et de leur longueur.
- **Vecteur normalisé** : vecteur ramené à une longueur de 1. Entre vecteurs normalisés,
  distance euclidienne et cosinus donnent le même classement.
- **Base vectorielle** : base de données qui stocke des embeddings et retrouve les plus
  proches d'un vecteur donné (ici Chroma).
- **Indexation** : phase préalable où l'on vectorise et stocke les documents.
- **Jeu d'évaluation** : questions fixées à l'avance avec leur réponse attendue, pour mesurer
  la qualité de la recherche (`jcvd eval`).
- **hit@3, MRR** : indicateurs de la recherche (bonne citation dans le top 3 ; rang
  réciproque moyen de la bonne citation).
- **Retrieval** : phase où l'on cherche les documents proches d'une question.
- **Prompt système** : instructions permanentes données au LLM (ici, la persona JCVD).
- **Contexte** : tout ce que le LLM reçoit à un appel (prompt système, historique, citations).
