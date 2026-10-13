# bwrap `serve` and `openchamber`: Detached Server on the Namespace Backend

**Date:** 2026-10-13
**Status:** Approved, pending implementation
**Scope:** Implement phase 2 of `2026-10-10-more-runtimes-design.md` for the detached OpenCode server: make `serve start|stop|attach` and `openchamber start|stop` work under `--runtime bwrap` with full parity to the Docker path. The server runs the host's installed OpenCode inside a detached, unprivileged bwrap sandbox; OpenChamber continues to run on the host and attach over loopback. Docker behavior is unchanged.

## Goal

`serve` and `openchamber` are today Docker-only. This design removes that limitation so a user who prefers the lightweight, daemonless bwrap backend can also run a detached OpenCode server (e.g. for phone/browser access) and drive it with OpenChamber, without re-downloading a toolchain into an image.

The observable contract stays the same as Docker's:

1. `serve start` returns immediately with a URL; the server keeps running after the launcher exits.
2. `serve stop` tears the server down; `serve attach` opens a TUI against it.
3. `openchamber start` brings up the server *and* the host-side UI in one command; `stop` stops both (`--keep-server` leaves the server).
4. `--port` / `--hostname` select the bind exactly as under Docker (both runtimes use host networking).
5. The server password never appears in command arguments.

The one deliberate difference: under bwrap the server runs the **host's** OpenCode, so an image-version pin (`--tool opencode@x`) is ignored with a warning — matching the interactive bwrap backend.

## Background and decision record

`2026-10-10-more-runtimes-design.md` introduced the bwrap backend for interactive runs and explicitly deferred `serve` ("Phase 2 (later specs)"). This spec is that phase.

Verified on this host (bubblewrap 0.13.0) while designing:

- Killing the bwrap **monitor** process does **not** terminate the sandboxed child (without `--die-with-parent` the child is orphaned). A detached server therefore cannot be stopped by signaling the monitor alone.
- Launching the sandbox under `setsid` and sending a **process-group** signal (`kill -TERM -- -PGID`) *does* reach the sandboxed child, even with `--unshare-all` (full PID-namespace isolation).
- OpenCode writes its own log to `<data-dir>/log/opencode.log`; under bwrap the data dir is the host's (via the existing tool-config passthrough), so OpenCode's logging works unchanged. No launcher-side log command is needed.

## Non-goals

- Changing Docker `serve`/`openchamber` behavior. The Docker path is refactored behind a seam but renders the same commands.
- Network isolation (`--unshare-net`) for the server; shared host networking continues in both runtimes.
- A `serve logs` subcommand. OpenCode logs itself; the launcher adds only a small fallback capture for startup failures.
- Root-user mode, the per-UID `ai-agent-home` volume, and the cleanup container — Docker-only concepts with no bwrap analogue.
- macOS/Seatbelt.

## Decisions (confirmed during brainstorming)

- **Full parity scope:** `serve start|stop|attach` and `openchamber start|stop` under bwrap.
- **Host tool, pins ignored:** the detached server runs the host's `opencode`; a requested `--tool opencode@x` is warned as ignored (same as interactive bwrap), and the v1/v2 command+health shape is derived from the **host** version.
- **No `serve logs`:** rely on OpenCode's own log; capture the detached process's stdout/stderr to a fallback file in the state dir for failures that happen before OpenCode's logger starts.
- **One runtime seam:** `stop`/`attach` dispatch on a recorded runtime (not the resolved `--runtime`), so `serve stop` (default runtime `docker`) still stops a bwrap server.

## Architecture

### Runtime seam for the serve actions

The `serve start|stop|attach` and `openchamber` bodies are refactored to dispatch on runtime:

- **`start`** dispatches on the *resolved* `--runtime` (CLI > env > config > default).
- **`stop` / `attach`** dispatch on the runtime *recorded by the server*, because a user may run `serve stop` without `--runtime bwrap`.

The bwrap backend records a small key/value state file, `$SERVE_STATE_DIR/serve.state` (Docker keeps its container labels, exactly as today):

