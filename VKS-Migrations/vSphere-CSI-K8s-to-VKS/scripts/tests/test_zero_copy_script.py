"""Offline regressions for FCD adoption; never invokes a real Kubernetes CLI.

Run: python3 -m unittest discover -s scripts/tests -v
Requires Bash and jq. Sourcing checks also cover zsh when installed.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "zero-copy-migration-poc-script.sh"
FCD = "12345678-1234-1234-1234-123456789abc"

# Stateful API double. Unknown operations fail closed, including unexpected
# kubeconfigs. Fixtures represent API objects, not a recording of shell lines.
MOCK = r'''
import copy, json, os, pathlib, sys
root = pathlib.Path(os.environ["MOCK_DIR"])
failure = os.environ.get("MOCK_FAILURE", "")
args = sys.argv[1:]
cluster, namespace, output, context = None, "default", None, None
words = []
i = 0
while i < len(args):
    arg = args[i]
    if arg.startswith("--kubeconfig="):
        cluster = pathlib.Path(arg.split("=", 1)[1]).name
    elif arg == "--kubeconfig":
        i += 1; cluster = pathlib.Path(args[i]).name
    elif arg.startswith("--context="):
        context = arg.split("=", 1)[1]
    elif arg == "--context":
        i += 1; context = args[i]
    elif arg.startswith("--request-timeout="):
        pass
    elif arg in ("-n", "--namespace"):
        i += 1; namespace = args[i]
    elif arg.startswith("--namespace="):
        namespace = arg.split("=", 1)[1]
    elif arg in ("-o", "--output"):
        i += 1; output = args[i]
    elif arg.startswith("-o="):
        output = arg.split("=", 1)[1]
    else:
        words.append(arg)
    i += 1
verb = words[0] if words else ""
payload = None
if verb in ("create", "apply", "delete") and "-f" in words:
    filename = words[words.index("-f") + 1]
    payload = json.load(sys.stdin) if filename == "-" else json.loads(pathlib.Path(filename).read_text())
if verb == "patch":
    for flag in ("-p", "--patch"):
        if flag in words:
            payload = json.loads(words[words.index(flag) + 1])
    for arg in words:
        if arg.startswith("--patch="):
            payload = json.loads(arg.split("=", 1)[1])
call = dict(args=args, words=words, verb=verb, cluster=cluster, namespace=namespace,
            context=context, payload=payload)
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps(call) + "\n")
statefile = root / "state.json"
state = json.loads(statefile.read_text())
counters = state.setdefault("_counters", {})

def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)

def save():
    statefile.write_text(json.dumps(state))

aliases = {"namespaces": "namespace", "ns": "namespace", "pods": "pod",
           "persistentvolume": "pv", "persistentvolumes": "pv",
           "persistentvolumeclaim": "pvc", "persistentvolumeclaims": "pvc",
           "volumeattachments": "volumeattachment", "cnsregistervolumes": "cnsregistervolume"}

def key(kind, name, ns=namespace):
    kind = kind.lower().split(".")[0]
    kind = aliases.get(kind, kind)
    return kind + "/" + (ns + "/" if kind in ("pvc", "pod", "cnsregistervolume") else "") + name

def result(obj):
    if output == "name":
        print(obj["kind"].lower() + "/" + obj["metadata"]["name"])
    elif output and output.startswith("jsonpath="):
        path = output.split("=", 1)[1].strip("'\"{}").lstrip(".")
        value = obj
        for part in path.split("."):
            value = value.get(part, "") if isinstance(value, dict) else ""
        print(str(value).lower() if isinstance(value, bool) else value, end="")
    else:
        print(json.dumps(obj))

if cluster not in state:
    die("Unexpected kubeconfig: " + str(cluster))
objects = state[cluster]
if verb == "config" and words[1:] == ["current-context"]:
    print(cluster + "-context")
elif verb == "cluster-info":
    print("Mock cluster " + cluster)
elif verb == "get":
    resource = words[1]
    if "/" in resource:
        resource, name = resource.split("/", 1)
    else:
        name = next((w for w in words[2:] if not w.startswith("-")), "")
    resource = aliases.get(resource.split(".")[0], resource.split(".")[0])
    countkey = cluster + "/" + key(resource, name)
    counters[countkey] = counters.get(countkey, 0) + 1
    save()
    if resource in ("pod", "volumeattachment"):
        if failure == resource + "_error": die("Forbidden: list " + resource)
        if resource == "volumeattachment" and failure == "detach_query_error" and counters[countkey] > 1:
            print(json.dumps({"items": []})); die("Failed API response after source deletion")
        if failure == resource + "_empty": sys.exit(0)
        if failure == resource + "_malformed": result({"items": None}); sys.exit(0)
        items = []
        if resource == "pod" and (failure == "pods_present" or
                (failure == "pods_race" and counters[countkey] > 1)):
            items = [{"metadata": {"name": "writer"}, "spec": {"volumes": [
                {"persistentVolumeClaim": {"claimName": "source-claim"}}]}}]
        if resource == "volumeattachment" and failure == "attachments_present" and counters[countkey] < 3:
            items = [{"spec": {"source": {"persistentVolumeName": "source-pv"}}}]
        result({"apiVersion": "v1", "kind": "List", "items": items})
    else:
        if failure == "target_get_error" and cluster == "dst" and resource == "pv":
            die("Forbidden: get target")
        obj = objects.get(key(resource, name))
        if obj is None:
            if "--ignore-not-found" not in words and "--ignore-not-found=true" not in words:
                die("NotFound: " + key(resource, name))
            sys.exit(0)
        obj = copy.deepcopy(obj)
        if cluster == "src" and resource == "pvc" and counters[countkey] > 1:
            if failure == "source_claim_replaced": obj["metadata"]["uid"] = "replacement-claim"
            if failure == "source_claim_replaced_after_retain" and objects["pv/source-pv"]["spec"]["persistentVolumeReclaimPolicy"] == "Retain":
                obj["metadata"]["uid"] = "replacement-claim"
        if cluster == "src" and resource == "pv" and counters[countkey] > 1:
            if failure == "source_pv_replaced": obj["metadata"]["uid"] = "replacement-pv"
        if resource == "cnsregistervolume" and cluster == "sup":
            if failure == "registration_get_error": die("Forbidden: get registration")
            if failure == "registration_empty": sys.exit(0)
            if failure == "registration_replaced": obj["metadata"]["uid"] = "replacement-registration"
        if cluster == "dst" and resource == "pv" and failure == "destination_wrong_binding":
            obj["spec"]["claimRef"]["uid"] = "unrelated-uid"
        result(obj)
elif verb == "patch":
    obj = objects[key(words[1], words[2])]
    if failure == "patch_conflict": die("Conflict: resourceVersion changed")
    if not isinstance(payload, list): die("Expected guarded JSON Patch")
    for operation in payload:
        parent = obj
        parts = operation["path"].strip("/").split("/")
        for part in parts[:-1]: parent = parent[part]
        if operation["op"] == "test":
            if parent.get(parts[-1]) != operation["value"]: die("Conflict: JSON Patch test failed")
        elif operation["op"] in ("replace", "add"):
            parent[parts[-1]] = operation["value"]
        else: die("Unexpected JSON Patch operation")
    obj["metadata"]["resourceVersion"] = str(int(obj["metadata"]["resourceVersion"]) + 1)
    save(); result(obj)
elif verb == "delete":
    raw = next((w.split("=", 1)[1] for w in words if w.startswith("--raw=")), None)
    if raw is None: die("Expected raw DELETE with UID/resourceVersion preconditions")
    parts = raw.split("/")
    ns, name = parts[4], parts[-1]
    objkey = key("pvc", name, ns)
    obj = objects[objkey]
    if payload.get("kind") != "DeleteOptions": die("Missing DeleteOptions")
    if failure == "delete_conflict": die("Conflict: PVC replaced before DELETE")
    for field in ("uid", "resourceVersion"):
        if payload.get("preconditions", {}).get(field) != obj["metadata"][field]:
            die("Conflict: missing or stale " + field)
    pv = objects[key("pv", obj["spec"]["volumeName"])]
    if pv["spec"]["persistentVolumeReclaimPolicy"] != "Retain":
        die("Unsafe DELETE: PV was not protected")
    del objects[objkey]
    pv["status"]["phase"] = "Released"
    save(); print(json.dumps({"kind": "Status", "status": "Success"}))
elif verb in ("create", "apply"):
    if verb == "apply": die("Unsafe apply: target must use create")
    if any(w.startswith("--dry-run") for w in words):
        if failure == "dry_run_error": die("Forbidden: dry-run create")
        result(payload); sys.exit(0)
    items = payload["items"] if payload["kind"] == "List" else [payload]
    for item in items:
        md = item["metadata"]
        ns = md.get("namespace", namespace)
        itemkey = key(item["kind"], md["name"], ns)
        if itemkey in objects: die("AlreadyExists: " + itemkey)
        md.update(uid="created-" + md["name"], resourceVersion="1")
        if item["kind"] == "CnsRegisterVolume":
            item["status"] = {"registered": failure != "registration_error"}
            if failure == "registration_error": item["status"]["error"] = "injected registration failure"
            pv = copy.deepcopy(state["src"]["pv/source-pv"])
            pvc = copy.deepcopy(state["_source_claim"])
            pvcname = item["spec"]["pvcName"]
            pvc["metadata"].update(name=pvcname, namespace=ns, uid="registered-claim")
            pvc["spec"]["volumeName"] = "registered-pv"
            pv["metadata"].update(name="registered-pv", uid="registered-pv")
            pv["spec"]["claimRef"] = {"namespace": ns, "name": pvcname, "uid": "registered-claim"}
            pv["spec"]["csi"]["volumeHandle"] = item["spec"]["volumeID"]
            pv["status"]["phase"] = "Bound"
            if failure == "supervisor_wrong_fcd": pv["spec"]["csi"]["volumeHandle"] = "wrong-fcd"
            if failure == "supervisor_wrong_size": pv["spec"]["capacity"]["storage"] = "2Gi"
            if failure == "supervisor_wrong_claim": pv["spec"]["claimRef"]["uid"] = "wrong-claim"
            if failure == "supervisor_wrong_fs": pv["spec"]["csi"]["fsType"] = "ext4"
            if failure == "supervisor_terminating": pvc["metadata"]["deletionTimestamp"] = "2026-11-12T00:00:00Z"
            objects[key("pvc", pvcname, ns)] = pvc
            objects[key("pv", "registered-pv")] = pv
        elif item["kind"] in ("PersistentVolume", "PersistentVolumeClaim"):
            item["status"] = {"phase": "Bound"}
        objects[itemkey] = item
    for item in objects.values():
        if item["kind"] == "PersistentVolumeClaim":
            pv = objects.get(key("pv", item["spec"].get("volumeName", "")))
            if pv:
                pv["spec"]["claimRef"] = {"namespace": item["metadata"].get("namespace", namespace),
                    "name": item["metadata"]["name"], "uid": item["metadata"]["uid"]}
    # Preserve injected binding fault after the fake controller finishes binding.
    if cluster == "sup" and failure == "supervisor_wrong_claim":
        objects["pv/registered-pv"]["spec"]["claimRef"]["uid"] = "wrong-claim"
    save()
    result(items[0] if len(items) == 1 else payload)
elif verb == "wait":
    print("condition met")
else:
    die("Unexpected API request: " + repr(args))
'''


def initial_state():
    state = {name: {} for name in ("src", "dst", "sup")}
    for cluster, objects in state.items():
        for ns in ("default", "team", "kube-system"):
            objects["namespace/" + ns] = {
                "kind": "Namespace", "metadata": {"name": ns, "uid": cluster + "-" + ns},
                "status": {"phase": "Active"}}
    pvc = {"apiVersion": "v1", "kind": "PersistentVolumeClaim",
           "metadata": {"name": "source-claim", "namespace": "default", "uid": "claim-uid", "resourceVersion": "10"},
           "spec": {"volumeName": "source-pv", "accessModes": ["ReadWriteOnce"], "volumeMode": "Filesystem",
                    "storageClassName": "storage-policy", "resources": {"requests": {"storage": "1Gi"}}},
           "status": {"phase": "Bound"}}
    pv = {"apiVersion": "v1", "kind": "PersistentVolume",
          "metadata": {"name": "source-pv", "uid": "pv-uid", "resourceVersion": "20"},
          "spec": {"capacity": {"storage": "1Gi"}, "accessModes": ["ReadWriteOnce"], "volumeMode": "Filesystem",
                   "persistentVolumeReclaimPolicy": "Delete", "storageClassName": "storage-policy",
                   "claimRef": {"namespace": "default", "name": "source-claim", "uid": "claim-uid"},
                   "csi": {"driver": "csi.vsphere.vmware.com", "volumeHandle": FCD, "fsType": "xfs"}},
          "status": {"phase": "Bound"}}
    state["src"].update({"pvc/default/source-claim": pvc, "pv/source-pv": pv})
    state["_source_claim"] = pvc
    return state


@unittest.skipUnless(shutil.which("bash") and shutil.which("jq"), "requires bash and jq")
class ZeroCopyScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="csi-script-tests-")
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        mock = self.directory / "kubectl"
        mock.write_text("#!" + sys.executable + "\n" + MOCK)
        mock.chmod(0o755)
        # An accidental return to oc must also never reach a live executable.
        oc = self.directory / "oc"
        oc.write_text("#!/bin/sh\necho 'Unexpected oc invocation; use the mocked kubectl' >&2\nexit 99\n")
        oc.chmod(0o755)
        # Readiness changes are driven by fake API state, not wall-clock delays.
        sleeper = self.directory / "sleep"
        sleeper.write_text("#!/bin/sh\nexit 0\n")
        sleeper.chmod(0o755)
        self.env = {"PATH": str(self.directory) + os.pathsep + os.environ["PATH"],
                    "HOME": str(self.directory), "MOCK_DIR": str(self.directory),
                    "SOURCE_NS": "default", "TARGET_NS": "default", "SUPERVISOR_NS": "team",
                    "PVC_NAME": "source-claim", "REGISTER_NAME": "adopt-test", "RUN_ID": "test",
                    "SUPERVISOR_PVC_NAME": "registered-claim", "VKS_PV_NAME": "adopted-pv",
                    "OUTPUT_DIR": str(self.directory / "rollback")}
        for variable, name in (("OCP_KUBECONFIG", "src"), ("VKS_KUBECONFIG", "dst"),
                               ("SUPERVISOR_KUBECONFIG", "sup")):
            config = self.directory / name
            config.write_text("mock file: the real CLI never reads this\n")
            self.env[variable] = str(config)
        self.state = initial_state()

    def run_script(self, failure="", overrides=None, confirmation=FCD):
        (self.directory / "state.json").write_text(json.dumps(self.state))
        (self.directory / "calls.jsonl").unlink(missing_ok=True)
        shutil.rmtree(self.directory / "rollback", ignore_errors=True)
        env = dict(self.env, MOCK_FAILURE=failure)
        env.update(overrides or {})
        result = subprocess.run(["bash", str(SCRIPT)], env=env, input=confirmation + "\n",
                                text=True, capture_output=True, timeout=45)
        log = self.directory / "calls.jsonl"
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    @staticmethod
    def mutations(calls, cluster=None):
        return [c for c in calls if c["verb"] in ("create", "apply", "patch", "delete")
                and not any(a.startswith("--dry-run") for a in c["args"])
                and (cluster is None or c["cluster"] == cluster)]

    def assert_failed(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_help_does_not_require_credentials_or_call_cli(self):
        result = subprocess.run(["bash", str(SCRIPT), "--help"], env={"PATH": self.env["PATH"]},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage:", result.stdout)
        self.assertFalse((self.directory / "calls.jsonl").exists())

    def test_sourcing_preserves_caller_options_without_cluster_calls(self):
        for shell in ("bash", "zsh"):
            if not shutil.which(shell): continue
            with self.subTest(shell=shell):
                result = subprocess.run([shell, "-c", 'set -eu; before=$-; . "$1"; test "$before" = "$-"; echo survived',
                                         "test", str(SCRIPT)], env=self.env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("survived", result.stdout)
        self.assertFalse((self.directory / "calls.jsonl").exists())

    def test_success_protects_source_before_delete_and_preserves_storage_identity(self):
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        changes = self.mutations(calls)
        self.assertEqual([(c["cluster"], c["verb"]) for c in changes],
                         [("src", "patch"), ("src", "delete"), ("sup", "create"), ("dst", "create"), ("dst", "create")])
        patch = changes[0]["payload"]
        self.assertIn({"op": "test", "path": "/metadata/uid", "value": "pv-uid"}, patch)
        self.assertIn({"op": "test", "path": "/metadata/resourceVersion", "value": "20"}, patch)
        self.assertEqual(changes[1]["payload"]["preconditions"], {"uid": "claim-uid", "resourceVersion": "10"})
        pv, pvc = changes[-2]["payload"], changes[-1]["payload"]
        self.assertEqual(pv["spec"]["csi"]["volumeHandle"], "registered-claim")
        self.assertEqual(pv["spec"]["csi"]["fsType"], "xfs")
        self.assertEqual(pv["spec"]["persistentVolumeReclaimPolicy"], "Retain")
        self.assertEqual(pvc["metadata"]["name"], "source-claim")
        state = json.loads((self.directory / "state.json").read_text())
        self.assertIn("pv/source-pv", state["src"])
        self.assertEqual(state["src"]["pv/source-pv"]["status"]["phase"], "Released")
        self.assertTrue(list((self.directory / "rollback").glob("*.json")))
        self.assertEqual((self.directory / "rollback").stat().st_mode & 0o777, 0o700)
        for file in (self.directory / "rollback").glob("*.json"):
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        first_mutation = next(i for i, c in enumerate(calls) if c in changes)
        dry_runs = [c for c in calls[:first_mutation] if any(a.startswith("--dry-run") for a in c["args"])]
        self.assertEqual({c["cluster"] for c in dry_runs}, {"sup", "dst"})

    def test_explicit_contexts_are_pinned_for_every_api_call(self):
        result, calls = self.run_script(overrides={"OCP_CONTEXT": "source-selected", "VKS_CONTEXT": "target-selected",
                                                   "SUPERVISOR_CONTEXT": "supervisor-selected"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        expected = {"src": "source-selected", "dst": "target-selected", "sup": "supervisor-selected"}
        for call in calls:
            if call["verb"] != "config": self.assertEqual(call["context"], expected[call["cluster"]])

    def test_confirmation_requires_exact_disk_id_even_with_legacy_yes(self):
        result, calls = self.run_script(confirmation="YES", overrides={"CONFIRM_DESTRUCTIVE_CUTOVER": "YES"})
        self.assert_failed(result)
        self.assertEqual(self.mutations(calls), [])

    def test_unreadable_config_is_rejected_before_api_calls(self):
        result, calls = self.run_script(overrides={"OCP_KUBECONFIG": str(self.directory / "missing")})
        self.assert_failed(result)
        self.assertEqual(calls, [])

    def test_same_cluster_cannot_be_source_target_or_supervisor(self):
        for other in ("dst", "sup"):
            with self.subTest(other=other):
                self.state = initial_state()
                self.state[other]["namespace/kube-system"]["metadata"]["uid"] = "src-kube-system"
                result, calls = self.run_script()
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls), [])

    def test_unsupported_or_wrong_source_identity_stops_before_mutation(self):
        variants = [("csi", "volumeHandle", "supervisor-pvc-name"),
                    ("csi", "driver", "other.csi.driver"),
                    ("claimRef", "uid", "unrelated-claim")]
        for section, field, value in variants:
            with self.subTest(field=field):
                self.state = initial_state()
                self.state["src"]["pv/source-pv"]["spec"][section][field] = value
                result, calls = self.run_script()
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls), [])
        for field, value in (("volumeMode", "Block"), ("accessModes", ["ReadWriteMany"])):
            with self.subTest(field=field):
                self.state = initial_state()
                self.state["src"]["pv/source-pv"]["spec"][field] = value
                result, calls = self.run_script()
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls), [])

    def test_unbound_or_terminating_source_is_rejected(self):
        for kind, field, value in (("pvc/default/source-claim", "phase", "Pending"),
                                   ("pv/source-pv", "phase", "Released"),
                                   ("pvc/default/source-claim", "deletionTimestamp", "2026-11-12T00:00:00Z")):
            with self.subTest(kind=kind, field=field):
                self.state = initial_state()
                section = "status" if field == "phase" else "metadata"
                self.state["src"][kind][section][field] = value
                result, calls = self.run_script()
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls), [])

    def test_missing_or_mismatched_filesystem_needs_resolution(self):
        self.state["src"]["pv/source-pv"]["spec"]["csi"].pop("fsType")
        result, calls = self.run_script()
        self.assert_failed(result)
        self.assertEqual(self.mutations(calls), [])
        result, calls = self.run_script(overrides={"FSTYPE": "xfs"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.state = initial_state()
        result, calls = self.run_script(overrides={"FSTYPE": "ext4"})
        self.assert_failed(result)
        self.assertEqual(self.mutations(calls), [])

    def test_missing_namespace_or_existing_target_is_not_overwritten(self):
        for mode in ("missing_namespace", "existing_target"):
            with self.subTest(mode=mode):
                self.state = initial_state()
                if mode == "missing_namespace": del self.state["dst"]["namespace/default"]
                else: self.state["dst"]["pv/adopted-pv"] = {"kind": "PersistentVolume", "metadata": {"name": "adopted-pv"}}
                result, calls = self.run_script()
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls), [])

    def test_api_failure_or_live_source_never_permits_cutover(self):
        for failure in ("target_get_error", "dry_run_error", "pods_present", "pods_race",
                        "pod_error", "pod_empty", "pod_malformed", "volumeattachment_error",
                        "volumeattachment_empty", "volumeattachment_malformed"):
            with self.subTest(failure=failure):
                result, calls = self.run_script(failure=failure)
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls), [])

    def test_attached_disk_is_not_registered_until_detachment(self):
        result, calls = self.run_script(failure="attachments_present")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        deletion = next(i for i, c in enumerate(calls) if c["verb"] == "delete")
        registration = next(i for i, c in enumerate(calls) if c["cluster"] == "sup" and c in self.mutations(calls))
        checks = [c for c in calls[deletion:registration] if c["verb"] == "get" and "volumeattachments" in c["words"]]
        self.assertGreaterEqual(len(checks), 2)

    def test_failed_detachment_query_never_allows_registration(self):
        result, calls = self.run_script(failure="detach_query_error")
        self.assert_failed(result)
        self.assertEqual(self.mutations(calls, "sup"), [])
        self.assertEqual(self.mutations(calls, "dst"), [])

    def test_source_identity_change_before_cutover_stops(self):
        for failure in ("source_claim_replaced", "source_pv_replaced"):
            with self.subTest(failure=failure):
                result, calls = self.run_script(failure=failure)
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls), [])

    def test_claim_replacement_after_retain_is_not_deleted(self):
        result, calls = self.run_script(failure="source_claim_replaced_after_retain")
        self.assert_failed(result)
        self.assertEqual([(c["cluster"], c["verb"]) for c in self.mutations(calls)], [("src", "patch")])

    def test_conflicts_never_reach_registration(self):
        for failure in ("patch_conflict", "delete_conflict"):
            with self.subTest(failure=failure):
                result, calls = self.run_script(failure=failure)
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls, "sup"), [])
                self.assertEqual(self.mutations(calls, "dst"), [])

    def test_registration_failure_or_replacement_prevents_vks_adoption(self):
        for failure in ("registration_error", "registration_get_error", "registration_empty", "registration_replaced"):
            with self.subTest(failure=failure):
                result, calls = self.run_script(failure=failure)
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls, "dst"), [])
                self.assertFalse(any(c["verb"] == "delete" and c["cluster"] != "src" for c in calls))

    def test_wrong_supervisor_chain_prevents_vks_adoption(self):
        for failure in ("supervisor_wrong_fcd", "supervisor_wrong_size", "supervisor_wrong_claim",
                        "supervisor_wrong_fs", "supervisor_terminating"):
            with self.subTest(failure=failure):
                result, calls = self.run_script(failure=failure)
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls, "dst"), [])

    def test_final_binding_failure_is_reported_without_cleanup(self):
        result, calls = self.run_script(failure="destination_wrong_binding")
        self.assert_failed(result)
        self.assertTrue(self.mutations(calls, "dst"))
        self.assertFalse(any(c["verb"] == "delete" and c["cluster"] != "src" for c in calls))


if __name__ == "__main__":
    unittest.main()
