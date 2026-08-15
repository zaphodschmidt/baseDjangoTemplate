# The one entry point. Every target is a thin call into tools/ — the logic
# lives in the scripts, so the same work runs from a shell, from CI, and from
# a server where make may not be installed.
#
# `make` on its own lists the targets.
.DEFAULT_GOAL := help
.PHONY: help up up-backend down down-now restart logs ps shell check check-quick \
        migrate api test deploy deploy-prod deploy-dry rollback \
        backup backup-prod backup-test backups restore restore-latest \
        db-monitor db-selftest db-selftest-full db-cron db-refresh db-refresh-test \
        pg-upgrade worker-role

COMPOSE ?= docker compose -f docker-compose.yml

help:  ## List targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Local stack ────────────────────────────────────────────────────────────
up:  ## Start the whole local stack
	$(COMPOSE) up -d

up-backend:  ## Start only db + backend
	$(COMPOSE) up -d db backend

down:  ## Back up, then stop the stack
	bash tools/db-backup.sh --label predown --quick && $(COMPOSE) down

down-now:  ## Stop the stack without backing up
	$(COMPOSE) down

restart:  ## Back up, then restart the stack
	bash tools/db-backup.sh --label prerestart --quick && $(COMPOSE) restart

logs:  ## Tail every service
	$(COMPOSE) logs -f --tail=100

ps:  ## Service status
	$(COMPOSE) ps

shell:  ## Django shell inside the backend container
	$(COMPOSE) exec backend python manage.py shell

# ── The gate ───────────────────────────────────────────────────────────────
check:  ## THE GATE. Run before every push
	bash tools/verify.sh

check-quick:  ## The gate without tests or the image build
	bash tools/verify.sh --quick

test:  ## Backend tests only
	$(COMPOSE) exec backend python manage.py test --noinput

# ── Schema and client ──────────────────────────────────────────────────────
migrate:  ## makemigrations + migrate + regenerate the API client
	bash tools/sync-django.sh

api:  ## Regenerate the API client only
	cd frontend && pnpm run generate-api

# ── Database ───────────────────────────────────────────────────────────────
backup:  ## Verified backup of the local database
	bash tools/db-backup.sh

backup-prod:  ## Verified backup of production
	bash tools/db-backup.sh --target prod

backup-test:  ## Verified backup of the test server
	bash tools/db-backup.sh --target test

backups:  ## List archives on disk
	bash tools/db-restore.sh list

restore:  ## Restore a named archive: make restore FILE=app_local_manual_....dump
	bash tools/db-restore.sh full $(FILE)

restore-latest:  ## Restore the newest local archive
	bash tools/db-restore.sh latest

db-monitor:  ## Are the backups actually working? (exit 0/1/2)
	bash tools/db-backup-monitor.sh

db-selftest:  ## Read-only preflight of the backup toolset
	bash tools/db-selftest.sh

db-selftest-full:  ## Real backup -> restore -> compare, into a throwaway database
	bash tools/db-selftest.sh --full

db-cron:  ## Install/inspect the nightly backup schedule
	bash tools/db-backup-cron.sh status

db-refresh:  ## Copy production's database into the local container
	bash tools/db-refresh-local.sh

db-refresh-test:  ## Copy production's database onto the test server
	bash tools/db-refresh-test-server.sh

pg-upgrade:  ## Move the local Postgres to a new major version
	bash tools/pg-upgrade.sh

worker-role:  ## Create the background worker's capped DB login
	bash tools/pg-worker-role.sh --target prod

# ── Deploy ─────────────────────────────────────────────────────────────────
deploy:  ## Verify, back up, ship to the test server
	bash tools/deploy.sh --target test

deploy-prod:  ## Verify, back up, ship to production
	bash tools/deploy.sh --target prod

deploy-dry:  ## Print the whole production deploy plan, change nothing
	bash tools/deploy.sh --target prod --dry-run

rollback:  ## Roll production back to the previous tag
	bash tools/deploy.sh --rollback --target prod
