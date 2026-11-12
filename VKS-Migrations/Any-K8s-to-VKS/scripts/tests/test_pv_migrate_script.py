"""Offline pv-migrate wrapper regressions; no real Kubernetes API is contacted.

Run: python3 -m unittest discover -s scripts/tests -v
Requires Bash, jq and Python 3. Sourcing checks include zsh when installed.
"""

import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "pv-migrate-poc.sh"

# Unknown requests fail closed. All external cluster/transfer tools on PATH are
# replaced so a missing mock behavior cannot accidentally contact a live API.
MOCK = r'''
import copy, json, os, pathlib, sys
root = pathlib.Path(os.environ["MOCK_DIR"])
failure = os.environ.get("MOCK_FAILURE", "")
args = sys.argv[1:]
tool = pathlib.Path(sys.argv[0]).name
statefile = root / "state.json"
state = json.loads(statefile.read_text())
counters = state.setdefault("_counters", {})

def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)

def save():
    statefile.write_text(json.dumps(state))

def log(call):
    with (root / "calls.jsonl").open("a") as f:
        f.write(json.dumps(call) + "\n")

if tool == "pv-migrate":
    log(dict(tool=tool, args=args))
    if "--help" in args or "-h" in args:
        flags = ["--source-kubeconfig", "--source-context", "--source-namespace", "--source",
                 "--dest-kubeconfig", "--dest-context", "--dest-namespace", "--dest", "--strategies",
                 "--rsync-push", "--id", "--no-cleanup-on-failure", "--helm-values", "--helm-set",
                 "--helm-timeout", "--loadbalancer-timeout", "--ignore-mounted", "--rsync-no-perms",
                 "--rsync-no-owner", "--rsync-no-group", "--non-root"]
        if failure == "missing_cli_flag": flags.remove("--rsync-push")
        print("Usage: pv-migrate [flags]\n" + "\n".join(flag + " value" for flag in flags))
    elif args in (["version"], ["--version"]):
        print("pv-migrate v3.7.0")
    elif args and args[0] == "cleanup":
        die("Unexpected automatic cleanup")
    else:
        state["_copy_done"] = True
        save()
        print("fake pv-migrate copy output")
        if failure == "copy_error": die("injected copy failure")
    sys.exit(0)

if tool == "helm":
    log(dict(tool=tool, args=args))
    if "list" in args or "ls" in args:
        if failure == "helm_error": die("Forbidden: Helm list")
        if failure == "helm_malformed": print("{}"); sys.exit(0)
        print("[]" if failure != "release_collision" else '[{"name":"pv-migrate-test-sshd"}]')
    elif "version" in args:
        print('v3.19.0')
    else:
        die("Unexpected Helm request")
    sys.exit(0)

if tool != "kubectl": die("Unexpected tool " + tool)
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
log(dict(tool=tool, args=args, words=words, verb=verb, cluster=cluster, namespace=namespace,
         context=context))
if cluster not in state: die("Unexpected kubeconfig " + str(cluster))
objects = state[cluster]
aliases = {"namespaces": "namespace", "ns": "namespace", "pods": "pod", "po": "pod",
           "persistentvolume": "pv", "persistentvolumes": "pv",
           "persistentvolumeclaim": "pvc", "persistentvolumeclaims": "pvc"}

def key(kind, name):
    return kind + "/" + (namespace + "/" if kind in ("pvc", "pod") else "") + name

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

if verb == "config" and words[1:] == ["current-context"]:
    print(cluster + "-context")
elif verb == "version":
    print('{"clientVersion":{"gitVersion":"v1.35.0"}}')
elif verb == "cluster-info":
    print("Mock cluster " + cluster)
elif verb == "auth" and words[1] == "can-i":
    if failure == "authorization_error": die("Forbidden: selfsubjectaccessreview")
    if failure == "authorization_denied":
        print("no"); sys.exit(1)
    print("yes")
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
    if failure == "get_error" and cluster == "dst" and resource == "pvc": die("Forbidden: get PVC")
    if failure == "get_empty" and cluster == "dst" and resource == "pvc": sys.exit(0)
    if failure == "get_malformed" and cluster == "dst" and resource == "pvc":
        print('{"items":[]}'); sys.exit(0)
    if resource == "pod":
        if failure == "pods_error": die("Forbidden: list pods")
        if failure == "pods_empty": sys.exit(0)
        if failure == "pods_malformed": result({"items": None}); sys.exit(0)
        items = []
        if failure == cluster + "_pod" or (failure == "pods_race" and cluster == "dst" and counters[countkey] > 1):
            items = [{"metadata": {"name": "writer"}, "status":{"phase":"Running"}, "spec":{"volumes":[
                {"persistentVolumeClaim":{"claimName":"source-data" if cluster == "src" else "target-data"}}]}}]
        result({"apiVersion":"v1","kind":"List","items":items})
    elif resource in ("secret", "secrets", "configmap", "configmaps", "job", "jobs", "service", "services", "all") or "," in resource:
        if failure == "collision_get_error": die("Forbidden: list migration objects")
        items = []
        if failure in ("release_collision", "object_collision"):
            items = [{"metadata":{"name":"sh.helm.release.v1.pv-migrate-test.v1","labels":{"name":"pv-migrate-test","app.kubernetes.io/instance":"pv-migrate-test"}}}]
        result({"apiVersion":"v1","kind":"List","items":items})
    else:
        obj = objects.get(key(resource, name))
        if obj is None:
            if "--ignore-not-found" in words or "--ignore-not-found=true" in words: sys.exit(0)
            die("NotFound: " + key(resource, name))
        obj = copy.deepcopy(obj)
        if resource == "namespace" and failure == "revalidate_namespace_error" and counters[countkey] > 1:
            result(obj); die("Failed API request with partial namespace output")
        if resource in ("pvc", "pv"):
            if failure == cluster + "_replaced" and counters[countkey] > 1:
                obj["metadata"]["uid"] = "replaced-uid"
            if failure == "postcopy_replaced" and state.get("_copy_done"):
                obj["metadata"]["uid"] = "postcopy-replaced"
            if failure == "postcopy_binding" and state.get("_copy_done") and resource == "pv":
                obj["spec"]["claimRef"]["uid"] = "wrong-claim"
        result(obj)
else:
    die("Unexpected kubectl command " + repr(args))
'''


