#!/bin/bash
# Nettoyage du disque d'un serveur. Implementation de reference du patron
# "Nettoyage du disque" (regles et pieges deja payes). Se COPIE sur le serveur,
# en root:root (ou au nom du compte en mode sans root), jamais execute depuis sa source.
#
#   nettoyage-disque.sh complet    passage de nuit, tous les niveaux
#   nettoyage-disque.sh urgence    passage horaire : ne fait rien sous SEUIL_URGENCE
#   nettoyage-disque.sh hebdomadaire  complet, plus ce qui demande du jugement :
#                                  DOSSIERS_HEBDO, VACUUM FULL Logflare, cache webpack
#                                  Next.js, vieilles versions d'outils (si
#                                  VIEILLES_VERSIONS=1). "hebdo" est accepte aussi.
#   nettoyage-disque.sh essai      n'efface rien, liste ce qui serait fait
#   nettoyage-disque.sh essai hebdomadaire   idem, niveau hebdomadaire inclus
#
# Sans root (compte de travail sans sudo) : le script le detecte
# seul. Il ne nettoie alors que ce que ce compte possede (ses caches, ses
# journaux d'outils, ses fichiers de /tmp, Docker s'il est du groupe docker,
# Logflare par docker exec) ; journal et temoin vont dans
# ~/.local/state/nettoyage-disque/. Ce qui exige root (journaux des
# conteneurs, journal systemd, apt, /var/log) est annonce, jamais tente.
#
# Reglages : fichier NETTOYAGE_CONF (defaut : nettoyage-disque.conf a cote du script).
# Journal : JOURNAL. Temoin du dernier passage : TEMOIN (lu par un controleur).
#
# Ne touche JAMAIS : volumes de base de donnees, fichiers envoyes par les
# utilisateurs, sauvegardes. Ces chemins n'apparaissent nulle part ci-dessous ;
# une purge de sauvegardes appartient au script de sauvegarde lui-meme.
#
# Pieges deja payes (voir le patron) : pas de set -e (un ((x++)) a 0 tue le
# script) ; docker exec qui lit l'entree standard prend -i, et < /dev/null dans
# une boucle while read ; find sur un dossier en lien symbolique prend -H (le
# lien donne en argument est suivi) et JAMAIS -L (tous les liens rencontres
# sont suivis, et la purge sort du dossier) ; un cache dont un processus vivant
# s'execute n'est pas un rebut ; VACUUM refuse une transaction : un -c par
# instruction ; psql -q masque le compte d'un DELETE : compter par
# "with d as (delete ... returning 1)".
set -u
MODE="${1:-complet}"
ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Valeurs par defaut, surchargees par le fichier de reglages.
SEUIL_URGENCE=88          # % : en dessous, le passage horaire ne fait rien
SEUIL_ALERTE=90           # % : encore au-dessus apres nettoyage = alerte
MOI="$(id -un)"
SANS_ROOT=0; [ "$(id -u)" = 0 ] || SANS_ROOT=1
if [ "$SANS_ROOT" = 1 ]; then
  ETAT="${XDG_STATE_HOME:-$HOME/.local/state}/nettoyage-disque"
  JOURNAL="$ETAT/journal.log"
  TEMOIN="$ETAT/dernier-passage"
  VERROU="$ETAT/verrou"
else
  JOURNAL=/var/log/nettoyage-disque.log
  TEMOIN=/var/lib/nettoyage-disque/dernier-passage
  VERROU=/run/lock/nettoyage-disque.lock
