# Malachi on OCI Always Free: an ephemeral three-node cluster, every day

This example builds a three-node Malachi cluster on Oracle Cloud's Always Free tier, runs a fixed set of checks
against it, prints a report, and destroys it. It runs every day on a timer, so the cluster exists for the length
of one run. A normal finish and a failed step both reach the teardown, and a stop during the destroy lets the destroy
and the report finish. A stop during an apply ends the run as `apply-stuck` with no destroy, because a destroy must not
race an apply that may still be running. A SIGKILL or a reboot can skip the teardown; then the next day's run finds the
leftovers, destroys them, and reports before it applies anything.

It is a reference, not a managed product. Its purpose is to show what Malachi does on real machines, on a
schedule anyone can read in the run's log, at no cost.

**What the run measures: correctness under load and under failure, never throughput.** The micro instance is
a voter with a fraction of an OCPU, and the load balancer carries 10 Mbps. A throughput number from this rig
would measure those, not Malachi. The report carries the micro's memory as an informative value; the load tool's
latency is in the probe logs, not the report. Nothing from this rig is a benchmark, and nothing here is written to
`benchmark/published/` or `docs/generated/`.

## What a run does

The daily run is the systemd timer `malachi-daily.timer` on the orchestrator instance, at the hour set by
`run_hour_utc` (03:00 UTC by default). Its script, `orchestrator/files/daily-run.sh`, does this in order:

1. Checks that every configuration value is set. A missing one stops the run before any OCI call, and the report
   names it.
2. Lists what is left in the cluster compartment, excluding terminated resources. Anything left stops the run before
   the apply. If the count cannot be made, the run stops as `sweep-failed`: a tooling failure is not reported as a leak.
3. Clones the newest commit of `main`, takes its cluster root, and updates the Resource Manager stack. The commit is
   written to the report, so each result names the code it ran.
4. Applies the stack. The apply job is polled until it reaches a final state, for up to three hours. If it is still
   running at that limit, the run stops as `apply-stuck` and no destroy is started against it. An "Out of host
   capacity" failure is retried twice, thirty minutes apart, and then reported as `no-capacity`.
5. Waits until both A1 nodes report healthy at the load balancer. Health means `/ready` answered 200, which happens
   only after the broker has read its metadata.
6. Runs a produce smoke over TLS through the public endpoint. It passes only when records were written and no
   produce failed. Then it checks that a plaintext connection is refused: the check counts as refused only when the
   probe reports a setup refusal. A timeout or any other failure is `indeterminate`, and never a pass.
7. Restarts one node while a load runs. The node rotates each day, so all three are restarted over three days.
8. Reads the peak memory of the micro instance from the built-in `oci_computeagent` namespace.
9. Destroys the stack. Before the destroy, the configuration of the last successful apply is put back on the stack,
   so a broken new commit cannot block the teardown. The restore is tried three times; if it still fails, the run ends
   as `restore-failed` with no destroy, and the next run tries again. On an orchestrator where no apply has ever
   succeeded there is nothing to restore, so the destroy uses the stack's configuration, which is the only one that
   can remove what a failed first apply created. It then lists what is left again and publishes the report to the
   topic the maintainer subscribed to.

The report ends with a line that says the numbers are informative only. The exit code agrees with the verdict.

## Results

| Result | Meaning |
| --- | --- |
| `pass` | Every check passed: TLS smoke, plaintext refused, the restarted node recovered, and the cluster was torn down. |
| `failed` | A check failed, or the run was stopped by a signal. The report says which check. The teardown still ran. |
| `config-missing` | A configuration value is not set. No cluster operation ran, and the report still goes to the topic, naming the value. |
| `restore-failed` | The last applied configuration could not be put back on the stack after three tries. **No destroy was started**, and the next run retries. |
| `sweep-failed` | The cluster compartment could not be counted, before the apply or after the destroy. Check it by hand. |
| `no-capacity` | Oracle had no A1 capacity in the availability domain after three attempts. Retry on another day or another domain. |
| `apply-failed` | The apply failed for a reason other than capacity. Read the job logs in Resource Manager. |
| `apply-stuck` | The apply job was still running at the three-hour limit, or the run was stopped during the apply wait. **No destroy was started.** Check the job and the stack. |
| `not-ready` | The nodes never reported healthy at the load balancer. |
| `leftovers` | The cluster compartment was not empty before the apply. Nothing was applied; the destroy then ran. |
| `destroy-failed` | The destroy job did not succeed. **The cluster may still exist.** Check the stack in Resource Manager. |
| `leak` | Resources remained after a destroy that reported success. The run fails loudly. |

