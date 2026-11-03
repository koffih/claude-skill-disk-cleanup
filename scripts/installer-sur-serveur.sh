#!/bin/bash
# Pose le nettoyage du disque sur CE serveur (root ou sudo requis).
#
#   sudo ./installer-sur-serveur.sh [--dossier /opt/ops/nettoyage-disque] [--heure 04:30] [--sans-hebdo]
#
# Copie le script (root:root, 755) dans le dossier, y laisse un nettoyage-disque.conf
# s'il n'existe pas, cree deux minuteries systemd :
#   nettoyage-disque.timer          chaque nuit (complet)
#   nettoyage-disque-urgence.timer  chaque heure (ne fait rien sous SEUIL_URGENCE)
#   nettoyage-disque-hebdo.timer    le dimanche a la meme heure (hebdomadaire), sauf --sans-hebdo
# puis lance un passage "essai" et un passage complet, et affiche le resultat.
# Se relance sans risque pour mettre a jour le script : le .conf en place est garde.
#
# Compte sans root ni sudo complet :
#   ./installer-sur-serveur.sh --utilisateur [--dossier ~/.local/share/nettoyage-disque] [--heure 03:30]
# Meme script, pose au nom du compte, et trois lignes dans SA crontab (bloc
# balise, remplace a chaque relance) au lieu des minuteries systemd. Le script
# se met en mode sans root tout seul.
# Choisir --heure AVANT les gros traitements de nuit (sauvegarde, imports).
set -euo pipefail
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOSSIER=/opt/ops/nettoyage-disque
HEURE=04:30
HEBDO=1
UTILISATEUR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dossier) DOSSIER="$2"; shift 2 ;;
    --heure)   HEURE="$2"; shift 2 ;;
    --sans-hebdo) HEBDO=0; shift ;;
    --utilisateur) UTILISATEUR=1; shift ;;
    *) echo "argument inconnu : $1" >&2; exit 2 ;;
  esac
done