fi
DOCKER_LOG_MAX_MO=100     # journaux json-file des conteneurs au-dela : tronques
JOURNALD_MAX=300M
JOURNALD_JOURS=14d
PM2_LOG_MAX_MO=200
PM2_LOG_DIRS="/root/.pm2/logs /home/*/.pm2/logs"
DOCKER_IMAGES_AGE=168h    # images inutilisees depuis 7 jours
UTILISATEURS_CACHES="$MOI" # comptes dont on vide les caches ci-dessous (root : defaut root)
# Caches par compte : ils se reconstruisent au besoin. Chaque entree dont un
# processus vivant se sert est EPARGNEE (serveurs MCP lances par npx ou uvx :
# ils s'executent depuis _npx et depuis .cache/uv).
# A NE JAMAIS AJOUTER ICI (voir les faux caches du patron) : .local/share/uv et
# .local/bin (outils installes), .cache/ms-playwright et .cache/puppeteer
# (navigateurs installes), .bun/bin (binaires), .claude-mem/chroma (index
# vectoriel, sa reconstruction coute des heures), .cache/chroma (modele
# d'embedding : son absence met la recherche en panne tant que le reseau ne
# l'a pas rendu).
# npm cache clean ne vide QUE _cacache : _npx se purge a part.
# Une entree utilisee est gardee ENTIERE (npx : _npx/<id> porte node_modules ET
# son package.json), sauf si son nom figure dans CACHES_SOUS_NIVEAU : c'est
# alors un rayonnage d'entrees independantes (uv : archive-v0/<id>, reliees par
# liens physiques), ou seule l'entree vivante est gardee.
CACHES_SOUS_NIVEAU="archive-v0"
CACHES_UTILISATEUR=".cache/uv .cache/pip .cache/deno .cache/typescript .cache/go-build .npm/_npx .bun/install/cache"
# Journaux d'outils par compte, purges par age et non vides d'un coup.
JOURNAUX_UTILISATEUR=".claude-mem/logs .npm/_logs"
JOURNAUX_UTILISATEUR_JOURS=14
APT_CACHE=1               # vider le cache du gestionnaire de paquets
TMP_JOURS=7
VARLOG_JOURS=30           # journaux tournes (.gz, .2 a .9) plus vieux : supprimes
COREDUMPS=1               # vider /var/lib/apport/coredump et /var/crash
# Bases de test jetables : conteneur postgres, motif, et le suffixe numerique
# est le pid du lanceur (une base dont le lanceur vit encore est epargnee).
BASES_TEST_CONTENEUR=""
BASES_TEST_MOTIF='^test_.*_[0-9]+$'
BASES_TEST_UTILISATEUR=postgres
# Purges propres au serveur, une par ligne : "chemin_ou_motif|jours" ou
# "chemin_ou_motif|jours|nom" (nom = motif de fichier, ex. *.html).
# ex : "/opt/app/tmp/*|3". Fichiers seulement, jamais de dossier entier.
PURGES_SUPPLEMENTAIRES=""
# Journaux ecrits en continu qu'aucune rotation ne couvre, "motif|Mo" : au-dela
# du plafond, le fichier est ramene a ses 512 derniers Ko, sans changer d'inode
# (un ecrivain en >> continue d'ecrire au bon endroit).
JOURNAUX_A_PLAFONNER=""
# Niveau hebdomadaire : dossiers purges par age, "chemin_ou_motif|jours".
# Pour ce qui demande du jugement et ne doit pas tourner chaque nuit.
DOSSIERS_HEBDO=""
# Commande d'alerte, recoit le message en argument (mail, webhook...). Vide = journal seul.
ALERTE_CMD=""
# L'alerte s'ecrit AUSSI dans le journal systeme (logger -t nettoyage-disque) :
# une cle de courriel invalide ne doit pas la faire disparaitre (constate le 2026-10-01).
# Images Docker : 1 = toutes les images inutilisees depuis DOCKER_IMAGES_AGE
# (prune -a, comportement historique) ; 0 = orphelines (<none>) seulement. Mettre 0
# si une image etiquetee sans conteneur sert a un retour arriere ou a un service
# arrete du compose (image :previous, postgres:15 du compose).
DOCKER_IMAGES_TOUTES=1
# Journaux Logflare de Supabase auto-heberge (base _supabase, tables
# _analytics.log_events_*) : aucune retention native, 4 a 11 Go constates.
# Vide = module coupe. Sinon le conteneur postgres (ex. supabase-db) ; il faut
# le role proprietaire des tables (supabase_admin).
LOGFLARE_CONTENEUR=""
LOGFLARE_UTILISATEUR=supabase_admin
LOGFLARE_JOURS=7
LOGFLARE_TOLERANCE=50000  # lignes au-dela de JOURS+1 tolerees avant alerte
# Plafond du WAL retenu par les creneaux de replication. Le creneau temporaire
# de Logflare (cainophile_*, publication logflare_pub) n'avance pas quand rien
# ne change : le WAL s'accumule jusqu'a ce plafond (4GB dans l'image Supabase),
# puis Postgres coupe et Logflare recree un creneau. Vide = ne rien regler.
# Ex. "1GB" : reaffirme par ALTER SYSTEM a chaque passage, sans redemarrage.
WAL_SLOT_PLAFOND=""
WAL_CONTENEUR=""          # defaut : LOGFLARE_CONTENEUR
# Applications Next.js (dossiers contenant .next), separes par des espaces.
# Cache d'images optimisees purge au-dela de NEXT_IMAGES_JOURS ; cache webpack
# vide en mode hebdomadaire. JAMAIS .next/cache/fetch-cache (sert les pages).
NEXT_DOSSIERS=""
NEXT_IMAGES_JOURS=14
# Mode hebdomadaire : vieilles versions de serveurs d'IDE (~/.cursor-server,
# ~/.vscode-server) et de Claude Code (~/.local/share/claude/versions). La plus
# recente (deux pour Claude Code) et toute version en cours d'execution sont gardees.
VIEILLES_VERSIONS=0


