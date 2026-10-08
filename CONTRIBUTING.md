# Contributing to docker-radvd

The [shared rules](https://github.com/cplieger/.github/blob/main/CONTRIBUTING.md) for commits, releases, synced files and checks apply here.

## Scope

Copying one of radvd's own config checks into the entrypoint, beyond the [path check](docs/how-it-works.md#the-entrypoint) it makes now, is out of scope. radvd changes those checks between releases, so a copy goes stale silently.

A pull request adding a warning about a config state names the radvd source line reporting that state, its log level, and whether radvd reaches it in the [keepalived setup](docs/high-availability.md). A state radvd already logs at debug level 0 gets no warning.

## Rules

- The `radvd` user the `Dockerfile` creates and `--username=radvd` on both radvd commands in `entrypoint.sh` change together. radvd exits at startup without that user. The reload check needs the flag too, since radvd judges the file's permissions against that user.
- `tests/shell/alert_contract_test.sh` fails any `level=error` or `level=warn` line in `entrypoint.sh` that no rule in `alerts/logql.yaml` matches. Any rule passes it, so choose the rule by what the operator has to fix.
- Put config faults from the entrypoint or radvd in `RadvdConfigError`, a config the entrypoint could not read in `RadvdAdvertisementsUnverified`, and supervisor faults in `RadvdSupervisorFault`. The wrong rule points the operator at the wrong fix.
- Reload refusals are the exception. Every line that starts `SIGHUP reload refused` lands in `RadvdConfigError` through that prefix, whatever its cause, so that rule's description names each cause that is not a config fault.

## Checks

After you change `entrypoint.sh` or a test under `tests/shell/`, also run `docker build .`, which reruns `bash tests/shell/run.sh` in the `test` stage with the image's BusyBox `awk`, `sed`, `grep` and `tr`. Those can fail where your host's tools pass.

A test that reads another file of the repository needs that file copied into the `Dockerfile` `test` stage, or the suite fails inside the build.

The shared local checks leave out the signal-contract suite, which the central `ci / validate` docker job runs against the image it builds. After you change the signal handling or the supervisor loop in `entrypoint.sh`, run it yourself with Docker:

```sh
docker build -t docker-radvd:smoke .
tests/image-test.sh docker-radvd:smoke
```
