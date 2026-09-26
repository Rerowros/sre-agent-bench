# sre-agent-bench

A small, reproducible benchmark of AI coding agents doing **one-shot recovery of a broken Linux server**.

Each agent gets root SSH access to a disposable Ubuntu 24.04 VPS and a single short task: *"the API stopped working after a failed update — restore it, don't lose data, make it survive reboots, run safely on the internet and have a verified backup; leave a report."* Nothing tells the agent what is actually broken. After the agent finishes, an external verifier (that the agent never sees) scores the server on 17 weighted checks, including killing the service with `SIGKILL` and rebooting the machine.

Runs were done in August 2026 on 11 model / harness configurations.

## What it measures

- **Diagnosis without hints.** Several independent faults are layered on top of each other; fixing the first visible one (HTTP 502) is not enough.
- **Fixing the root cause vs. making the symptom go away.** E.g. getting the service up by running it as root, or leaving PostgreSQL open to the internet, still costs points.
- **Data safety.** The seed rows must survive, and the verifier's own new order must survive a reboot.
- **Operational hygiene.** Non-root service user, restart policy, secrets file permissions, a bounded and non-world-writable log, a working backup timer.
- **Proof of work.** A backup must actually restore into a fresh database, and an operator report must exist on the server.

It does **not** measure cost-efficiency in a controlled way (token counts are self-reported from harness UIs and only available for part of the runs), nor general coding ability.

## The stand

`server/bootstrap.sh` installs a known-good baseline and verifies it:

- **Orders API**: a ~100-line Flask app (`server/app/app.py`) behind Gunicorn, `GET/POST /orders`, `GET /health`.
- **PostgreSQL 16** with a dedicated role and 5 seed orders; the DB password is generated per stand (`openssl rand`) and never leaves the server.
- **Nginx** reverse proxy on :80 → Gunicorn on 127.0.0.1:3000.
- **systemd** unit (`orders-api.service`, unprivileged user, hardening options, `Restart=on-failure`).
- **Backup**: `/usr/local/sbin/orders-backup` (`pg_dump -Fc` + `pg_restore --list` validation) driven by `orders-backup.timer`.
- **UFW**: only SSH and Nginx open.

Then `server/inject-faults.sh` breaks it and confirms the service is down, and `server/enable-observability.sh` turns on action capture.

## Injected faults

| # | Fault | Simulated story |
|---|-------|-----------------|
| 1 | `DATABASE_URL` in `/etc/orders-api/orders.env` has a wrong password | failed secrets rotation |
| 2 | `orders.env` made world-readable (`0644`) | same rotation, sloppy permissions |
| 3 | Nginx upstream points to `127.0.0.1:3999` instead of `:3000` | config copied from another environment |
| 4 | Service runs as `User=root` / `Group=root` | rushed override |
| 5 | `Restart=no` | same override |
| 6 | Service disabled and stopped | failed update left it off |
| 7 | PostgreSQL `listen_addresses = '*'` | remote debugging |
| 8 | `pg_hba.conf`: `host all all 0.0.0.0/0` | remote debugging |
| 9 | UFW allows `5432/tcp` from anywhere | remote debugging |
| 10 | Backup script dumps a non-existent DB, owned by root, existing dumps deleted | broken backup job |
| 11 | 64 MiB `app.log`, owned by root, mode `0666` | forgotten debug log |

`server/validate-benchmark-ready.sh` can be run on a stand to confirm all faults are in place before an agent gets access.

## Scoring

`verifier/verify-server.ps1` runs from the operator's machine over HTTP + SSH. Score = passed weight / total weight × 100.

| Check | Weight |
|-------|-------:|
| HTTP `/health` OK and connected to `orders_benchmark` | 8 |
| All 5 original seed rows preserved | 12 |
| API accepts and persists a new order | 5 |
| `orders-api.service` active | 5 |
| `orders-api.service` enabled | 5 |
| Service runs as `orders-api` (not root) | 5 |
| Restart policy `on-failure` or `always` | 5 |
| tcp/5432 not reachable from the verifier's network | 5 |
| PostgreSQL bound to loopback, no public `pg_hba` rule, no UFW exception | 5 |
| `orders.env` mode `600`/`640`, owned by root | 4 |
| `app.log` removed, or not group/world-writable **and** < 16 MiB | 3 |
| Backup script produces a valid custom-format dump | 7 |
| Backup timer enabled | 3 |
| That dump restores into a fresh DB with ≥ 6 rows | 10 |
| `/root/REPORT.md` exists and is ≥ 200 bytes | 3 |
| `-Deep`: service recovers after `SIGKILL` of the main process | 7 |
| `-Deep`: after a reboot, API healthy and the verifier's order is still there | 8 |
| **Total** | **100** |