CONF="${NETTOYAGE_CONF:-$ICI/nettoyage-disque.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
# Sans root, un chemin de journal, de temoin ou de verrou impose par les
# reglages (l'exemple vise /var/log) est inutilisable : repli sur le dossier
# du compte, sinon le passage ecrit dans le vide (banc d'essai, 2026-11-02).
if [ "$SANS_ROOT" = 1 ]; then
  ecrivable() { d=$(dirname "$1"); mkdir -p "$d" 2>/dev/null; [ -w "$d" ] && { [ ! -e "$1" ] || [ -w "$1" ]; }; }
  ecrivable "$JOURNAL" || JOURNAL="$ETAT/journal.log"
  ecrivable "$TEMOIN"  || TEMOIN="$ETAT/dernier-passage"
  ecrivable "$VERROU"  || VERROU="$ETAT/verrou"
fi

HEBDO=0
ESSAI=0
if [ "$MODE" = essai ]; then ESSAI=1; MODE="${2:-complet}"; fi
case "$MODE" in hebdo|hebdomadaire) HEBDO=1; MODE=complet ;; esac
case "$MODE" in complet|urgence) ;; *) echo "mode inconnu : $MODE" >&2; exit 2 ;; esac
PROBLEMES=""
signaler() { PROBLEMES="${PROBLEMES}- $*"$'\n'; echo "  ANOMALIE : $*"; }

usage() { df --output=pcent / | tail -1 | tr -dc '0-9'; }
libre() { df -h --output=avail / | tail -1 | tr -d ' '; }
libre_ko() { df --output=avail / | tail -1 | tr -dc '0-9'; }

AVANT=$(usage)
if [ "$MODE" = urgence ] && [ "$AVANT" -lt "$SEUIL_URGENCE" ]; then exit 0; fi

if [ "$ESSAI" != 1 ]; then
  mkdir -p "$(dirname "$TEMOIN")" "$(dirname "$JOURNAL")" 2>/dev/null
  exec >>"$JOURNAL" 2>&1
  # Un seul passage a la fois : le controle horaire peut tomber sur le passage de nuit.
  if command -v flock >/dev/null; then
    exec 9>"$VERROU"
    flock -n 9 || { echo "=== $(date -Is) mode=$MODE : un passage est deja en cours, abandon"; exit 0; }
  fi
fi
# Le descripteur 3 porte ce que "essai" annonce : une action dont la sortie est
# jetee (>/dev/null) doit quand meme apparaitre dans l'essai, sinon l'essai ment.
exec 3>&1
faire() { if [ "$ESSAI" = 1 ]; then echo "  [essai] $*" >&3; else "$@"; fi; }
a_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

AVANT_KO=$(libre_ko)
echo "=== $(date -Is) mode=$MODE hebdo=$HEBDO disque=${AVANT}% libre=$(libre)$([ "$SANS_ROOT" = 1 ] && echo " compte=$MOI sans root")"
# Sans root, ce qui exige root est annonce une fois par passage, jamais tente.
root_requis() { echo "  root requis, laisse de cote : $*"; }

