# claude-skill-disk-cleanup

A [Claude Code](https://claude.com/claude-code) skill that installs, audits and
extends an automatic disk cleanup on a Linux server: a nightly pass, an hourly
emergency check and a weekly aggressive pass, for Docker, self-hosted Supabase,
PM2, Node and Python stacks.

- **Never touches data**: database volumes, uploads and backups are out of scope.
- **Spares what is in use**: a cache entry a live process runs from (`npx`, `uvx`
  tools) is kept, the rest goes.
- **Proves its work**: one journal line per action, before and after, MB freed,
  and a dated witness file for a monitor.
- **Root or not**: systemd timers as root, or a tagged crontab block from a work
  account without root, cleaning only what that account owns.
- **Tested in a sandbox**: `scripts/banc-essai.sh` runs 27 checks in a throwaway
  container, including what must survive.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/koffih/claude-skill-disk-cleanup/main/install.sh | bash
```

Options after `bash -s --`: `--project`, `--uninstall`. Or through the catalog
[koffih/claude-skills](https://github.com/koffih/claude-skills):
`install.sh disk-cleanup`.

Then ask Claude Code: "the disk is full", "set up the disk cleanup on this
server", "is the disk cleanup doing anything?".

## Use the script directly

```bash
cd scripts
cp nettoyage-disque.conf.exemple nettoyage-disque.conf   # edit it
NETTOYAGE_CONF=$PWD/nettoyage-disque.conf ./nettoyage-disque.sh essai hebdomadaire   # dry run
sudo ./installer-sur-serveur.sh --dossier /opt/ops/nettoyage-disque --heure 01:30    # root
./installer-sur-serveur.sh --utilisateur --heure 03:30                               # no root
```

The script and its messages are in French; `SKILL.md` and `references/` explain
everything in English.

## License

MIT
