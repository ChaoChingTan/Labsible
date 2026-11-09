#!/usr/bin/env python3
"""Sync a class roster into Guacamole through its REST API.

Roster CSV columns:  class,email,name     (class is PA31, PA32 or PA33)

For every roster row the script makes sure there is
  * a Guacamole user named by the email (random password, set ONLY when the user is new),
  * an RDP connection "<CLASS>-S<NN> <email>" to the student's Kali (10.0.<class>.<100+NN>)
    that routes through the class guacd pool (NLB at 10.0.<class>.10:4822),
  * READ permission for that user on that connection only,
  * membership of the class user group (PA31 / PA32 / PA33).
Existing users keep their password. Nothing is ever deleted. The index NN is the next
unused number in the class (existing connections are read back from Guacamole).

Writes (git-ignored, mode 600) to --out-dir:
  credentials-<timestamp>.csv   email,password,class,index   NEW users only
  assignments-<timestamp>.csv   class,index,ip,email,name    every roster row

Needs: AWS CLI configured, LAB_DOMAIN and AWS_REGION in the environment (params/lab.env).

  source params/lab.env
  scripts/sync_guac.py roster/roster.csv --dry-run
  scripts/sync_guac.py roster/roster.csv
  scripts/sync_guac.py --reset alice@example.com      # new password for one user
  scripts/sync_guac.py --show alice@example.com       # what can this user see? (read-only)
  scripts/sync_guac.py --list-class PA31              # indexes with a connection, e.g. 1,2,3 (read-only)
"""
import argparse, csv, datetime, json, os, re, secrets, subprocess, sys
import http.cookiejar, urllib.error, urllib.parse, urllib.request

PREFIX = os.environ.get("LAB_PREFIX", "lab")
CLASS_RE = re.compile(r"^PA(\d{2})$")
ALLOWED_OCTETS = {31, 32, 33}
CONN_RE = re.compile(r"^(PA\d{2})-S(\d+) (.+)$")
GUACD_PORT = "4822"
ALPHABET = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no look-alikes

RDP_PARAMS = {
    "port": "3389", "username": "kali", "password": "kali",
    "security": "any", "ignore-cert": "true", "color-depth": "16",
    "enable-wallpaper": "false", "enable-theming": "false",
    "enable-font-smoothing": "false", "enable-full-window-drag": "false",
    "enable-desktop-composition": "false", "enable-menu-animations": "false",
    "resize-method": "display-update", "disable-audio": "true",
}


