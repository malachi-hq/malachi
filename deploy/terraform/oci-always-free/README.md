# Malachi on OCI Always Free: an ephemeral three-node cluster, every day

This example builds a three-node Malachi cluster on Oracle Cloud's Always Free tier, runs a fixed set of checks
against it, prints a report, and destroys it. It runs every day on a timer, so the cluster exists only for the
length of one run and nothing is left behind.

It is a reference, not a managed product. Its purpose is to show what Malachi does on real machines, on a
schedule anyone can read in the run's log, at no cost.

**What the run measures: correctness under load and under failure, never throughput.** The micro instance is
a voter with a fraction of an OCPU, and the load balancer carries 10 Mbps. A throughput number from this rig
would measure those, not Malachi. Latency and memory are printed as informative values. Nothing from this rig
is a benchmark, and nothing here is written to `benchmark/published/` or `docs/generated/`.

## What a run does

The daily run is the systemd timer `malachi-daily.timer` on the orchestrator instance, at the hour set by
`run_hour_utc` (03:00 UTC by default). Its script, `orchestrator/files/daily-run.sh`, does this in order:

1. Lists what is left in the cluster compartment. Anything left before the apply stops the run.
2. Fetches the configuration of one pinned commit, checks its SHA-256, and updates the Resource Manager stack.
3. Applies the stack. An "Out of host capacity" failure is retried twice, thirty minutes apart, and then reported
   as `no-capacity`, which is a normal event on the free tier, not a regression.
4. Waits until both A1 nodes report healthy at the load balancer. Health means `/ready` answered 200, which
   happens only after the broker has read its metadata.
5. Runs a produce smoke over TLS through the public endpoint, and checks that a plaintext connection is refused.
6. Restarts one node while a load runs. The node rotates each day, so all three are restarted over three days.
7. Reads the peak memory of the micro instance from the built-in `oci_computeagent` namespace.
8. Destroys the stack from an exit trap, which runs even when an earlier step failed, lists what is left again,
   and publishes the report to the topic the maintainer subscribed to.

The report ends with a line that says the numbers are informative only. The exit code agrees with the verdict.

## Results

| Result | Meaning |
| --- | --- |
| `pass` | Every check passed: TLS smoke, plaintext refused, the restarted node recovered, and the cluster was torn down. |
| `failed` | A check failed. The report says which one. The cluster was still destroyed. |
| `no-capacity` | Oracle had no A1 capacity in the availability domain after three attempts. Retry on another day or another domain. |
| `apply-failed` | The apply failed for a reason other than capacity. Read the job logs in Resource Manager. |
| `not-ready` | The nodes never reported healthy at the load balancer. |
| `leftovers` | The cluster compartment was not empty before the apply. Nothing was applied. |
| `destroy-failed` | The destroy job did not succeed. **The cluster may still exist.** Check the stack in Resource Manager. |
| `leak` | Resources remained after the destroy. The run fails loudly. |

A `micro memory` line above the limit (70% of 1 GB, a proposal not yet measured) marks the run as degraded for
the maintainer to read. It does not fail the run.

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

   The `config_commit_sha` and `config_tarball_sha256` are the commit the daily run will apply and the SHA-256 of
   its GitHub tarball. Take the hash by saving the tarball first, then hashing the saved file:

   ```bash
   curl -fsSL -o malachi-src.tar.gz "https://codeload.github.com/malachi-hq/malachi/tar.gz/<sha>"
   shasum -a 256 malachi-src.tar.gz
   ```

4. **Confirm the e-mail subscription** that OCI Notifications sends after the apply.

5. **Run it once by hand** on the orchestrator instance, to see the first report before the timer does:

   ```bash
   sudo systemctl start malachi-daily.service
   journalctl -u malachi-daily.service -f
   ```

## What the first run must confirm

The first run is also the first test of several assumptions. The plan lists each one; the run answers them:

- The orchestrator's instance principal can create and wait for apply and destroy jobs in the cluster compartment.
- The load balancer and the instances come up without a NAT gateway, through the internet gateway alone.
- `bin/malachi eval` with `Malachi.Loadtest.run/1` starts TLS and produces a report that proves produced equals
  consumed. If it does not, the run needs `Malachi.Smoke.run/1` in the release, with its own tests.
- `MemoryUtilization` from `oci_computeagent` is a percentage on Ubuntu 24.04. One source calls it a cumulative
  counter, which does not fit a percentage. Check it against `free -m` on the instance once.
- The alarm on the orchestrator's CPU series fires when the instance is stopped.
- The first A1 capacity in the chosen availability domain (a `no-capacity` result is expected from time to time).

Some CLI flags in `daily-run.sh` were written from the reference pages and are not yet run against the live
service: `oci resource-manager job create-apply-job --execution-plan-strategy AUTO_APPROVED` (the reference
describes that strategy only through another option, so the first run must confirm which flag takes it),
`oci resource-manager stack get-stack-tf-state`, `oci network-load-balancer backend-set-health get`, and
`oci search resource structured-search`. A failure on any of them shows up as `failed` with the command in the
log, never as a pass.

## Invariants the tests and the review hold

- **Always Free only.** Do not upgrade the tenancy to Pay As You Go. On a free-only account an out-of-limit resource
  fails at creation instead of billing. The arithmetic is tested in `cluster/tests/budget.tftest.hcl`.
- **No SSH.** No rule opens port 22. The cluster is operated through the API and the report.
- **No default secret.** Every password and the cookie are generated at apply. None of the example defaults of
  the compose files appears in the instance definitions.
- **TLS on the client port.** The broker refuses plaintext, and the run checks that it does.
- **The state holds secrets.** Keys, the cookie and the seed passwords are in the Resource Manager state, inside
  OCI. Restrict who can read stacks and jobs in the tenancy's IAM, as you would any secret store.
- **Pinned everything.** Provider versions, the lock files, the OCI CLI (`oci-cli==3.96.0`), the Docker image tag,
  the commit SHA and the tarball hash. Nothing is `latest`, and nothing is piped into a shell.

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