# Cliche de ce dont les processus vivants se servent : ligne de commande,
# dossier courant, executable, fichiers projetes en memoire. Pris une fois.
CLICHE=""
prendre_cliche() {
  [ -n "$CLICHE" ] && return
  CLICHE=$(mktemp /tmp/nettoyage-cliche.XXXXXX) || return
  trap 'rm -f "$CLICHE"' EXIT
  for p in /proc/[0-9]*; do
    tr '\0' '\n' < "$p/cmdline" 2>/dev/null
    l=$(readlink "$p/cwd" 2>/dev/null) && echo "$l/"
    readlink "$p/exe" 2>/dev/null
    awk '{ $1=$2=$3=$4=$5=""; sub(/^ +/,""); if ($0 ~ /^\//) print }' "$p/maps" 2>/dev/null
  done 2>/dev/null | grep -a / | sort -u > "$CLICHE"   # un processus peut mourir pendant le releve
}
utilise() { grep -qaF -e "$1/" "$CLICHE" 2>/dev/null || grep -qaxF -e "$1" "$CLICHE" 2>/dev/null; }

# Vide un cache en epargnant ce qu'un processus vivant utilise. Ne descend d'un
# niveau que dans les rayonnages nommes par CACHES_SOUS_NIVEAU.
vider_cache() { # $1 = dossier
  local e s ote=0 garde=0
  prendre_cliche
  [ -n "$CLICHE" ] && [ -s "$CLICHE" ] || { echo "    cliche des processus indisponible : cache laisse intact"; return; }
  for e in "$1"/* "$1"/.[!.]*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    if ! utilise "$e"; then
      ote=$((ote + 1)); [ "$ESSAI" = 1 ] || rm -rf -- "$e"; continue
    fi
    case " $CACHES_SOUS_NIVEAU " in *" ${e##*/} "*) [ -d "$e" ] && [ ! -L "$e" ] ;; *) false ;; esac ||
      { garde=$((garde + 1)); echo "    garde (processus vivant) : $e"; continue; }
    for s in "$e"/* "$e"/.[!.]*; do
      [ -e "$s" ] || [ -L "$s" ] || continue
      if utilise "$s"; then garde=$((garde + 1)); echo "    garde (processus vivant) : $s"
      else ote=$((ote + 1)); [ "$ESSAI" = 1 ] || rm -rf -- "$s"; fi
    done
  done
  if [ "$ESSAI" = 1 ]; then echo "  [essai] $1 : $ote entrees a supprimer, $garde gardees" >&3
  else echo "    $ote entrees supprimees, $garde gardees"; fi
}

# 1. Journaux des conteneurs Docker. json-file n'a aucune limite par defaut :
#    un seul conteneur bavard remplit le disque (un pooler : 12 Go). Et un
#    conteneur cree AVANT l'ecriture de log-opts garde son absence de limite
#    tant qu'il n'est pas recree (analytics : 351 Mo).
if [ "$SANS_ROOT" = 1 ]; then
  # /var/lib/docker est illisible sans root : on passe par Docker lui-meme.
  if a_docker; then
    root_requis "journaux des conteneurs Docker (plafond log-opts a poser par root)"
    sans_plafond=$(docker inspect -f '{{.Name}} {{index .HostConfig.LogConfig.Config "max-size"}}' $(docker ps -q) 2>/dev/null | awk 'NF==1 || $2=="<no" {gsub("/","",$1); print $1}' | tr '\n' ' ')
    [ -n "$sans_plafond" ] && echo "    conteneurs sans plafond de journal : $sans_plafond"
  fi
elif [ -d /var/lib/docker/containers ]; then
  for f in /var/lib/docker/containers/*/*-json.log; do
    [ -f "$f" ] || continue
    t=$(stat -c %s "$f")
    if [ "$t" -gt $((DOCKER_LOG_MAX_MO*1024*1024)) ]; then
      nom=$(docker inspect -f '{{.Name}}' "$(basename "$(dirname "$f")")" 2>/dev/null || basename "$(dirname "$f")" | cut -c1-12)
      echo "  journal docker ${nom} : $((t/1048576)) Mo, tronque"
      faire truncate -s 0 "$f"
    fi
  done
fi

# 2. Journal systemd.
if [ "$SANS_ROOT" = 1 ]; then root_requis "journal systemd"
else command -v journalctl >/dev/null && faire journalctl --vacuum-size="$JOURNALD_MAX" --vacuum-time="$JOURNALD_JOURS" 2>&1 | tail -1
fi

