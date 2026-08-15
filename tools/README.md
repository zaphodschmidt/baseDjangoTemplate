# `tools/` — backup, restore, verify, deploy

The operational half of the template. Every script is project-agnostic:
everything that differs between one repo and the next lives in
[`project.env`](project.env), so porting the toolset is one edit rather than
fourteen.

Everything is reachable through `make` from the repo root. `make` with no
target lists them.

---

## Before anything else: `project.env`

Open `tools/project.env` and set the identity, the compose files, the service
names, and the ssh aliases. Nothing else in `tools/` should ever need editing
for a new project.

Two values are load-bearing:

- **`BACKUP_PREFIX`** is the first field of every archive filename. Changing it
  after backups exist orphans the old ones, because the pruner and the restore
  lookup both glob on it.
- **`COMPOSE_PROD`** names a production compose file that this template does
  not ship. Every remote-target script refuses to run until it exists. That
  refusal is deliberate: a deploy script that guesses at your production
  topology is worse than one that stops and says so.

---

## The one thing to know: targets

Every database script takes `--target local | prod | test`.

| target | Postgres | reached via | auth |
|---|---|---|---|
| `local` | the `db` container from the local compose file | `docker exec` | the DB user/password in `.env` |
| `test` | **host** postgres on the test server | `ssh $TEST_SSH` | peer auth as `postgres`, no password |
| `prod` | **host** postgres on the production server | `ssh $PROD_SSH` | peer auth as `postgres`, no password |

**`pg_dump` and `pg_restore` always run on the target, never here.** A client
older than the server refuses the dump outright, and the two boxes drift apart
the moment either is upgraded — so a tool that dumps locally works until the
day a server is patched, then stops. Running on the far side also means the
verification pass uses a `pg_restore` that actually understands the archive it
just wrote. As a bonus, peer auth needs no password, so there is no secret in
the path at all.

---

## Backups

```bash
make backup                            # local, label 'manual'
make backup-prod                       # production, over ssh
./tools/db-backup.sh --target prod --label predeploy --sql
make backups                           # what's on disk
```

Archives land in `backups/<target>/` (gitignored) as
`<prefix>_<target>_<label>_<timestamp>.dump`, custom format, compress=6.

The order of operations is the point:

1. `pg_dump` on the target, to a temp file **on the target**.
2. `pg_restore --list` on the target. A dump is not a backup until something
   has proved it can be read; if this fails the file is deleted and the script
   exits non-zero, so a corrupt dump never becomes a file that *looks* like a
   backup.
3. `sha256sum` on the target, then stream the archive back and re-checksum
   here. Size and hash must both match or the local copy is deleted.
4. Write a `.meta` sidecar: server version, source size and table count, sha256,
   the repo commit that was deployed, who ran it, and the exact restore command.
5. Prune, per label.
6. The target-side temp file is removed on **every** exit path, so nothing is
   left owned by `postgres` in `/tmp` on a production box.

### Retention

Pruning is per label, because the two kinds of backup mean different things:

| label | kept for | what it is |
|---|---|---|
| `auto` | 30 days | the nightly cron job |
| anything else | 90 days | a human made this at a moment that mattered |

The newest `--keep-min` (default 5) of each label are **never** pruned, so an
outage that stops backups for six weeks cannot also delete the last good one.
`--keep-days N` / `--no-prune` override.

Labels the toolset uses itself: `predeploy`, `safety` (before a restore),
`predown` / `prerestart`, `pgupgrade`, `selftest`.

---

## Restore

```bash
make backups                                        # pick one
make restore-latest                                 # newest for the target
make restore FILE=app_local_manual_20260731_120000.dump
./tools/db-restore.sh full <file> --target test
```

The dangerous script, so it is deliberately obstructive. In order:

1. Prints the current database next to what the archive contains, so you can
   see what you are about to lose.
2. Re-checksums the archive against its `.meta` and **refuses** if the file
   changed on disk.
3. Refuses a major-version downgrade unless you confirm — those routinely fail
   *after* the drop.
4. **Takes a safety dump of the current database first.** A restore is itself a
   destructive write, and the state you are about to overwrite is in no backup
   unless you make one. If the safety dump fails, the restore does not happen.
   `--no-safety-dump` exists; don't use it.
5. Stops the app services, so nothing reconnects and writes into a half-restored
   schema.
6. Uploads, verifies on the target, terminates stray sessions, drops, recreates,
   restores with 4 parallel jobs.
7. Restarts **exactly** the services that were running — via an `EXIT` trap, so
   a failed restore never also leaves you with a stack that is down.
8. Compares table counts against the `.meta`.

---

## Is any of this actually working?

```bash
make db-monitor                        # exit 0 healthy / 1 warn / 2 critical
make db-selftest                       # read-only preflight
make db-selftest-full                  # real backup -> restore -> compare
```

`db-backup-monitor.sh` is what turns "we have backups" into something
checkable — a cron job that silently stopped looks exactly like one that never
had a problem. It checks freshness, count, disk headroom, whether a cron entry
exists at all, and re-verifies the newest archive's sha256, which is what
catches bit-rot before you discover it at 3am. Non-zero exit is the alertable
signal, so wire it to whatever pages you.

