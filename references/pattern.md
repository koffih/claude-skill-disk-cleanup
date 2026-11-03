# Disk cleanup: the pattern

## The problem

A full disk gives no warning. Postgres can no longer write its lock file and
restarts in a loop, authentication returns 500s, the build fails, the nightly
import stops. And the volume has little to do with user activity: automated
jobs write logs, backups, caches and generated files every day.

The second problem is worse: purges that purge nothing. On one fleet, three
cleanups wrote "done" every night for weeks without deleting anything.

## Seven rules

1. **Never touch data.** Database volumes, uploads, backups are out of scope.
   The cleanup handles logs, caches, temporary files and build leftovers.
   Backup rotation belongs to the backup script.
2. **Three levels.** A full nightly pass; an hourly check that does nothing
   below a threshold and acts only on big, fast items; an optional weekly
   aggressive pass for what needs judgment (old IDE servers, cloned repos,
   agent session recordings). The nightly pass runs BEFORE the heavy nightly
   jobs (imports, backups), not after.
3. **Cap at the source when you can, truncate otherwise.** Docker `json-file`
   logs have no limit by default. The native limit (`log-opts max-size`)
   only applies to containers created after it: truncate in the meantime.
4. **A huge log is a symptom.** Read what it repeats before emptying it. One
   pooler reconnecting in a loop to deleted test databases produced 12 GB of
   log AND timeouts in production.
5. **Check the result, not the run.** Every action leaves a journal line with
   the percentage before and after. A dated witness carries the result of the
   last pass. A "done" pass with no action line is suspect.
6. **A cache in use is not junk.** Tools started by `npx` and `uvx` run FROM
   their cache: emptying it breaks them silently, and the failure shows up
   elsewhere, later. Spare the live entry, empty the rest.
7. **A checker keeps a margin.** A verifier that runs after a cleaner reads
   its retention setting instead of copying it, and checks at retention + 1.
   An alert that rings every day ends up ignored.

More aggressive does not mean a lower threshold on what serves traffic: the
render cache of the live build makes a site fast for crawlers. Useful
aggressiveness is finding what nobody reads (the render cache of the
ROLLBACK build, 2.8 GB) and treating it every night.

## What fills a disk, most frequent first

| Item | Seen | Treatment |
|---|---|---|
| Docker container logs | 1.6 to 12 GB per container | truncate above 100 MB, then `log-opts` at the next Docker restart |
| Local backups never rotated | 13 to 34 GB | rotation INSIDE the backup script, checked separately |
| Supabase Logflare logs (`_supabase._analytics`) | 4 to 11 GB | no native retention: delete with retention, then `VACUUM FULL` |
| systemd journal | 2.3 to 2.8 GB | `journalctl --vacuum-size`, and `SystemMaxUse` set once |
| npm, uv, pip, npx, bun, deno caches | 1 to 5 GB per account | empty, they download again; spare the entry a live process uses |
| Render cache of the rollback build (`.next.previous`) | 2.8 GB | purge by EXTENSION (`.html`, `.rsc`, `.meta`, `.body`), never `.js` |
| Agent session temp files in `/tmp` | 0.8 GB | purge by age |
| Stale builds, stacked IDE servers | several GB | weekly level, with judgment |
| Postgres WAL held by a replication slot | up to `max_slot_wal_keep_size` (4 GB in the Supabase image) | lower the cap; NEVER delete `pg_wal` by hand |
| Next.js caches (optimized images, webpack) | 0.7 to 1.1 GB | images by age, webpack weekly; NEVER `.next/cache/fetch-cache` |

## Traps already paid

- `find` on a symlink does not descend without `-L`, and `-L` follows EVERY
  link met inside, so the purge leaves the folder (a sessions folder held a
  link to a notes folder). Use `-H`: it follows the link given as argument only.
- `((x++))` under `set -e` kills the script on the first round (post-increment
  is 0, status 1). Write `x=$((x + 1))`, or no `set -e` in a cleaner.
- `docker exec` without `-i` sends no standard input: the SQL heredoc never
  arrives, psql exits 0, silent purge for 20 days. In a `while read` loop add
  `< /dev/null`, or `docker exec` swallows the list.
- A purge that only runs after a successful backup: disk full, backup fails,
  purge never runs, spiral.
- A logrotate pattern that matches its own output: 631,479 files stacked up.
  Test with `logrotate -d`.
- Fake caches: a path containing `cache` can be a live install
  (`~/.claude/plugins/cache/...`); `~/.local/share/uv` holds installed tools;
  Playwright and Puppeteer browsers are installed, not cached.
- Deleting a Supabase storage file without its row gives a 500, not a missing
  image: go through the Storage API.
- Throwaway test databases behind a pooler: each dropped database leaves a
  handler reconnecting in a loop. Drop a test database only when the process
  that created it is dead.
- A non-root account does not see everything: `du` ignores `/root` and
  `/var/lib/docker`. A read-only container `-v /:/host:ro` measures it.
- `VACUUM` refuses a transaction, and several statements in one `psql -c` are
  one transaction: one `-c` per statement.
- Deleting millions of rows produces as much WAL, held by the Logflare slot.
  For the FIRST cleanup of a huge log table: copy what you keep, truncate,
  reinsert, in one transaction under an exclusive lock (7.8 GB down to
  650 MB in 25 seconds).
- `psql -q` hides the count of a `DELETE`: count with
  `with d as (delete ... returning 1) select count(*) from d`.
- An alert sent only by email vanishes with the email (invalid key, no local
  trace). The script always writes the alert to the system journal.
- Emptying `~/.cache/uv` under a live `uvx` tool breaks it. The script spares
  every ENTRY a live process uses (command line, working directory,
  executable, memory-mapped files) and empties the rest. An `npx` entry is
  kept whole; a `uv` shelf is sorted entry by entry.
- A tagged Docker image with no container is not necessarily junk: rollback
  image, stopped compose service. `prune -a` takes it.
- A tool version whose binary a process runs is untouchable: check
  `/proc/*/exe` before deleting an old IDE server or Claude Code version.
- A dry run that lies by omission: an action whose output went to
  `/dev/null` did not show in the dry run. It now announces on its own channel.
- A container created before the log cap never gets it: recreate it.
- Cleaning disarms remedies tied to a threshold: once the disk is down,
  anything that only triggers above a fill level never runs. Reread them.
- A lock deleted under its holder lets a second runner in: `/tmp` purge spares
  `*.lock`, service private folders and socket folders.
- Running a checker outside its schedule has effects: it sends real alerts and
  rewrites its remembered state.
- A non-root account is not a server without cleanup: 6 GB of caches and old
  tool versions. No-root mode and crontab install exist for that.
- Without root, a setting pointing at `/var/log` makes the pass write into the
  void: the script falls back to `~/.local/state/nettoyage-disque/`.
- npm not on the PATH (cron, nvm, non-interactive shell): `npm cache clean`
  never runs (2 GB). Without root the script empties `~/.npm/_cacache` entry by entry.
- `env -i` also wipes the settings path: a dry run started with `env -i` and
  `NETTOYAGE_CONF` placed before it runs with the defaults, including
  `docker image prune -a`. Always read the Docker line of a dry run first.
