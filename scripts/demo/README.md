# Scripted demo

`scripts/demo/run.sh` starts one Malachi node with Jaeger and Prometheus from the default
`docker-compose.yml`, produces 20 records and consumes them as a consumer group with the Node.js clients in
`scripts/`, then shows the trace of a produce and the count of produced records, with the URL of each UI
(issue #373). It needs Docker and Node.js 22 or newer.

```bash
scripts/demo/run.sh          # runs, then stops the stack and removes its volumes
scripts/demo/run.sh --keep   # leaves the stack running to explore Jaeger and Prometheus
```

It runs as its own compose project (`<COMPOSE_PROJECT_NAME or malachi>-demo`), so it never removes a
development stack's volumes. It uses the compose file's host ports, which `worktree.env` sets per worktree:
stop a development stack on the same ports first.

## Recording

The demo is written to be recorded as it runs:

```bash
asciinema rec -c scripts/demo/run.sh demo.cast
```

A two to three minute video per milestone is recorded by the maintainer from the same run. Malachi runs and is
measured on Linux only; the demo runs it in Docker.