`db-selftest.sh --full` is the only check that proves anything end to end: it
takes a real backup and restores it into a **throwaway** database on the same
server, compares table counts, and drops it. The live database is never
touched. Cheap enough to run monthly — an untested backup is a hypothesis.

### Scheduling

```bash
./tools/db-backup-cron.sh install                   # local, nightly 02:00 + 03:00 health check
./tools/db-backup-cron.sh install --target prod --hour 3 --weekly-sql
./tools/db-backup-cron.sh status
./tools/db-backup-cron.sh remove
```

It manages a fenced block in your crontab, so `remove` takes out exactly what
`install` added and re-running `install` replaces the block rather than
appending a second copy. Logs to `backups/cron.log`.

⚠️ For `--target prod|test`, **cron has no ssh-agent.** The key must be
passphrase-less and named in `~/.ssh/config`, or the jobs fail silently at 3am.
`ssh -o BatchMode=yes <alias> true` is the check, and the installer runs it.

---

## Verify — `make check`

```bash
make check                             # every gate
make check-quick                       # skip tests and the image build
./tools/verify.sh --no-image
```

Cheapest gate first, aborting on the first failure:

| # | gate | catches |
|---|---|---|
| 1 | `manage.py check` | a misconfigured setting — a container that boots and 500s |
| 2 | `makemigrations --check` | a model edited with no migration: deploys fine, then serves against a schema that doesn't match |
| 3 | `tsc --noEmit` | frontend type errors, including in the generated client |
| 4 | regenerate + `git diff` on `src/api/` | a committed client that no longer matches the schema |
| 5 | the test suite | everything else |
| 6 | production image build | **the point of the script** |

Gate 6 is why this exists. There is no image registry, so production images are
compiled **on the production box** during `up -d --build` — after the pre-deploy
backup, and after the checkout has already moved to the new tag. A TypeScript
error is therefore not a dev-box failure; it is a mid-deploy failure with the
stack down. Building the same images here first makes it a dev-box failure
again.

Gate 4 deserves a note: it regenerates *before* comparing, so hand-editing
`src/api/` proves nothing — what it catches is an API change that was never
regenerated, which is the failure that matters. And `git diff` sees only tracked
files, so the gate is inert until `src/api/` has been committed once.

Gates 1, 2 and 4 need the local stack; it is started if it isn't up.

---

## Deploy

```bash
make deploy                            # -> test server
make deploy-prod                       # -> production, patch bump
make deploy-dry                        # print the whole plan, change nothing
./tools/deploy.sh --target prod --minor
make rollback
```

Images build on the target, so the deploy itself is just pull + rebuild. The
value is on either side of that.

**Before** — a clean working tree is required (`--force` overrides, and also
disables the version bump); the remote checkout, env file and passwordless
`sudo docker` are all verified; the tree is synced with `origin` so "latest"
means latest on origin rather than latest on whichever box you are sitting at;
then **`tools/verify.sh` runs before any mutation** — no bump, no tag, no push,
no backup, so a failed gate costs nothing and leaves nothing behind. Then
`VERSION` is bumped, committed, tagged `v<semver>` and pushed *before* the
remote pulls; then a **verified pre-deploy backup of the target database**.

That backup is a hard gate. If it fails, the deploy does not happen. Deploying a
Django change runs `migrate` on boot, and a migration is the one kind of deploy
`git revert` alone cannot undo.

**After** — it polls until every service in `DEPLOY_EXPECT_SERVICES` reports
`running`, because `up -d --build` exits 0 even when a container starts and
immediately crash-loops. Then it polls the app itself: `--health-url`, else
`https://<first allowed host><HEALTH_PATH>`, else the remote loopback. It
probes the site root as well as the API, because a deploy in which only the
frontend upstream broke passes an API-only check green while the whole UI 502s.
On failure it dumps the last 40 log lines and prints the exact rollback
commands — or runs them, with `--rollback-on-fail`.

Rollback checks out the previous `v*` tag and rebuilds. It also reminds you,
loudly, that **a code rollback does not roll back a migration** — restore the
pre-deploy backup too.

---

## Postgres major upgrades

```bash
./tools/pg-upgrade.sh --to 17
```

Local only, and on purpose. Postgres refuses to start on a data directory
written by a different major version, so bumping `image: postgres:16` to `:17`
just makes the container crash-loop; the volume has to be dumped, destroyed and
refilled. The script does that in four steps, with a verified archive taken
first and a loud confirmation before `docker volume rm`.

Servers run Postgres on the host, not in a container — upgrading those is a
`pg_upgradecluster` job, and a script that deleted a docker volume there would
delete the wrong thing.

---

## Pulling production data down

Distinct from `db-restore.sh`: these copy **production's live database**
somewhere else, rather than replaying an archive.

```bash
make db-refresh                        # production -> your local container
make db-refresh-test                   # production -> the test server
```

