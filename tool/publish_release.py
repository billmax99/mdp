# 双平台发布 Release（GitHub + Gitee 同步创建，含 APK 附件）
# 用法：python tool\publish_release.py <tag如v2.4.1> <apk路径> [notes文件md]
# 令牌经 `git credential fill` 临时获取，仅在内存中使用，不落盘、不打印、不进提交。
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

GITHUB_API = "https://api.github.com/repos/billmax99/mdp"
GITEE_API = "https://gitee.com/api/v5/repos/bill_zzx/mdp"


def credential(host):
    env = dict(os.environ, GCM_INTERACTIVE="never", GIT_TERMINAL_PROMPT="0")
    p = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=%s\n\n" % host,
        capture_output=True, text=True, encoding="utf-8", env=env, timeout=30)
    for line in p.stdout.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1]
    raise SystemExit("credential fill 未返回 %s 的令牌" % host)


def http(url, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, headers=headers or {},
                                 method=method)
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.status, r.read()


def github_publish(tag, name, body, apk_path):
    tok = credential("github.com")
    auth = {"Authorization": "Bearer " + tok,
            "Accept": "application/vnd.github+json"}
    status, raw = http(GITHUB_API + "/releases", data=json.dumps({
        "tag_name": tag, "target_commitish": "master", "name": name,
        "body": body, "draft": False, "prerelease": False,
    }).encode("utf-8"), headers={**auth, "Content-Type": "application/json"})
    rid = json.loads(raw)["id"]
    print("GitHub release id=%d" % rid)
    fname = os.path.basename(apk_path)
    up = ("https://uploads.github.com/repos/billmax99/mdp/releases/%d"
          "/assets?name=%s" % (rid, urllib.parse.quote(fname)))
    status, raw = http(up, data=open(apk_path, "rb").read(), headers={
        **auth, "Content-Type": "application/vnd.android.package-archive"})
    asset = json.loads(raw)
    print("GitHub asset: %s (%d bytes)"
          % (asset["browser_download_url"], asset["size"]))
    print("GitHub 页面: https://github.com/billmax99/mdp/releases/tag/%s" % tag)


def gitee_publish(tag, name, body, apk_path):
    tok = credential("gitee.com")
    status, raw = http(GITEE_API + "/releases", data=urllib.parse.urlencode({
        "access_token": tok, "tag_name": tag, "name": name,
        "body": body, "target_commitish": "master",
    }).encode("utf-8"))
    rid = json.loads(raw)["id"]
    print("Gitee release id=%d" % rid)
    boundary = "----mdprelease"
    fname = os.path.basename(apk_path)
    part = []
    part.append(("--%s\r\nContent-Disposition: form-data; name=\"access_token\""
                 "\r\n\r\n%s\r\n" % (boundary, tok)).encode("utf-8"))
    part.append(("--%s\r\nContent-Disposition: form-data; name=\"file\"; "
                 "filename=\"%s\"\r\nContent-Type: "
                 "application/vnd.android.package-archive\r\n\r\n"
                 % (boundary, fname)).encode("utf-8"))
    payload = b"".join(part) + open(apk_path, "rb").read() + \
        ("\r\n--%s--\r\n" % boundary).encode("utf-8")
    status, raw = http(GITEE_API + "/releases/%d/attach_files" % rid,
                       data=payload, headers={
                           "Content-Type": "multipart/form-data; boundary=%s"
                           % boundary})
    assets = json.loads(raw)
    for a in assets:
        print("Gitee asset: %s (%s bytes)" % (a.get("browser_download_url"),
                                              a.get("size")))
    print("Gitee 页面: https://gitee.com/bill_zzx/mdp/releases/tag/%s" % tag)


if __name__ == "__main__":
    tag = sys.argv[1]
    apk = sys.argv[2]
    notes = sys.argv[3] if len(sys.argv) > 3 else os.path.join(
        os.path.dirname(__file__), "..", "publish",
        "%s_release_notes.md" % tag.lstrip("v"))
    name = "MD+ %s" % tag.lstrip("v")
    body = open(os.path.abspath(notes), encoding="utf-8").read()
    print("== GitHub ==")
    github_publish(tag, name, body, apk)
    print("== Gitee ==")
    gitee_publish(tag, name, body, apk)
    print("done")