# 3. Journaux PM2.
for d in $PM2_LOG_DIRS; do
  for f in "$d"/*.log; do
    [ -f "$f" ] && [ -w "$f" ] && [ "$(stat -c %s "$f")" -gt $((PM2_LOG_MAX_MO*1024*1024)) ] && { echo "  journal pm2 $f tronque"; faire truncate -s 0 "$f"; }
  done
done

if [ "$MODE" = complet ] || [ "$(usage)" -ge "$SEUIL_URGENCE" ]; then
  # 4. Docker : images inutilisees, cache de construction. Jamais les volumes.
  if a_docker; then
    if [ "$DOCKER_IMAGES_TOUTES" = 1 ]; then
      faire docker image prune -af --filter "until=$DOCKER_IMAGES_AGE" 2>&1 | tail -1
    else
      faire docker image prune -f 2>&1 | tail -1
    fi
    faire docker builder prune -af 2>&1 | tail -1
  fi

  # 5. Caches par compte : se retelechargent au besoin. La liste des faux
  #    caches a NE PAS toucher est dans les reglages, en haut. uvx et npx
  #    executent leurs outils DEPUIS ces caches (chroma-mcp
  #    de claude-mem, 21 mcp-remote sur un serveur) : vider_cache epargne chaque
  #    entree qu'un processus vivant utilise, au lieu d'epargner le cache entier.
  for u in $UTILISATEURS_CACHES; do
    if [ "$SANS_ROOT" = 1 ] && [ "$u" != "$MOI" ]; then root_requis "caches du compte $u"; continue; fi
    h=$(getent passwd "$u" | cut -d: -f6); [ -n "$h" ] && [ -d "$h" ] || continue
    if command -v npm >/dev/null; then
      if [ "$u" = "$MOI" ]; then faire env HOME="$h" npm cache clean --force >/dev/null 2>&1
      else faire sudo -u "$u" env HOME="$h" npm cache clean --force >/dev/null 2>&1; fi
    elif [ "$SANS_ROOT" = 1 ] && [ -d "$h/.npm/_cacache" ] && [ ! -L "$h/.npm/_cacache" ]; then
      # npm hors du PATH (cron, nvm, session non interactive) : son cache est vide
      # comme les autres, entree par entree, ce que fait npm cache clean.
      t=$(du -sm "$h/.npm/_cacache" 2>/dev/null | cut -f1)
      echo "  cache $u:.npm/_cacache : ${t:-?} Mo (npm hors du PATH)"
      vider_cache "$h/.npm/_cacache"
    fi
    for rel in $CACHES_UTILISATEUR; do
      c="$h/$rel"
      [ -d "$c" ] && [ ! -L "$c" ] || continue
      t=$(du -sm "$c" 2>/dev/null | cut -f1)
      [ -n "$t" ] && [ "$t" -ge 10 ] || continue
      echo "  cache $u:$rel : ${t} Mo"
      vider_cache "$c"
    done
    for rel in $JOURNAUX_UTILISATEUR; do
      d="$h/$rel"
      [ -d "$d" ] && [ ! -L "$d" ] || continue
      n=$(find "$d" -xdev -type f -mtime +"$JOURNAUX_UTILISATEUR_JOURS" 2>/dev/null | wc -l)
      [ "$n" -gt 0 ] || continue
      echo "  journaux $u:$rel : $n fichiers de plus de ${JOURNAUX_UTILISATEUR_JOURS} j"
      faire find "$d" -xdev -type f -mtime +"$JOURNAUX_UTILISATEUR_JOURS" -delete 2>/dev/null
    done
  done

  # 5bis. Cache du gestionnaire de paquets. Les listes (/var/lib/apt/lists) ne
  #       sont PAS touchees : elles se retelechargent chaque nuit sinon.
  if [ "$APT_CACHE" = 1 ] && [ "$SANS_ROOT" = 0 ]; then
    command -v apt-get >/dev/null && faire apt-get clean >/dev/null 2>&1
    command -v dnf >/dev/null && faire dnf clean packages >/dev/null 2>&1
  fi

  # 6. Temporaires, vieux journaux tournes, coredumps. Dans /tmp on epargne les
  #    verrous (un verrou supprime sous son detenteur laisse entrer un second
  #    lanceur), les dossiers prives des services systemd et les dossiers de
  #    sockets (.X11-unix, .ICE-unix...), comme le fait systemd-tmpfiles.
  # Sans root, seuls les fichiers de ce compte sont vises.
  PROPRIO=""; [ "$SANS_ROOT" = 1 ] && PROPRIO="-user $(id -u)"
  # shellcheck disable=SC2086
  faire find /tmp -xdev -mindepth 1 -type f $PROPRIO -mtime +"$TMP_JOURS" -not -name '*.lock' -not -path '/tmp/systemd-private-*' -delete 2>/dev/null
  # shellcheck disable=SC2086
  faire find /tmp -xdev -mindepth 1 -type d $PROPRIO -empty -mtime +"$TMP_JOURS" -not -path '/tmp/systemd-private-*' -not -name '.*-unix' -delete 2>/dev/null
  if [ "$SANS_ROOT" = 1 ]; then root_requis "journaux tournes de /var/log, coredumps, cache apt"
  else
  faire find /var/log -xdev -type f \( -name '*.gz' -o -name '*.[2-9]' \) -mtime +"$VARLOG_JOURS" -delete 2>/dev/null
  if [ "$COREDUMPS" = 1 ]; then
    for d in /var/lib/apport/coredump /var/crash; do
      [ -d "$d" ] && faire find "$d" -mindepth 1 -type f -delete 2>/dev/null
    done
  fi
  fi

  # 7. Purges propres au serveur. -H et pas -L : le chemin donne peut etre un
  #    lien, mais un lien rencontre A L'INTERIEUR n'est jamais suivi.
  printf '%s\n' "$PURGES_SUPPLEMENTAIRES" | while IFS='|' read -r motif jours nom; do
    [ -n "$motif" ] || continue
    case "$motif" in \#*) continue ;; esac
    for p in $motif; do
      [ -e "$p" ] || continue
      n=$(find -H "$p" -xdev -type f -name "${nom:-*}" -mtime +"${jours:-7}" 2>/dev/null | wc -l)
      [ "$n" -gt 0 ] || continue
      echo "  purge $p ${nom:+($nom) }: $n fichiers de plus de ${jours:-7} j"
      faire find -H "$p" -xdev -type f -name "${nom:-*}" -mtime +"${jours:-7}" -delete 2>/dev/null
    done
  done

  # 7bis. Journaux en ecriture continue, sans rotation : plafonnes sur place.
  printf '%s\n' "$JOURNAUX_A_PLAFONNER" | while IFS='|' read -r motif mo; do
    [ -n "$motif" ] || continue
    case "$motif" in \#*) continue ;; esac
    for f in $motif; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      t=$(stat -c %s "$f")
      [ "$t" -gt $(( ${mo:-10} * 1048576 )) ] || continue
      echo "  journal $f : $((t/1024)) Ko, ramene a ses 512 derniers Ko"
      if [ "$ESSAI" = 1 ]; then echo "  [essai] plafonner $f" >&3
      else tail -c 524288 "$f" > "$f.plafond.$$" && cat "$f.plafond.$$" > "$f"; rm -f "$f.plafond.$$"; fi
    done
  done

  # 7ter. Niveau hebdomadaire : ce qui demande du jugement. Jamais sous urgence,
  #       jamais chaque nuit : des artefacts de session recents servent encore.
  if [ "$HEBDO" = 1 ]; then
    printf '%s\n' "$DOSSIERS_HEBDO" | while IFS='|' read -r motif jours; do
      [ -n "$motif" ] || continue
      case "$motif" in \#*) continue ;; esac
      for p in $motif; do
        [ -d "$p" ] || continue
        t=$(du -sm "$p" 2>/dev/null | cut -f1)
        n=$(find -H "$p" -xdev -type f -mtime +"${jours:-30}" 2>/dev/null | wc -l)
        echo "  hebdo $p : ${t:-?} Mo, $n fichiers de plus de ${jours:-30} j"
        [ "$n" -gt 0 ] || continue
        faire find -H "$p" -xdev -type f -mtime +"${jours:-30}" -delete 2>/dev/null
        faire find -H "$p" -xdev -mindepth 1 -type d -empty -delete 2>/dev/null
      done
    done
  fi

  # 8. Bases de test orphelines (tests interrompus). Sans FORCE : une base
  #    encore ouverte n'est pas supprimee ; et jamais si le lanceur vit.
  if [ -n "$BASES_TEST_CONTENEUR" ] && a_docker; then
    docker exec "$BASES_TEST_CONTENEUR" psql -U "$BASES_TEST_UTILISATEUR" -tAc \
      "select datname from pg_database where datname ~ '$BASES_TEST_MOTIF'" </dev/null 2>/dev/null |
    while read -r db; do
      [ -n "$db" ] || continue
      kill -0 "${db##*_}" 2>/dev/null && continue
      if [ "$ESSAI" = 1 ]; then echo "  [essai] base de test $db"
      else docker exec "$BASES_TEST_CONTENEUR" psql -U "$BASES_TEST_UTILISATEUR" -qc "drop database \"$db\"" </dev/null >/dev/null 2>&1 \
        && echo "  base de test supprimee : $db"; fi
    done
  fi
fi

# 9. Logflare : purge en base, verification du RESULTAT.
#    Pour un PREMIER nettoyage d'une table de plusieurs Go, ne pas passer par ici :
#    un DELETE de millions de lignes produit autant de WAL, retenu par le creneau
#    de Logflare. Copier ce qu'on garde, TRUNCATE, reinserer (voir le patron).
lf_sql() { docker exec "$LOGFLARE_CONTENEUR" psql -U "$LOGFLARE_UTILISATEUR" -d _supabase -v ON_ERROR_STOP=1 -tAq "$@" </dev/null 2>&1; }
if [ -n "$LOGFLARE_CONTENEUR" ] && a_docker; then
  for t in $(lf_sql -c "select tablename from pg_tables where schemaname='_analytics' and tablename like 'log_events_%'"); do
    if [ "$ESSAI" = 1 ]; then
      n=$(lf_sql -c "select count(*) from _analytics.$t where \"timestamp\" < now() - interval '$LOGFLARE_JOURS days'")
      echo "  [essai] logflare $t : $n lignes a supprimer"; continue
    fi
    n=$(lf_sql -c "set lock_timeout='60s'" -c "with d as (delete from _analytics.$t where \"timestamp\" < now() - interval '$LOGFLARE_JOURS days' returning 1) select count(*) from d" | tail -1)
    if [ "$HEBDO" = 1 ]; then
      lf_sql -c "set lock_timeout='60s'" -c "vacuum (full, analyze) _analytics.$t" >/dev/null || echo "  vacuum full echoue : $t"
    else
      lf_sql -c "vacuum (analyze) _analytics.$t" >/dev/null || echo "  vacuum echoue : $t"
    fi
    [ "${n:-0}" != 0 ] && echo "  logflare $t : $n lignes supprimees (retention $LOGFLARE_JOURS j)"
  done
  # Controle a retention + 1 : le controleur ne recopie pas le seuil du nettoyeur.
  vieux=0
  for t in $(lf_sql -c "select tablename from pg_tables where schemaname='_analytics' and tablename like 'log_events_%'"); do
    v=$(lf_sql -c "select count(*) from _analytics.$t where \"timestamp\" < now() - interval '$((LOGFLARE_JOURS + 1)) days'")
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    vieux=$((vieux + v))
  done
  taille=$(lf_sql -c "select pg_database_size('_supabase')/1048576")
  echo "  logflare : base _supabase ${taille} Mo, ${vieux} lignes au-dela de $((LOGFLARE_JOURS + 1)) j"
  [ "$vieux" -gt "$LOGFLARE_TOLERANCE" ] && signaler "${vieux} lignes Logflare au-dela de $((LOGFLARE_JOURS + 1)) jours : la purge ne fait pas son travail"
fi

# 10. Plafond du WAL retenu par les creneaux de replication. Ne JAMAIS effacer pg_wal a la main.
WAL_CONTENEUR="${WAL_CONTENEUR:-$LOGFLARE_CONTENEUR}"
if [ -n "$WAL_SLOT_PLAFOND" ] && [ -n "$WAL_CONTENEUR" ] && a_docker; then
  wal_sql() { docker exec "$WAL_CONTENEUR" psql -U "$LOGFLARE_UTILISATEUR" -d postgres -tAq -c "$1" </dev/null 2>/dev/null; }
  actuel=$(wal_sql "show max_slot_wal_keep_size")
  if [ "$actuel" != "$WAL_SLOT_PLAFOND" ]; then
    if [ "$ESSAI" = 1 ]; then echo "  [essai] max_slot_wal_keep_size $actuel -> $WAL_SLOT_PLAFOND"
    else
      wal_sql "alter system set max_slot_wal_keep_size = '$WAL_SLOT_PLAFOND'" >/dev/null && wal_sql "select pg_reload_conf()" >/dev/null \
        && echo "  max_slot_wal_keep_size : $actuel -> $WAL_SLOT_PLAFOND"
    fi
  fi
  retenu=$(wal_sql "select coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)),0)::bigint/1048576 from pg_replication_slots")
  plafond_mo=$(wal_sql "select setting::bigint from pg_settings where name='max_slot_wal_keep_size'")
  echo "  WAL retenu par les creneaux : ${retenu:-?} Mo (plafond ${plafond_mo:-?} Mo)"
  case "$retenu$plafond_mo" in *[!0-9]*|'') ;; *)
    [ "$plafond_mo" -gt 0 ] && [ "$retenu" -gt $((plafond_mo + plafond_mo / 2)) ] \
      && signaler "un creneau de replication retient ${retenu} Mo de WAL, au-dela du plafond de ${plafond_mo} Mo" ;;
  esac
fi

# 11. Caches de Next.js. Jamais .next/cache/fetch-cache : il sert les pages en production.
for app in $NEXT_DOSSIERS; do
  d="$app/.next/cache/images"
  if [ -d "$d" ]; then
    avant_mo=$(du -sm "$d" | cut -f1)
    faire find "$d" -type f -mtime +"$NEXT_IMAGES_JOURS" -delete 2>/dev/null
    faire find "$d" -mindepth 1 -type d -empty -delete 2>/dev/null
    echo "  cache images Next.js $app : ${avant_mo} -> $(du -sm "$d" | cut -f1) Mo"
  fi
  d="$app/.next/cache/webpack"
  if [ "$HEBDO" = 1 ] && [ -d "$d" ]; then
    echo "  cache webpack Next.js $app : $(du -sm "$d" | cut -f1) Mo, vide (build suivant plus lent)"
    faire rm -rf "$d"
  fi
done

# 12. Vieilles versions d'outils (hebdomadaire seulement). Une version dont un
#     processus execute le binaire est intouchable.
en_cours() { ls -l /proc/[0-9]*/exe 2>/dev/null | grep -qF "$1"; }
if [ "$HEBDO" = 1 ] && [ "$VIEILLES_VERSIONS" = 1 ]; then
  for u in $UTILISATEURS_CACHES; do
    [ "$SANS_ROOT" = 1 ] && [ "$u" != "$MOI" ] && continue
    h=$(getent passwd "$u" | cut -d: -f6); [ -n "$h" ] && [ -d "$h" ] || continue
    for d in "$h/.cursor-server/bin/linux-x64" "$h/.vscode-server/bin" "$h/.vscode-server/cli/servers"; do
      [ -d "$d" ] || continue
      pgrep -u "$u" -f "$(dirname "$d")" >/dev/null 2>&1 && continue
      for v in $(ls -1t "$d" | tail -n +2); do
        en_cours "$d/$v" && continue
        echo "  vieille version supprimee : $d/$v"; faire rm -rf "${d:?}/$v"
      done
    done
    d="$h/.local/share/claude/versions"
    if [ -d "$d" ]; then
      for v in $(ls -1t "$d" | tail -n +3); do
        en_cours "$d/$v" && continue
        echo "  vieille version de Claude Code supprimee : $u $v"; faire rm -rf "${d:?}/$v"
      done
    fi
  done
fi

APRES=$(usage)
GAGNE_MO=$(( ( $(libre_ko) - AVANT_KO ) / 1024 ))
echo "  fin : disque ${AVANT}% -> ${APRES}% libre=$(libre) (${GAGNE_MO} Mo liberes)"
[ "$ESSAI" = 1 ] && exit 0
# Temoin : un controleur verifie la DATE et le RESULTAT, pas seulement que le service a tourne.
printf '%s mode=%s avant=%s apres=%s liberes_mo=%s\n' "$(date -Is)" "$MODE" "$AVANT" "$APRES" "$GAGNE_MO" > "$TEMOIN"
[ "$APRES" -ge "$SEUIL_ALERTE" ] && PROBLEMES="- disque encore a ${APRES}% apres nettoyage ($MODE)"$'\n'"$PROBLEMES"
if [ -n "$PROBLEMES" ]; then
  msg="$(hostname) : nettoyage du disque ($MODE)"$'\n'"$PROBLEMES""Voir $JOURNAL"
  echo "  ALERTE : $msg"
  logger -t nettoyage-disque -p user.warning "$msg" 2>/dev/null
  [ -n "$ALERTE_CMD" ] && $ALERTE_CMD "$msg"
fi
exit 0
