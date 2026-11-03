#!/bin/bash
# Banc d'essai du nettoyage, a lancer dans un conteneur JETABLE, jamais sur un serveur :
#
#   docker run --rm -v <reference>:/ref:ro ubuntu:24.04 bash /ref/banc-essai.sh
#   (non-regression root : monter aussi l'ancienne version, -v <ancien.sh>:/banc/ancien.sh:ro)
#
# Pose un compte dev, des caches dont une entree est utilisee par un processus vivant,
# des donnees, un navigateur installe, un lien vers un dossier a proteger, une crontab
# existante, puis installe en --utilisateur, passe en complet et en hebdomadaire, et
# verifie ce qui DOIT partir comme ce qui DOIT survivre. Sortie : nombre d'echecs.
set -u
echc=0
ok()  { echo "OK    $*"; }
ko()  { echo "ECHEC $*"; echc=$((echc+1)); }
existe()  { [ -e "$1" ] && ok "survit : $1" || ko "a disparu : $1"; }
disparu() { [ -e "$1" ] && ko "toujours la : $1" || ok "supprime : $1"; }

apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq cron procps util-linux >/dev/null 2>&1
useradd -m -s /bin/bash dev
H=/home/dev
vieux() { touch -d '40 days ago' "$@"; }
su dev -c '
H=$HOME
mkdir -p $H/.npm/_npx/vivant/node_modules $H/.npm/_npx/mort/node_modules $H/.npm/_logs
mkdir -p $H/.cache/uv/archive-v0/vivant $H/.cache/uv/archive-v0/mort $H/.cache/uv/autre
mkdir -p $H/.cache/ms-playwright/chromium $H/.local/share/uv/tools/x $H/donnees $H/precieux
for d in .npm/_npx/vivant .npm/_npx/mort .cache/uv/archive-v0/vivant .cache/uv/archive-v0/mort .cache/uv/autre; do
  head -c 6000000 /dev/zero > $H/$d/gros.bin; done
echo garde > $H/precieux/a-garder.txt; echo base > $H/donnees/base.db; echo nav > $H/.cache/ms-playwright/chromium/chrome
ln -s $H/precieux $H/.cache/uv/autre/lien-vers-precieux
echo vieux > $H/.npm/_logs/ancien.log; echo neuf > $H/.npm/_logs/recent.log
mkdir -p $H/.cursor-server/bin/linux-x64/v1 $H/.cursor-server/bin/linux-x64/v2
mkdir -p $H/.npm/_cacache/content-v2; echo c > $H/.npm/_cacache/content-v2/x
echo x > /tmp/dev-vieux.txt
'
vieux $H/.npm/_logs/ancien.log /tmp/dev-vieux.txt $H/.cursor-server/bin/linux-x64/v1
echo root > /tmp/root-vieux.txt; vieux /tmp/root-vieux.txt
# Un outil vivant execute depuis chaque entree "vivant" (comme npx et uvx).
cp /bin/sleep $H/.npm/_npx/vivant/node_modules/outil; cp /bin/sleep $H/.cache/uv/archive-v0/vivant/outil; chown -R dev: $H
su dev -c "cd $H/.npm/_npx/vivant && setsid ./node_modules/outil 600 >/dev/null 2>&1 &"
su dev -c "setsid $H/.cache/uv/archive-v0/vivant/outil 600 >/dev/null 2>&1 &"
sleep 1

# Crontab existante a preserver.
su dev -c '(echo "30 4 * * * /home/dev/sauvegarde.sh") | crontab -'
cp -r /ref /home/dev/ref; chown -R dev: /home/dev/ref
echo "--- installation (1re fois)"
su dev -c 'cd ~/ref && ./installer-sur-serveur.sh --utilisateur --heure 03:30' > /tmp/install1.log 2>&1; echo "code $?"
cat /tmp/install1.log | sed 's/^/    /' | tail -40
su dev -c 'NETTOYAGE_CONF=$HOME/.local/share/nettoyage-disque/nettoyage-disque.conf VIEILLES_VERSIONS=1 true'
echo "VIEILLES_VERSIONS=1" >> $H/.local/share/nettoyage-disque/nettoyage-disque.conf
echo "--- passage hebdomadaire"
su dev -c 'NETTOYAGE_CONF=$HOME/.local/share/nettoyage-disque/nettoyage-disque.conf ~/.local/share/nettoyage-disque/nettoyage-disque.sh hebdomadaire'; echo "code $?"
tail -25 $H/.local/state/nettoyage-disque/journal.log | sed 's/^/    /'
echo "--- relance de l'installeur (idempotence)"
su dev -c 'cd ~/ref && ./installer-sur-serveur.sh --utilisateur --heure 03:30' >/dev/null 2>&1; echo "code $?"