def sh(*cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def export(name, region):
    return sh("aws", "cloudformation", "list-exports", "--region", region,
              "--query", f"Exports[?Name=='{name}'].Value", "--output", "text")


def admin_password(region):
    arn = export(f"{PREFIX}-GuacAdminSecretArn", region)
    if not arn:
        sys.exit("export GuacAdminSecretArn not found (is lab-platform deployed?)")
    secret = sh("aws", "secretsmanager", "get-secret-value", "--region", region,
                "--secret-id", arn, "--query", "SecretString", "--output", "text")
    return json.loads(secret)["password"]


class Api:
    def __init__(self, base, password):
        self.base = base.rstrip("/")
        # Keep the ALB stickiness cookie: a Guacamole token only exists on the web node that
        # issued it, so every call must reach the same node.
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        body = urllib.parse.urlencode({"username": "guacadmin", "password": password}).encode()
        r = self._call("POST", "/api/tokens", raw=body,
                       ctype="application/x-www-form-urlencoded", auth=False)
        self.token, self.ds = r["authToken"], r["dataSource"]

    def _call(self, method, path, body=None, raw=None, ctype="application/json", auth=True, soft=False):
        url = self.base + path
        if auth:
            url += ("&" if "?" in url else "?") + "token=" + urllib.parse.quote(self.token)
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(url, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", ctype)
        try:
            with self.opener.open(req, timeout=30) as resp:
                text = resp.read().decode()
        except urllib.error.HTTPError as e:
            msg = f"API error {e.code} on {method} {path}: {e.read().decode()[:300]}"
            if soft:
                print("WARNING: " + msg, file=sys.stderr)
                return None
            sys.exit(msg)
        return json.loads(text) if text else None

    def d(self, path):
        return f"/api/session/data/{self.ds}{path}"


def q(s):
    return urllib.parse.quote(s, safe="")


def new_password():
    return "".join(secrets.choice(ALPHABET) for _ in range(14))


def read_roster(path):
    rows, seen = [], set()
    with open(path, newline="", encoding="utf-8-sig") as f:
        for n, r in enumerate(csv.DictReader(f), start=2):
            cls = (r.get("class") or "").strip().upper()
            email = (r.get("email") or "").strip().lower()
            name = (r.get("name") or "").strip()
            m = CLASS_RE.match(cls)
            if not m or int(m.group(1)) not in ALLOWED_OCTETS:
                sys.exit(f"{path} line {n}: bad class '{cls}' (use PA31, PA32 or PA33)")
            if not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", email):
                sys.exit(f"{path} line {n}: bad email '{email}'")
            if email in seen:
                sys.exit(f"{path} line {n}: duplicate email {email}")
            seen.add(email)
            rows.append({"class": cls, "email": email, "name": name})
    if not rows:
        sys.exit("roster is empty")
    return rows


def write_private(path, header, rows):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("roster", nargs="?")
    ap.add_argument("--dry-run", action="store_true", help="show what would change, change nothing")
    ap.add_argument("--out-dir", default="roster/out")
    ap.add_argument("--reset", metavar="EMAIL", help="set a new random password for one existing user")
    ap.add_argument("--show", metavar="EMAIL", help="list what one user can see and do (diagnostic, read-only)")
    ap.add_argument("--list-class", metavar="CLASS", help="print the student indexes (comma-separated) of every connection in a class, e.g. PA31 (read-only)")
    ap.add_argument("--url", help="base URL (default https://$LAB_DOMAIN)")
    a = ap.parse_args()

    region = os.environ.get("AWS_REGION") or sys.exit("source params/lab.env first (AWS_REGION)")
    base = a.url or ("https://" + (os.environ.get("LAB_DOMAIN") or sys.exit("LAB_DOMAIN not set")))
    api = Api(base, admin_password(region))
    stamp = datetime.datetime.now().strftime("%Y-%m-%dT%H%M%S")  # time included: never overwrite an earlier run's passwords

    if a.list_class:
        cls = a.list_class.strip().upper()
        if not CLASS_RE.match(cls):
            sys.exit(f"bad class '{cls}' (use PA31, PA32 or PA33)")
        found = []
        for c in api._call("GET", api.d("/connections")).values():
            m = CONN_RE.match(c.get("name", ""))
            if m and m.group(1) == cls:
                found.append(int(m.group(2)))
        print(",".join(str(i) for i in sorted(set(found))))
        return

    if a.show:
        email = a.show.strip().lower()
        conns = api._call("GET", api.d("/connections"))
        names = {c["identifier"]: c["name"] for c in conns.values()}
        for label, path in (("direct", "permissions"), ("EFFECTIVE (direct + via groups)", "effectivePermissions")):
            perms = api._call("GET", api.d(f"/users/{q(email)}/{path}"))
            print(f"--- {label}")
            print("system permissions:", perms.get("systemPermissions") or "none")
            print("connections:")
            for cid, p in perms.get("connectionPermissions", {}).items():
                print(f"  {names.get(cid, cid)}: {p}")
            print("connection groups:", perms.get("connectionGroupPermissions") or "none")
        print("user group memberships:", api._call("GET", api.d(f"/users/{q(email)}/userGroups")) or "none")
        return

    if a.reset:
        email = a.reset.strip().lower()
        user = api._call("GET", api.d(f"/users/{q(email)}"))
        user["password"] = new_password()
        api._call("PUT", api.d(f"/users/{q(email)}"), user)
        os.makedirs(a.out_dir, exist_ok=True)
        write_private(os.path.join(a.out_dir, f"reset-{stamp}.csv"), ["email", "password"], [[email, user["password"]]])
        print(f"password reset for {email}; written to {a.out_dir}/reset-{stamp}.csv")
        return

    if not a.roster:
        ap.error("roster file required")
    roster = read_roster(a.roster)

    users = set(api._call("GET", api.d("/users")))
    # Class groups are only a convenience. If the group calls fail, warn and carry on without them.
    g = api._call("GET", api.d("/userGroups"), soft=True)
    use_groups = g is not None
    groups = set(g or {})
    if not use_groups:
        print("WARNING: user groups unavailable; continuing without class groups", file=sys.stderr)
    conns = api._call("GET", api.d("/connections"))

    by_email, max_idx = {}, {}
    for c in conns.values():
        m = CONN_RE.match(c.get("name", ""))
        if m:
            cls, idx, email = m.group(1), int(m.group(2)), m.group(3).lower()
            by_email[email] = (cls, idx, c["identifier"])
            max_idx[cls] = max(max_idx.get(cls, 0), idx)

    creds, assign, plan = [], [], []
    for r in roster:
        cls, email = r["class"], r["email"]
        octet = int(cls[2:])
        if email in by_email:
            ecls, idx, cid = by_email[email]
            if ecls != cls:
                sys.exit(f"{email} already has a connection in {ecls}, roster says {cls}. "
                         "Moving a student between classes is not automatic; resolve it by hand.")
        else:
            idx, cid = max_idx.get(cls, 0) + 1, None
            max_idx[cls] = idx
            if idx > 154:
                sys.exit(f"{cls}: more than 154 students (subnet limit)")
        ip = f"10.0.{octet}.{100 + idx}"
        assign.append([cls, idx, ip, email, r["name"]])
        r.update(idx=idx, cid=cid, ip=ip, octet=octet, new_user=email not in users)

    for r in roster:
        cls, email, idx = r["class"], r["email"], r["idx"]
        todo = []
        if r["new_user"]:
            todo.append("create user")
        if r["cid"] is None:
            todo.append(f"create connection {cls}-S{idx:02d} -> {r['ip']}")
        if use_groups and r["new_user"] and cls not in groups:
            todo.append(f"create group {cls}")
        plan.append((email, todo))
        print(f"{email:40} {cls} #{idx:<3} {r['ip']:15} {', '.join(todo) or 'no change'}")

    if a.dry_run:
        print("dry run: nothing changed")
        return

    for r in roster:
        cls, email, idx = r["class"], r["email"], r["idx"]
        if r["new_user"]:
            pw = new_password()
            attrs = {"guac-email-address": email}
            if r["name"]:
                attrs["guac-full-name"] = r["name"]
            api._call("POST", api.d("/users"), {"username": email, "password": pw, "attributes": attrs})
            creds.append([email, pw, cls, idx])
            if use_groups:
                if cls not in groups:
                    if api._call("POST", api.d("/userGroups"), {"identifier": cls, "attributes": {}}, soft=True) is None:
                        use_groups = False
                    else:
                        groups.add(cls)
                if use_groups:
                    api._call("PATCH", api.d(f"/userGroups/{q(cls)}/memberUsers"),
                              [{"op": "add", "path": "/", "value": email}], soft=True)
        if r["cid"] is None:
            conn = api._call("POST", api.d("/connections"), {
                "parentIdentifier": "ROOT",
                "name": f"{cls}-S{idx:02d} {email}",
                "protocol": "rdp",
                "parameters": dict(RDP_PARAMS, hostname=r["ip"]),
                "attributes": {"guacd-hostname": f"10.0.{r['octet']}.10", "guacd-port": GUACD_PORT},
            })
            r["cid"] = conn["identifier"]
            r["granted"] = True
        # A new user always needs READ on their connection, including when the connection
        # already existed (for example after the user was deleted and re-created).
        if r["new_user"] or r.get("granted"):
            api._call("PATCH", api.d(f"/users/{q(email)}/permissions"),
                      [{"op": "add", "path": f"/connectionPermissions/{r['cid']}", "value": "READ"}])

    os.makedirs(a.out_dir, exist_ok=True)
    write_private(os.path.join(a.out_dir, f"assignments-{stamp}.csv"),
                  ["class", "index", "ip", "email", "name"], assign)
    if creds:
        write_private(os.path.join(a.out_dir, f"credentials-{stamp}.csv"),
                      ["email", "password", "class", "index"], creds)
    print(f"done: {len(creds)} new user(s). Files in {a.out_dir}/ (git-ignored).")


if __name__ == "__main__":
    main()