from rest_framework.pagination import CursorPagination


class TimestampCursorPagination(CursorPagination):
    """The project-wide default. Cursor, ordered by `(-created_at, -pk)`.

    Two decisions, each with a failure behind it.

    **Cursor, not offset.** A deep offset scans every row it skips, and when
    rows arrive constantly the page boundaries move under a user who is paging
    through a list — they see a row twice, or never.

    **The primary key is in the ordering.** `created_at` is not unique, and a
    partial order lets the query plan choose which of two tied rows comes
    first. Nothing errors: the same query simply returns a different order
    after an index change or a table crossing a plan threshold, and a cursor
    built on a non-total order can then skip or repeat rows. This is the same
    defect as a `DISTINCT ON` with a partial `ORDER BY`, one layer up.

    A view whose model has no `created_at` sets its own `ordering` — and that
    ordering must still be total.
    """

    ordering = ('-created_at', '-pk')
    page_size = 50
    max_page_size = 200
    page_size_query_param = 'page_size'