echo "=== verdicts"
existe $H/.npm/_npx/vivant/node_modules/outil
disparu $H/.npm/_npx/mort
existe $H/.cache/uv/archive-v0/vivant/outil
disparu $H/.cache/uv/archive-v0/mort
disparu $H/.cache/uv/autre
existe $H/precieux/a-garder.txt
existe $H/donnees/base.db
existe $H/.cache/ms-playwright/chromium/chrome
existe $H/.local/share/uv/tools/x
disparu $H/.npm/_logs/ancien.log
disparu $H/.npm/_cacache/content-v2
existe $H/.npm/_logs/recent.log
disparu /tmp/dev-vieux.txt
existe /tmp/root-vieux.txt
disparu $H/.cursor-server/bin/linux-x64/v1
existe $H/.cursor-server/bin/linux-x64/v2
pgrep -f archive-v0/vivant/outil >/dev/null && ok "outil uv toujours vivant" || ko "outil uv tue"
n=$(su dev -c 'crontab -l' | grep -c '^# nettoyage-disque debut'); [ "$n" = 1 ] && ok "un seul bloc crontab" || ko "$n blocs crontab"
su dev -c 'crontab -l' | grep -q sauvegarde.sh && ok "ligne crontab existante gardee" || ko "ligne crontab perdue"
[ "$(su dev -c 'crontab -l' | grep -c nettoyage-disque.sh)" = 3 ] && ok "trois lignes planifiees" || ko "lignes planifiees"
[ -s $H/.local/state/nettoyage-disque/dernier-passage ] && ok "temoin ecrit : $(cat $H/.local/state/nettoyage-disque/dernier-passage)" || ko "temoin absent"
grep -q "root requis" $H/.local/state/nettoyage-disque/journal.log && ok "ce qui exige root est annonce" || ko "rien d'annonce"
[ ! -e /var/log/nettoyage-disque.log ] && ok "aucune ecriture dans /var/log" || ko "ecrit dans /var/log"
# Repli : un reglage qui impose /var/log ne doit pas faire ecrire dans le vide.
printf 'JOURNAL=/var/log/nettoyage-disque.log\nTEMOIN=/var/lib/nettoyage-disque/dernier-passage\n' > /tmp/conf-root.conf; chmod 644 /tmp/conf-root.conf
rm -f $H/.local/state/nettoyage-disque/journal.log
su dev -c 'NETTOYAGE_CONF=/tmp/conf-root.conf ~/.local/share/nettoyage-disque/nettoyage-disque.sh complet' 2>/tmp/repli.err
[ -s $H/.local/state/nettoyage-disque/journal.log ] && [ ! -s /tmp/repli.err ] && ok "repli du journal vers le compte" || ko "repli du journal : $(cat /tmp/repli.err)"
# Non-regression en root : memes actions annoncees par l'ancien et le nouveau script.
mkdir -p /root/.npm/_npx/z; head -c 11000000 /dev/zero > /root/.npm/_npx/z/f
if [ -f /banc/ancien.sh ]; then
  bash /banc/ancien.sh essai hebdomadaire 2>&1 | sed 1d | grep -v '^  fin' > /tmp/a.txt
  bash /ref/nettoyage-disque.sh essai hebdomadaire 2>&1 | sed 1d | grep -v '^  fin' > /tmp/b.txt
  if diff /tmp/a.txt /tmp/b.txt >/dev/null; then ok "root : essai identique a l'ancien script ($(wc -l < /tmp/b.txt) lignes)"; else ko "root : essai different"; diff /tmp/a.txt /tmp/b.txt; fi
else echo "(pas d'ancienne version montee : non-regression root sautee)"; fi
bash /ref/nettoyage-disque.sh complet; grep -q "1 entrees supprimees" /var/log/nettoyage-disque.log && ok "root : passage reel dans /var/log" || ko "root : passage reel"
echo "=== $echc echec(s)"
exit $((echc > 0))
