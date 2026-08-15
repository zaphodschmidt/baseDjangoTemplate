#!/bin/sh
# Production container entrypoint: migrate, collect static, then serve.
#
# `migrate` runs on boot rather than as a deploy step because the container is
# the only place that reliably has both the code and the database — but that is
# also exactly why tools/deploy.sh takes a verified backup BEFORE the remote
# rebuild. A migration is the one kind of deploy `git revert` alone cannot undo.
#
# `set -e` is the point: if either command fails the container must exit, not
# start serving against a schema it failed to reach. A backend that boots
# anyway is a backend that 500s every request while reporting itself up.
set -e

echo "==> migrate"
python manage.py migrate --noinput

echo "==> collectstatic"
python manage.py collectstatic --noinput --clear

echo "==> gunicorn"
exec gunicorn config.wsgi:application \
    --bind 0.0.0.0:8000 \
    --workers "${GUNICORN_WORKERS:-3}" \
    --timeout "${GUNICORN_TIMEOUT:-60}" \
    --access-logfile - \
    --error-logfile -