Both are thin: `pg_dump` on production (peer auth, no password) streams a
custom-format archive here, then `db-restore.sh` loads it into the target.
Everything dangerous — verify-before-dropping, safety dump, stop the writers,
restart exactly what was stopped — comes from `db-restore.sh`, and the source
side comes from the `src_*` helpers in `lib/common.sh`. Neither script drops or
restores anything itself.

**Major versions are compared up front**, before the dump and long before
anything is dropped, because a newer archive fails *partway into* an older
server — after the drop. If your local container is behind:

```bash
./tools/db-refresh-local.sh --upgrade-pg    # one pass: dump, bump local PG, restore
```

`--dump-only` fetches the archive and restores nothing. The file is written
`0600` — it is a complete copy of production — with a `.meta` sidecar, so one
dump can feed both the test server and the local box.

---

## Schema + client codegen

```bash
make migrate                           # all apps
./tools/sync-django.sh core billing    # only these app LABELS
./tools/sync-django.sh --no-api        # migrations only
```

`makemigrations` + `migrate` inside the backend container, then `generate-api`
on the host against the container's `/api/schema/`. Both halves in one command,
because doing only the first is the failure this exists to prevent: the schema
moves, the committed client does not, and the frontend's types keep describing
an API that no longer exists. They still compile.

Note that an app **label** is not always its module name. `makemigrations
<name>` for a name that is not a label silently does nothing and exits 0, which
looks exactly like success — so this defaults to every app.

---

## The watchdog, and the worker's connection budget

These two are halves of one lesson: *a background worker must not be able to
take the application down, and a watchdog must not be able to hide that it did.*

```bash
./tools/pg-worker-role.sh --target prod --limit 20   # create/repair the role
./tools/pg-worker-role.sh --target prod --show       # report, change nothing
```

The failure they come from: a background worker leaked a Postgres connection
per task (threads that touch the ORM get their own connection, and Django only
closes connections at request/task boundaries — never at thread exit). It
reached all 100 of `max_connections`, at which point the API and `psql` itself
could not connect to a database that was otherwise healthy. Every writer shared
one unlimited role, so nothing in the system could express *"a worker may not
use every connection."*

`pg-worker-role.sh` creates that missing invariant at layer 1: a dedicated login
`IN ROLE` the app role — so it inherits every privilege and needs no GRANTs of
its own — with a `CONNECTION LIMIT`. Give that login to the worker service only,
falling back to the shared credentials when unset so local and test boot
unchanged. A future leak then exhausts the worker's own budget and fails
background tasks in one container, loudly, while the site stays up.

`app-health-check.sh` is the systemd watchdog. Its predecessor responded to
*any* 502 with `compose down` + `systemctl restart postgresql` + `up -d --build`,
which during that outage meant: destroy the evidence, restart the database under
every healthy client, rebuild every image, and start the leaking worker again —
a loop it repeated every 15 minutes without ever fixing anything. This version
logs the per-container connection census *before* acting, restarts only the
container that is hogging slots (or only the ones that are not running),
escalates just once, never touches PostgreSQL, never rebuilds, and has a
cooldown so a recurring fault surfaces as a failed unit instead of a flap.

Install it as a **systemd timer**, not cron: systemd records a failed unit, and
a watchdog whose failures are invisible is the exact failure mode it exists to
prevent.

```ini
# /etc/systemd/system/app-health-check.service
[Service]
Type=oneshot
Environment=HEALTH_URL=https://example.com/api/health/
Environment=REPO_DIR=/home/ubuntu/app
Environment=APP_CONTAINERS=backend nginx
ExecStart=/home/ubuntu/app/tools/app-health-check.sh
```

```ini
# /etc/systemd/system/app-health-check.timer
[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
```

Point `ExecStart` at the file **in the checkout**, never a copy in a home
directory — an untracked copy is how the previous watchdog stayed wrong for a
year.

---

## Layout

```
tools/
  project.env               the only file you edit for a new project
  lib/common.sh             target + source abstraction, .env parsing, logging, compose control
  db-backup.sh              dump + verify + checksum + prune
  db-restore.sh             safety dump + stop + restore + restart + verify
  db-refresh-local.sh       production -> local container
  db-refresh-test-server.sh production -> test server
  db-backup-monitor.sh      health check, non-zero exit on trouble
  db-backup-cron.sh         install/status/remove the schedule
  db-selftest.sh            preflight, and --full round-trip proof
  verify.sh                 the gate: checks, migrations, types, codegen, tests, image build
  deploy.sh                 verify gate + version + backup gate + ship + health + rollback
  pg-upgrade.sh             local PG major version bump
  pg-worker-role.sh         the worker's own capped DB login (CONNECTION LIMIT)
  app-health-check.sh       the production watchdog systemd runs every 15 min
```

`lib/common.sh` is sourced by all of them and is where the target abstraction
lives — the same reason the backend keeps logic in `services.py` instead of the
view. **If you add a script, put the shared part there** rather than copying the
`tgt_*` helpers; two copies of a target abstraction is how one of them ends up
dumping production into the wrong place.
