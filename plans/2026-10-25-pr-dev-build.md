# Reduced CI build - simplexmq

Line numbers refer to `.github/workflows/build.yml` on simplexmq master 381828400.
Sources, GitHub Actions API, 2026-10-25:
- `simplexmq/build_runs.json`: the last 40 build.yml runs with GHC jobs in simplex-chat/simplexmq, with job and step timings.
- `simplexmq/logs`: job logs of runs 40208397814, 40208402680 and 40208423064.
- `simplexmq-fork/...`: runs and job logs of evgeny-simplex/simplexmq; a log is named by its run id.
- Cache listings: `GET /repos/<owner>/simplexmq/actions/caches`.

## Goal

A manual run on a branch and a draft pull request each run one build job: ubuntu-24.04 x86-64, GHC 9.6.3, -O0, warm cache.
The agent selects the tests.
The full matrix runs when the pull request is marked ready for review and on every push build (build.yml:4-9).

## Triggers and jobs

```
reduced run
  triggers
    workflow_dispatch on a branch (agents: fork branch ep/<topic>)
    pull_request on a draft (any type of change 1)
  jobs
    maybe-release (output reduced, change 2)
    resolver (python) (Q4)
    build-reduced: ubuntu-24.04-x86-64, GHC: 9.6.3 (change 5)
  targets
    dist-postgres at -O0: every component of the package (build.yml:253)
    dist-newstyle: skipped (change 6, Q5)
  tests
    the selection (Test selection)
    no pattern: none
    1 attempt (build.yml:399)

full run
  triggers
    pull_request on a non-draft (any type of change 1, ready_for_review included)
    push to master
    push to stable
    push of a v* tag
  jobs
    maybe-release
    resolver (python)
    build: the five entries of build.yml:99-129
  targets
    dist-postgres (build.yml:253)
    dist-newstyle (build.yml:297)
    -O0 on pull requests (change 3)
    -O2 on pushes (change 3)
    -O0 reseed on master and stable pushes (build.yml:415-459)
  tests
    full suite on each x86-64 entry that runs (build.yml:392); 8.10.7 is skipped on stable and tags (build.yml:105)
    3 attempts on stable and tags (build.yml:400)
```

