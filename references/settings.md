# Settings that matter

The settings file is sourced by the script. Put only what differs from the
defaults. Data paths (database, uploads, backups) NEVER go there.

| Setting | Default | Meaning |
|---|---|---|
| `SEUIL_URGENCE` | 88 | percent: below it, the hourly check does nothing |
| `SEUIL_ALERTE` | 90 | percent: still above after cleaning means an alert |
| `JOURNAL`, `TEMOIN` | `/var/log/...`, `/var/lib/...` (root); `~/.local/state/nettoyage-disque/` (no root) | journal and witness; without root an unwritable path falls back to the account folder |
| `UTILISATEURS_CACHES` | the account running the script | accounts whose caches and tool logs are cleaned; without root only the running account |
| `CACHES_UTILISATEUR` | uv, pip, deno, typescript, go-build, npx, bun | per-account caches; any entry a live process uses is spared |
| `DOCKER_IMAGES_TOUTES` | 1 | 1 = every unused image older than `DOCKER_IMAGES_AGE`; 0 = dangling only. Use 0 when tagged rollback images exist |
| `DOCKER_LOG_MAX_MO` | 100 | container json logs above this are truncated (root only) |
| `PURGES_SUPPLEMENTAIRES` | empty | `"glob|days"` or `"glob|days|name"`, files only |
| `JOURNAUX_A_PLAFONNER` | empty | `"glob|MB"`: append-only logs cut back to their last 512 KB, same inode |
| `DOSSIERS_HEBDO` | empty | `"folder|days"`, weekly only |
| `VIEILLES_VERSIONS` | 0 | weekly: old IDE server and Claude Code versions; the newest and any running one are kept |
| `LOGFLARE_CONTENEUR` | empty | self-hosted Supabase: purge `_analytics.log_events_*` beyond `LOGFLARE_JOURS` |
| `WAL_SLOT_PLAFOND` | empty | e.g. `1GB`: cap on WAL held by replication slots |
| `NEXT_DOSSIERS` | empty | Next.js apps: optimized image cache by age, webpack cache weekly; never `fetch-cache` |
| `ALERTE_CMD` | empty | command receiving the alert message; alerts always go to the system journal too |

Never add to the caches: `.local/share/uv` and `.local/bin` (installed
tools), `.cache/ms-playwright` and `.cache/puppeteer` (installed browsers),
`.bun/bin`, a vector index, an embedding model cache.