def initial_state():
    state = {name: {} for name in ("src", "dst")}
    for cluster, objects in state.items():
        for ns in ("default", "kube-system"):
            objects["namespace/" + ns] = {
                "apiVersion": "v1", "kind": "Namespace",
                "metadata": {"name": ns, "uid": cluster + "-" + ns}, "status": {"phase": "Active"}}
        claim = "source-data" if cluster == "src" else "target-data"
        pvname = cluster + "-pv"
        pvc = {"apiVersion":"v1", "kind":"PersistentVolumeClaim",
               "metadata":{"name":claim,"namespace":"default","uid":cluster+"-claim-uid","resourceVersion":"10"},
               "spec":{"volumeName":pvname,"accessModes":["ReadWriteOnce"],"volumeMode":"Filesystem",
                       "storageClassName":"test-class","resources":{"requests":{"storage":"1Gi"}}},
               "status":{"phase":"Bound","capacity":{"storage":"1Gi"},"accessModes":["ReadWriteOnce"]}}
        pv = {"apiVersion":"v1","kind":"PersistentVolume",
              "metadata":{"name":pvname,"uid":cluster+"-pv-uid","resourceVersion":"20"},
              "spec":{"capacity":{"storage":"1Gi"},"accessModes":["ReadWriteOnce"],"volumeMode":"Filesystem",
                      "persistentVolumeReclaimPolicy":"Delete","storageClassName":"test-class",
                      "claimRef":{"namespace":"default","name":claim,"uid":cluster+"-claim-uid"}},
              "status":{"phase":"Bound"}}
        if cluster == "src": pv["spec"]["hostPath"] = {"path":"/data/source","type":"DirectoryOrCreate"}
        else: pv["spec"]["csi"] = {"driver":"csi.vsphere.vmware.com","volumeHandle":"destination-handle","fsType":"ext4"}
        objects.update({"pvc/default/"+claim:pvc,"pv/"+pvname:pv})
    return state


