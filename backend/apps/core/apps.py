from django.apps import AppConfig


class CoreConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    # The module path is `apps.core`; the app LABEL is `core`. Migrations and
    # `db_table` names use the label, and `makemigrations <name>` for anything
    # that is not a label silently does nothing and exits 0 — so keep them the
    # same unless you have a reason not to, and write the reason here if you do.
    name = 'apps.core'
    label = 'core'
