# baseDjangoTemplate

Django + DRF, React + TanStack, one Postgres, and the operational toolset to
run and deploy it. Copy it, and start from a stack that already has a gate, a
verified backup path and a deploy that can be undone.

**[`CLAUDE.md`](CLAUDE.md) is the standard** — what to build, where logic goes,
and why each rule exists. Read it before writing code. It is also the file
Claude Code reads, so the conventions apply to human and agent alike.

**[`tools/README.md`](tools/README.md)** documents the operational half.

## Start

```bash
cp .env.template .env
python -c 'from django.core.management.utils import get_random_secret_key as k; print(k())'
#   ...paste into SECRET_KEY, set DB_PASSWORD, then:
make up                    # start the stack
make hooks                 # install the git hooks (once per checkout)
make check                 # THE GATE — run this before every push
```

`make` with no target lists everything.

The stack is **same-origin in both environments**: vite proxies `/api` to the
backend in development, nginx serves the built frontend and proxies `/api` in
production. That is why there is no CORS configuration anywhere, and why the
frontend calls `/api/...` rather than a hostname.

## First commits in a new project

1. Edit [`tools/project.env`](tools/project.env) — identity, service names, ssh
   aliases. It is the only file in `tools/` a new project should need to change.
2. Pick your host ports in `.env`. Any host port is a shared resource on a box
   running several stacks, and the obvious default is the most likely to be
   taken — `docker ps --format '{{.Ports}}'` before you claim one.
3. Rename `apps/core` to your real core app if you want, and fill in the
   blessed-core table in [`backend/apps/README.md`](backend/apps/README.md).
   That table is the only place the one-way dependency rule is checkable.
4. Rewrite `CLAUDE.md`'s stack table and layout for what you are actually
   building, and delete the sections that do not apply. Leave the reasoning
   alone — that part is portable.
