# CI fast PR build - simplexmq

Goal: a draft pull request runs one reduced Linux x86-64 build; the full matrix runs when the pull request is marked ready for review. Grounded against `.github/workflows/build.yml` on the fork `master`.

## Grounding
This plan targets master's build.yml. Branch `ep/pr-dev-build` and PR #14 base `stable`, whose build.yml predates the -O0, split-cache and concurrency work; the delta applies to a branch cut from `master`.

## Current state (master, already present)
- PR trigger, no path filter: build.yml:10 (default types opened, synchronize, reopened).
- Concurrency group keyed on `github.ref`, cancel-in-progress off for tags: build.yml:12-14.
- PR optimisation -O0: `opt` build.yml:74, `ghc_options` = `--ghc-options=-O0` build.yml:75; -O2 only on push and tags. The cabal stanzas set -O2 (simplexmq.cabal:328 library, :462, :484, :504, :523 executables, :605 test-suite); `--ghc-options=-O0` overrides, GHC taking the last -O.
- Split cache, per branch and commit: restore deps build.yml:210-219 (`~/.cabal/store`), restore build dirs :225-237 (`dist-newstyle`, `dist-postgres`), save deps :359-364, save build dirs :366-373. Restore-keys supply a warm fallback.
- No `cabal clean`; `scripts/ci/prune-old-builds.sh` prunes stale units: build.yml:251, :443.
- A push to master or stable reseeds the -O0 cache a PR reads: build.yml:415-459 (gated by `cache_o0`, build.yml:79).
- Matrix of five entries, build.yml:99-129: 8.10.7 x86-64 22.04 (:100-105), 9.6.3 x86-64 22.04 (:106-111), 9.6.3 x86-64 24.04 (:112-117), aarch64 22.04 (:118-123), aarch64 24.04 (:124-129). All run on a PR; `should_run: true` on four (:111, :117, :123, :129), conditional on the 8.10.7 entry (:105).
- Tests run only on x86-64 (build.yml:392); PR attempts = 1 (build.yml:400).
- Build targets: "Build smp-server, xftp-server (postgresql) and tests" compiles the full test build and copies smp-server, xftp-server, ntf-server, simplexmq-test (build.yml:253-260); "Build everything else (standard)" builds the server executables (build.yml:292-304). The test-suite `simplexmq-test` (simplexmq.cabal:534, main-is Test.hs :538) draws server sources from apps/* (simplexmq.cabal:597-601); `cabal build simplexmq-test` skips the four executable stanzas (simplexmq.cabal:448, :469, :494, :510).

## Delta
1. Activity type. build.yml:10 `pull_request:` gains `types: [opened, synchronize, reopened, ready_for_review]`, so marking ready triggers a run.

2. Draft env. Add to job env (build.yml:72-81): `fast_pr: ${{ github.event.pull_request.draft == true }}`.

3. Single platform on a draft. Guard the four heavy matrix entries with `github.event.pull_request.draft == false`; the 9.6.3 x86-64 22.04 entry (build.yml:111) stays the one draft job.
   - 8.10.7 (build.yml:105): `should_run: ${{ !(github.ref == 'refs/heads/stable' || startsWith(github.ref, 'refs/tags/v')) && github.event.pull_request.draft == false }}`
   - 9.6.3 24.04 (:117), aarch64 22.04 (:123), aarch64 24.04 (:129): `should_run: ${{ github.event.pull_request.draft == false }}`

   On a push `github.event.pull_request.draft` is null, coerced to false, so the four run; on a draft PR they are skipped; on a ready PR they run.

4. Test target on a draft. In "Build smp-server, xftp-server (postgresql) and tests" (build.yml:246-260) branch on `env.fast_pr`. On a draft:
   ```
   cabal build --builddir=${{ env.postgres_dist }} --jobs=$(nproc) --enable-tests -fserver_postgres --ghc-options=-O0 simplexmq-test
   mkdir -p /out
   bin=$(find /project/${{ env.postgres_dist }} -name simplexmq-test -type f -executable)
   chmod +x "$bin"
   cp "$bin" /out/
   ```
   otherwise the current body (build.yml:253-260). Append `&& env.fast_pr != 'true'` to the "Build everything else (standard)" if (build.yml:294). "Copy simplexmq-test from container" (build.yml:262-266) is unchanged.

5. Test subset on a draft. Commit `tests/ci-fast.txt`, one hspec match pattern per line. In "Test" (build.yml:391-413), inside the retry loop, replace `./simplexmq-test` (build.yml:402):
   ```
   matches=()
   if [ "$FAST_PR" = true ] && [ -f tests/ci-fast.txt ]; then
     while IFS= read -r p; do [ -n "$p" ] && matches+=(-m "$p"); done < tests/ci-fast.txt
   fi
   ./simplexmq-test "${matches[@]}"
   ```
   with `env: FAST_PR: ${{ env.fast_pr }}`. The runner passes CLI args to hspec `readConfig`, so `-m` filters (Test.hs:202). The Postgres service is present (build.yml:83-95) and `-fserver_postgres` compiles the Postgres specs; the committed patterns determine their inclusion.

## Draft and full builds
A draft pull request runs only the reduced build: the single 9.6.3 x86-64 22.04 job, the `simplexmq-test` target (the library and the test suite, skipping the four server executables), and the `tests/ci-fast.txt` subset, all at -O0. The warm `dist-postgres` cache (build.yml:225-237) limits recompilation to the units the change affects. Successive pushes to a draft re-run only this reduced build, so review feedback iterates without triggering the five-entry matrix.

The full matrix runs on ready_for_review. A pull request marked ready (`draft == false`) runs the five-entry matrix and the full `./simplexmq-test` at -O0; the reduced path keys on `fast_pr`, so it applies to drafts only. Pushes to master and stable and tag builds keep the five-entry matrix, every target, -O2 (or the -O0 reseed on master and stable), and the full `./simplexmq-test` with retries. The resolver-test job (build.yml:468-485) is independent and unaffected.

## Validation
The first draft pull request on the fork measures the warm reduced-build time.