The `micro memory` line says `over-limit` when the peak is above 70% of 1 GB (a proposal, not yet measured). That
line is information for the maintainer: the verdict does not change. A reading that cannot be made says `unmeasured`,
never `within-limit`.

## Layout

```
cluster/        The ephemeral cluster: network, three nodes, the load balancer, the secrets and the cloud-init.
                Applied and destroyed by Resource Manager every day. Never applied by hand.
orchestrator/   The fixed part: its own VCN, a micro instance, the dynamic group, the policy, the report topic,
                the absence alarm, and files/daily-run.sh. Applied once by the maintainer, then left alone.
```

Both roots validate with Terraform 1.5.7, the newest version Resource Manager offers. The plan tests in each
`tests/` directory need Terraform 1.7 or newer (`mock_provider`), and CI runs them on the newest release.

## Bootstrap (the maintainer, once)

These steps need your OCI credentials. Nothing in this repository holds them, and no automation runs them.

1. **Create two compartments** in the home region: one for the cluster, one for the orchestrator. They must be
   different compartments: the policy refuses a shared one.

2. **Create the Resource Manager stack once**, with the OCI CLI. Terraform's provider has no resource for a
   stack, so this is the only way to create it.

   ```bash
   # The configuration, zipped as the daily run zips it (no state, no provider cache, no tests).
   (cd deploy/terraform/oci-always-free/cluster && \
     zip -r "$HOME/malachi-cluster.zip" . -x '.terraform/*' 'tests/*' '*.tfvars' 'terraform.tfstate*')

   # The stack's variables. Replace the placeholders with your values.
   cat > "$HOME/malachi-cluster-vars.json" <<'JSON'
   {"region": "replace-me-home-region",
    "compartment_id": "ocid1.compartment.oc1..cluster",
    "availability_domain": "replace-me-ad",
    "image_tag": "0.22.7"}
   JSON

   oci resource-manager stack create \
     --compartment-id ocid1.compartment.oc1..orchestrator \
     --display-name malachi-cluster \
     --terraform-version 1.5.x \
     --config-source "$HOME/malachi-cluster.zip" \
     --variables file://$HOME/malachi-cluster-vars.json
   ```

   Keep the `id` of the stack (`ocid1.ormstack...`). The daily run needs it.

3. **Apply the orchestrator root**, from your machine, with your OCI provider configuration (`~/.oci/config`):

   ```bash
   cd deploy/terraform/oci-always-free/orchestrator
   cp terraform.tfvars.example terraform.tfvars   # fill in every value, including stack_id
   terraform init
   terraform apply
   ```

   You do not choose a commit: each daily run clones the newest commit of `main`. For that to be safe, `main` must
   be protected on GitHub, so that every change reaches it through a reviewed pull request (one approval). The
   protection is configured in the repository settings, and the run depends on it.

4. **Confirm the e-mail subscription** that OCI Notifications sends after the apply.

5. **Run it once by hand** on the orchestrator instance, to see the first report before the timer does:

   ```bash
   sudo systemctl start malachi-daily.service
   journalctl -u malachi-daily.service -f
   ```

## What the first run must confirm

The first run is also the first test of several assumptions. The plan lists each one; the run answers them:

- The orchestrator's instance principal can create and wait for apply and destroy jobs in the cluster compartment.
- `git clone` of `main` works from the orchestrator (the instance needs outbound access to GitHub).
- The load balancer and the instances come up without a NAT gateway, through the internet gateway alone.
- `bin/malachi eval` with `Malachi.Loadtest.run/1` starts TLS and reports records written with no errors, which is
  what the smoke checks. The smoke does not read the records back: a produce-then-consume check is not built yet, and
  would need `Malachi.Smoke.run/1` in the release, with its own tests.