```
runtime=bwrap
package=opencode-ai@1.x | @opencode/cli@2.x   # selects the attach command shape
port=4096
hostname=0.0.0.0
pgid=<process group id>
pw_var=OPENCODE_PASSWORD | OPENCODE_SERVER_PASSWORD  # the env var the server password is read into
```

`$SERVE_STATE_DIR` is already the per-user, per-workspace directory (`.../ai-sandbox/serve/ai-sandbox-serve-<uid>-<hash>`), already created `0700` for `start`, and already preserved on success by the `SERVE_STARTED` guard in the exit trap. Generated files that a detached server needs (below) live there so `stop` can remove them.

**Runtime dispatch:** the presence of `serve.state` marks a bwrap server; when it is absent the server is a Docker server and `stop`/`attach` use the container labels exactly as today. This keeps the Docker path byte-identical while giving bwrap a runtime-agnostic record.

### Detached bwrap server

`serve start` under bwrap assembles the **same** sandbox as an interactive run — `bwrap_prepare_base`, `bwrap_prepare_git`, `bwrap_translate_mounts`, `bwrap_prepare_env`, `bwrap_translate_env`, the tool-config passthrough mounts, git policy/config, and the browser MCP wiring — with two differences:

1. **Detached, not tied to the launcher.** `bwrap_prepare_base` gains a `BWRAP_DETACHED` mode that **omits `--die-with-parent`** (the server must outlive the launcher). Interactive runs keep it.
2. **Background launch.** The sandbox is started as

   ```sh
   setsid bwrap "${args[@]}" </dev/null >>"$SERVE_STATE_DIR/server.log" 2>&1 &
   ```

   `setsid` makes the monitor a session/group leader, so its PID is the process-group ID; the launcher records that PGID in `serve.state`.

**Readiness probe.** The server binds the host network (`--share-net`), exactly like Docker's `network_mode: host`, so the probe runs on the host against loopback (mapping `0.0.0.0`→`127.0.0.1`, `::`→`::1`), reusing Docker's authenticated `/global/health` (v1) / `/api/info` (v2) check. The credential is supplied through the environment (Node) or a `0600` netrc file (curl fallback) — never argv. The probe also checks group liveness and stops early if the process dies, mirroring Docker's `State.Running` checks.

**Teardown (`stop`).** `serve_stop_bwrap`:

```sh
kill -TERM -- "-$pgid"          # reaches the sandboxed server
# wait up to N seconds for the group to disappear
kill -KILL -- "-$pgid" 2>/dev/null || true
```

then removes `$SERVE_STATE_DIR` (state, password file, generated git/mcp files, log) and prints the stopped message. A stale `serve.state` whose group is gone is treated as a stopped server, matching Docker's stopped-container handling.

**Liveness.** `kill -0 -- "-$pgid"` decides running vs. stopped for duplicate/reuse logic. (A PGID reused by an unrelated process after a crash is a theoretical false positive; mitigated by removing the state dir on every clean stop and by the low probability of exact PGID reuse.)

**`attach`.** Assembles the interactive sandbox (`--die-with-parent` on) and runs the attach client against the recorded URL: `opencode attach http://<host>:<port>` (v1) or `opencode --server http://<host>:<port>` (v2), shape selected from `serve.state`'s `package`. `attach` opens a *second* sandbox that shares the workspace and home layer with the running server, analogous to Docker's `exec` sharing the container.

### Credential handling

Docker forwards `-e NAME`, so the password value never enters argv. `bwrap --setenv NAME VALUE` *would* expose it in the monitor's argv (`ps`). To preserve Docker's property:

- The launcher writes the server password to a `0600` file in `$SERVE_STATE_DIR`.
- The file is bound read-only (`--ro-bind`) into the sandbox.
- The sandboxed command is a tiny `sh -c 'export OPENCODE_PASSWORD="$(cat …)"; exec …'` that reads the file into the environment immediately before `exec`, so the value is never an argument and not in the sandbox's argv either.
- `stop` deletes the file with the state dir.

The variable name follows Docker's rule: `OPENCODE_SERVER_PASSWORD` for v1, and `OPENCODE_PASSWORD` (or `OPENCODE_SERVER_PASSWORD` when that is what the user set) for v2.