- The reduced job's name stays `ubuntu-24.04-x86-64, GHC: 9.6.3` (build.yml:67). Among the entries with tests, it has the shortest median job time (Measurements).
- A dispatch requires the `workflow_dispatch` trigger in build.yml on the fork's default branch (master) and on the dispatched branch (https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows). Both hold once change 1 is merged into master and the fork is synced; a branch cut from master after that sync contains it.
- Agents dispatch with:
  ```
  gh workflow run build.yml -R evgeny-simplex/simplexmq --ref ep/<topic> -f tests=$'/Core tests/Encoding tests/\nSMP proxy'
  ```
  (`--ref` and `-f`: https://cli.github.com/manual/gh_workflow_run)
- On a new dispatch on the same branch, GitHub cancels the run in progress (build.yml:12-14).

## Test selection

Mechanism:
- Each selected pattern is passed to `./simplexmq-test` as `-m <pattern>`. `--fail-on=empty` is added when at least one pattern is given (change 7).
- At tests/Test.hs:202 the command-line arguments are passed to hspec `readConfig`.
- The hspec-core version in CI is 2.11.7: every hspec-core version string in simplexmq/logs is `hspec-core-2.11.7` (84 occurrences). In that version an item is selected when any `-m` pattern is a substring of its path `/group/.../item/` or of its formatted description (Test/Hspec/Core/Config/Definition.hs:423, :429-438; Test/Hspec/Core/Util.hs:100-101, :122-128).
- With `--fail-on=empty`, the run fails when no item is selected: "all spec items have been filtered; failing due to --fail-on=empty" (Definition.hs:339; Runner.hs:369-371).

Syntax:
- One pattern per line.
- Leading and trailing whitespace is removed.
- Empty lines are ignored.
- workflow_dispatch: input `tests`.
- Draft pull request: a fenced block with info string `ci-tests` in the description (Q1):
  ````
  ```ci-tests
  /Core tests/Encoding tests/
  SMP proxy
  ```
  ````
  The block is read from the event payload (`github.event.pull_request.body`) of the run. A description edit takes effect from the next push, since the types in change 1 exclude `edited`.
- Group names are the `describe` names in tests/Test.hs:86-196. Every group whose path contains a pattern is selected. Example: with `SMP client agent, server memory message store`, the parallel group (330 items) and the sequential group (4 items) are selected (log 40208423064, 22.04 x86-64 9.6.3).

Default:
- `/` selects the whole suite: every item path contains `/`.
- With no pattern, a reduced run builds without tests and its Test step prints "No tests selected" (change 7).
- The selection is ignored on full runs: `TESTS` is empty outside workflow_dispatch, and `PR_BODY` is empty unless the pull request is a draft (change 7).

## Warm cache

`<target>` is `<os>-<arch>-ghc<ghc>-<toolchain hash>` (build.yml:205-206). The reduced target is `24.04-x86-64-ghc9.6.3-<hash>`.
Restore order: the scope of the run, then the default branch; for a pull request run, the base branch is also read. Of several prefix matches, the most recently created entry is restored (https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching). Default branches: stable in simplex-chat/simplexmq, master in evgeny-simplex/simplexmq (`GET /repos/<owner>/simplexmq`, field `default_branch`).

Cache listings: `GET /repos/<owner>/simplexmq/actions/caches` at 2026-10-25 18:47 UTC. Main repository: 74 entries, 23,644 MB. Fork: 27 entries, 10,558 MB.

Main repository, draft pull request:
- Docker image: registry cache `ghcr.io/simplex-chat/simplexmq-build-cache:24.04-x86-64-ghc9.6.3-<ISO week>` (build.yml:80, :167-170, :183). Written by master pushes (build.yml:184).
- `~/.cabal/store`: key `deps-<target>-master-<sha>`, restore keys `deps-<target>-master-` and `deps-<target>-` (build.yml:216-219). Read from the merge ref `refs/pull/<n>/merge`, master (base branch) and stable (default branch; the listing holds master and pull request entries only). Written by master pushes and by earlier runs of the same pull request when the store hash changes (build.yml:353-364).
- `dist-newstyle` and `dist-postgres`: key `dist-<target>-O0-master-<sha>` (build.yml:233-236). Written by the -O0 reseed of master pushes (build.yml:79, :415-459) and by earlier runs of the same pull request (build.yml:366-373).
- Listing: master holds -O0 seeds of all five targets at 381828400 and a deps entry only for 22.04 x86-64 9.6.3. The 24.04 x86-64 deps entry is saved again by the next master push (build.yml:360). Until then, dependencies are rebuilt in the first reduced run of each pull request (Build step 463-668 s, Measurements).

Fork, workflow_dispatch on `ep/<topic>`:
- `env.branch` is `ep/<topic>`: `github.base_ref` is available only for pull_request and pull_request_target events (https://docs.github.com/en/actions/reference/workflows-and-actions/contexts), so `github.ref_name` is used at build.yml:78.
- `~/.cabal/store`: key `deps-<target>-ep/<topic>-<sha>`, restore keys `deps-<target>-ep/<topic>-` and `deps-<target>-`.
- `dist-newstyle` and `dist-postgres`: key `dist-<target>-O0-ep/<topic>-<sha>`, restore keys `dist-<target>-O0-ep/<topic>-` and `dist-<target>-O0-` (build.yml:233-236 with change 3).
- On the first dispatch on a branch, the -O0 seed of the fork's master is restored. On later dispatches, the newest entry of the branch is restored.
- Seeds: on a push to the fork's master, the full matrix and the -O0 reseed run (build.yml:79, :415-459; Q6). Listing: the fork's master holds `dist-24.04-x86-64-ghc9.6.3-d5c22248ca9a4e99-O0-master-381828400…` and `deps-24.04-x86-64-ghc9.6.3-d5c22248ca9a4e99-master-d398dbe5f6db7d40`.
- Docker image today: in the fork, the import of `ghcr.io/simplex-chat/simplexmq-build-cache` fails with "403 Forbidden" (simplexmq-fork/logs/40206702982-pull_request-ep_pr-dev-build-ubuntu-22.04-x86-64__GHC__8.10.7.txt:1354), and the master export fails with "permission_denied" (simplexmq-fork/logs/40199771805-push-master-ubuntu-24.04-x86-64__GHC__9.6.3.txt:2581). The package requires authentication: on 2026-10-25 an anonymous `https://ghcr.io/token?scope=repository:simplex-chat/simplexmq-build-cache:pull` request returned 401, and the same request for the public `actions/actions-runner` returned 200. In every fork job, the image is built from scratch (171-244 s).
- Docker image after change 4: `ghcr.io/evgeny-simplex/simplexmq-build-cache`, written by fork master pushes (build.yml:184) with `packages: write` (build.yml:71). Validation steps 4 and 5 check the write and the read. The tag includes the ISO week (build.yml:167-170, :183), so on a dispatch in a week before the first fork master push of that week, the image is rebuilt.
- Toolchain hashes differ between the repositories: 24.04 x86-64 is `d5c22248ca9a4e99` in the fork and `9f33e17a9e49fd6b` in the main repository (listings). Caches are per repository.

Eviction: entries unused for 7 days are removed; above the size limit, entries are deleted in order of last access, oldest first (dependency-caching page). A 24.04 x86-64 -O0 dist entry is 489-500 MB; a deps entry is 52-53 MB (listings). On 2026-10-25, deps were restored on all five targets in the master push run of 13:53; from 14:12, the 24.04 x86-64 deps entry was missed in all 8 runs (simplexmq/build_runs.json, step "Warn if dependencies not in cache").

## Changes to build.yml

1. Triggers. Line 10:
   ```yaml
     pull_request:
   ```
   becomes:
   ```yaml
     pull_request:
       types: [opened, synchronize, reopened, ready_for_review]
     workflow_dispatch:
       inputs:
         tests:
           description: "hspec match patterns, one per line; / runs all tests, empty runs none"
           type: string
           default: ""
   ```
   The default pull_request types are opened, synchronize and reopened (events page).

2. Reduced output and tag guard. Lines 25-27 become the lines below; line 28 (`- name: Clone project`) and the release steps follow unchanged.
   ```yaml
     maybe-release:
       runs-on: ubuntu-latest
       outputs:
         reduced: ${{ github.event_name == 'workflow_dispatch' || github.event.pull_request.draft == true }}
       steps:
         - name: Reject a manual run on a tag
           if: github.event_name == 'workflow_dispatch' && github.ref_type == 'tag'
           run: |
             echo "::error::A manual run starts on a branch; to retry a release, re-run the jobs of its tag push."
             exit 1
   ```
   A re-run of a tag-push run keeps its event, `push` (re-runs 40172782505, 40078644261 and 40078171679, attempt 2, kept event `pull_request`), so the guard applies only to new manual runs.

3. Optimisation level. Lines 74-75 become:
   ```yaml
         opt: ${{ github.event_name == 'push' && 'O2' || 'O0' }}
         ghc_options: ${{ github.event_name != 'push' && '--ghc-options=-O0' || '' }}
   ```
   Code is compiled at -O0 on pull_request and workflow_dispatch runs, and at -O2 on push runs, tags included.

4. Image cache namespace. Line 80 becomes:
   ```yaml
         image_cache: ghcr.io/${{ github.repository_owner }}/simplexmq-build-cache:${{ matrix.os }}-${{ matrix.arch }}-ghc${{ matrix.ghc }}
   ```
   In the main repository the value is unchanged (`simplex-chat`).

5. Reduced job (Q2). The build job gets `if: needs.maybe-release.outputs.reduced != 'true'` after `needs` (line 68), and anchors on its `env` (line 72), `services` (line 83) and `steps` (line 130): `env: &build-env`, `services: &build-services`, `steps: &build-steps`. Its matrix (lines 99-129) is unchanged. A new job follows it:
   ```yaml
     build-reduced:
       name: "ubuntu-${{ matrix.os }}-${{ matrix.arch }}, GHC: ${{ matrix.ghc }}"
       needs: maybe-release
       if: needs.maybe-release.outputs.reduced == 'true'
       permissions:
         contents: write
         packages: write
       env: *build-env
       runs-on: ${{ matrix.runner }}
       services: *build-services
       strategy:
         matrix:
           include:
             - os: 24.04
               os_underscore: 24_04
               arch: x86-64
               runner: "ubuntu-24.04"
               ghc: "9.6.3"
               should_run: true
       steps: *build-steps
   ```
   On a reduced run, build is skipped without starting a runner, and build-reduced runs the shared steps for the one entry.

6. Standard build on reduced runs (Q5). Line 294 becomes:
   ```yaml
           if: matrix.should_run == true && needs.maybe-release.outputs.reduced != 'true'
   ```
   On reduced runs `dist-newstyle` (non-Postgres library and executables, build.yml:297-304) is not built. The -O0 reseed (build.yml:417) runs only when `cache_o0` is true; it is false on pull_request and workflow_dispatch runs (build.yml:79).

7. Test selection. Lines 395-402 become the lines below; lines 403-413 follow unchanged.
   ```yaml
           env:
             PGHOST: localhost
             REDUCED: ${{ needs.maybe-release.outputs.reduced }}
             TESTS: ${{ github.event_name == 'workflow_dispatch' && inputs.tests || '' }}
             PR_BODY: ${{ github.event.pull_request.draft == true && github.event.pull_request.body || '' }}
           run: |
             if [ -n "$PR_BODY" ]; then
               TESTS=$(printf '%s\n' "$PR_BODY" | tr -d '\r' | awk '/^```ci-tests[ \t]*$/ {f = 1; next} /^```[ \t]*$/ {f = 0} f')
             fi
             args=()
             while read -r p; do
               if [ -n "$p" ]; then args+=(-m "$p"); fi
             done <<< "$TESTS"
             if [ "${#args[@]}" -gt 0 ]; then
               args+=(--fail-on=empty)
             elif [ "$REDUCED" = true ]; then
               echo "No tests selected"
               exit 0
             fi
             i=1
             attempts=1
             ${{ (github.ref == 'refs/heads/stable' || startsWith(github.ref, 'refs/tags/v')) }} && attempts=3
             while [ "$i" -le "$attempts" ]; do
               if ./simplexmq-test "${args[@]}"; then
   ```
   The description and the input reach the script through environment variables, the method prescribed for untrusted input in https://docs.github.com/en/actions/reference/security/secure-use. For the here-string, bash appends a final newline, so the last pattern is read.

## Measurements

Main repository build.yml runs of 2026-10-25 (simplexmq/build_runs.json: 40 runs, 36 pull_request and 4 push). Durations are `completed_at` minus `started_at` of successful pull_request jobs (31 per x86-64 entry, 33 per aarch64 entry) and of their steps.

| Measure | 24.04 x86-64 9.6.3 | 22.04 x86-64 9.6.3 | 22.04 x86-64 8.10.7 | 22.04 / 24.04 aarch64 |
|---|---|---|---|---|
| Test step, median (min-max) | 666 s (571-942) | 676 s (566-898) | 676 s (566-987) | not run (build.yml:392) |
| Job, median | 950 s | 973 s | 1063 s | 294 s / 285 s, without tests |
| Job minus Test and standard build, warm jobs, median (max) | 224.5 s (304), 26 jobs | 238 s (302), 31 jobs | - | - |
| Build step (build.yml:246), median (min-max) | 111 s (23-668) | 95 s (28-165) | 180 s (32-783) | 125 s / 127 s |
| Build step with a dependency rebuild | 5 of 31 jobs, 463-668 s | 0 of 31 jobs | - | - |
| Standard build step (build.yml:292), median | 39 s | 45 s | 77 s | 47 s / 44 s |
| Install PostgreSQL 15 client tools, median | not run (build.yml:148) | 15 s | 16 s | 17 s / not run |
| Docker image step, median (max) | 58 s (82) | 60 s (77) | 61 s (79) | 48 s (68) / 51 s (70) |

Warm jobs: Build step under 200 s.

24.04 x86-64 minus 22.04 x86-64 (GHC 9.6.3), 26 pull_request runs where both jobs are warm:

| Measure | Median | Mean | 24.04 faster |
|---|---|---|---|
| Job | -48.5 s | -48.2 s | 19 of 26 |
| Test step | -3.5 s | -17.4 s | 15 of 26 |
| Job start to Test start | -35 s | -30.0 s | 20 of 26 |

Test suite, 9 x86-64 logs of runs 40208397814, 40208402680 and 40208423064 (simplexmq/logs). Section times are intervals between the log timestamps of top-level group headers, that is, print intervals.

| Measure | Value |
|---|---|
| hspec "Finished in" | 569-684 s |
| Examples | 1443-1447, 63 pending |
| Parallel section (tests/Test.hs:85-140) | 473-571 s |
| Two "SMP client agent" groups within it | 396-493 s |
| Sequential section (tests/Test.hs:141-197) | 96-116 s |
| "Server CLIs" group | 9.2-10.3 s |

Other:

| Measure | Value | Source |
|---|---|---|
| Fork Docker image step | 171-244 s | 4 logs in simplexmq-fork/logs, step group start to next group start |
| resolver (python) job, median | 12 s | build_runs.json, 40 runs |
| maybe-release job, median | 4 s | build_runs.json, 40 runs |
| Build job with all steps skipped | 27-33 s, "Initialize containers" 21-27 s | fork run 40168482343, `GET /repos/evgeny-simplex/simplexmq/actions/runs/40168482343/jobs`, 4 jobs |
| Fork master push, 8.10.7 job | 42 min | simplexmq-fork/logs/40199771805-push-master-ubuntu-22.04-x86-64__GHC__8.10.7.txt, first to last timestamp |
| Runner size, x64 and arm64 | 4 CPU, 16 GB RAM | https://docs.github.com/en/actions/reference/runners/github-hosted-runners |

## Validation

The change is proposed as a draft pull request in simplex-chat/simplexmq from a fork branch. Its description contains a `ci-tests` block with `/Core tests/Encoding tests/`.

1. Draft run.
   - Pass: three jobs run, and build is skipped.
     - maybe-release
     - resolver (python)
     - build-reduced: ubuntu-24.04-x86-64, GHC: 9.6.3
   - Pass: "Build everything else (standard)" is skipped.
   - Pass: the Test log reports "16 examples, 0 failures" (16 items under `/Core tests/Encoding tests/` in 40208423064, 24.04 x86-64).
   - Pass: with the block removed from the description, the next push builds and the Test step prints "No tests selected".
   - Pass: "Restore build directories from cache" logs `Cache restored from key: dist-24.04-x86-64-ghc9.6.3-`.
   - Pass: job time minus the Test step is at most 304 s when both restores hit.
   - Pass after a deps miss: the Build step takes at most 668 s.
   - Fail: any other `ubuntu-*` job.
   - Fail: a "Cache miss" warning on build directories (build.yml:238-240) while the toolchain hash in the key equals that of the master seed. A different hash is produced by a new image (build.yml:167-170, :205-206), outside this change.
   - Fail: a time above its bound.
2. Ready for review.
   - Pass: five build jobs.
   - Pass: each x86-64 Test step reports the example count of the latest master run.
3. Merge to master.
   - Pass: five build jobs.
   - Pass: "Save -O0 build directories to cache" succeeds in each.
4. Push to the fork's master after the sync.
   - Pass: "Build and cache Docker image" logs `exporting cache to registry` and no `ERROR` line after it. An import `ERROR` before it is allowed: the fork image is absent before this push.
5. Dispatch on a fork branch `ep/<topic>` with empty `tests`, in the ISO week of step 4. In steps 5-7, each dispatch starts after the previous run completes.
   - Pass: one build job.
   - Pass: the step env shows `opt: O0`.
   - Pass: a key starting with `dist-24.04-x86-64-ghc9.6.3-<fork hash>-O0-master-` is restored.
   - Pass: "Build and cache Docker image" logs `importing cache manifest from ghcr.io/evgeny-simplex/simplexmq-build-cache`, no `ERROR` line, and takes at most 82 s.
6. Dispatch on the same branch with `tests=no-such-test`.
   - Pass: the Test step fails with "all spec items have been filtered; failing due to --fail-on=empty".
7. Dispatch on the same branch with `tests=$'/Core tests/Encoding tests/\n/Core tests/Version range/'`.
   - Pass: "22 examples, 0 failures" (16 plus 6 in 40208423064, 24.04 x86-64).
   - Pass: the restored key starts with `dist-24.04-x86-64-ghc9.6.3-<fork hash>-O0-ep/<topic>-`.

## Open questions

Q1. Source of the test selection on a draft pull request (visible to the reviewer).
- A. `ci-tests` block in the description (written in change 7). Cost: a visible block; an edit takes effect from the next push.
- B. A file committed in the branch. Cost: the file reaches master on merge; parallel pull requests conflict on it.
- C. A trailer in the head commit message. Cost: an extra fetch of the head commit in the Test step (INFERENCE: the depth-1 checkout of the merge ref at build.yml:131-135 lacks the head commit); trailers reach master history on merge.
- D. Full suite on every draft run. Cost: about 11 minutes of Test step per push (666 s median); agents cannot select tests on drafts.
- Recommendation: A. With B, merge-time cleanup is needed; with C, a fetch. With D, the expectation is unmet.

Q2. Matrix mechanism for one job. Decided by the user: YAML job conditions (change 5), in place of a matrix produced as JSON by a shell step.

Q3. aarch64 test time. Tests are off on aarch64 since b020a08ea0 (2025-09-15, "ci: disable aarch64 tests (#1638)"); the commit message is the title only.
- A. One experiment: a throwaway fork branch where the build-reduced entry is set to `arch: aarch64` and `runner: "ubuntu-24.04-arm"` and the `matrix.arch == 'x86-64'` conditions at build.yml:376, :384, :392 are removed; three dispatches with empty `tests`. The image of that runner includes PostgreSQL 16.15 (log 40208423064 24.04 aarch64:17-19 names image 20261012.149.1; https://github.com/actions/runner-images/blob/ubuntu24-arm64/20261012.149/images/ubuntu/Ubuntu2404-Arm64-Readme.md). Cost: three runs of about 16 minutes (INFERENCE: 285 s job median plus the 666 s x86-64 Test median); the branch is deleted afterwards.
- B. A permanent dispatch input for the architecture. Cost: a permanent input plus matrix logic for a one-time comparison.
- C. No experiment. Cost: arm64 test time stays unmeasured.
- Recommendation: A. If all three runs pass every test with a Test step median below 666 s, the reduced entry is switched to `arm_2404`, with its Test step enabled, in a follow-up change.

Q4. resolver (python) on reduced runs (median 12 s on ubuntu-latest, build.yml:468-485).
- A. Keep. Cost: one 12 s job per reduced run.
- B. Skip on reduced runs. Cost: resolver changes are tested only after ready_for_review.
- C. Run when `scripts/resolver/` changes. Cost: a change-detection step or action.
- Recommendation: A. With B, resolver checks wait for ready_for_review. With C, a detection step is maintained to save 12 s of runner time.

Q5. Standard build on reduced runs (change 6).
- A. Skip it. Cost: code compiled only without `-fserver_postgres` (the `#else` branches of `dbServerPostgres`, for example src/Simplex/Messaging/Server/Main.hs:262, :296, :450, :569 at 381828400; cpp-options at simplexmq.cabal:433-434) is compiled first on ready_for_review.
- B. Keep it. Cost: 39 s median per reduced run (Measurements).
- Recommendation: A. With B, every reduced run includes a second build configuration.

Q6. Fork master push builds (the seeds of fork dispatches).
- A. Full matrix, as today. Cost: five jobs per sync of the fork's master; the 8.10.7 job takes 42 minutes (Measurements).
- B. One entry in forks: on a push outside simplex-chat/simplexmq, build-reduced runs and build is skipped (a `github.repository` term in both job conditions); `reduced` keeps the expression of change 2, so the standard build and the -O0 reseed (build.yml:415-459) run. Cost: one condition term in each of the two jobs.
- Recommendation: B. With A, each sync adds four jobs, while fork dispatches read only the 24.04 x86-64 entries.