@unittest.skipUnless(shutil.which("bash") and shutil.which("jq"), "requires Bash and jq")
class PvMigrateScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pv-migrate-script-tests-")
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        for name in ("kubectl", "pv-migrate", "helm"):
            p = self.directory / name
            p.write_text("#!" + sys.executable + "\n" + MOCK)
            p.chmod(0o755)
        for name in ("oc", "govc"):
            p = self.directory / name
            p.write_text("#!/bin/sh\necho 'Unexpected external tool' >&2\nexit 99\n")
            p.chmod(0o755)
        p = self.directory / "sleep"
        p.write_text("#!/bin/sh\nexit 0\n")
        p.chmod(0o755)
        self.env = {"PATH": str(self.directory)+os.pathsep+os.environ["PATH"],
                    "HOME":str(self.directory),"MOCK_DIR":str(self.directory),
                    "SRC_NAMESPACE":"default","DST_NAMESPACE":"default",
                    "SRC_PVC":"source-data","DST_PVC":"target-data",
                    "MIGRATION_ID":"test","OUTPUT_DIR":str(self.directory/"evidence")}
        for var, name in (("SRC_KUBECONFIG","src"),("DST_KUBECONFIG","dst")):
            p = self.directory/name; p.write_text("mock config; never read by real kubectl\n")
            self.env[var] = str(p)
        self.state = initial_state()

    def run_script(self, failure="", overrides=None, confirmation="dst-claim-uid", keep_output=False):
        (self.directory/"state.json").write_text(json.dumps(self.state))
        (self.directory/"calls.jsonl").unlink(missing_ok=True)
        if not keep_output: shutil.rmtree(self.directory/"evidence",ignore_errors=True)
        env = dict(self.env, MOCK_FAILURE=failure)
        env.update(overrides or {})
        result = subprocess.run(["bash",str(SCRIPT)],env=env,input=confirmation+"\n",capture_output=True,text=True,timeout=45)
        path = self.directory/"calls.jsonl"
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return result,calls

    def assert_failed(self,result):
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)

    @staticmethod
    def copies(calls):
        return [c for c in calls if c["tool"]=="pv-migrate" and not any(a in c["args"] for a in ("--help","-h","version","--version"))]

    def test_help_needs_no_credentials_or_cluster_calls(self):
        r = subprocess.run(["bash",str(SCRIPT),"--help"],env={"PATH":self.env["PATH"]},text=True,capture_output=True)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn("Usage:",r.stdout)
        self.assertFalse((self.directory/"calls.jsonl").exists())

    def test_sourcing_keeps_shell_options_and_never_calls_tools(self):
        for shell in ("bash","zsh"):
            if not shutil.which(shell): continue
            with self.subTest(shell=shell):
                r = subprocess.run([shell,"-c",'set -eu; before=$-; . "$1"; test "$before" = "$-"; echo survived',"test",str(SCRIPT)],env=self.env,text=True,capture_output=True)
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertIn("survived",r.stdout)
        self.assertFalse((self.directory/"calls.jsonl").exists())

    def test_success_pins_contexts_and_retains_diagnostics_without_deleting_claims(self):
        r,calls=self.run_script()
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        copies=self.copies(calls);self.assertEqual(len(copies),1)
        args=copies[0]["args"]
        for flag in ("--rsync-push","--no-cleanup-on-failure"): self.assertIn(flag,args)
        for flag,value in (("--source-context","src-context"),("--dest-context","dst-context"),
                           ("--source","source-data"),("--dest","target-data"),
                           ("--source-namespace","default"),("--dest-namespace","default")):
            self.assertIn(flag,args);self.assertEqual(args[args.index(flag)+1],value)
        self.assertNotIn("--dest-delete-extraneous-files",args)
        self.assertFalse(any(c.get("verb") in ("create","patch","delete","apply") for c in calls))
        for c in calls:
            if c["tool"]=="kubectl" and c["verb"] not in ("config","version"):
                self.assertEqual(c["context"],c["cluster"]+"-context")
        self.assertTrue(list((self.directory/"evidence").glob("*.json")))
        self.assertEqual((self.directory/"evidence").stat().st_mode&0o777,0o700)
        for p in (self.directory/"evidence").iterdir():
            if p.is_file():self.assertEqual(p.stat().st_mode&0o777,0o600)

    def test_explicit_contexts_are_forwarded_to_copy_and_api_calls(self):
        r,calls=self.run_script(overrides={"SRC_CONTEXT":"chosen-src","DST_CONTEXT":"chosen-dst"})
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        args=self.copies(calls)[0]["args"]
        self.assertEqual(args[args.index("--source-context")+1],"chosen-src")
        self.assertEqual(args[args.index("--dest-context")+1],"chosen-dst")
        for c in calls:
            if c["tool"]=="kubectl" and c["verb"] not in ("config","version"):
                self.assertEqual(c["context"],"chosen-"+c["cluster"])

    def test_legacy_yes_does_not_approve_copy(self):
        r,calls=self.run_script(overrides={"ACK_FINAL_COPY":"yes"},confirmation="yes")
        self.assert_failed(r);self.assertEqual(self.copies(calls),[])

    def test_same_cluster_is_rejected_before_copy(self):
        self.state["dst"]["namespace/kube-system"]["metadata"]["uid"]="src-kube-system"
        r,calls=self.run_script();self.assert_failed(r);self.assertEqual(self.copies(calls),[])

    def test_same_csi_backing_handle_is_rejected(self):
        self.state["src"]["pv/src-pv"]["spec"].pop("hostPath")
        self.state["src"]["pv/src-pv"]["spec"]["csi"]=copy.deepcopy(self.state["dst"]["pv/dst-pv"]["spec"]["csi"])
        r,calls=self.run_script();self.assert_failed(r);self.assertEqual(self.copies(calls),[])

    def test_unreadable_kubeconfig_prevents_api_calls(self):
        r,calls=self.run_script(overrides={"SRC_KUBECONFIG":str(self.directory/"missing")})
        self.assert_failed(r);self.assertFalse(any(c["tool"]=="kubectl" for c in calls));self.assertEqual(self.copies(calls),[])

    def test_both_sides_must_be_bound_nonterminating_filesystems_with_matching_claims(self):
        variants=[("status","phase","Pending"),("metadata","deletionTimestamp","2026-11-12T00:00:00Z"),
                  ("spec","volumeMode","Block")]
        for cluster,kind in (("src","pvc/default/source-data"),("dst","pvc/default/target-data"),("src","pv/src-pv"),("dst","pv/dst-pv")):
            for section,key,value in variants:
                with self.subTest(cluster=cluster,kind=kind,key=key):
                    self.state=initial_state();self.state[cluster][kind][section][key]=value
                    r,calls=self.run_script();self.assert_failed(r);self.assertEqual(self.copies(calls),[])
        self.state=initial_state();self.state["dst"]["pv/dst-pv"]["spec"]["claimRef"]["uid"]="wrong"
        r,calls=self.run_script();self.assert_failed(r);self.assertEqual(self.copies(calls),[])

    def test_api_errors_empty_outputs_and_pod_use_stop_before_copy(self):
        for failure in ("get_error","get_empty","get_malformed","src_pod","dst_pod","pods_race",
                        "pods_error","pods_empty","pods_malformed","release_collision","helm_error","helm_malformed"):
            with self.subTest(failure=failure):
                r,calls=self.run_script(failure=failure);self.assert_failed(r);self.assertEqual(self.copies(calls),[])

    def test_failed_namespace_revalidation_is_not_hidden_by_valid_stdout(self):
        r,calls=self.run_script(failure="revalidate_namespace_error")
        self.assert_failed(r);self.assertEqual(self.copies(calls),[])

    def test_capacity_compares_quantities_not_strings(self):
        for capacity,success in (("1024Mi",True),("2Gi",True),("512Mi",False),("1G",False),("1.1Gi",True)):
            with self.subTest(capacity=capacity):
                self.state=initial_state()
                self.state["dst"]["pv/dst-pv"]["spec"]["capacity"]["storage"]=capacity
                self.state["dst"]["pvc/default/target-data"]["status"]["capacity"]["storage"]=capacity
                r,calls=self.run_script()
                self.assertEqual(r.returncode==0,success,r.stdout+r.stderr)
                self.assertEqual(bool(self.copies(calls)),success)

    def test_binary_exabyte_and_decimal_exponent_quantities(self):
        for source,destination in (("1Ei","1024Pi"),("1e9","1000000000")):
            with self.subTest(source=source,destination=destination):
                self.state=initial_state()
                self.state["src"]["pv/src-pv"]["spec"]["capacity"]["storage"]=source
                self.state["dst"]["pv/dst-pv"]["spec"]["capacity"]["storage"]=destination
                self.state["src"]["pvc/default/source-data"]["status"]["capacity"]["storage"]=source
                self.state["dst"]["pvc/default/target-data"]["status"]["capacity"]["storage"]=destination
                r,calls=self.run_script()
                self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertEqual(len(self.copies(calls)),1)

    def test_access_mode_superset_and_completed_resize_capacity(self):
        for cluster in ("src","dst"):
            self.state[cluster]["pv/"+cluster+"-pv"]["spec"]["accessModes"]=["ReadWriteOnce","ReadOnlyMany","ReadWriteMany"]
        r,calls=self.run_script()
        self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertEqual(len(self.copies(calls)),1)

    def test_active_resize_or_small_filesystem_blocks_copy(self):
        for cluster,claim in (("src","source-data"),("dst","target-data")):
            for condition in ("Resizing","FileSystemResizePending"):
                with self.subTest(cluster=cluster,condition=condition):
                    self.state=initial_state()
                    self.state[cluster]["pvc/default/"+claim]["status"]["conditions"]=[{"type":condition,"status":"True"}]
                    r,calls=self.run_script();self.assert_failed(r);self.assertEqual(self.copies(calls),[])
        self.state=initial_state()
        self.state["dst"]["pvc/default/target-data"]["status"]["capacity"]["storage"]="512Mi"
        r,calls=self.run_script();self.assert_failed(r);self.assertEqual(self.copies(calls),[])

    def test_identity_change_after_confirmation_prevents_copy(self):
        for failure in ("src_replaced","dst_replaced"):
            with self.subTest(failure=failure):
                r,calls=self.run_script(failure=failure);self.assert_failed(r);self.assertEqual(self.copies(calls),[])

    def test_copy_failure_is_propagated_without_cleanup(self):
        r,calls=self.run_script(failure="copy_error");self.assert_failed(r);self.assertEqual(len(self.copies(calls)),1)
        self.assertFalse(any(c.get("verb")=="delete" for c in calls))
        self.assertTrue(list((self.directory/"evidence").iterdir()))

    def test_postcopy_identity_or_binding_changes_report_failure(self):
        for failure in ("postcopy_replaced","postcopy_binding"):
            with self.subTest(failure=failure):
                r,calls=self.run_script(failure=failure);self.assert_failed(r);self.assertEqual(len(self.copies(calls)),1)

    def test_missing_required_pv_migrate_flag_is_rejected(self):
        r,calls=self.run_script(failure="missing_cli_flag")
        self.assert_failed(r);self.assertEqual(self.copies(calls),[])

    def test_invalid_ids_strategies_and_unreadable_values_prevent_copy(self):
        for override in ({"MIGRATION_ID":"Invalid-ID"},{"MIGRATION_ID":"x"*25},
                         {"STRATEGIES":"bogus"},{"PV_MIGRATE_VALUES_FILE":str(self.directory/"missing")},
                         {"NON_ROOT":"maybe"}):
            with self.subTest(override=override):
                r,calls=self.run_script(overrides=override)
                self.assert_failed(r);self.assertEqual(self.copies(calls),[])

    def test_values_and_nonroot_options_are_passed_as_separate_arguments(self):
        values=self.directory/"custom values.yaml"
        values.write_text("rsync: {}\n")
        r,calls=self.run_script(overrides={"PV_MIGRATE_VALUES_FILE":str(values),"NON_ROOT":"yes", "STRATEGIES":"local"})
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        args=self.copies(calls)[0]["args"]
        self.assertIn("--non-root",args)
        self.assertEqual(args[args.index("--helm-values")+1],str(self.directory/"evidence"/"helm-values.yaml"))
        self.assertEqual((self.directory/"evidence"/"helm-values.yaml").read_text(),values.read_text())
        self.assertEqual(args[args.index("--strategies")+1],"local")

    def test_existing_evidence_directory_is_not_overwritten(self):
        p=self.directory/"evidence";p.mkdir();(p/"marker").write_text("keep me")
        r,calls=self.run_script(keep_output=True);self.assert_failed(r);self.assertEqual(self.copies(calls),[])
        self.assertEqual((p/"marker").read_text(),"keep me")


if __name__=="__main__":
    unittest.main()
