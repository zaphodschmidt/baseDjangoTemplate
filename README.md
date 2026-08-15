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
cp .env.template .env      # then edit it
make up                    # start the stack
make check                 # the gate — run this before every push
```

`make` with no target lists everything.

## First commits in a new project

1. Edit [`tools/project.env`](tools/project.env) — identity, service names, ssh
   aliases. It is the only file in `tools/` that a new project should need to
   change.
2. Work through **Known divergences in this template** in `CLAUDE.md`. The
   template ships with `DEBUG = True`, a committed `SECRET_KEY`, and no default
   DRF permission class; each is listed there with its `file:line` and the
   smallest fix.
3. Rewrite `CLAUDE.md`'s stack table and layout for what you are actually
   building, and delete the sections that do not apply. Leave the reasoning
   alone — that part is portable.
4. Write `docker-compose.prod.yml`. Until it exists, every remote-target tool
   refuses to run, on purpose.
