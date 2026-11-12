"""Offline storage-transition regressions. Never calls a real kubectl.

Run: python3 -m unittest discover -s tests -v
Requires Bash and jq; zsh sourcing checks run when zsh is installed.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ("same-vcenter-example.sh", "cross-vcenter-example.sh")

# A small stateful API double, rather than a replay of a script's exact commands.
# Unknown requests fail, so accidental calls cannot fall through to a live CLI.
MOCK_KUBECTL = r'''
import json, os, pathlib, sys

args = sys.argv[1:]
root = pathlib.Path(os.environ["MOCK_DIR"])
failure = os.environ.get("MOCK_FAILURE", "")
cluster, namespace, output = None, "default", None
words = []
i = 0
while i < len(args):
    arg = args[i]
    if arg.startswith("--kubeconfig="):
        cluster = pathlib.Path(arg.split("=", 1)[1]).name
    elif arg == "--kubeconfig":
        i += 1
        cluster = pathlib.Path(args[i]).name
    elif arg.startswith("--request-timeout="):
        pass
    elif arg.startswith("--context="):
        pass
    elif arg == "--context":
        i += 1
    elif arg in ("-n", "--namespace"):
        i += 1
        namespace = args[i]
    elif arg.startswith("--namespace="):
        namespace = arg.split("=", 1)[1]
    elif arg in ("-o", "--output"):
        i += 1
        output = args[i]
    elif arg.startswith("-o="):
        output = arg.split("=", 1)[1]
    else:
        words.append(arg)
    i += 1

verb = words[0] if words else ""
payload = None
if verb in ("create", "apply") and "-f" in words:
    payload = json.load(sys.stdin)
call = {"args": args, "cluster": cluster, "namespace": namespace,
        "verb": verb, "words": words, "payload": payload}
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps(call) + "\n")
statefile = root / "state.json"
state = json.loads(statefile.read_text())

def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)

def save():
    statefile.write_text(json.dumps(state))

aliases = {
    "namespaces": "namespace", "ns": "namespace",
    "persistentvolume": "pv", "persistentvolumes": "pv",
    "persistentvolumeclaim": "pvc", "persistentvolumeclaims": "pvc",
    "volumesnapshots": "volumesnapshot",
    "volumesnapshotclasses": "volumesnapshotclass",
    "cnsregistervolumes": "cnsregistervolume",
}

def key(kind, name, ns=namespace):
    kind = aliases.get(kind.lower(), kind.lower())
    return kind + "/" + (ns + "/" if kind in
        ("pvc", "volumesnapshot", "cnsregistervolume") else "") + name

def result(obj):
    if output == "name":
        print(obj["kind"].lower() + "/" + obj["metadata"]["name"])
    elif output and output.startswith("jsonpath="):
        path = output.split("=", 1)[1].strip("'\"{}").lstrip(".")
        value = obj
        for part in path.split("."):
            value = value.get(part, "") if isinstance(value, dict) else ""
        if isinstance(value, bool):
            value = str(value).lower()
        print(value, end="")
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
        name = next((v for v in words[2:] if not v.startswith("-")), "")
    resource = aliases.get(resource, resource)
    if resource == "volumeattachments":
        if failure == "attachments_empty":
            sys.exit(0)
        if failure == "attachments_error":
            die("Forbidden: cannot list volumeattachments")
        result({"items": ([{"spec": {"source": {"persistentVolumeName": "source-pv"}}}]
                           if failure == "attachments_present" else [])})
    elif resource == "pods":
        result({"items": ([{"spec": {"volumes": [{"persistentVolumeClaim":
                            {"claimName": "source-claim"}}]}}]
                           if failure == "pods_present" else [])})
    else:
        if resource == "cnsregistervolume" and key(resource, name) in objects:
            if failure == "registration_query_error":
                die("Forbidden: cannot read registration")
            if failure == "registration_empty":
                sys.exit(0)
        obj = objects.get(key(resource, name))
        if obj is None:
            if "--ignore-not-found" not in words and "--ignore-not-found=true" not in words:
                die("NotFound: " + key(resource, name))
        else:
            if failure == "registered_wrong_claim" and cluster == "dst-sup" and resource == "pv":
                obj["spec"]["claimRef"]["uid"] = "another-claim-uid"
            result(obj)
elif verb in ("create", "apply"):
    items = payload["items"] if payload["kind"] == "List" else [payload]
    if any(w.startswith("--dry-run") for w in words):
        print("dry run passed")
        sys.exit(0)
    for item in items:
        metadata = item["metadata"]
        ns = metadata.get("namespace", namespace)
        itemkey = key(item["kind"], metadata["name"], ns)
        if itemkey in objects and verb == "create":
            die("AlreadyExists: " + itemkey)
        metadata["uid"] = "created-" + metadata["name"]
        if item["kind"] == "VolumeSnapshot":
            item["status"] = {"readyToUse": True, "boundVolumeSnapshotContentName": "snapshot-content"}
        elif item["kind"] == "CnsRegisterVolume":
            item["status"] = {"registered": failure not in ("registration_error", "registration_timeout")}
            if failure == "registration_error":
                item["status"]["error"] = "injected registration failure"
            pvcname = item["spec"]["pvcName"]
            pvc = json.loads(json.dumps(state["sup"]["pvc/shared/supervisor-claim"]))
            pv = json.loads(json.dumps(state["sup"]["pv/supervisor-pv"]))
            pvc["metadata"].update(name=pvcname, namespace=ns, uid="registered-claim-uid")
            pvc["spec"]["volumeName"] = "registered-pv"
            pv["metadata"].update(name="registered-pv", uid="registered-pv-uid")
            pv["spec"]["claimRef"] = {"name": pvcname, "namespace": ns, "uid": "registered-claim-uid"}
            pv["spec"]["csi"]["volumeHandle"] = item["spec"]["volumeID"]
            if failure == "registered_wrong_fcd":
                pv["spec"]["csi"]["volumeHandle"] = "wrong-fcd"
            if failure == "registered_wrong_size":
                pv["spec"]["capacity"]["storage"] = "2Gi"
            if failure == "registered_pvc_terminating":
                pvc["metadata"]["deletionTimestamp"] = "2026-11-12T12:00:00Z"
            if failure == "registered_pv_terminating":
                pv["metadata"]["deletionTimestamp"] = "2026-11-12T12:00:00Z"
            objects[key("pvc", pvcname, ns)] = pvc
            objects[key("pv", "registered-pv")] = pv
        elif item["kind"] in ("PersistentVolume", "PersistentVolumeClaim"):
            item["status"] = {"phase": "Bound"}
        objects[itemkey] = item
    # Model PV/PVC binding after the API accepts both objects.
    for item in objects.values():
        if item["kind"] == "PersistentVolumeClaim":
            pv = objects.get(key("pv", item["spec"].get("volumeName", "")))
            if pv:
                pv["spec"]["claimRef"] = {
                    "name": item["metadata"]["name"],
                    "namespace": item["metadata"].get("namespace", namespace),
                    "uid": item["metadata"]["uid"],
                }
    save()
    if output == "json":
        if failure == "registration_create_empty" and items[0]["kind"] == "CnsRegisterVolume":
            sys.exit(0)
        result(items[0] if len(items) == 1 else payload)
    else:
        print("created")
elif verb == "delete":
    resource, name = words[1:3]
    if failure == "deletion_timeout":
        die("injected source deletion timeout")
    objects.pop(key(resource, name), None)
    if resource == "pv" and cluster == "src":
        pvc = state["sup"]["pvc/shared/supervisor-claim"]
        pv = state["sup"]["pv/supervisor-pv"]
        if failure == "preserved_pvc_terminating":
            pvc["metadata"]["deletionTimestamp"] = "2026-11-12T12:00:00Z"
        if failure == "preserved_pv_terminating":
            pv["metadata"]["deletionTimestamp"] = "2026-11-12T12:00:00Z"
        if failure == "preserved_wrong_fcd":
            pv["spec"]["csi"]["volumeHandle"] = "changed-fcd"
        if failure == "preserved_rebound":
            pvc["spec"]["volumeName"] = "replacement-pv"
        if failure == "preserved_recreated":
            pvc["metadata"]["uid"] = "replacement-uid"
    save()
    print("deleted")
elif verb == "wait":
    if failure == "snapshot_timeout" and any(w.startswith("volumesnapshot/") for w in words):
        die("injected snapshot timeout")
    if failure in ("registration_error", "registration_timeout") and any(w.startswith("cnsregistervolume/") for w in words):
        die("injected registration wait timeout")
    print("condition met")
else:
    die("Unexpected mock request: " + repr(args))
'''


def volume_pair(pvc_name, pv_name, namespace, handle, fs_type="xfs"):
    claim_uid = pvc_name + "-uid"
    pvc = {
        "apiVersion": "v1", "kind": "PersistentVolumeClaim",
        "metadata": {"name": pvc_name, "namespace": namespace, "uid": claim_uid},
        "spec": {"volumeName": pv_name, "storageClassName": "storage-policy",
                 "accessModes": ["ReadWriteOnce"], "volumeMode": "Filesystem",
                 "resources": {"requests": {"storage": "1Gi"}}},
        "status": {"phase": "Bound"},
    }
    pv = {
        "apiVersion": "v1", "kind": "PersistentVolume",
        "metadata": {"name": pv_name, "uid": pv_name + "-uid"},
        "spec": {"capacity": {"storage": "1Gi"}, "accessModes": ["ReadWriteOnce"],
                 "volumeMode": "Filesystem", "persistentVolumeReclaimPolicy": "Delete",
                 "claimRef": {"namespace": namespace, "name": pvc_name, "uid": claim_uid},
                 "csi": {"driver": "csi.vsphere.vmware.com", "volumeHandle": handle, "fsType": fs_type}},
        "status": {"phase": "Bound"},
    }
    return {"pvc/" + namespace + "/" + pvc_name: pvc, "pv/" + pv_name: pv}


def initial_state():
    state = {cluster: {} for cluster in ("src", "dst", "sup", "dst-sup")}
    for cluster, objects in state.items():
        for namespace in ("default", "shared", "kube-system"):
            objects["namespace/" + namespace] = {
                "kind": "Namespace", "metadata": {"name": namespace, "uid": cluster + "-" + namespace},
                "status": {"phase": "Active"},
            }
    state["src"].update(volume_pair("source-claim", "source-pv", "default", "supervisor-claim"))
    state["sup"].update(volume_pair("supervisor-claim", "supervisor-pv", "shared", "source-fcd"))
    state["sup"]["volumesnapshotclass/volumesnapshotclass-delete"] = {
        "kind": "VolumeSnapshotClass", "metadata": {"name": "volumesnapshotclass-delete"},
        "driver": "csi.vsphere.vmware.com", "deletionPolicy": "Delete",
    }
    return state


@unittest.skipUnless(shutil.which("jq") and shutil.which("bash"), "requires jq and bash")
class MigrationScriptsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="migration-script-tests-")
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        mock = self.directory / "kubectl"
        mock.write_text("#!" + sys.executable + "\n" + MOCK_KUBECTL)
        mock.chmod(0o755)
        self.env = {"PATH": str(self.directory) + os.pathsep + os.environ["PATH"],
                    "HOME": str(self.directory), "MOCK_DIR": str(self.directory),
                    "SRC_SUP_NS": "shared", "DST_SUP_NS": "shared",
                    "SRC_VKS_PVC": "source-claim", "VKS_PVC_SIZE": "1Gi",
                    "DEST_FCD_UUID": "destination-fcd", "FSTYPE": "xfs"}
        for variable, name in (("SRC_VKS_KUBECONFIG", "src"), ("DST_VKS_KUBECONFIG", "dst"),
                               ("SUPERVISOR_KUBECONFIG", "sup"), ("DST_SUP_KUBECONFIG", "dst-sup")):
            config = self.directory / name
            config.write_text("mock kubeconfig; never read by real kubectl\n")
            self.env[variable] = str(config)
        self.state = initial_state()

    def run_script(self, script=SCRIPTS[0], failure="", overrides=None, confirmation=None):
        (self.directory / "state.json").write_text(json.dumps(self.state))
        (self.directory / "calls.jsonl").unlink(missing_ok=True)
        env = self.env.copy()
        env["MOCK_FAILURE"] = failure
        env.update(overrides or {})
        if confirmation is None:
            confirmation = "source-claim" if script == SCRIPTS[0] else "destination-fcd"
        result = subprocess.run(["bash", str(ROOT / script)], env=env,
                                input=confirmation + "\n", text=True,
                                capture_output=True, timeout=20)
        log = self.directory / "calls.jsonl"
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    def assert_succeeded(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_failed(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    @staticmethod
    def mutations(calls, cluster=None):
        return [call for call in calls if call["verb"] in ("create", "apply", "delete", "patch")
                and not any(arg.startswith("--dry-run") for arg in call["args"])
                and (cluster is None or call["cluster"] == cluster)]

    def test_help_needs_no_configuration_or_cluster_access(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                result = subprocess.run(["bash", str(ROOT / script), "--help"],
                                        env={"PATH": self.env["PATH"]}, capture_output=True, text=True)
                self.assert_succeeded(result)
                self.assertIn("Usage:", result.stdout)
        self.assertFalse((self.directory / "calls.jsonl").exists())

    def test_sourcing_preserves_strict_caller_shell_and_never_calls_kubectl(self):
        for shell in ("bash", "zsh"):
            if not shutil.which(shell):
                continue
            for script in SCRIPTS:
                with self.subTest(shell=shell, script=script):
                    result = subprocess.run([
                        shell, "-c", 'set -eu; before=$-; . "$1"; test "$before" = "$-"; echo caller-survived',
                        "test", str(ROOT / script)], env=self.env, capture_output=True, text=True)
                    self.assert_succeeded(result)
                    self.assertIn("caller-survived", result.stdout)
        self.assertFalse((self.directory / "calls.jsonl").exists())

    def test_same_success_preserves_chain_filesystem_and_claim_name(self):
        self.env.pop("FSTYPE")
        result, calls = self.run_script()
        self.assert_succeeded(result)
        changes = self.mutations(calls)
        self.assertEqual([(c["cluster"], c["verb"]) for c in changes],
                         [("sup", "create"), ("src", "delete"), ("src", "delete"), ("dst", "create")])
        ready = next(i for i, c in enumerate(calls) if c["verb"] == "wait" and c["cluster"] == "sup")
        removal = next(i for i, c in enumerate(calls) if c["verb"] == "delete")
        self.assertLess(ready, removal)
        pv, pvc = changes[-1]["payload"]["items"]
        self.assertEqual(pv["spec"]["csi"]["volumeHandle"], "supervisor-claim")
        self.assertEqual(pv["spec"]["csi"]["fsType"], "xfs")
        self.assertEqual(pv["spec"]["persistentVolumeReclaimPolicy"], "Retain")
        self.assertEqual(pvc["metadata"]["name"], "source-claim")
        self.assertEqual(pvc["spec"]["storageClassName"], "")
        self.assertIn("no source CSI deletion retries", result.stdout)

    def test_same_namespace_mismatch_stops_before_cluster_access(self):
        result, calls = self.run_script(overrides={"DST_SUP_NS": "different"})
        self.assert_failed(result)
        self.assertEqual(calls, [])

    def test_same_legacy_namespace_alias(self):
        self.env.pop("SRC_SUP_NS")
        result, _ = self.run_script(overrides={"SUP_NS": "shared"})
        self.assert_succeeded(result)

    def test_same_refuses_attached_volume_or_unreadable_attachment_list(self):
        for failure in ("attachments_present", "attachments_error", "attachments_empty", "pods_present"):
            with self.subTest(failure=failure):
                result, calls = self.run_script(failure=failure)
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls), [])

    def test_same_rejects_unsupported_source_volume_before_changes(self):
        for field, value in (("volumeMode", "Block"), ("accessModes", ["ReadWriteMany"])):
            with self.subTest(field=field):
                self.state = initial_state()
                self.state["src"]["pv/source-pv"]["spec"][field] = value
                result, calls = self.run_script()
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls), [])

    def test_same_refuses_wrong_filesystem(self):
        result, calls = self.run_script(overrides={"FSTYPE": "ext4"})
        self.assert_failed(result)
        self.assertEqual(self.mutations(calls), [])

    def test_same_refuses_existing_destination(self):
        self.state["dst"].update(volume_pair("source-claim", "unrelated-pv", "default", "unrelated-handle"))
        result, calls = self.run_script()
        self.assert_failed(result)
        self.assertEqual(self.mutations(calls), [])

    def test_same_refuses_missing_destination_namespace(self):
        del self.state["dst"]["namespace/default"]
        result, calls = self.run_script()
        self.assert_failed(result)
        self.assertEqual(self.mutations(calls), [])

    def test_same_refuses_same_cluster_even_with_different_contexts(self):
        self.state["dst"]["namespace/kube-system"]["metadata"]["uid"] = "src-kube-system"
        result, calls = self.run_script()
        self.assert_failed(result)
        self.assertEqual(self.mutations(calls), [])

    def test_same_refuses_existing_snapshot(self):
        self.state["sup"]["volumesnapshot/shared/supervisor-claim-migration-snapshot"] = {
            "kind": "VolumeSnapshot", "metadata": {"name": "supervisor-claim-migration-snapshot"}}
        result, calls = self.run_script()
        self.assert_failed(result)
        self.assertEqual(self.mutations(calls), [])

    def test_same_confirmation_mismatch_changes_nothing(self):
        result, calls = self.run_script(confirmation="yes")
        self.assert_failed(result)
        self.assertEqual(self.mutations(calls), [])

    def test_same_snapshot_timeout_never_deletes_source(self):
        result, calls = self.run_script(failure="snapshot_timeout")
        self.assert_failed(result)
        self.assertEqual([c["cluster"] for c in self.mutations(calls)], ["sup"])
        self.assertIn("snapshot", result.stderr)

    def test_same_deletion_timeout_never_adopts_or_removes_protection(self):
        result, calls = self.run_script(failure="deletion_timeout")
        self.assert_failed(result)
        self.assertEqual(self.mutations(calls, "dst"), [])
        self.assertFalse(any(c["cluster"] == "sup" and c["verb"] == "delete" for c in calls))

    def test_same_changed_preserved_chain_stops_destination_adoption(self):
        for failure in ("preserved_pvc_terminating", "preserved_pv_terminating",
                        "preserved_wrong_fcd", "preserved_rebound", "preserved_recreated"):
            with self.subTest(failure=failure):
                result, calls = self.run_script(failure=failure)
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls, "dst"), [])
                self.assertEqual(len(self.mutations(calls, "src")), 2)

    def test_cross_success_registers_destination_fcd_then_adopts_supervisor_claim(self):
        result, calls = self.run_script(SCRIPTS[1])
        self.assert_succeeded(result)
        changes = self.mutations(calls)
        self.assertEqual([(c["cluster"], c["verb"]) for c in changes],
                         [("dst-sup", "create"), ("dst", "create")])
        self.assertEqual(changes[0]["payload"]["spec"]["volumeID"], "destination-fcd")
        pv, pvc = changes[1]["payload"]["items"]
        self.assertEqual(pv["spec"]["csi"]["volumeHandle"], "migrated-cross-supervisor-pvc")
        self.assertEqual(pv["spec"]["csi"]["fsType"], "xfs")
        self.assertEqual(pvc["metadata"]["name"], "source-claim")
        self.assertFalse(any(c["cluster"] in ("src", "sup") for c in calls))

    def test_cross_registration_error_is_reported_and_never_adopted(self):
        result, calls = self.run_script(SCRIPTS[1], failure="registration_error")
        self.assert_failed(result)
        self.assertEqual(self.mutations(calls, "dst"), [])
        self.assertIn("injected registration failure", result.stdout + result.stderr)

    def test_cross_unreadable_registration_never_adopts(self):
        for failure in ("registration_query_error", "registration_empty", "registration_create_empty"):
            with self.subTest(failure=failure):
                result, calls = self.run_script(SCRIPTS[1], failure=failure)
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls, "dst"), [])

    def test_cross_invalid_registered_chain_never_adopts(self):
        for failure in ("registered_wrong_fcd", "registered_wrong_size",
                        "registered_pvc_terminating", "registered_pv_terminating", "registered_wrong_claim"):
            with self.subTest(failure=failure):
                result, calls = self.run_script(SCRIPTS[1], failure=failure)
                self.assert_failed(result)
                self.assertEqual(self.mutations(calls, "dst"), [])

    def test_cross_missing_recorded_capacity_stops_before_cluster_access(self):
        self.env.pop("VKS_PVC_SIZE")
        result, calls = self.run_script(SCRIPTS[1])
        self.assert_failed(result)
        self.assertEqual(calls, [])

    def test_cross_existing_destination_prevents_registration(self):
        self.state["dst"].update(volume_pair("source-claim", "unrelated-pv", "default", "unrelated-handle"))
        result, calls = self.run_script(SCRIPTS[1])
        self.assert_failed(result)
        self.assertEqual(self.mutations(calls), [])

    def test_cross_confirmation_mismatch_changes_nothing(self):
        result, calls = self.run_script(SCRIPTS[1], confirmation="yes")
        self.assert_failed(result)
        self.assertEqual(self.mutations(calls), [])


if __name__ == "__main__":
    unittest.main()