if [ "$UTILISATEUR" = 1 ]; then
  [ "$(id -u)" != 0 ] || { echo "ARRET : --utilisateur se lance avec le compte vise, pas en root" >&2; exit 1; }
  command -v crontab >/dev/null || { echo "ARRET : crontab introuvable" >&2; exit 1; }
  [ "$DOSSIER" = /opt/ops/nettoyage-disque ] && DOSSIER="$HOME/.local/share/nettoyage-disque"
  case "$HEURE" in [0-2][0-9]:[0-5][0-9]) ;; *) echo "ARRET : --heure HH:MM" >&2; exit 2 ;; esac
  H=$((10#${HEURE%%:*})); M=$((10#${HEURE##*:}))
  mkdir -p "$DOSSIER"
  install -m 755 "$SOURCE/nettoyage-disque.sh" "$DOSSIER/nettoyage-disque.sh"
  if [ ! -f "$DOSSIER/nettoyage-disque.conf" ]; then
    # L'exemple vise root : journal sous /var/log, caches de root et dev.
    sed -e 's|^JOURNAL=|#JOURNAL=|' -e "s|^UTILISATEURS_CACHES=.*|UTILISATEURS_CACHES=\"$(id -un)\"|" \
      "$SOURCE/nettoyage-disque.conf.exemple" > "$DOSSIER/nettoyage-disque.conf"
    chmod 644 "$DOSSIER/nettoyage-disque.conf"
  fi
  L="NETTOYAGE_CONF=$DOSSIER/nettoyage-disque.conf nice -n 15 ionice -c 3 $DOSSIER/nettoyage-disque.sh"
  {
    echo "# nettoyage-disque debut (installer-sur-serveur.sh --utilisateur, ne pas editer a la main)"
    if [ "$HEBDO" = 1 ]; then
      echo "$M $H * * 1-6 $L complet"
      echo "$M $H * * 0 $L hebdomadaire"
    else
      echo "$M $H * * * $L complet"
    fi
    echo "$(( (M + 23) % 60 )) * * * * $L urgence"
    echo "# nettoyage-disque fin"
  } > "$DOSSIER/crontab.bloc"
  # Le reste de la crontab est garde tel quel, le bloc balise est remplace.
  { crontab -l 2>/dev/null | sed '/^# nettoyage-disque debut/,/^# nettoyage-disque fin/d'; cat "$DOSSIER/crontab.bloc"; } | crontab -
  crontab -l | grep -q '^# nettoyage-disque fin' || { echo "ECHEC : bloc absent de la crontab" >&2; exit 1; }
  MODE_ESSAI=complet; [ "$HEBDO" = 1 ] && MODE_ESSAI=hebdomadaire
  echo "--- essai (rien n'est efface) :"; NETTOYAGE_CONF="$DOSSIER/nettoyage-disque.conf" "$DOSSIER/nettoyage-disque.sh" essai "$MODE_ESSAI"
  echo "--- passage complet :"; NETTOYAGE_CONF="$DOSSIER/nettoyage-disque.conf" "$DOSSIER/nettoyage-disque.sh" complet
  ETAT="${XDG_STATE_HOME:-$HOME/.local/state}/nettoyage-disque"
  tail -15 "$ETAT/journal.log"; echo "--- temoin :"; cat "$ETAT/dernier-passage"
  echo "--- crontab :"; cat "$DOSSIER/crontab.bloc"
  exit 0
fi

[ "$(id -u)" = 0 ] || { echo "ARRET : lancer en root (sudo), ou --utilisateur pour un compte sans root" >&2; exit 1; }

mkdir -p "$DOSSIER/systemd"
install -o root -g root -m 755 "$SOURCE/nettoyage-disque.sh" "$DOSSIER/nettoyage-disque.sh"
[ -f "$DOSSIER/nettoyage-disque.conf" ] || install -o root -g root -m 644 "$SOURCE/nettoyage-disque.conf.exemple" "$DOSSIER/nettoyage-disque.conf"

unite() { # nom description mode calendrier
  cat > "$DOSSIER/systemd/$1.service" <<U
[Unit]
Description=$2
After=docker.service

[Service]
Type=oneshot
Environment=NETTOYAGE_CONF=$DOSSIER/nettoyage-disque.conf
ExecStart=$DOSSIER/nettoyage-disque.sh $3
Nice=15
IOSchedulingClass=idle
U
  cat > "$DOSSIER/systemd/$1.timer" <<U
[Unit]
Description=$2 (minuterie)

[Timer]
OnCalendar=$4
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
U
}
# Le passage de nuit ne tourne pas le dimanche quand le passage hebdomadaire le remplace.
if [ "$HEBDO" = 1 ]; then
  unite nettoyage-disque "Nettoyage du disque, passage de nuit" complet "Mon..Sat *-*-* $HEURE:00"
  unite nettoyage-disque-hebdo "Nettoyage du disque, passage hebdomadaire" hebdomadaire "Sun *-*-* $HEURE:00"
  UNITES="nettoyage-disque nettoyage-disque-urgence nettoyage-disque-hebdo"
else
  unite nettoyage-disque "Nettoyage du disque, passage de nuit" complet "*-*-* $HEURE:00"
  UNITES="nettoyage-disque nettoyage-disque-urgence"
fi
unite nettoyage-disque-urgence "Nettoyage du disque, controle horaire" urgence hourly
chown -R root:root "$DOSSIER"; chmod 644 "$DOSSIER"/systemd/*

for u in $UNITES; do
  systemctl link "$DOSSIER/systemd/$u.service" "$DOSSIER/systemd/$u.timer" >/dev/null
done
systemctl daemon-reload
for u in $UNITES; do systemctl enable --now "$u.timer"; done

MODE_ESSAI=complet; [ "$HEBDO" = 1 ] && MODE_ESSAI=hebdomadaire
echo "--- essai (rien n'est efface) :"; NETTOYAGE_CONF="$DOSSIER/nettoyage-disque.conf" "$DOSSIER/nettoyage-disque.sh" essai "$MODE_ESSAI"
echo "--- passage complet :"; systemctl start nettoyage-disque.service
. "$DOSSIER/nettoyage-disque.conf"; tail -15 "${JOURNAL:-/var/log/nettoyage-disque.log}"
systemctl list-timers --no-pager | grep nettoyage-disque