The verifier only creates a `Verifier Probe` order and a temporary `orders_restore_check` database; it never drops the working database. By default it does not write the target address into the result JSON (`-IncludeHost` to keep it).

## Results (August 2026)

One run per configuration, all runs `-Deep`. Full data: [`results/2026-08/summary.csv`](results/2026-08/summary.csv).

| Configuration | Model | Reasoning | Harness | Batch | Score | Time | Tokens | SSH calls |
|---|---|---|---|:-:|--:|--:|--:|--:|
| composer-2.5 | Composer 2.5 | default | Cursor | 2 | **100** | ~6.6 min* | — | 37 |
| grok-4.6-high | Grok 4.6 | high | n/r | 3 | **100** | — | — | — |
| grok-4.5-high | Grok 4.5 | high | Cursor | 1 | **99**† | 7.1 min | 0.82 M | 20 |
| kimi-k3-max | Kimi K3 | max | Cursor | 1 | **98**† | 10.1 min | 1.5 M | 27 |
| opus-5-low | Claude Opus 5 | low | Cursor | 1 | 97† | 13.5 min | 3.6 M | 29 |
| luna-high | GPT-5.6 Luna | high | Cursor | 1 | 97† | 9.3 min | 3.0 M | 39 |
| sol-low | GPT-5.6 Sol | low | Cursor | 1 | 97† | 5.6 min | 1.2 M | 18 |
| gemini-3.6-flash-high | Gemini 3.6 Flash | high | Antigravity (Fast Mode) | 2 | 97 | ~12.3 min* | — | 65 |
| sol-low-codex | GPT-5.6 Sol | low | Codex App | 2 | 97 | ~6.4 min* | — | 23 |
| sol-medium-cursor | GPT-5.6 Sol | medium | Cursor | 2 | 97 | ~8.5 min* | — | 18 |
| terra-medium-cursor | GPT-5.6 Terra | medium | Cursor | 2 | 97 | ~5.8 min* | — | 29 |

- **Time**: wall-clock from `results.csv` where recorded; `*` = span between the agent's first and last SSH call from the server-side trace (a lower bound on wall-clock). "SSH calls" = SSH sessions opened by the agent, from `action-metrics.json`. "n/r" = not recorded.
- **†Batch-1 scores are hand-corrected.** The batch-1 verifier (v1) ran `pg_restore` as `postgres` directly on a dump in a `0750 orders-api` directory, so the restore check failed for everyone with *Permission denied* — a verifier bug, not an agent failure. The check was re-credited (+10) after a manual re-check and the verifier fixed (v2 copies the dump first). Two manual adjustments on top: Grok 4.5 −1 (left its own test order in the DB), Kimi K3 +1 partial credit (fixed log permissions but kept the 64 MiB file). v1 also used the looser rule "log removed or secured"; v2 adds the size bound. Raw v1 JSONs are published unchanged; batch-2 and batch-3 scores are raw v2 output.
- **The discriminating fault was the log file.** Every configuration fixed the outage, credentials, proxy, service user, restart policy, database exposure and backups, and survived `SIGKILL` + reboot. The only thing separating 97 from 100 was fault #11: 8 of 11 configurations left the 64 MiB world-writable `app.log` in place.
- With n = 1 per configuration and a 3-point spread, **this is not a ranking** — differences are within run-to-run noise. The interesting signal is qualitative (which faults get noticed) and in cost/speed, which varies ~2–4× at equal score.

### Result files

```
results/2026-08/
  summary.csv                 merged table above (scores, time, tokens, trace metrics, failed checks)
  results.csv                 operator log as recorded during the runs (target addresses removed)
  action-metrics.json         per-run counts from auditd/SSH traces: SSH calls, root execve calls, top executables
  verification/*.json         raw verifier output per configuration (target address removed)
```

Transcripts, raw traces, the agents' own `REPORT.md` files and generated prompts are intentionally **not** published: they contain real addresses, per-stand credentials and SSH commands.

## Reproducing

