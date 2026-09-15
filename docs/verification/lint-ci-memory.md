# CI lint memory measurement

The 2026-09-14 mirror commissioning measured `bin/fm-lint.sh` in its CI mode (full canonical set, `--external-sources`, extended dataflow, two bounded workers) after the seed's `Lint` job died on a hosted runner with only its two banner lines printed.
At the time of that measurement the seed repository was private; `brentsec/firstmate` is a PUBLIC fork of the official repository today, so its CI runs on the 16 GB public runner and the 8 GB figures below are historical commissioning evidence, not a live constraint.
The seed was commit `bd4caf87209d802b2ee30d639bd4f39129c4b314`; the official common ancestor was `a6618ddc690b4e613b62c6c4a3f6df4808a778b1`; the candidate was that seed plus the lint fixes and the one-process-per-root worker shape this record accompanies.
ShellCheck was the repository-pinned 0.11.0 Linux x86_64 build, whose GHC 9.8.2 runtime has its memory options compiled out (`shellcheck +RTS -M4g -RTS` answers `Most RTS options are disabled`), so no heap limit can be handed to it.
The host was Linux 7.2.0 with 16 cores and 60 GB; `/usr/bin/time` was absent, so peak RSS came from the `ps` sampler and the `VmHWM` probe recorded below.

## Runner and job facts

GitHub's standard `ubuntu-latest` runner is 2 vCPUs and 8 GB for a private repository and 4 vCPUs and 16 GB for a public one ([hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)).
The seed's `Lint` job, run while the repository was still private (`brentsec/firstmate` run 34927649628, image `ubuntu-24.04` 20260907.300.1), started `bin/fm-lint.sh` at 04:08:26Z, printed only the ShellCheck version and analysis-mode banner lines, and ended at 04:22:37Z with `Process completed with exit code 143`; the job's 25 minute timeout was not reached and the log carries no cancellation or runner-shutdown annotation.
The official `Lint` job at the imported commit `da5e658562128ce94d2ea374fb018004b859bfdf` ran the same script on a public runner from 03:27:18Z to 03:40:46Z and passed.
Roots inside each shard are linted in canonical order (`bin/*.sh`, `bin/backends/*.sh`, `tests/*.sh`), so the heaviest source graphs (`bin/fm-teardown.sh`, `bin/fm-watch.sh`, `tests/fm-pending-reply.test.sh`) are reached late in a shard.

## Whole-run measurements

Each row is one `CI=true bin/fm-lint.sh` run on the host above with the `ps` sampler; worker peaks are the largest per-process RSS values, and the concurrent peak is the largest sum over all ShellCheck processes at one sample.

| Tree | Worker shape | Worker peak RSS | Concurrent peak | Wall | Result |
| --- | --- | --- | ---: | ---: | --- |
| ancestor `a6618dd` | one ShellCheck process per shard | 8.3 GiB and 5.9 GiB | 13.9 GiB | 429 s | exit 0 |
| seed `bd4caf87` | one ShellCheck process per shard | 9.4 GiB and 8.6 GiB | 18.0 GiB | 401 s | exit 1: SC1007 in `bin/backends/herdr.sh`, SC2100 twice in `bin/fm-pending-reply-lib.sh`, SC2329 in `tests/fm-backend.test.sh` |
| candidate | one ShellCheck process per root | 9.5 GiB and 8.4 GiB (largest single roots) | 12.4 GiB | 418 s | exit 0 |

The seed's five custom commits grew the largest source graphs by adding `bin/fm-claude-permission-lib.sh` and its dependencies to many roots (`bin/fm-watch.sh` 830 KiB to 896 KiB, `bin/fm-teardown.sh` 778 KiB to 841 KiB, `tests/fm-pending-reply.test.sh` 513 KiB to 576 KiB), which is why the seed needs more than the ancestor.
One process per root does not lower a worker's peak, because the peak is the largest single root either way; it lowers the concurrent sum because memory is returned between roots instead of staying at the shard's high-water mark, and it makes the peak of every root observable on its own.

## Memory cap reproduction

Running the seed tree under a 7 GiB cgroup limit without swap reproduces the hosted symptom exactly: the two banner lines and exit status 143, nothing else.
The candidate (one process per root) fails the same way under the same cap, because its largest roots alone exceed the limit.