### Version and command-shape resolution

Under bwrap the running server is the host's OpenCode, so:

- `hv="$(detect_host_version opencode)"` decides the shape: `''|1|1.*` → `web` (or `serve` with `--headless`) + `/global/health`; otherwise → `serve` + `/api/info`.
- A requested pin (`OPENCODE_VERSION` or `--tool opencode@x`) is **ignored** with the existing interactive warning ("version pins are ignored under --runtime bwrap; the host opencode is used").
- openchamber's "requires OpenCode 2.0.20+" check is evaluated against the **host** version under bwrap (against `TOOL_PACKAGE` under Docker).

### openchamber integration

`openchamber_start_ui` is already runtime-agnostic: it attaches the host UI to `http://127.0.0.1:$SERVE_PORT`. Only two things are Docker-coupled today and are routed through the seam:

- The **server-reuse** path reads Docker labels; it now reads `serve.state` (falling back to labels).
- **stop** (`--keep-server` or not) already calls `openchamber_stop_ui` then the shared server stop; the shared stop is now runtime-dispatched.

`openchamber` inherits the bwrap behavioral differences: host tool (pins ignored), detached `setsid` server, and teardown by group signal.

### Refactor shape

- Split `run_bwrap_agent` into a sandbox **assembly** step and a **run a command** step, so `serve` (detached) and `attach` (interactive) reuse the assembly without duplicating the mount/env/git/policy logic.
- Add `serve_start_bwrap`, `serve_stop_bwrap`, `serve_attach_bwrap`, and `serve_state_{write,read,clear}` helpers, all **outside** the main guard (testability invariant).
- `bwrap_prepare_base` consults a `BWRAP_DETACHED` flag for `--die-with-parent`; `bwrap_prepare_git` writes its generated config into `$SERVE_STATE_DIR` when detached (so `stop` can remove it) instead of a bare `mktemp`.

## Compatibility matrix (updated)

| Concern | Docker backend | bwrap backend |
|---|---|---|
| `serve` | Yes | **Yes (this spec)** |
| `serve attach` | `docker exec` TUI | Second bwrap sandbox, same home layer |
| Detached server | `docker compose run -d` | `setsid bwrap … &`, recorded PGID |
| Server state | Container labels | `serve.state` |
| Teardown | `docker stop` / `rm` | group `SIGTERM`, then `SIGKILL` |
| Readiness probe | `docker exec node` (in container) | host-side node/curl against loopback |
| Server tool | `npx @pinned` in the image | host `opencode` (pins ignored) |
| Password in argv | No (`-e NAME`) | No (0600 file, read before `exec`) |
| Server logs | `docker logs` | OpenCode's own log; launcher fallback in `server.log` |
| `openchamber` | Yes | **Yes (this spec)** |
| Cleanup container / root mode / volume | Yes | Not applicable |
| Network | host | host |

## Error handling

- `serve` / `openchamber` with `--runtime bwrap` no longer error; the "available only with --runtime docker in this release" rejection is removed.
- bwrap unavailable (no `bwrap`, or unprivileged user namespaces restricted) is rejected before any server starts, with the existing `bwrap_available` remediation.
- A `stop`/`attach` whose server cannot be found reports the same "server is not running for <workspace>" message as Docker.
- A server that never becomes ready leaves its state and log for inspection and directs the user to `asb serve stop`, matching Docker's "inspect … then use `asb serve stop`" behavior.

## Security model and trade-offs

- The detached server keeps Docker's properties: host networking, a mounted (host-passed) OpenCode config/data/log, and a password that never appears in command arguments.
- It additionally keeps bwrap's kernel-enforced write boundary: the server can write only the workspace, the per-workspace home layer, and explicitly `:rw` paths — the same boundary as an interactive bwrap run.
- The credential file lives in the per-user `0700` state dir, is bound read-only, and is removed on stop.
- `--die-with-parent` is dropped only for the detached server; every interactive bwrap run (including `attach`) keeps it, so a killed launcher still reaps interactive sandboxes.
- The threat model is unchanged: accidental damage by the agent, not adversarial escape.