Requirements: a Windows operator machine (the batch scripts spawn `powershell.exe` jobs) with OpenSSH `ssh`/`scp` and `tar`; N disposable Ubuntu 24.04 VPS (1 vCPU / 2 GB RAM / 30 GB disk is enough) with root key auth. Use only throwaway machines with no production data, VPN, private network or cloud IAM role.

1. **Inventory.** Copy `config/servers.example.json` to e.g. `servers.batch1.json` (git-ignored) and fill `name`, `host`, `port`, `user` (`root`), `keyPath`. The private key is referenced by path, never embedded. Either pass `-ServersFile` to every script or set it once:

   ```powershell
   $env:SRE_BENCH_SERVERS = "$PWD\servers.batch1.json"
   ```

2. **Provision all stands in parallel** (bootstrap → verify baseline → inject faults → enable observability):

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\deploy-batch.ps1
   ```

   Optionally confirm each stand with `ssh root@<host> 'bash -s' < server/validate-benchmark-ready.sh`. Note that this call is recorded by the SSH logger and will be counted by `analyze-traces.ps1` unless you discount it.

3. **Generate one prompt per stand** from `prompts/TEMPLATE.md` + `TASK.md` into `prompts/<name>.prompt.md` (git-ignored). The published runs used the Russian `TASK.md`; `TASK.en.md` is an English translation:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\generate-prompts.ps1                    # or: -TaskFile .\TASK.en.md
   ```

4. **Run each agent** in a fresh chat, in an **empty** workspace (never this repository — the agent must not see `server/inject-faults.sh` or `verifier/`), with exactly that one prompt and no follow-up messages.

5. **Collect traces, then verify** (traces are pulled before the verifier touches the server):

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\verify-batch.ps1 -Deep
   powershell -ExecutionPolicy Bypass -File .\analyze-traces.ps1 -TraceRoot .\traces\<UTC stamp>   # optional: action metrics
   ```

6. Record time/tokens, then destroy the VPS.

Fair-comparison rules used for the published runs: same provider, region, image and VPS size; identical deploy bundle; one message per agent; no hints after start; infrastructure retries noted separately; sub-agent actions count toward the parent configuration.

## Action capture

Two independent sources are installed before the agent gets access:

- **SSH wrapper** (`ForceCommand` for root): logs every non-interactive SSH command verbatim and records interactive sessions with `script`.
- **auditd**: `execve`/`execveat` by root plus writes to all benchmark files.

`collect-traces.ps1` pulls an archive with both, the service journal, initial and final configs, the agent's `REPORT.md` and a SHA-256. Root can disable auditing, so this is observability, not tamper-proofing. Raw traces contain secrets of the disposable stand — `traces/` is git-ignored.

## Limitations

- **One scenario, one run per configuration.** No variance estimate; 1–3 point differences are noise.
- **Published faults.** With this repository public, the fault set is now contaminable. For future evaluations, change or randomize the faults and keep the variant private.
- **Outcome-only scoring.** The verifier checks end state, not how it was reached (e.g. whether the agent read logs or guessed). Traces allow a qualitative review, which is not scored.
- **Manual corrections in batch 1** (see above), and a verifier change between batches.
- **Model and harness are confounded.** Most runs used Cursor; the same model in another harness (e.g. GPT-5.6 Sol in Cursor vs Codex App) may behave differently.
- **Incomplete cost data.** Tokens are self-reported from harness UIs and missing for batches 2–3; wall-clock time is missing for batch 2 (trace span shown instead).
- **Narrow stack.** Ubuntu 24.04 + systemd + PostgreSQL 16 + Nginx + Flask only. The "reachable from the internet" check is only as good as the verifier's network vantage point.

## Repository layout

```
server/                     stand: app, bootstrap, fault injector, observability, trace collector, readiness check
verifier/verify-server.ps1  external scorer (never shown to agents)
deploy-batch.ps1            parallel provisioning of all stands in an inventory file
generate-prompts.ps1        per-stand prompts from prompts/TEMPLATE.md + TASK.md
collect-traces.ps1          pull server-side action traces
verify-batch.ps1            collect traces, then run the verifier on all stands in parallel
analyze-traces.ps1          action metrics from a trace batch
TASK.md / TASK.en.md        the task given to agents (original Russian / English translation)
config/servers.example.json inventory template (documentation IPs only)
results/2026-08/            anonymized results of the August 2026 runs
```

## License

MIT © 2026 Iaroslav
