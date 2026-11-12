# Migration scripts

These scripts automate parts of the [worked examples](../examples/README.md). Complete the relevant example's prerequisites before running them.

| Script | Automated steps |
|---|---|
| [same-vcenter-example.sh](same-vcenter-example.sh) | [Example 1](../examples/1-same-supervisor-and-namespace.md): snapshot protection, source VKS PVC/PV deletion, and destination adoption between clusters in the same Supervisor namespace. |
| [cross-vcenter-example.sh](cross-vcenter-example.sh) | [Example 3](../examples/3-across-supervisors-and-vcenters.md): destination registration and adoption after the disk has been migrated and detached. |

Requires **Bash, kubectl, and jq**. Each run handles one `ReadWriteOnce` filesystem volume.

From this directory, inspect the required environment variables and defaults:

```bash
bash same-vcenter-example.sh --help
bash cross-vcenter-example.sh --help
```

Export the settings for your chosen script, then run it without `--help`. Use a separate Bash process; sourcing skips execution. The script displays its selected contexts and volume identities before requesting typed confirmation.

Existing destination objects cause a stop. After a failed or partial run, inspect the remaining objects before retrying. Backup/restore, data validation, workload restart, and cleanup remain in the walkthrough.

Run the offline regression tests with Python 3:

```bash
python3 -m unittest discover -s tests -v
```

The [live validation report](tests/live-validation-2026-11-12.json) records successful same-Supervisor migration and destination registration/adoption tests. Cross-vCenter vMotion was not tested.
