from django.db import models


class TimeStampedModel(models.Model):
    """`created_at` / `updated_at` on every table, from the first migration.

    Both columns are indexed-by-default only where a query needs it, but they
    exist everywhere from day one because adding a timestamp to a populated
    table later means a backfill with no true value to backfill.

    `created_at` is also the first half of the pagination ordering. It is NOT
    unique, which is exactly why the pagination class adds the primary key —
    see apps/core/pagination.py.
    """

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True
