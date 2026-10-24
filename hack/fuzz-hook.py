#!/usr/bin/env python3
"""Fuzz the OCI hook with random container root filesystems.

Each case builds a random rootfs (trust store layouts, symlinks that point
outside the rootfs, loops, broken PEM, odd names, missing files), runs the hook
on it as CRI-O would, and checks that:
  - the hook exits 0 and finishes within the time limit
  - no file outside the rootfs changes (host canaries)
  - every good certificate is kept and every bad root is removed
    from the bundles the hook covers

Usage: hack/fuzz-hook.py BAD_PEM_DIR GOOD_PEM [CASES]
  BAD_PEM_DIR  directory with one PEM file per compromised root
  GOOD_PEM     PEM bundle of unrelated, valid certificates
"""
import hashlib, json, os, random, re, shutil, subprocess, sys, tempfile, time

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hook", "rhsb-2026-012-scrub")
TIME_LIMIT = 5.0

BUNDLES = [
    "etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
    "etc/ssl/certs/ca-certificates.crt",
    "etc/ssl/cert.pem",
    "etc/ssl/ca-bundle.pem",
    "var/lib/ca-certificates/ca-bundle.pem",
    "usr/lib/python3.11/site-packages/certifi/cacert.pem",
    "usr/local/lib/python3.12/site-packages/pip/_vendor/certifi/cacert.pem",
    "opt/app-root/lib64/python3.9/site-packages/certifi/cacert.pem",
]


def pems(text):
    return re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\r?\n?", text, re.S)


def digest_tree(path):
    out = {}
    for d, _, files in os.walk(path):
        for f in files:
            p = os.path.join(d, f)
            if not os.path.islink(p):
                out[p] = hashlib.sha256(open(p, "rb").read()).hexdigest()
    return out


