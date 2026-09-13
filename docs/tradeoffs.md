# Design tradeoffs

This document records decisions where multiple reasonable options existed. The goal is to make it easy to revisit these choices if requirements change.

## Privilege dropping: `runuser` vs `gosu`

The container entrypoint runs as root so it can create the target user/group and write `/etc/gitconfig`. Before exec-ing Claude Code, it must drop to the target user so that files created inside the container are owned by the host user.

### `gosu` (not chosen)

[gosu](https://github.com/tianon/gosu) is the most widely recommended Docker pattern for privilege dropping. It is a minimal C binary that calls `setuid`/`setgid`/`initgroups` then exec-s the target command — no PAM, no shell overhead.

**Why not used:** It is not present in the base `node:22-bookworm` image and must either be installed at image build time (requires a custom `Dockerfile`) or at entrypoint startup (`apt-get install gosu` on every cold start). Neither is attractive for a project that intentionally avoids a custom image.

### `runuser` (chosen)

`runuser` is part of `util-linux`, which is a mandatory base package on Debian and is therefore always present in `node:22-bookworm`. It is purpose-built for running commands as another user without authentication, automatically initialises supplementary groups from `/etc/group`, and does not require PAM authentication (unlike `su`).

**Trade-off:** `runuser` requires the username to exist in `/etc/passwd`. This is guaranteed here because `useradd` always runs before `runuser` in the entrypoint.

### `setpriv` (considered but not chosen)

`setpriv` (also in `util-linux`) operates at a lower level: it sets Linux UIDs/GIDs and adjusts capabilities, then exec-s the command. It takes numeric IDs rather than a username, which works but is less readable. `--init-groups` must be passed explicitly to initialise supplementary groups. It is the right tool when fine-grained capability manipulation is needed; for simply "run as this user" `runuser` expresses intent more directly.

---

## Network isolation: host mode vs bridge

### Current status: `network_mode: host`

The container shares the host's network namespace. This means it has unrestricted outbound access and can reach host-local services (e.g. a proxy at `127.0.0.1:7890`) without bridge or address translation configuration.

Reachability is separate from proxy selection: host networking does not copy the host's proxy environment or force traffic through a proxy. By default the launcher forwards non-empty uppercase and lowercase `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, and `NO_PROXY` variables. Users can disable this with `proxy.env_passthrough: false` or `SANDBOX_PROXY_ENV_PASSTHROUGH=false`, particularly when proxy URLs contain credentials that should not enter the container.

**Why chosen:** Simplicity. Getting Claude Code's MCP servers, npm installs, and user proxies to work through a custom network configuration adds friction that was not worth addressing before filesystem sandboxing was settled.

### Future options

If network isolation becomes a goal, the main approaches are:

**Custom bridge network with egress rules**
Create a named Docker network and add `iptables`/`nftables` rules on the host to restrict what the container can reach. Allows precise whitelisting (e.g. Anthropic's API endpoints only). Requires host-level firewall management, which makes the tool harder to install and less portable.

**No network (`network_mode: none`)**
Completely disables networking. Claude Code itself would not function (it needs to reach the Anthropic API), so this is only viable if an HTTP proxy sidecar is added to the compose stack.

**Internal network + proxy sidecar**
Run a filtering HTTP proxy (e.g. Squid, mitmproxy) as a second compose service on a shared internal network. The `ai-agent` container has no direct internet access; all traffic is forced through the proxy, which can enforce allowlists. Most flexible option but significantly more complex to set up and maintain.

**User-namespace remapping**
Not strictly network isolation, but `--userns-remap` at the Docker daemon level limits what a container process can do on the host even if it escapes. Orthogonal to network restrictions; requires daemon configuration and is not per-container.

The current `network_mode: host` approach should be revisited if:
- A requirement emerges to prevent Claude Code from making arbitrary outbound connections.
- A user proxy setup makes host networking problematic (e.g. conflicting port bindings).
- The project moves toward a stricter security model after filesystem sandboxing matures.

---

## Git operation policy: wrapper script vs git aliases vs hooks

### Wrapper script (chosen)

A bash wrapper at `/usr/local/bin/git` (bind-mounted from `share/ai-sandbox/git-wrapper`) intercepts every `git` invocation. It parses argv, applies a blocklist of destructive subcommands plus flag-level checks, then `exec`s `/usr/bin/git` for allowed commands.

**Why chosen:** Handles flag-level checks naturally (`git commit --amend` blocked while `git commit -m` allowed). Centralised, inspectable, works for all users. Cannot be overridden by user git config.

**Trade-off:** Soft barrier — calling `/usr/bin/git` by absolute path bypasses it. See "Soft barrier vs hard barrier" below.

### Git aliases via `git config --system` (not chosen)

Alias `push`, `reset`, etc. to commands that fail.

**Why not used:** Aliases are bypassable via `git -c alias.push=push push`. Cannot express flag-level checks (`commit --amend` is not a separate alias from `commit`). Does not cover all destructive ops.

### Per-repo git hooks (not chosen)

Install `pre-commit`, `post-rewrite`, etc. in each repo's `.git/hooks`.

**Why not used:** Per-repo (Claude would need to init them). `--no-verify` bypasses most hooks. Does not cover `reset --hard`, `clean`, etc.

---

## Soft barrier vs hard barrier for git operations

### Current: soft barrier (wrapper script)

The wrapper at `/usr/local/bin/git` intercepts `git` invocations. Claude (or any process) can bypass it by calling `/usr/bin/git` directly.

**Why acceptable:** The threat model is accidental damage by Claude, not adversarial bypass. Claude uses `git <subcommand>` — it does not call `/usr/bin/git` by absolute path in normal operation. The existing push protection (system git config) has the same soft-barrier property (user config can override system config).

### Hard barrier options (not implemented)

- `chmod 700 /usr/bin/git` + setuid wrapper binary: blocks non-root access to real git. Requires a compiled setuid binary (setuid scripts don't work on Linux). Significant complexity.
- AppArmor/SELinux profile: restricts which binaries can execute git. Requires host-level MAC configuration, harms portability.
- Custom git binary with built-in restrictions: requires building git from source, ongoing maintenance.

Hard barriers are out of scope for the non-adversarial threat model. If the threat model changes (e.g. running untrusted Claude plugins), revisit.

---

## Browser automation: on-host remote MCP vs in-sandbox browser

### On-host Playwright MCP server (chosen)

A resident systemd user service runs the `playwright-mcp` package on the host, bound to `127.0.0.1`, exposing HTTP at `/mcp`. The agent (inside the container) reaches it through `network_mode: host` and drives a browser that is created and shown on the host.

**Why chosen:** The browser is user-visible and interactive by default, which is the main goal. There is no browser (or large Playwright browser cache) inside the container, so the sandbox's blast radius does not gain a networking surface beyond the MCP endpoint. The MCP server provides high-level agent-friendly tools (`browser_navigate`, `browser_click`, `browser_snapshot`) rather than raw CDP.

**Trade-offs:**
- The MCP port is reachable by any process in the container (host networking). Mitigations: bound to `127.0.0.1` only, and the agent already has the same trust boundary as the documented host proxy passthrough. Not an adversarial boundary.
- The service is a resident process, though the expensive resource (the browser) is still launched only on demand. True socket activation was considered but rejected: `playwright-mcp`'s HTTP transport must bind its own port, so a systemd socket would have to hand off the listening FD to a Node HTTP server, which the tool does not support cleanly.
- Requires the `playwright-mcp` package and `node`. The launcher prefers a *system* browser (chromium/chrome, then firefox) so the user's real profile/logins are driven and no Playwright browser build is downloaded; if none validates against the installed Playwright, it falls back to Playwright's own chromium (auto-installed on first need). Headed mode additionally needs a display (auto-detected — Wayland or X11).

### Playwright in the container (not chosen)
Install `playwright`/`chromium` inside the container and run it headless or with a VNC.

**Why not used:** A headless in-container browser is invisible to the user (defeating the main point), needs a sizeable cache in the `ai-agent-home` volume, and headless displays must still be mirrored back out. On-demand host browser is both simpler and more aligned with the goal of user visibility.

### Raw CDP to a host Chrome (alternative)
Launch Chrome on the host with `--remote-debugging-port` and connect from inside over CDP.

**Why not used for the wire-up:** It works and is lighter, but CDP is a low-level protocol; the MCP server adds the accessibility-snapshot tooling agents actually use. CDP remains the fallback if `PLAYWRIGHT_MCP_URL` is used directly from a Playwright script.
