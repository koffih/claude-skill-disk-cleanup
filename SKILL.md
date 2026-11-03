---
name: disk-cleanup
description: Install, audit or extend an automatic disk cleanup on a Linux server (Docker, self-hosted Supabase, PM2, Node, Python), with a nightly pass, an hourly emergency check and a weekly aggressive pass that never touches data and proves every night it did something. Works as root (systemd timers) or from a work account without root (crontab). Use when a disk is above 80 percent, when "the disk is full", when a service falls over for lack of space (Postgres restart loop, failed build, unexplained 500s), to set up the cleanup on a new VPS, or to check that an existing cleanup really frees anything. French triggers (nettoie le disque, nettoyage agressif de mes VPS, menage sur le serveur, le disque est plein, libere de la place, purge les caches, nettoyage de nuit, nettoyage-disque). If a skill named nettoyage-disque is also installed, prefer it: it is the maintainer copy of this same tool.
argument-hint: "[install | status | extend] [server]"
---

# Disk cleanup

A server disk fills up without warning, and mostly not because of users:
logs, caches, build leftovers and temporary files written every day by
automated jobs. The second problem is worse: cleanups that report "done"
every night and delete nothing. This skill installs one portable script that
does the cleaning, keeps a journal line for every action, and leaves a dated
witness file that a monitor can check.

The script and its messages are in French (it is a mirror of the
maintainer's working copy). Everything you need to drive it is below.

## The rule above all

A cleanup never touches data. Database volumes, user uploads and backups
appear nowhere in the script. Backup rotation belongs to the backup script
and is checked separately. Never add such a path to the settings.

## Files

- `scripts/nettoyage-disque.sh`: the cleaner. Modes `complet` (nightly),
  `urgence` (hourly, does nothing below `SEUIL_URGENCE`), `hebdomadaire`
  (weekly, adds what needs judgment), `essai` and `essai hebdomadaire`
  (dry run: lists everything, deletes nothing).
- `scripts/nettoyage-disque.conf.exemple`: every setting, commented.
- `scripts/installer-sur-serveur.sh`: installs and verifies on a server.
- `scripts/banc-essai.sh`: sandbox bench, run in a throwaway container only.
- `references/pattern.md`: why each rule exists, and the traps already paid.
- `references/settings.md`: the settings that matter most, in English.

## Install on a server

1. **Measure before cutting.** `df -h /`, then `du -xh --max-depth=1` as
   root. Go down to the big items. Delete nothing at this stage.
2. **Name every big item**: data, installed software, or junk? See the fake
   caches in `references/pattern.md`. A huge container log is a SYMPTOM:
   read what it repeats (`docker logs --tail 2000 <c> | sort | uniq -c | sort -rn | head`)
   before emptying it. The cause is often a bug elsewhere.
3. **Write the settings first**, from the example. Pick the hour BEFORE the
   nightly backup and imports. Docker images: set `DOCKER_IMAGES_TOUTES=0`
   as soon as tagged rollback images exist (`previous`, `rollback`,
   `candidate`, `before-*`): sorting them is the owner's decision.
4. **Dry run**, and read the Docker line before anything else:
   `NETTOYAGE_CONF=<conf> ./nettoyage-disque.sh essai hebdomadaire`.
   A dry run started with `env -i` and the variable placed before it runs
   with the defaults: check that the settings were actually loaded.
5. **Install.**
   - As root: `sudo ./installer-sur-serveur.sh --dossier /opt/<project>/ops/nettoyage-disque --heure 01:30`.
     Copies the script as root:root, creates three systemd timers (nightly
     Monday to Saturday, weekly on Sunday, hourly emergency; `--sans-hebdo`
     keeps two), runs a dry run then a real pass.
   - Without root (work account without full sudo): run as that account
     `./installer-sur-serveur.sh --utilisateur --heure 03:30`. Same script,
     installed in `~/.local/share/nettoyage-disque`, three lines in a tagged
     block of the account's crontab (the rest of the crontab is kept as is,
     the block is replaced on every rerun). The script switches to no-root
     mode by itself: it cleans only what the account owns (its caches, its
     tool logs, its files in `/tmp`, Docker if it is in the docker group,
     the npm cache even when npm is not on the PATH), and prints one
     `root requis` line for what it leaves (container logs, systemd
     journal, apt, `/var/log`), with the list of containers that have no
     log size limit. Journal and witness go to `~/.local/state/nettoyage-disque/`.
     Never use the docker group to write on the host instead: the missing
     root is a deliberate boundary.
   On a self-hosted Supabase stack, enable `LOGFLARE_CONTENEUR` and
   `WAL_SLOT_PLAFOND`; for a Next.js app, `NEXT_DOSSIERS`. They are off by
   default. For a FIRST cleanup of a Logflare table of several GB, follow
   `references/pattern.md` (copy, truncate, reinsert) before enabling the purge.
6. **Check the RESULT, not the run.** Read the journal: each action leaves a
   line, the percentage before and after, and the MB freed. A pass that
   writes "termine" with no action line is suspect. Check what had to
   SURVIVE too: the `garde (processus vivant)` lines, the health of the
   services, and that data did not change size.
7. **Wire the witness to a monitor**: alert when the witness file is older
   than 26 hours or when `apres=` stays at or above 90.
8. **Treat the cause** of what filled the disk, and write it down.

## Status

- Root: `systemctl list-timers | grep nettoyage-disque`,
  `sudo tail -40 /var/log/nettoyage-disque.log`,
  `sudo cat /var/lib/nettoyage-disque/dernier-passage`.
- No root: `crontab -l | sed -n '/nettoyage-disque debut/,/nettoyage-disque fin/p'`,
  `tail -40 ~/.local/state/nettoyage-disque/journal.log`,
  `cat ~/.local/state/nettoyage-disque/dernier-passage`.

The witness line reads `<date> mode=... avant=<pct> apres=<pct> liberes_mo=<MB>`.
Report in plain words: when it last ran, before and after, what was freed,
what was kept because a live process uses it, and what needs root.

## Extend it

A shared improvement goes into the script with a default that changes
nothing on servers already equipped. What belongs to ONE server goes into
its settings file (`PURGES_SUPPLEMENTAIRES`, `JOURNAUX_A_PLAFONNER`,
`DOSSIERS_HEBDO`, `BASES_TEST_*`), never into the script.

Every new guard is tested in a sandbox BEFORE any server, and you watch it
refuse: a fake process started from a cache, a symlink to a folder to
protect, then the reverse case where everything must go. A guard you never
saw refuse proves nothing. The bench does this:

```bash
docker run --rm -v "$PWD/scripts":/ref:ro ubuntu:24.04 bash /ref/banc-essai.sh
# add -v <previous nettoyage-disque.sh>:/banc/ancien.sh:ro to check that
# root mode announces exactly the same actions as before
```

Exit code 0 means every check passed (27 checks: what must go, what must
survive, crontab, journal fallback, root non-regression).