- `MemoryUtilization` from `oci_computeagent` is a percentage on Ubuntu 24.04. One source calls it a cumulative
  counter, which does not fit a percentage. Check it against `free -m` on the instance once.
- The alarm on the orchestrator's CPU series fires when the instance is stopped.
- The first A1 capacity in the chosen availability domain (a `no-capacity` result is expected from time to time).

Some CLI flags in `daily-run.sh` were written from the reference pages and are not yet run against the live
service: `oci resource-manager job create-apply-job --execution-plan-strategy AUTO_APPROVED` (the reference
describes that strategy only through another option, so the first run must confirm which flag takes it),
`oci resource-manager stack get-stack-tf-state`, `oci network-load-balancer backend-set-health get`, and
`oci search resource structured-search`, and the search's query language for `lifecycleState`. The errors of the
two `backend-set-health` and `structured-search` calls go to `lb-health.err` and `sweep.err` in the run directory,
not to the report: read those files when the result is `not-ready` or `sweep-failed`. A failure of the apply, the
state read or the destroy job shows up in the run's log with the command's own error.

## Invariants the tests and the review hold

- **Always Free only.** Do not upgrade the tenancy to Pay As You Go. On a free-only account an out-of-limit resource
  fails at creation instead of billing. The arithmetic is tested in `cluster/tests/budget.tftest.hcl`.
- **No SSH.** No rule opens port 22. The cluster is operated through the API and the report.
- **No default secret.** Every password and the cookie are generated at apply. None of the example defaults of
  the compose files appears in the instance definitions.
- **TLS on the client port.** The broker refuses plaintext, and the run checks that it does, for a setup refusal
  only (see the step about the smoke).
- **The secrets live in two places.** Keys, the cookie and the seed passwords are in the Resource Manager state,
  inside OCI. The run also copies that state to `state.json` in its run directory on the orchestrator's disk, where
  it stays after the run, together with `cacert.pem` and `probe.env`. Restricting stacks and jobs in IAM does not
  protect that copy: restrict who can log in to the orchestrator as well, and treat its boot volume as a secret store.
- **Pinned by version, and the code follows `main`.** Provider versions and the lock files, the OCI CLI
  (`oci-cli==3.96.0`). Each run applies the newest commit of `main`, and writes that commit into its report. Whatever
  `main` holds runs in your account the next day, so `main` must be protected: a pull request with one approval.
  The node image is the newest Ubuntu 24.04 image at the moment of each apply: its
  date is not pinned. The orchestrator's apt packages are not pinned by version. The Docker image is pinned by its
  tag, not by its digest. Nothing is `latest` in the image, and nothing is piped into a shell.

## Updating the orchestrator

The daily run clones the cluster root from `main`, but `daily-run.sh` and the timer live in the orchestrator's
cloud-init. A change to either reaches the instance only through `terraform apply` of the orchestrator root, which
replaces the instance. The new instance is created before the old one is destroyed, so when OCI has no micro
capacity the apply fails and the old orchestrator keeps running; apply again later. Apply outside the daily run:
during it, the cluster holds the second free micro and 150 GB of the 200 GB of boot volume, and the new instance
cannot be created.

## Known limits

- **Idle reclamation.** Oracle reclaims an Always Free instance whose CPU and network stay under 20% (p95) for
  seven days, and an A1 also needs memory under 20%. The orchestrator micro is mostly idle, so it may be reclaimed.
  The absence alarm tells the maintainer, and the response is to re-apply the orchestrator root. The cluster
  itself is recreated every day, so it is not at risk from this rule.
- **A1 capacity** is not guaranteed in any availability domain. Two domains are worth trying.
- **One home region.** Always Free compute exists only in the tenancy's home region.
- **Load balancer bandwidth** is 10 Mbps, which bounds what the client port can carry. The load is sized for that.

## Cost evidence

The run never spends. To show the cost is zero, keep the account on Always Free for a full billing cycle, export
the cost report for that cycle, and attach it to the pull request that introduces this example before it leaves
draft. Until that export exists, the cost claim is an expectation, not a measurement.