def build_case(rng, base, bad, good, canary_dir):
    bundle = os.path.join(base, "bundle")
    root = os.path.join(bundle, rng.choice(["rootfs", "merged", "r o o t"]))
    os.makedirs(root)
    expect = {}  # bundle path -> set of good certs that must remain

    for rel in rng.sample(BUNDLES, rng.randint(0, len(BUNDLES))):
        p = os.path.join(root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        kind = rng.choice(["mixed", "mixed", "good", "bad_only", "broken", "empty", "crlf", "host_link", "dir"])
        g = rng.sample(good, rng.randint(1, min(len(good), 20)))
        b = rng.sample(bad, rng.randint(1, len(bad)))
        if kind == "mixed":
            certs = g + b
            rng.shuffle(certs)
            body = "".join(("# comment %d\n" % rng.randint(0, 9) if rng.random() < .3 else "") + c for c in certs)
            open(p, "w").write(body)
            expect[rel] = set(g)
        elif kind == "good":
            open(p, "w").write("".join(g))
            expect[rel] = set(g)
        elif kind == "bad_only":
            open(p, "w").write("".join(b))
        elif kind == "broken":
            c = b[0]
            open(p, "w").write("".join(g) + c[: rng.randint(10, len(c) - 10)])
        elif kind == "empty":
            open(p, "w").close()
        elif kind == "crlf":
            open(p, "w").write("".join(g + b).replace("\n", "\r\n"))
            expect[rel] = set(c.replace("\n", "\r\n") for c in g)
        elif kind == "host_link":
            os.symlink(os.path.join(canary_dir, "canary.pem"), p)
        elif kind == "dir":
            os.makedirs(p)

    # OpenSSL hash directory, Debian layout, with hostile entries
    if rng.random() < .6:
        certs = os.path.join(root, "etc/ssl/certs")
        share = os.path.join(root, "usr/share/ca-certificates/mozilla")
        os.makedirs(certs, exist_ok=True)
        os.makedirs(share, exist_ok=True)
        for i, c in enumerate(rng.sample(good, 5) + bad):
            name = "c%d %s.crt" % (i, rng.choice(["", "x", "é", "--", "*"]))
            open(os.path.join(share, name), "w").write(c)
            pem = name.replace(".crt", ".pem")
            os.symlink("/usr/share/ca-certificates/mozilla/" + name, os.path.join(certs, pem))
            os.symlink(pem, os.path.join(certs, "%08x.0" % rng.getrandbits(32)))
        os.symlink("loop.0", os.path.join(certs, "loop.0"))
        os.symlink(os.path.join(canary_dir, "canary.pem"), os.path.join(certs, "host.0"))
        os.symlink("/does/not/exist", os.path.join(certs, "dangling.0"))

    # Java keystores: sometimes a regular file, sometimes a link to the host
    for rel in ["etc/pki/ca-trust/extracted/java/cacerts", "etc/ssl/certs/java/cacerts"]:
        if rng.random() < .3:
            p = os.path.join(root, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            if rng.random() < .5:
                open(p, "wb").write(b"\xfe\xed\xfe\xed emSign ECC Root CA - G3 " + os.urandom(64))
            else:
                os.symlink(os.path.join(canary_dir, "cacerts"), p)

    # A whole trust directory replaced by a link to the host
    if rng.random() < .2:
        os.makedirs(os.path.join(root, "etc"), exist_ok=True)
        if not os.path.exists(os.path.join(root, "etc/pki")):
            os.symlink(canary_dir, os.path.join(root, "etc/pki"))

    config = {"ociVersion": "1.0.2", "process": {"args": ["sh"]},
              "root": {"path": os.path.basename(root) if rng.random() < .5 else root, "readonly": False},
              "hooks": {"prestart": [{"path": "/usr/bin/bash"}]}}
    text = json.dumps(config, indent=rng.choice([None, 2]))
    valid = rng.random() >= .05
    if not valid:
        text = text[: len(text) // 2]  # truncated config.json: the hook must do nothing
    open(os.path.join(bundle, "config.json"), "w").write(text)
    state = {"ociVersion": "1.0.2", "id": "%064x" % rng.getrandbits(256), "status": "creating", "pid": 1, "bundle": bundle}
    if rng.random() < .05:
        valid = False
        state_text = rng.choice(["", "{", "not json", "\x00" * 10])
    else:
        state_text = json.dumps(state)
    return root, state_text, expect if valid else {}


def main():
    bad_dir, good_file = sys.argv[1], sys.argv[2]
    cases = int(sys.argv[3]) if len(sys.argv) > 3 else 300
    bad = [pems(open(os.path.join(bad_dir, f)).read())[0] for f in sorted(os.listdir(bad_dir))]
    good = pems(open(good_file).read())
    failures, slowest = 0, 0.0
    for n in range(cases):
        rng = random.Random(n)
        base = tempfile.mkdtemp(prefix="fuzz-")
        canary_dir = os.path.join(base, "host")
        os.makedirs(os.path.join(canary_dir, "ca-trust/extracted/pem"))
        open(os.path.join(canary_dir, "canary.pem"), "w").write("".join(good[:3] + bad))
        open(os.path.join(canary_dir, "cacerts"), "wb").write(b"emSign ECC Root CA - G3 host keystore")
        open(os.path.join(canary_dir, "ca-trust/extracted/pem/tls-ca-bundle.pem"), "w").write("".join(good[:3] + bad))
        java = os.path.join(base, "patched-cacerts")
        open(java, "wb").write(b"patched keystore")
        before = digest_tree(canary_dir)
        root, state, expect = build_case(rng, base, bad, good, canary_dir)
        env = dict(os.environ, RHSB_LOG=os.path.join(base, "hook.log"), RHSB_JAVA_CACERTS=java)
        t = time.time()
        try:
            r = subprocess.run(["bash", HOOK], input=state.encode(), env=env, capture_output=True, timeout=30)
            rc = r.returncode
        except subprocess.TimeoutExpired:
            rc = "timeout"
        took = time.time() - t
        slowest = max(slowest, took)
        problems = []
        if rc != 0:
            problems.append("exit %s" % rc)
        if took > TIME_LIMIT:
            problems.append("slow %.1fs" % took)
        if digest_tree(canary_dir) != before:
            problems.append("HOST FILE CHANGED")
        if state.startswith("{\"") and os.path.isdir(root):
            for rel, keep in expect.items():
                p = os.path.join(root, rel)
                if os.path.islink(p) or not os.path.isfile(p):
                    continue
                text = open(p, newline="").read()
                left = set(pems(text))
                if not keep <= left:
                    problems.append("lost good certs in %s" % rel)
                if any(b.splitlines()[-2] in text for b in bad):
                    problems.append("bad root left in %s" % rel)
        if problems:
            failures += 1
            print("case %d: %s  (kept in %s)" % (n, ", ".join(problems), base))
        else:
            shutil.rmtree(base)
    print("%d cases, %d failed, slowest %.2fs" % (cases, failures, slowest))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