## Testing

Source-level (host, no root, no Docker), using a **stubbed `bwrap`** that records argv, mirroring `tests/serve/test.sh`'s stubbed `docker`:

- `serve start --runtime bwrap` argv assembly: `--unshare-all --share-net`, **no `--die-with-parent`**, workspace/home-layer/tool-config binds, git-wrapper bind, translated `--setenv`.
- `setsid` is used and the recorded `serve.state` has `runtime=bwrap`, port, hostname, package, and a live PGID.
- The password value appears in **no** argv element (it is passed via the bound file), for both v1 and v2 variable names.
- Host-version → command/health shape: `web`+`/global/health` (v1) vs `serve`+`/api/info` (v2); a pin is warned as ignored.
- `serve stop` (with the default `--runtime docker`) dispatches on `serve.state` and signals the recorded group; `serve stop --runtime bwrap` does the same.
- `serve attach` builds the interactive shape (`--die-with-parent` present) with the recorded URL and `attach`/`--server` per package.
- Legacy fallback: with no `serve.state` but a Docker container present, `stop`/`attach` use labels (regression lock for existing behavior — the current `tests/serve` cases must stay green).
- openchamber reuse under bwrap reads `serve.state`; the host-version v2 check; `stop`/`--keep-server` route through the seam.
- The Docker `serve`/`openchamber` rendered commands are unchanged (existing `tests/serve` and `tests/openchamber` are the regression lock).

Integration (skipped when `bwrap` or user namespaces are unavailable), mirroring `tests/bwrap/test.sh`:

- With a **fake `opencode`** on `PATH` that serves a tiny HTTP endpoint honoring `--hostname`/`--port` and the password env: `serve start` detaches, reports ready, and the process survives the launcher; `serve stop` terminates it (no orphan remains); the workspace is writable and a write outside it fails.
- `serve attach` runs the fake tool with the attach shape against the recorded URL.

## Documentation

Per the "Keeping docs in sync" checklist:

- `README.md` — drop "`serve` … remain Docker-only" and the `--runtime bwrap` non-goal note; document bwrap `serve`/`openchamber` (detached, host tool, pins ignored, OpenCode's own log).
- `docs/architecture.md` — the serve runtime seam, the detached-bwrap lifecycle, and the state file.
- `docs/development.md` — invariants (runtime dispatch on recorded state; credentials never in argv; `--die-with-parent` off only for detached serve; generated files in the state dir) and manual test items.
- `docs/configuration.md` — note that `runtime` now applies to `serve`/`openchamber`.
- `--help` — the `OPENCHAMBER`/`serve` text no longer implies Docker-only.
- Completions — unchanged (no new flags).

## Files expected to change

| File | Change |
|---|---|
| `bin/ai-sandbox` | Remove the bwrap-serve rejection; runtime seam for `serve`/`openchamber`; `serve.state`; `serve_{start,stop,attach}_bwrap`; `BWRAP_DETACHED`; credential-file handling; split `run_bwrap_agent` assembly/run |
| `tests/serve/test.sh` | Stubbed-bwrap unit cases + `serve.state` + legacy-label fallback |
| `tests/openchamber/test.sh` | bwrap reuse/stop routing; host-version check |
| `tests/bwrap/test.sh` | Real-bwrap detached lifecycle with a fake `opencode` (skippable) |
| `README.md`, `docs/architecture.md`, `docs/development.md`, `docs/configuration.md` | As above |
| `docs/superpowers/specs/2026-10-13-bwrap-serve-design.md` | This spec |

## Open questions

- **Probe interpreter.** Prefer host `node` (password via env); fall back to `curl --netrc-file`. Finalized in the plan by checking what the bwrap backend can already assume about the host toolchain.
- **Failure retention.** Whether a never-ready bwrap server is left running for inspection (Docker parity) or reaped but its log kept. Leaning to Docker parity (leave it, require `serve stop`).
- **PGID reuse.** Whether to record the process start time to harden stale-state detection, or rely on clean-stop state removal.