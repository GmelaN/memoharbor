"""HTTP smoke test against a deployed WAR; stdlib only, dedicated test server required."""
import argparse
import http.cookiejar
import re
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


parser = argparse.ArgumentParser()
parser.add_argument("--base-url", default="http://127.0.0.1:8080/memoharbor")
parser.add_argument("--username", required=True)
parser.add_argument("--existing", action="store_true", help="Verify persistence after redeployment, then delete the memo")
parser.add_argument("--backend", choices=["SQLite", "MariaDB"])
args = parser.parse_args()
client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), NoRedirect())


def request(path, status=200, fields=None):
    data = None if fields is None else urllib.parse.urlencode(fields).encode("utf-8")
    req = urllib.request.Request(args.base_url.rstrip("/") + path, data=data)
    try:
        response = client.open(req, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        assert response.code == status, (path, response.code, status)
        return response.read().decode("utf-8")


def token(html):
    return re.search(r"name='csrf' value='([^']+)'", html).group(1)


health = request("/health")
assert '"database":"UP"' in health
if args.backend:
    assert '"backend":"' + args.backend + '"' in health
assert '"status":"UP"' in request("/live")
request("/", 303)
request("/create", 401, {"title": "unauthorized", "detail": "test"})
csrf = token(request("/login"))
request("/login" if args.existing else "/register", 303,
        {"username": args.username, "password": "wildfly-test-password-123", "csrf": csrf})
html = request("/")
csrf = token(html)
if not args.existing:
    request("/create", 403, {"title": "csrf-invalid", "detail": "test", "csrf": "wrong"})
    request("/create", 303, {"title": "WildFly <memo> 한글", "detail": "persistent data", "csrf": csrf})
    html = request("/")
assert "WildFly &lt;memo&gt; 한글" in html
request("/WEB-INF/db/memoharbor.sqlite", 404)
request("/.env", 403)
if args.existing:
    entry_id = re.search(r"name='id' value='(\d+)'", html).group(1)
    request("/delete", 303, {"id": entry_id, "csrf": csrf})
    assert "WildFly &lt;memo&gt; 한글" not in request("/")
request("/logout", 303, {"csrf": csrf})
request("/", 303)
print("WildFly HTTP smoke passed" + (" (redeploy persistence and delete)" if args.existing else " (register and create)"))