```text
$ systemd-run --user --scope -q -p MemoryMax=7G -p MemorySwapMax=0 env CI=true bin/fm-lint.sh; echo exit=$?
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: full ShellCheck extended analysis enabled
exit=143
```

Locally the kernel OOM killer took the ShellCheck process and systemd's default `OOMPolicy=stop` then stopped the scope with SIGTERM, which `bin/fm-lint.sh` reports as 143 (`journalctl --user`: `run-p3195004-i3191294.scope: The kernel OOM killer killed some processes in this unit.` followed by `Failed with result 'oom-kill'.` and `7G memory peak`).
The hosted VM's exact path from the kernel kill to SIGTERM was not observed; what is established is that the tree needs more memory than the runner has and that every other explanation checked (job or step timeout, cancellation, a diagnostic-driven exit) leaves a trace this log does not contain.

## Per-root measurements

`x` is `--external-sources`, `dataflow` is ShellCheck's default extended analysis, `nodataflow` is `--extended-analysis=false`, and `nox+dataflow` also excludes the cross-file codes `SC1091,SC2034,SC2153,SC2329` exactly as the local changed-file mode does.
Graph size is the transitive `# shellcheck source=` closure at the seed, excluding `/dev/null` boundaries.
Peak RSS is `VmHWM` sampled every 0.1 s; wall time is one process on an otherwise loaded host.

| Root | Source graph (bytes / files) | x+dataflow | x+nodataflow | nox+dataflow |
| --- | --- | --- | --- | --- |
| `tests/fm-pending-reply.test.sh` | 576 KiB / 18 | 9681 MiB / 62 s | 1016 MiB / 20 s | 175 MiB / 1 s |
| `bin/fm-teardown.sh` | 841 KiB / 27 | 8753 MiB / 54 s | 761 MiB / 14 s | 678 MiB / 2 s |
| `bin/fm-watch.sh` | 895 KiB / 25 | 5613 MiB / 27 s | 551 MiB / 9 s | 449 MiB / 1 s |
| `bin/fm-backlog-handoff.sh` | 640 KiB / 21 | 4460 MiB / 28 s | 550 MiB / 9 s | 109 MiB / 0 s |
| `bin/fm-send.sh` | 575 KiB / 21 | 4278 MiB / 25 s | 492 MiB / 8 s | 160 MiB / 0 s |
| `bin/fm-spawn.sh` | 753 KiB / 23 | 4120 MiB / 13 s | 307 MiB / 5 s | 1058 MiB / 3 s |
| `tests/fm-remote-reply.test.sh` | 578 KiB / 19 | 4071 MiB / 21 s | 438 MiB / 7 s | 36 MiB / 0 s |
| `bin/fm-remote-secondmate-control.sh` | 542 KiB / 19 | 3550 MiB / 20 s | 475 MiB / 7 s | 32 MiB / 0 s |
| `tests/fm-daemon.test.sh` | 764 KiB / 20 | 2825 MiB / 14 s | 339 MiB / 5 s | 260 MiB / 2 s |
| `bin/fm-bootstrap.sh` | 536 KiB / 20 | 2443 MiB / 13 s | 313 MiB / 6 s | 208 MiB / 1 s |
| `bin/fm-supervise-daemon.sh` | 574 KiB / 16 | 1946 MiB / 10 s | 246 MiB / 4 s | 171 MiB / 1 s |
| `bin/fm-session-start.sh` | 496 KiB / 17 | 1908 MiB / 10 s | 273 MiB / 4 s | 94 MiB / 0 s |
| `bin/fm-control.sh` | 446 KiB / 14 | 1428 MiB / 7 s | 164 MiB / 3 s | 102 MiB / 0 s |
| `bin/backends/herdr.sh` | 551 KiB / 14 | 1104 MiB / 7 s | 179 MiB / 3 s | 314 MiB / 2 s |

Every source-aware, dataflow-enabled root above 4 GiB has a source graph above 550 KiB, and the largest single root needs more than the 8 GB a private-repository runner offers, so no arrangement of the current CI definition (per root, per shard, one worker, or two) would have fitted that runner.
This is why the repository's visibility matters to CI: the candidate's 12.4 GiB concurrent peak fits the 16 GB public runner the fork now uses, and converting the repository back to private would break `Lint` again.
Either setting alone stays near or under 1 GiB per process.

## Which checks need which setting

A two-file fixture (a root that sources a library through a literal `# shellcheck source=` directive, with a function the library calls, a function nobody calls, an unreachable command, a variable only the library defines, and a variable nobody defines) was linted under each setting:

- SC2329 (function never invoked) needs dataflow and is only correct with `--external-sources`: without source following it also flags the function the library calls.
- SC2317 (unreachable command) needs dataflow and is judged inside the file, so `nox+dataflow` reports it identically.
- SC2154, SC2034, and SC2153 do not need dataflow: `x+nodataflow` reports them exactly as `x+dataflow` does, including the `did you mean` misspelling hint.
- `--include=SC2034,SC2329` is honoured by 0.11.0 and returns exit 1 when a listed code fires.

Over the whole canonical set at the candidate commit, `x+nodataflow` (all codes) over 394 roots took 153 s with two workers and reported nothing; `nox+dataflow` with the local exclusions took 49 s and reported nothing.
Those two passes together miss only cross-file SC2329 relative to the CI definition.

## Reproduction

Install the pinned binary with `bin/fm-install-shellcheck.sh`, put it first on `PATH`, export a tree at the commit under measurement, and run the commands from that tree.
Only one measurement may run at a time because the sampler sees every ShellCheck process on the host.

```bash
cat > /tmp/rss-sample.sh <<'SH'
#!/usr/bin/env bash
# rss-sample.sh <label> <outfile> -- <command...>
set -u
label=$1; out=$2; shift 2; [ "$1" = -- ] && shift
start=$(date +%s)
"$@" > "$out.log" 2>&1 &
cmd=$!
declare -A maxrss
maxsum=0
while kill -0 "$cmd" 2>/dev/null; do
  sum=0
  while read -r pid rss; do
    [ -n "$pid" ] || continue
    sum=$((sum + rss))
    if [ "${maxrss[$pid]:-0}" -lt "$rss" ]; then maxrss[$pid]=$rss; fi
  done < <(ps -o pid=,rss= -C shellcheck 2>/dev/null)
  [ "$sum" -gt "$maxsum" ] && maxsum=$sum
  sleep 2
done
wait "$cmd"; rc=$?
{
  echo "label=$label rc=$rc wall_s=$(( $(date +%s) - start )) max_concurrent_sum_kib=$maxsum"
  for p in "${!maxrss[@]}"; do echo "pid=$p max_rss_kib=${maxrss[$p]}"; done | sort -t= -k3 -n -r | head -6
} > "$out"
SH
CI=true bash /tmp/rss-sample.sh whole-run /tmp/rss-whole-run.txt -- bin/fm-lint.sh
cat /tmp/rss-whole-run.txt

# Peak RSS and wall time of one ShellCheck process on one root.
cat > /tmp/probe-root.sh <<'SH'
#!/usr/bin/env bash
# probe-root.sh <root> <label> <shellcheck args...>
set -u
root=$1; label=$2; shift 2
start=$(date +%s.%N)
shellcheck "$@" -- "$root" > /dev/null 2>&1 &
pid=$!
hwm=0
while [ -d "/proc/$pid" ]; do
  v=$(awk '/^VmHWM:/ {print $2}' "/proc/$pid/status" 2>/dev/null)
  [ -n "${v:-}" ] && [ "$v" -gt "$hwm" ] && hwm=$v
  sleep 0.1
done
wait "$pid"; rc=$?
end=$(date +%s.%N)
printf '%-44s %-14s rc=%d peak_rss_mib=%6d wall_s=%6.1f\n' "$root" "$label" "$rc" $((hwm / 1024)) "$(awk -v s="$start" -v e="$end" 'BEGIN{print e-s}')"
SH
bash /tmp/probe-root.sh tests/fm-pending-reply.test.sh x+dataflow --norc --external-sources
bash /tmp/probe-root.sh tests/fm-pending-reply.test.sh x+nodataflow --norc --external-sources --extended-analysis=false
bash /tmp/probe-root.sh tests/fm-pending-reply.test.sh nox+dataflow --norc --exclude=SC1091,SC2034,SC2153,SC2329

# The hosted runner's memory, as a cgroup cap without swap.
systemd-run --user --scope -q -p MemoryMax=7G -p MemorySwapMax=0 env CI=true bin/fm-lint.sh; echo exit=$?
```

The seed whole-run sample recorded:

```text
label=seed rc=1 wall_s=401 max_concurrent_sum_kib=18910476
pid=2256809 max_rss_kib=9908852
pid=2256808 max_rss_kib=9001624
```
