#!/usr/bin/env python3
"""YSQ 中控：Python 标准库单文件网页服务，供本机 Nginx 反向代理。

首次初始化：python3 ysq-center.py --init-admin admin
运行：python3 ysq-center.py
默认 HTTP 127.0.0.1:8099，对外 https://panel.eulmo.com。
数据库、凭据和会话位于 --data-dir 指定的目录；不要公开该目录。
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import datetime as dt
import getpass
import hashlib
import hmac
import http.cookies
import http.server
import ipaddress
import json
import logging
import os
import re
import secrets
import signal
import socket
import socketserver
import sqlite3
import tempfile
import threading
import time
import urllib.parse
import uuid
from pathlib import Path

VERSION = "2026.10.23.6"
PROTOCOL = 1
MAX_BODY = 2 * 1024 * 1024
MAX_BYTES = (1 << 63) - 1
DETAIL_RETENTION_DAYS = 100
MAX_CHART_DAYS = 90
PASSWORD_ITERATIONS = 600_000
SESSION_SECONDS = 8 * 3600
NODE_RE = re.compile(r"n_[0-9a-f]{32}\Z")
USER_RE = re.compile(r"u_[0-9a-f]{32}\Z")
NAME_RE = re.compile(r"[A-Za-z0-9]{1,32}\Z")
TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{32,256}\Z")
EPOCH_RE = re.compile(r"[A-Za-z0-9_-]{8,128}\Z")
PASS_RE = re.compile(r"[A-Za-z0-9_-]{6,128}\Z")
COOKIE_NAME = "ysq_session"
LOG = logging.getLogger("ysq-center")
DEFAULT_NODE_NAME_TEMPLATE = "{{server}} · {{inbound}}"
DEFAULT_CLASH_TEMPLATE = '''mixed-port: 7890
allow-lan: false
mode: rule
ipv6: true
log-level: info
proxies:
{{proxies}}
proxy-groups:
  - name: {{group_name}}
    type: select
    proxies: {{proxy_names}}
rules:
{{rules}}
'''


class APIError(Exception):
    def __init__(self, status, message):
        self.status = status
        self.message = message
        super().__init__(message)


def now():
    return int(time.time())


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def integer(value, label, minimum=0, maximum=MAX_BYTES):
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise APIError(400, f"{label} 超出允许范围")
    return value


def text_value(value, label, minimum=1, maximum=128):
    if not isinstance(value, str):
        raise APIError(400, f"{label} 必须是文本")
    value = value.strip()
    if not minimum <= len(value) <= maximum or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise APIError(400, f"{label} 长度或字符不合法")
    return value


def error_text(value, label):
    if not isinstance(value, str) or len(value) > 3000:
        raise APIError(400, f"{label} 必须是长度不超过 3000 的文本")
    return " ".join(value.split())[:1500]


def boolean(value, label):
    if not isinstance(value, bool):
        raise APIError(400, f"{label} 必须是布尔值")
    return value


def valid_name(value):
    if not isinstance(value, str) or not NAME_RE.fullmatch(value):
        raise APIError(400, "用户名仅允许 1–32 位英文字母或数字")
    return value


def valid_uuid(value):
    try:
        if not isinstance(value, str) or len(value) != 36:
            raise ValueError()
        result = str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise APIError(400, "UUID 格式不正确")
    return result


def valid_tuic(value):
    if not isinstance(value, str) or not PASS_RE.fullmatch(value):
        raise APIError(400, "TUIC 密码须为 6–128 位字母、数字、下划线或连字符")
    return value


def password_hash(password):
    salt = secrets.token_hex(16)
    encoded = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), bytes.fromhex(salt), PASSWORD_ITERATIONS)
    return f"pbkdf2_sha256${PASSWORD_ITERATIONS}${salt}${encoded.hex()}"


def password_matches(password, stored):
    try:
        algo, rounds, salt, expected = stored.split("$")
        if algo != "pbkdf2_sha256" or not 1 <= int(rounds) <= 2_000_000:
            return False
        encoded = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), bytes.fromhex(salt), int(rounds))
        return hmac.compare_digest(encoded.hex(), expected)
    except (ValueError, TypeError, AttributeError):
        return False


def validate_admin_password(password):
    if not isinstance(password, str) or not 12 <= len(password) <= 256:
        raise APIError(400, "管理员密码须为 12–256 个字符")
    return password


def node_id_valid(value):
    if not isinstance(value, str) or not NODE_RE.fullmatch(value):
        raise APIError(400, "服务器 ID 不合法")
    return value


def user_id_valid(value):
    if not isinstance(value, str) or not USER_RE.fullmatch(value):
        raise APIError(400, "用户 ID 不合法")
    return value


SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS admins(username TEXT PRIMARY KEY,password_hash TEXT NOT NULL,created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sessions(token_hash TEXT PRIMARY KEY,username TEXT NOT NULL REFERENCES admins(username),csrf TEXT NOT NULL,created_at INTEGER NOT NULL,expires_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS sessions_expiry ON sessions(expires_at);
CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS nodes(
 id TEXT PRIMARY KEY,name TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'created',
 token_hash TEXT,join_hash TEXT,join_expires INTEGER NOT NULL DEFAULT 0,
 registration_id TEXT UNIQUE,registration_hash TEXT,inventory TEXT NOT NULL DEFAULT '{}',
 hostname TEXT NOT NULL DEFAULT '',revision INTEGER NOT NULL DEFAULT 0,applied_revision INTEGER NOT NULL DEFAULT 0,
 last_seen INTEGER NOT NULL DEFAULT 0,agent_version TEXT NOT NULL DEFAULT '',last_error TEXT NOT NULL DEFAULT '',
 sample_error TEXT NOT NULL DEFAULT '',service_running INTEGER NOT NULL DEFAULT 0,last_sample_at INTEGER NOT NULL DEFAULT 0,
 pending_batches INTEGER NOT NULL DEFAULT 0,created_at INTEGER NOT NULL,approved_at INTEGER NOT NULL DEFAULT 0);
CREATE UNIQUE INDEX IF NOT EXISTS nodes_tokens ON nodes(token_hash) WHERE token_hash IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS nodes_joins ON nodes(join_hash) WHERE join_hash IS NOT NULL;
CREATE TABLE IF NOT EXISTS users(
 id TEXT PRIMARY KEY,name TEXT NOT NULL UNIQUE,uuid TEXT NOT NULL,tuic_pass TEXT NOT NULL,
 enabled INTEGER NOT NULL DEFAULT 1,deleted INTEGER NOT NULL DEFAULT 0,
 origin_node TEXT REFERENCES nodes(id),created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS user_policies(
 user_id TEXT PRIMARY KEY REFERENCES users(id),quota_bytes INTEGER NOT NULL DEFAULT 0,
 quota_period TEXT NOT NULL DEFAULT 'monthly',quota_blocked INTEGER NOT NULL DEFAULT 0,
 subscription_token TEXT NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS assignments(
 user_id TEXT NOT NULL REFERENCES users(id),node_id TEXT NOT NULL REFERENCES nodes(id),
 active INTEGER NOT NULL DEFAULT 1,first_seen INTEGER NOT NULL,last_active INTEGER NOT NULL,
 PRIMARY KEY(user_id,node_id));
CREATE INDEX IF NOT EXISTS assignments_nodes ON assignments(node_id,active);
CREATE TABLE IF NOT EXISTS batches(
 node_id TEXT NOT NULL REFERENCES nodes(id),epoch TEXT NOT NULL,seq INTEGER NOT NULL,
 payload_hash TEXT NOT NULL,received_at INTEGER NOT NULL,row_count INTEGER NOT NULL,up INTEGER NOT NULL,down INTEGER NOT NULL,
 PRIMARY KEY(node_id,epoch,seq));
CREATE TABLE IF NOT EXISTS usage(
 node_id TEXT NOT NULL REFERENCES nodes(id),user_id TEXT NOT NULL REFERENCES users(id),ts INTEGER NOT NULL,
 up INTEGER NOT NULL,down INTEGER NOT NULL,PRIMARY KEY(node_id,user_id,ts));
CREATE INDEX IF NOT EXISTS usage_time ON usage(ts);
CREATE INDEX IF NOT EXISTS usage_user_time ON usage(user_id,ts);
CREATE TABLE IF NOT EXISTS totals(
 node_id TEXT NOT NULL REFERENCES nodes(id),user_id TEXT NOT NULL REFERENCES users(id),up INTEGER NOT NULL DEFAULT 0,down INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(node_id,user_id));
CREATE TABLE IF NOT EXISTS activity_events(
 node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,event_id TEXT NOT NULL,
 user_id TEXT REFERENCES users(id) ON DELETE CASCADE,ts INTEGER NOT NULL,kind TEXT NOT NULL,
 source_ip TEXT NOT NULL,target TEXT NOT NULL,port INTEGER NOT NULL,network TEXT NOT NULL,
 inbound TEXT NOT NULL,message TEXT NOT NULL,received_at INTEGER NOT NULL,PRIMARY KEY(node_id,event_id));
CREATE INDEX IF NOT EXISTS activity_events_time ON activity_events(ts);
CREATE INDEX IF NOT EXISTS activity_events_user_time ON activity_events(user_id,ts);
CREATE INDEX IF NOT EXISTS activity_events_node_time ON activity_events(node_id,ts);
CREATE TABLE IF NOT EXISTS activity_receipts(
 node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,event_id TEXT NOT NULL,
 user_id TEXT REFERENCES users(id) ON DELETE CASCADE,ts INTEGER NOT NULL,payload_hash TEXT NOT NULL,
 PRIMARY KEY(node_id,event_id));
CREATE INDEX IF NOT EXISTS activity_receipts_time ON activity_receipts(ts);
CREATE TABLE IF NOT EXISTS activity_hourly(
 node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,user_id TEXT NOT NULL,hour INTEGER NOT NULL,
 connections INTEGER NOT NULL,errors INTEGER NOT NULL,gaps INTEGER NOT NULL,last_at INTEGER NOT NULL,
 PRIMARY KEY(node_id,user_id,hour));
CREATE INDEX IF NOT EXISTS activity_hourly_time ON activity_hourly(hour);
CREATE INDEX IF NOT EXISTS activity_hourly_user_time ON activity_hourly(user_id,hour);
CREATE TABLE IF NOT EXISTS activity_status(
 node_id TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,received_at INTEGER NOT NULL,
 collected_at INTEGER NOT NULL,pending INTEGER NOT NULL,dropped INTEGER NOT NULL,gaps INTEGER NOT NULL,
 error TEXT NOT NULL,source TEXT NOT NULL);

CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY AUTOINCREMENT,ts INTEGER NOT NULL,actor TEXT NOT NULL,action TEXT NOT NULL,detail TEXT NOT NULL);
"""


class Store:
    def __init__(self, directory):
        if sqlite3.sqlite_version_info < (3, 24, 0):
            raise RuntimeError("需要 SQLite 3.24 或更新版本，请使用带有新版 sqlite3 的 Python")
        self.directory = Path(directory).resolve()
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.directory, 0o700)
        self.path = self.directory / "center.db"
        self.maintenance_lock = threading.Lock()
        self.changes = threading.Condition()
        self.last_maintenance = 0.0
        with self.connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript(SCHEMA)
            version = db.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
            if version and version[0] != "1":
                raise RuntimeError("数据库版本不兼容，请先备份并使用匹配版本程序")
            db.execute("INSERT OR IGNORE INTO meta VALUES('schema_version','1')")
            db.execute("INSERT OR IGNORE INTO settings VALUES('timezone_offset','480')")
            db.execute("INSERT OR IGNORE INTO settings VALUES('clash_template',?)", (DEFAULT_CLASH_TEMPLATE,))
            db.execute("UPDATE settings SET value=? WHERE key='clash_template' AND value=?", (DEFAULT_CLASH_TEMPLATE, DEFAULT_CLASH_TEMPLATE.replace("{{group_name}}", "{{subscription_name}}")))
            db.execute("INSERT OR IGNORE INTO settings VALUES('node_name_template',?)", (DEFAULT_NODE_NAME_TEMPLATE,))
            db.execute("INSERT OR IGNORE INTO settings VALUES('activity_detail_days','7')")
            db.execute("INSERT OR IGNORE INTO settings VALUES('activity_summary_days','90')")
            columns = {r[1] for r in db.execute("PRAGMA table_info(user_policies)")}
            for column, definition in (("subscription_name", "TEXT NOT NULL DEFAULT 'plzquick'"),
                                       ("subscription_enabled", "INTEGER NOT NULL DEFAULT 1"),
                                       ("subscription_expires_at", "INTEGER NOT NULL DEFAULT 0")):
                if column not in columns:
                    db.execute(f"ALTER TABLE user_policies ADD COLUMN {column} {definition}")
        os.chmod(self.path, 0o600)
        # One-time compatible upgrade: finish previously registered pending nodes.
        # The original one-time join code was validated when they registered.
        with self.transaction() as db:
            # Upgrade legacy soft deletions to the same permanent deletion used by the UI.
            for old in db.execute("SELECT id FROM users WHERE deleted=1").fetchall():
                self._purge_user(db, old["id"])
            for old in db.execute("SELECT id FROM nodes WHERE status IN ('revoked','detached')").fetchall():
                self._purge_node(db, old["id"])
            self._refresh_quotas(db)
            for old in db.execute("SELECT id FROM nodes WHERE status='pending' ORDER BY created_at,id").fetchall():
                self._activate_node(db, self._node(db, old["id"]), "system-upgrade")

    @contextlib.contextmanager
    def connect(self):
        db = sqlite3.connect(str(self.path), timeout=10, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("PRAGMA busy_timeout=10000")
        db.execute("PRAGMA synchronous=FULL")
        try:
            yield db
        finally:
            db.close()

    @contextlib.contextmanager
    def transaction(self, notify=True):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                yield db
                db.execute("COMMIT")
                if notify:
                    with self.changes:
                        self.changes.notify_all()
            except BaseException:
                if db.in_transaction:
                    db.execute("ROLLBACK")
                raise

    @staticmethod
    def audit(db, actor, action, detail):
        db.execute("INSERT INTO audit(ts,actor,action,detail) VALUES(?,?,?,?)", (now(), str(actor)[:80], action, str(detail)[:1000]))

    def initialize_admin(self, username, password, reset=False):
        username = text_value(username, "管理员名称", 1, 64)
        validate_admin_password(password)
        encoded = password_hash(password)
        with self.transaction() as db:
            exists = db.execute("SELECT 1 FROM admins WHERE username=?", (username,)).fetchone()
            if exists and not reset:
                raise APIError(409, "管理员已存在；更换密码请使用 --reset-admin")
            if not exists and reset:
                raise APIError(404, "管理员不存在")
            if exists:
                db.execute("UPDATE admins SET password_hash=? WHERE username=?", (encoded, username))
                db.execute("DELETE FROM sessions WHERE username=?", (username,))
            else:
                db.execute("INSERT INTO admins VALUES(?,?,?)", (username, encoded, now()))
            self.audit(db, "local", "admin.reset" if reset else "admin.create", username)

    def has_admin(self):
        with self.connect() as db:
            return bool(db.execute("SELECT 1 FROM admins LIMIT 1").fetchone())

    def login(self, username, password):
        with self.connect() as db:
            row = db.execute("SELECT password_hash FROM admins WHERE username=?", (username,)).fetchone()
        # Spend the same KDF work for unknown names without revealing account existence.
        if row:
            good = password_matches(password, row[0])
        else:
            password_matches(password, f"pbkdf2_sha256${PASSWORD_ITERATIONS}$" + "0" * 32 + "$" + "0" * 64)
            good = False
        if not good:
            raise APIError(401, "账号或密码不正确")
        token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        with self.transaction() as db:
            current = db.execute("SELECT password_hash FROM admins WHERE username=?", (username,)).fetchone()
            if not current or not hmac.compare_digest(current[0], row[0]):
                raise APIError(401, "密码刚刚发生变化，请重新登录")
            db.execute("DELETE FROM sessions WHERE expires_at<=?", (now(),))
            # Retain at most ten current sessions for each administrator.
            db.execute("DELETE FROM sessions WHERE username=? AND token_hash NOT IN (SELECT token_hash FROM sessions WHERE username=? ORDER BY created_at DESC LIMIT 9)", (username, username))
            db.execute("INSERT INTO sessions VALUES(?,?,?,?,?)", (digest(token), username, csrf, now(), now() + SESSION_SECONDS))
            self.audit(db, username, "login", "网页登录")
        return token, {"username": username, "csrf": csrf, "version": VERSION}

    def session(self, token):
        if not isinstance(token, str) or not TOKEN_RE.fullmatch(token):
            raise APIError(401, "请先登录")
        with self.connect() as db:
            row = db.execute("SELECT username,csrf,expires_at FROM sessions WHERE token_hash=?", (digest(token),)).fetchone()
        if not row or row["expires_at"] <= now():
            raise APIError(401, "登录已过期，请重新登录")
        return dict(row)

    def logout(self, token):
        with self.transaction() as db:
            db.execute("DELETE FROM sessions WHERE token_hash=?", (digest(token),))

    def change_password(self, username, old_password, new_password):
        validate_admin_password(new_password)
        with self.connect() as db:
            row = db.execute("SELECT password_hash FROM admins WHERE username=?", (username,)).fetchone()
        if not row or not password_matches(old_password, row[0]):
            raise APIError(403, "当前密码不正确")
        encoded = password_hash(new_password)
        with self.transaction() as db:
            # Compare-and-swap guards simultaneous password change requests.
            result = db.execute("UPDATE admins SET password_hash=? WHERE username=? AND password_hash=?", (encoded, username, row[0]))
            if not result.rowcount:
                raise APIError(409, "密码已被另一个操作修改，请重新登录")
            db.execute("DELETE FROM sessions WHERE username=?", (username,))
            self.audit(db, username, "admin.password", "修改密码并注销全部会话")

    def create_node(self, name, actor):
        name = text_value(name, "服务器名称", 1, 80)
        ident = "n_" + uuid.uuid4().hex
        code = secrets.token_urlsafe(32)
        with self.transaction() as db:
            db.execute("INSERT INTO nodes(id,name,join_hash,join_expires,created_at) VALUES(?,?,?,?,?)", (ident, name, digest(code), now() + 600, now()))
            self.audit(db, actor, "node.create", name)
        return {"node_id": ident, "join_code": code, "expires_at": now() + 600, "name": name}

    def rename_node(self, ident, name, actor):
        node_id_valid(ident)
        name = text_value(name, "服务器名称", 1, 80)
        with self.transaction() as db:
            node = self._node(db, ident)
            changed = node["name"] != name
            if changed:
                db.execute("UPDATE nodes SET name=? WHERE id=?", (name, ident))
                self.audit(db, actor, "node.rename", node["name"] + " → " + name)
        # Display-only rename; no need to update the node's proxy configuration.
        return {"node_id": ident, "name": name, "changed": changed}

    def reissue_join(self, ident, actor):
        node_id_valid(ident)
        code = secrets.token_urlsafe(32)
        with self.transaction() as db:
            node = self._node(db, ident)
            if node["status"] != "created":
                raise APIError(409, "仅未注册的服务器可以重新生成接入码；重新绑定请新建服务器记录")
            db.execute("UPDATE nodes SET join_hash=?,join_expires=? WHERE id=?", (digest(code), now() + 600, ident))
            self.audit(db, actor, "node.join-code", node["name"])
        return {"node_id": ident, "join_code": code, "expires_at": now() + 600, "name": node["name"]}

    @staticmethod
    def _node(db, ident):
        node = db.execute("SELECT * FROM nodes WHERE id=?", (ident,)).fetchone()
        if not node:
            raise APIError(404, "服务器不存在")
        return node

    @staticmethod
    def _inventory(data):
        users = data.get("users", [])
        inbounds = data.get("inbounds", [])
        if not isinstance(users, list) or len(users) > 2000 or not isinstance(inbounds, list) or len(inbounds) > 2000:
            raise APIError(400, "接入清单格式不正确或过大")
        clean_users, seen_names, seen_uuid = [], set(), set()
        for value in users:
            if not isinstance(value, dict):
                raise APIError(400, "用户清单格式不正确")
            item = {"name": valid_name(value.get("name")), "uuid": valid_uuid(value.get("uuid")), "tuic_pass": valid_tuic(value.get("tuic_pass"))}
            if item["name"] in seen_names or item["uuid"] in seen_uuid:
                raise APIError(400, "本机存在重复用户名或 UUID，无法接管")
            seen_names.add(item["name"])
            seen_uuid.add(item["uuid"])
            clean_users.append(item)
        clean_inbounds = []
        for value in inbounds:
            if not isinstance(value, dict):
                raise APIError(400, "入口清单格式不正确")
            item = {"name": text_value(value.get("name", "入口"), "入口名称", 1, 160),
                                   "tag": text_value(value.get("tag", "unknown"), "入口标签", 1, 160),
                                   "type": text_value(value.get("type", "unknown"), "入口类型", 1, 64),
                                   "port": integer(value.get("port"), "入口端口", 1, 65535)}
            for key in ("server", "sni", "public_key", "short_id"):
                if key in value:
                    field = text_value(value[key], "订阅 " + key, 0, 253)
                    if any(c.isspace() or c in "/?#@\\" for c in field):
                        raise APIError(400, "订阅 " + key + " 格式不正确")
                    if key == "public_key" and field and not re.fullmatch(r"[A-Za-z0-9_-]{43}", field):
                        raise APIError(400, "Reality 公钥格式不正确")
                    if key == "short_id" and (len(field) % 2 or not re.fullmatch(r"[0-9a-fA-F]{0,16}", field)):
                        raise APIError(400, "Reality Short ID 格式不正确")
                    item[key] = field
            if "skip_cert_verify" in value:
                item["skip_cert_verify"] = boolean(value["skip_cert_verify"], "跳过证书验证")
            clean_inbounds.append(item)
        return {"users": clean_users, "inbounds": clean_inbounds}

    def register(self, data):
        self._protocol(data)
        code = text_value(data.get("join_code"), "接入码", 16, 256)
        registration_id = text_value(data.get("registration_id"), "注册标识", 8, 128)
        token = data.get("node_token")
        if not isinstance(token, str) or not TOKEN_RE.fullmatch(token):
            raise APIError(400, "节点令牌格式不正确")
        inventory = self._inventory(data)
        hostname = text_value(data.get("hostname", "unknown"), "主机名", 1, 255)
        agent_version = text_value(data.get("agent_version", "unknown"), "Agent 版本", 1, 64)
        registration_hash = digest(canonical({"inventory": inventory, "hostname": hostname, "agent_version": agent_version}))
        token_hash = digest(token)
        with self.transaction() as db:
            old = db.execute("SELECT * FROM nodes WHERE registration_id=?", (registration_id,)).fetchone()
            if old:
                if old["status"] not in ("pending", "active") or not hmac.compare_digest(old["token_hash"] or "", token_hash):
                    raise APIError(403, "注册恢复失败，请在中控检查服务器状态")
                if not hmac.compare_digest(old["registration_hash"] or "", registration_hash):
                    raise APIError(409, "同一注册标识的清单发生变化，请恢复原始注册请求")
                if old["status"] == "pending":
                    return self._activate_node(db, old, "automatic-retry")
                return {"protocol": PROTOCOL, "node_id": old["id"], "status": old["status"],
                        "revision": old["revision"], "imported": json.loads(old["inventory"]).get("imported", [])}
            node = db.execute("SELECT * FROM nodes WHERE join_hash=?", (digest(code),)).fetchone()
            if not node or node["status"] != "created" or node["join_expires"] <= now():
                raise APIError(403, "接入码不存在、已过期或已使用")
            db.execute("UPDATE nodes SET status='pending',token_hash=?,join_hash=NULL,join_expires=0,registration_id=?,registration_hash=?,inventory=?,hostname=?,agent_version=?,last_seen=? WHERE id=?",
                       (token_hash, registration_id, registration_hash, canonical(inventory), hostname, agent_version, now(), node["id"]))
            self.audit(db, node["id"], "node.register", node["name"] + "：接入码验证通过")
            return self._activate_node(db, self._node(db, node["id"]), "automatic-registration")

    def _activate_node(self, db, node, actor):
        """Atomically adopt existing users as part of successful one-time registration."""
        if node["status"] == "active":
            return {"protocol": PROTOCOL, "node_id": node["id"], "status": "active", "revision": node["revision"]}
        if node["status"] != "pending":
            raise APIError(409, "服务器尚未注册或已停止接管")
        inventory = json.loads(node["inventory"])
        imported = []
        for original in inventory.get("users", []):
            named = db.execute("SELECT * FROM users WHERE name=? AND deleted=0", (original["name"],)).fetchone()
            matching = db.execute("SELECT * FROM users WHERE uuid=? AND deleted=0", (original["uuid"],)).fetchall()
            if named and any(user["id"] != named["id"] for user in matching):
                raise APIError(409, f"用户 {original['name']} 的用户名和 UUID 分别属于不同中控用户，请先统一认证资料")
            if not named and len(matching) > 1:
                raise APIError(409, f"用户 {original['name']} 的 UUID 对应多个中控用户，请先统一认证资料")
            existing = named or (matching[0] if matching else None)
            uid = existing["id"] if existing else "u_" + uuid.uuid4().hex
            name = existing["name"] if existing else original["name"]
            if not existing:
                db.execute("INSERT INTO users VALUES(?,?,?,?,1,0,?,?,?)", (uid, name, original["uuid"], original["tuic_pass"], node["id"], now(), now()))
            collision = db.execute("SELECT u.name FROM users u JOIN assignments a ON a.user_id=u.id WHERE a.node_id=? AND a.active=1 AND u.uuid=? AND u.id!=?",
                                   (node["id"], existing["uuid"] if existing else original["uuid"], uid)).fetchone()
            if collision:
                raise APIError(409, f"服务器上的 {collision['name']} 与 {name} 使用相同 UUID，请先统一认证资料")
            db.execute("INSERT INTO assignments VALUES(?,?,1,?,?) ON CONFLICT(user_id,node_id) DO UPDATE SET active=1,last_active=excluded.last_active", (uid, node["id"], now(), now()))
            imported.append({"id": uid, "name": name, "old_name": original["name"]})
        # Do not retain imported proxy secrets in the temporary registration inventory.
        db.execute("UPDATE nodes SET status='active',revision=1,approved_at=?,inventory=? WHERE id=?",
                   (now(), canonical({"inbounds": inventory.get("inbounds", []), "imported": imported}), node["id"]))
        self._refresh_quotas(db)
        self.audit(db, actor, "node.auto-adopt", f"{node['name']}：绑定 {len(imported)} 位用户，同名或相同 UUID 复用中控账户")
        return {"protocol": PROTOCOL, "node_id": node["id"], "status": "active", "revision": 1, "imported": imported}

    def approve_node(self, ident, actor):
        """Legacy API for old browser versions; no manual approval is needed."""
        node_id_valid(ident)
        with self.transaction() as db:
            node = self._node(db, ident)
            return self._activate_node(db, node, actor)

    def revoke_node(self, ident, actor):
        # Older browser versions used revoke for removal; keep its semantics consistent.
        return self.delete_node(ident, actor)

    @staticmethod
    def _purge_node(db, ident):
        for table in ("assignments", "usage", "totals", "batches"):
            db.execute(f"DELETE FROM {table} WHERE node_id=?", (ident,))
        db.execute("UPDATE users SET origin_node=NULL WHERE origin_node=?", (ident,))
        db.execute("DELETE FROM nodes WHERE id=?", (ident,))

    def delete_node(self, ident, actor):
        node_id_valid(ident)
        with self.transaction() as db:
            node = self._node(db, ident)
            self._purge_node(db, ident)
            self._refresh_quotas(db)
            self.audit(db, actor, "node.delete", node["name"] + "：删除服务器及关联流量；Agent 恢复连接后自动解绑")
        return {"ok": True}

    @staticmethod
    def _protocol(data):
        if not isinstance(data, dict) or type(data.get("protocol")) is not int or data["protocol"] != PROTOCOL:
            raise APIError(400, "协议版本不兼容，请更新中控与 Agent")

    @staticmethod
    def _authenticated_node(db, ident, token):
        node_id_valid(ident)
        if not isinstance(token, str) or not TOKEN_RE.fullmatch(token):
            raise APIError(401, "节点认证失败")
        node = db.execute("SELECT * FROM nodes WHERE id=?", (ident,)).fetchone()
        if not node or node["status"] not in ("pending", "active"):
            raise APIError(410, "服务器已删除或解绑，请恢复本机独立管理")
        if not hmac.compare_digest(node["token_hash"] or "", digest(token)):
            raise APIError(401, "节点凭据已失效")
        return node

    def wait_for_changes(self, data, token):
        self._protocol(data)
        ident = node_id_valid(data.get("node_id"))
        applied = integer(data.get("applied_revision", 0), "已应用版本", 0)
        timeout = integer(data.get("timeout", 20), "等待时间", 1, 25)
        deadline = time.monotonic() + timeout
        # Read and enter wait under one condition to avoid missing a committed change.
        with self.changes:
            while True:
                with self.connect() as db:
                    node = self._authenticated_node(db, ident, token)
                    revision = node["revision"]
                if revision != applied:
                    return {"protocol": PROTOCOL, "changed": True, "revision": revision}
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return {"protocol": PROTOCOL, "changed": False, "revision": revision}
                self.changes.wait(remaining)

    @staticmethod
    def _snapshot(db, ident, revision):
        rows = db.execute("SELECT u.id,u.name,u.uuid,u.tuic_pass,u.enabled,COALESCE(p.quota_blocked,0) blocked FROM users u JOIN assignments a ON a.user_id=u.id LEFT JOIN user_policies p ON p.user_id=u.id WHERE a.node_id=? AND a.active=1 AND u.deleted=0 ORDER BY u.id", (ident,)).fetchall()
        users = [{"id": r["id"], "name": r["name"], "uuid": r["uuid"], "tuic_pass": r["tuic_pass"], "enabled": bool(r["enabled"] and not r["blocked"])} for r in rows]
        return {"node_id": ident, "revision": revision, "users": users}

    def sync(self, data, token):
        self._protocol(data)
        ident = node_id_valid(data.get("node_id"))
        applied = integer(data.get("applied_revision", 0), "已应用版本", 0)
        batches = data.get("batches", [])
        if not isinstance(batches, list) or len(batches) > 16:
            raise APIError(400, "流量批次数量不正确")
        version = text_value(data.get("agent_version", "unknown"), "Agent 版本", 1, 64)
        apply_error = error_text(data.get("apply_error", ""), "应用错误")
        collector_error = error_text(data.get("collector_error", ""), "采集错误")
        last_sample = integer(data.get("last_sample_at", 0), "采集时间", 0, now() + 300)
        pending = integer(data.get("pending_batches", 0), "待上传批次", 0, 10_000_000)
        running = boolean(data.get("service_running", False), "运行状态")
        ack = []
        with self.transaction() as db:
            node = self._authenticated_node(db, ident, token)
            if "inbounds" in data:
                inventory = self._inventory({"inbounds": data["inbounds"]})
                stored_inventory = json.loads(node["inventory"])
                stored_inventory["inbounds"] = inventory["inbounds"]
                db.execute("UPDATE nodes SET inventory=? WHERE id=?", (canonical(stored_inventory), ident))
            if applied > node["revision"]:
                raise APIError(409, "节点配置版本领先于中控，请检查数据库恢复或重新绑定")
            if batches and node["status"] != "active":
                raise APIError(409, "服务器尚未完成接入，暂不能上传流量")
            for batch in batches:
                if not isinstance(batch, dict):
                    raise APIError(400, "流量批次格式错误")
                epoch = batch.get("epoch")
                if not isinstance(epoch, str) or not EPOCH_RE.fullmatch(epoch):
                    raise APIError(400, "流量账本身份不合法")
                seq = integer(batch.get("seq"), "流量批次序号", 1)
                rows = batch.get("rows")
                if not isinstance(rows, list) or len(rows) > 12000:
                    raise APIError(400, "流量批次记录不合法或过大")
                payload_hash = digest(canonical({"epoch": epoch, "seq": seq, "rows": rows}))
                existing = db.execute("SELECT payload_hash FROM batches WHERE node_id=? AND epoch=? AND seq=?", (ident, epoch, seq)).fetchone()
                if existing:
                    if not hmac.compare_digest(existing[0], payload_hash):
                        raise APIError(409, "重复批次的内容不一致，已拒绝覆盖")
                    ack.append({"epoch": epoch, "seq": seq})
                    continue
                clean, sums = [], [0, 0]
                for item in rows:
                    if not isinstance(item, dict):
                        raise APIError(400, "流量行格式错误")
                    uid = user_id_valid(item.get("user_id"))
                    timestamp = integer(item.get("ts"), "流量采集时间", 1_577_836_800, now() + 300)
                    up, down = integer(item.get("up"), "上传字节"), integer(item.get("down"), "下载字节")
                    # A queued batch can arrive after a permanent user deletion.
                    # ACK it without recreating data or blocking the remaining users.
                    if not db.execute("SELECT 1 FROM users WHERE id=?", (uid,)).fetchone():
                        continue
                    if not db.execute("SELECT 1 FROM assignments WHERE node_id=? AND user_id=?", (ident, uid)).fetchone():
                        raise APIError(403, "上报包含从未分配给本服务器的用户")
                    sums[0] += up
                    sums[1] += down
                    if sums[0] > MAX_BYTES or sums[1] > MAX_BYTES:
                        raise APIError(400, "流量批次超出整数范围")
                    clean.append((uid, timestamp // 60 * 60, up, down))
                db.execute("INSERT INTO batches VALUES(?,?,?,?,?,?,?,?)", (ident, epoch, seq, payload_hash, now(), len(clean), sums[0], sums[1]))
                for uid, timestamp, up, down in clean:
                    total = db.execute("SELECT up,down FROM totals WHERE node_id=? AND user_id=?", (ident, uid)).fetchone()
                    if total and (total[0] + up > MAX_BYTES or total[1] + down > MAX_BYTES):
                        raise APIError(400, "累计流量超出整数范围")
                    db.execute("INSERT INTO totals VALUES(?,?,?,?) ON CONFLICT(node_id,user_id) DO UPDATE SET up=totals.up+excluded.up,down=totals.down+excluded.down", (ident, uid, up, down))
                    if up or down:
                        db.execute("INSERT INTO usage VALUES(?,?,?,?,?) ON CONFLICT(node_id,user_id,ts) DO UPDATE SET up=usage.up+excluded.up,down=usage.down+excluded.down", (ident, uid, timestamp, up, down))
                ack.append({"epoch": epoch, "seq": seq})
            db.execute("UPDATE nodes SET applied_revision=?,last_seen=?,agent_version=?,last_error=?,sample_error=?,service_running=?,last_sample_at=?,pending_batches=? WHERE id=?",
                       (applied, now(), version, apply_error, collector_error, int(running), last_sample, pending, ident))
            self._refresh_quotas(db)
            node = self._node(db, ident)
            desired = self._snapshot(db, ident, node["revision"]) if node["status"] == "active" and node["revision"] != applied else None
            result = {"protocol": PROTOCOL, "node_id": ident, "status": node["status"], "server_time": now(), "ack": ack, "desired": desired}
        # ACK leaves this method only after the surrounding transaction committed.
        return result

    def ingest_activity(self, data, token):
        self._protocol(data)
        ident = node_id_valid(data.get("node_id"))
        events = data.get("events", [])
        if not isinstance(events, list) or len(events) > 400:
            raise APIError(400, "行为记录批次过大")
        status = data.get("status", {})
        if not isinstance(status, dict):
            raise APIError(400, "行为采集状态不合法")
        pending = integer(status.get("pending", 0), "待上传行为", 0, 1000000)
        dropped = integer(status.get("dropped", 0), "丢弃行为", 0)
        gaps = integer(status.get("gaps", 0), "日志缺口", 0)
        collected = integer(status.get("collected_at", 0), "日志读取时间", 0, now() + 300)
        error = error_text(status.get("error", ""), "日志采集错误")
        ack = []
        with self.transaction(notify=False) as db:
            node = self._authenticated_node(db, ident, token)
            if node["status"] != "active":
                raise APIError(409, "服务器尚未接入")
            detail_days, summary_days = self._activity_retention(db)
            for event in events:
                if not isinstance(event, dict):
                    raise APIError(400, "行为记录不合法")
                eid = event.get("id")
                if not isinstance(eid, str) or not re.fullmatch(r"[0-9a-f]{64}", eid):
                    raise APIError(400, "行为记录 ID 不合法")
                ts = integer(event.get("ts"), "行为时间", 1577836800, now() + 300)
                kind = event.get("kind")
                if kind not in ("connection", "error", "gap"):
                    raise APIError(400, "行为类型不合法")
                uid = event.get("user_id") or None
                if uid:
                    user_id_valid(uid)
                    # Late reports must not recreate permanently deleted users.
                    if not db.execute("SELECT 1 FROM users WHERE id=?", (uid,)).fetchone():
                        ack.append(eid)
                        continue
                    if not db.execute("SELECT 1 FROM assignments WHERE user_id=? AND node_id=?", (uid, ident)).fetchone():
                        raise APIError(403, "行为用户未分配给本服务器")
                fields = [text_value(event.get(key, ""), key, 0, limit) for key, limit in
                          (("source_ip", 64), ("target", 512), ("network", 8), ("inbound", 100), ("message", 500))]
                port = integer(event.get("port", 0), "目标端口", 0, 65535)
                if fields[2] not in ("", "tcp", "udp"):
                    raise APIError(400, "传输协议不合法")
                payload_hash = digest(canonical([ts, uid, kind, port, fields]))
                previous = db.execute("SELECT payload_hash FROM activity_receipts WHERE node_id=? AND event_id=?", (ident, eid)).fetchone()
                if previous:
                    if previous[0] != payload_hash:
                        raise APIError(409, "重复行为记录的内容不一致")
                elif ts >= now() - summary_days * 86400:
                    db.execute("INSERT INTO activity_receipts VALUES(?,?,?,?,?)", (ident, eid, uid, ts, payload_hash))
                    if ts >= now() - detail_days * 86400:
                        db.execute("INSERT INTO activity_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                                   (ident, eid, uid, ts, kind, fields[0], fields[1], port, fields[2], fields[3], fields[4], now()))
                    db.execute("""INSERT INTO activity_hourly VALUES(?,?,?,?,?,?,?)
                               ON CONFLICT(node_id,user_id,hour) DO UPDATE SET
                               connections=connections+excluded.connections,errors=errors+excluded.errors,
                               gaps=gaps+excluded.gaps,last_at=MAX(last_at,excluded.last_at)""",
                               (ident, uid or "", ts // 3600 * 3600, int(kind == "connection"), int(kind == "error"), int(kind == "gap"), ts))
                ack.append(eid)
            db.execute("""INSERT INTO activity_status VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(node_id) DO UPDATE SET
                       received_at=excluded.received_at,collected_at=excluded.collected_at,pending=excluded.pending,
                       dropped=excluded.dropped,gaps=excluded.gaps,error=excluded.error,source=excluded.source""",
                       (ident, now(), collected, pending, dropped, gaps, error, "file"))
        return {"protocol": PROTOCOL, "ack": ack}

    @staticmethod
    def _activity_retention(db):
        values = dict(db.execute("SELECT key,value FROM settings WHERE key IN ('activity_detail_days','activity_summary_days')"))
        return int(values.get("activity_detail_days", 7)), int(values.get("activity_summary_days", 90))

    def activity(self, query):
        uid, nid, search = (query.get(key, [""])[0] for key in ("user_id", "node_id", "q"))
        if uid:
            user_id_valid(uid)
        if nid:
            node_id_valid(nid)
        search = text_value(search, "搜索目标", 0, 100)
        try:
            hours = integer(int(query.get("hours", ["24"])[0]), "时间范围", 1, 2160)
            page = integer(int(query.get("page", ["1"])[0]), "页码", 1, 1000000)
        except (ValueError, TypeError):
            raise APIError(400, "时间范围或页码不合法")
        with self.connect() as db:
            detail_days, summary_days = self._activity_retention(db)
            hours = min(hours, summary_days * 24)
            since = now() // 3600 * 3600 - (hours - 1) * 3600
            detail_since = max(since, now() - detail_days * 86400)
            conditions, params = [], []
            for key, value in (("user_id", uid), ("node_id", nid)):
                if value:
                    conditions.append(key + "=?")
                    params.append(value)
            base = " AND ".join(conditions) or "1=1"
            hourly = [dict(row) for row in db.execute("SELECT hour,SUM(connections) connections,SUM(errors) errors,SUM(gaps) gaps,MAX(last_at) last_at FROM activity_hourly WHERE " + base + " AND hour>=? GROUP BY hour ORDER BY hour", (*params, since))]
            summary = {key: sum(row[key] for row in hourly) for key in ("connections", "errors", "gaps")}
            summary["last_at"] = max((row["last_at"] for row in hourly), default=0)
            where = base + " AND ts>=?"
            detail_params = [*params, detail_since]
            if search:
                where += " AND instr(lower(target),lower(?))>0"
                detail_params.append(search)
            total = db.execute("SELECT COUNT(*) FROM activity_events WHERE " + where, detail_params).fetchone()[0]
            page = min(page, max(1, (total + 49) // 50))
            events = [dict(row) for row in db.execute("SELECT * FROM activity_events WHERE " + where + " ORDER BY ts DESC,event_id DESC LIMIT 50 OFFSET ?", (*detail_params, (page - 1) * 50))]
            users = [dict(row) for row in db.execute("SELECT id,name FROM users ORDER BY name COLLATE NOCASE")]
            nodes = [dict(row) for row in db.execute("SELECT id,name FROM nodes ORDER BY name COLLATE NOCASE")]
            user_names, node_names = {x["id"]: x["name"] for x in users}, {x["id"]: x["name"] for x in nodes}
            for row in events:
                row.update(user_name=user_names.get(row["user_id"], "未归属"), node_name=node_names.get(row["node_id"], ""))
            rankings = {}
            for field, label in (("target", "targets"), ("source_ip", "sources")):
                rankings[label] = [dict(row) for row in db.execute("SELECT " + field + " name,COUNT(*) count FROM activity_events WHERE " + where + " AND kind='connection' AND " + field + "!='' GROUP BY " + field + " ORDER BY count DESC,name LIMIT 8", detail_params)]
            summary["source_ips"] = db.execute("SELECT COUNT(DISTINCT source_ip) FROM activity_events WHERE " + where + " AND kind='connection' AND source_ip!=''", detail_params).fetchone()[0]
            telemetry = [dict(row) for row in db.execute("SELECT n.id,n.name,s.received_at,s.collected_at,s.pending,s.dropped,s.gaps,s.error FROM nodes n LEFT JOIN activity_status s ON s.node_id=n.id WHERE n.status='active'" + (" AND n.id=?" if nid else "") + " ORDER BY n.name", (nid,) if nid else ())]
        return {"summary": summary, "hourly": hourly, "events": events, "users": users, "nodes": nodes,
                **rankings, "telemetry": telemetry, "page": page, "total": total, "page_size": 50,
                "since": since, "detail_since": detail_since, "detail_days": detail_days,
                "summary_days": summary_days, "hours": hours}


    def detach(self, data, token):
        self._protocol(data)
        ident = node_id_valid(data.get("node_id"))
        with self.transaction() as db:
            node = self._authenticated_node(db, ident, token)
            self._purge_node(db, ident)
            self._refresh_quotas(db)
            self.audit(db, ident, "node.detach", node["name"] + "：主动解绑并删除服务器及关联流量")
        return {"ok": True, "protocol": PROTOCOL}

    @staticmethod
    def _check_assignments(db, uid, user_uuid, node_ids):
        if not isinstance(node_ids, list) or len(node_ids) > 2000 or any(not isinstance(x, str) for x in node_ids) or len(set(node_ids)) != len(node_ids):
            raise APIError(400, "授权服务器列表格式不正确")
        for ident in node_ids:
            node_id_valid(ident)
            node = Store._node(db, ident)
            if node["status"] != "active":
                raise APIError(409, f"服务器 {node['name']} 尚未接管或已撤销")
            collision = db.execute("SELECT u.name FROM users u JOIN assignments a ON a.user_id=u.id WHERE a.node_id=? AND a.active=1 AND u.deleted=0 AND u.uuid=? AND u.id!=?", (ident, user_uuid, uid or "")).fetchone()
            if collision:
                raise APIError(409, f"服务器 {node['name']} 上的用户 {collision['name']} 已使用相同 UUID，请先重置其中一人的凭据")

    def save_user(self, data, actor, uid=None):
        if not isinstance(data, dict):
            raise APIError(400, "用户资料格式错误")
        if uid:
            user_id_valid(uid)
        with self.transaction() as db:
            old = db.execute("SELECT * FROM users WHERE id=? AND deleted=0", (uid,)).fetchone() if uid else None
            if uid and not old:
                raise APIError(404, "用户不存在或已删除")
            name = valid_name(data.get("name", old["name"] if old else None))
            reset = data.get("reset_credentials", False)
            boolean(reset, "重置凭据")
            user_uuid = valid_uuid(str(uuid.uuid4()) if reset else data.get("uuid") or (old["uuid"] if old else str(uuid.uuid4())))
            tuic_pass = valid_tuic(secrets.token_urlsafe(24) if reset else data.get("tuic_pass") or (old["tuic_pass"] if old else secrets.token_urlsafe(24)))
            enabled = boolean(data.get("enabled", bool(old["enabled"]) if old else True), "启用状态")
            policy = self._policy(db, uid) if old else None
            quota = integer(data.get("quota_bytes", policy["quota_bytes"] if policy else 0), "流量额度", 0)
            quota_period = data.get("quota_period", policy["quota_period"] if policy else "monthly")
            if quota_period not in ("monthly", "total"):
                raise APIError(400, "额度周期必须为每月或累计")
            before = {r[0] for r in db.execute("SELECT node_id FROM assignments WHERE user_id=? AND active=1", (uid,))} if uid else set()
            node_ids = data.get("node_ids", sorted(before))
            self._check_assignments(db, uid, user_uuid, node_ids)
            duplicate = db.execute("SELECT 1 FROM users WHERE name=? AND id!=?", (name, uid or "")).fetchone()
            if duplicate:
                raise APIError(409, "用户名已存在")
            proxy_changed = not old or any((old["name"] != name, old["uuid"] != user_uuid, old["tuic_pass"] != tuic_pass, bool(old["enabled"]) != enabled, before != set(node_ids)))
            changed = proxy_changed or policy["quota_bytes"] != quota or policy["quota_period"] != quota_period
            revisions = {r["id"]: r["revision"] for r in db.execute("SELECT id,revision FROM nodes") if r["id"] in before | set(node_ids)}
            uid = uid or "u_" + uuid.uuid4().hex
            if old:
                db.execute("UPDATE users SET name=?,uuid=?,tuic_pass=?,enabled=?,updated_at=? WHERE id=?", (name, user_uuid, tuic_pass, int(enabled), now(), uid))
            else:
                db.execute("INSERT INTO users VALUES(?,?,?,?,?,0,NULL,?,?)", (uid, name, user_uuid, tuic_pass, int(enabled), now(), now()))
            self._policy(db, uid)
            db.execute("UPDATE user_policies SET quota_bytes=?,quota_period=? WHERE user_id=?", (quota, quota_period, uid))
            db.execute("UPDATE assignments SET active=0 WHERE user_id=?", (uid,))
            for ident in node_ids:
                db.execute("INSERT INTO assignments VALUES(?,?,1,?,?) ON CONFLICT(user_id,node_id) DO UPDATE SET active=1,last_active=excluded.last_active", (uid, ident, now(), now()))
            if changed:
                if proxy_changed:
                    for ident in before | set(node_ids):
                        db.execute("UPDATE nodes SET revision=revision+1 WHERE id=? AND status='active'", (ident,))
                self.audit(db, actor, "user.update" if old else "user.create", f"{name}：{'启用' if enabled else '禁用'}，授权 {len(node_ids)} 台服务器" + ("，重置凭据" if reset else ""))
            self._refresh_quotas(db)
            requires_sync = any(r["id"] in revisions and r["revision"] != revisions[r["id"]] for r in db.execute("SELECT id,revision FROM nodes"))
        return {"id": uid, "ok": True, "changed": bool(changed), "requires_sync": requires_sync}

    @staticmethod
    def _purge_user(db, uid):
        db.execute("DELETE FROM activity_hourly WHERE user_id=?", (uid,))
        db.execute("UPDATE nodes SET revision=revision+1 WHERE status='active' AND id IN (SELECT node_id FROM assignments WHERE user_id=? AND active=1)", (uid,))
        for table in ("user_policies", "assignments", "usage", "totals"):
            db.execute(f"DELETE FROM {table} WHERE user_id=?", (uid,))
        for node in db.execute("SELECT id,inventory FROM nodes WHERE inventory LIKE '%\"imported\"%'").fetchall():
            inventory = json.loads(node["inventory"])
            imported = inventory.get("imported", [])
            if any(item["id"] == uid for item in imported):
                inventory["imported"] = [item for item in imported if item["id"] != uid]
                db.execute("UPDATE nodes SET inventory=? WHERE id=?", (canonical(inventory), node["id"]))
        db.execute("DELETE FROM users WHERE id=?", (uid,))

    def delete_user(self, uid, actor):
        user_id_valid(uid)
        with self.transaction() as db:
            user = db.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
            if not user:
                raise APIError(404, "用户不存在")
            self._purge_user(db, uid)
            self.audit(db, actor, "user.delete", user["name"] + "：永久删除用户、授权、流量和订阅")
        return {"ok": True}

    @staticmethod
    def _policy(db, uid):
        db.execute("INSERT OR IGNORE INTO user_policies(user_id,subscription_token) VALUES(?,?)",
                   (uid, secrets.token_urlsafe(32)))
        return db.execute("SELECT * FROM user_policies WHERE user_id=?", (uid,)).fetchone()

    def _quota_values(self, db):
        offset, today, month = self._time_bounds(db)
        tz = dt.timezone(dt.timedelta(minutes=offset))
        current = dt.datetime.fromtimestamp(month, tz)
        end = int(dt.datetime(current.year + (current.month == 12), current.month % 12 + 1, 1, tzinfo=tz).timestamp())
        values = {r["user_id"]: {"quota_bytes": r["quota_bytes"], "quota_period": r["quota_period"],
                                   "quota_up": 0, "quota_down": 0,
                                   "quota_reset": end if r["quota_period"] == "monthly" else 0}
                  for r in db.execute("SELECT p.* FROM user_policies p JOIN users u ON u.id=p.user_id WHERE u.deleted=0")}
        for r in db.execute("SELECT t.user_id,t.up,t.down FROM totals t JOIN user_policies p ON p.user_id=t.user_id WHERE p.quota_period='total'"):
            if r["user_id"] in values:
                entry = values[r["user_id"]]
                entry["quota_up"] += r["up"]
                entry["quota_down"] += r["down"]
        for r in db.execute("SELECT u.user_id,SUM(u.up) up,SUM(u.down) down FROM usage u JOIN user_policies p ON p.user_id=u.user_id WHERE p.quota_period='monthly' AND u.ts>=? AND u.ts<? GROUP BY u.node_id,u.user_id", (month, end)):
            if r["user_id"] in values:
                entry = values[r["user_id"]]
                entry["quota_up"] += r["up"]
                entry["quota_down"] += r["down"]
        for entry in values.values():
            entry["quota_used"] = entry["quota_up"] + entry["quota_down"]
            entry["quota_blocked"] = bool(entry["quota_bytes"] and entry["quota_used"] >= entry["quota_bytes"])
            entry["quota_remaining"] = max(0, entry["quota_bytes"] - entry["quota_used"]) if entry["quota_bytes"] else None
        return values

    def _refresh_quotas(self, db):
        values = self._quota_values(db)
        for policy in db.execute("SELECT p.user_id,p.quota_blocked,u.enabled FROM user_policies p JOIN users u ON u.id=p.user_id").fetchall():
            entry = values.get(policy["user_id"])
            if entry and bool(policy["quota_blocked"]) != entry["quota_blocked"]:
                db.execute("UPDATE user_policies SET quota_blocked=? WHERE user_id=?", (int(entry["quota_blocked"]), policy["user_id"]))
                if policy["enabled"]:
                    db.execute("UPDATE nodes SET revision=revision+1 WHERE status='active' AND id IN (SELECT node_id FROM assignments WHERE user_id=? AND active=1)", (policy["user_id"],))
        return values

    @staticmethod
    def _subscription_nodes(db, user):
        proxies, links, missing = [], [], []
        stored = db.execute("SELECT value FROM settings WHERE key='node_name_template'").fetchone()
        template = stored[0] if stored else DEFAULT_NODE_NAME_TEMPLATE
        labels = set()
        nodes = db.execute("SELECT n.id,n.name,n.inventory FROM nodes n JOIN assignments a ON a.node_id=n.id WHERE a.user_id=? AND a.active=1 AND n.status='active' ORDER BY n.name,n.id", (user["id"],))
        for node in nodes:
            inbounds = json.loads(node["inventory"]).get("inbounds", [])
            if not inbounds:
                missing.append(node["name"])
            for index, inbound in enumerate(inbounds):
                kind = inbound["type"].split("-", 1)[0]
                server, sni = inbound.get("server", ""), inbound.get("sni", "")
                if kind not in ("vless", "tuic") or not server or not sni or (kind == "vless" and not inbound.get("public_key")):
                    missing.append(node["name"] + " / " + inbound["name"])
                    continue
                fields = {"server": node["name"], "inbound": inbound["name"], "username": user["name"], "index": str(index + 1)}
                label = re.sub(r"\{\{(server|inbound|username|index)\}\}", lambda match: fields[match[1]], template)
                if label in labels:
                    label += f" · {node['id'][-6:]}-{index+1}"
                while label in labels:
                    label += "-2"
                labels.add(label)
                host = "[" + server + "]" if ":" in server and not server.startswith("[") else server
                proxy = {"name": label, "type": kind, "server": server.strip("[]"), "port": inbound["port"], "uuid": user["uuid"]}
                if kind == "vless":
                    proxy.update(network="tcp", udp=True, tls=True, flow="xtls-rprx-vision", servername=sni)
                    proxy["client-fingerprint"] = "chrome"
                    proxy["reality-opts"] = {"public-key": inbound["public_key"], "short-id": inbound.get("short_id", "")}
                    query = {"encryption": "none", "flow": "xtls-rprx-vision", "security": "reality", "sni": sni,
                             "fp": "chrome", "pbk": inbound["public_key"], "sid": inbound.get("short_id", ""), "type": "tcp", "headerType": "none"}
                    authority = user["uuid"]
                else:
                    proxy.update(password=user["tuic_pass"], sni=sni, alpn=["h3"])
                    proxy["skip-cert-verify"] = inbound.get("skip_cert_verify", True)
                    proxy["congestion-controller"] = "bbr"
                    proxy["udp-relay-mode"] = "native"
                    query = {"congestion_control": "bbr", "alpn": "h3", "sni": sni,
                             "allow_insecure": "1" if proxy["skip-cert-verify"] else "0"}
                    authority = user["uuid"] + ":" + urllib.parse.quote(user["tuic_pass"], safe="")
                proxies.append(proxy)
                links.append(f"{kind}://{authority}@{host}:{inbound['port']}?{urllib.parse.urlencode(query, quote_via=urllib.parse.quote)}#{urllib.parse.quote(label, safe='')}")
        return proxies, links, missing

    def subscription_info(self, uid, actor=None, reset=False, data=None):
        user_id_valid(uid)
        with self.transaction() as db:
            user = db.execute("SELECT * FROM users WHERE id=? AND deleted=0", (uid,)).fetchone()
            if not user:
                raise APIError(404, "用户不存在或已删除")
            policy = self._policy(db, uid)
            if data is not None:
                if not isinstance(data, dict):
                    raise APIError(400, "订阅设置格式错误")
                title = text_value(data.get("subscription_name", policy["subscription_name"]), "订阅名称", 1, 80)
                enabled = boolean(data.get("subscription_enabled", bool(policy["subscription_enabled"])), "订阅启用状态")
                expires = integer(data.get("subscription_expires_at", policy["subscription_expires_at"]), "订阅到期时间", 0, 253402300799)
                db.execute("UPDATE user_policies SET subscription_name=?,subscription_enabled=?,subscription_expires_at=? WHERE user_id=?", (title, int(enabled), expires, uid))
                self.audit(db, actor, "user.subscription.update", user["name"] + "：更新订阅设置")
            if reset:
                db.execute("UPDATE user_policies SET subscription_token=? WHERE user_id=?", (secrets.token_urlsafe(32), uid))
                self.audit(db, actor, "user.subscription.reset", user["name"])
            policy = self._policy(db, uid)
            quota = self._refresh_quotas(db)[uid]
            return self._subscription_metadata(db, user, policy, quota)

    def _subscription_metadata(self, db, user, policy, quota):
        proxies, links, missing = self._subscription_nodes(db, user)
        path = "/sub/" + policy["subscription_token"]
        return {"id": user["id"], "name": user["name"], "enabled": bool(user["enabled"]), **quota,
                "subscription_name": policy["subscription_name"], "subscription_enabled": bool(policy["subscription_enabled"]),
                "subscription_expires_at": policy["subscription_expires_at"],
                "subscription_expired": bool(policy["subscription_expires_at"] and policy["subscription_expires_at"] <= now()),
                "url": path, "clash": path + "/clash", "v2ray": path + "/v2ray", "nodes_count": len(proxies), "missing": missing}

    def list_subscriptions(self):
        with self.transaction() as db:
            users = db.execute("SELECT * FROM users WHERE deleted=0 ORDER BY name COLLATE NOCASE").fetchall()
            policies = {user["id"]: self._policy(db, user["id"]) for user in users}
            quotas = self._refresh_quotas(db)
            return {"subscriptions": [self._subscription_metadata(db, user, policies[user["id"]], quotas[user["id"]]) for user in users]}

    @staticmethod
    def subscription_format(kind=None, user_agent="", accept=""):
        if kind is not None and kind not in ("auto", "clash", "v2ray"):
            raise APIError(400, "订阅格式必须为 auto、clash 或 v2ray")
        if kind in ("clash", "v2ray"):
            return kind
        agent = user_agent.lower()
        if "v2ray" in agent:
            return "v2ray"
        if any(name in agent for name in ("clash", "mihomo", "stash")):
            return "clash"
        for item in accept.lower().split(","):
            parts = [part.strip() for part in item.split(";")]
            if parts[0] in ("text/yaml", "application/yaml", "application/x-yaml"):
                try:
                    quality = next((float(part[2:]) for part in parts[1:] if part.startswith("q=")), 1)
                except ValueError:
                    quality = 0
                if quality > 0:
                    return "clash"
        return "v2ray"

    def subscription(self, token, kind=None, user_agent="", accept=""):
        kind = self.subscription_format(kind, user_agent, accept)
        with self.transaction() as db:
            user = db.execute("SELECT u.* FROM users u JOIN user_policies p ON p.user_id=u.id WHERE p.subscription_token=? AND u.deleted=0", (token,)).fetchone()
            if not user:
                raise APIError(404, "订阅不存在")
            policy = self._policy(db, user["id"])
            if not policy["subscription_enabled"]:
                raise APIError(403, "订阅已停用")
            if policy["subscription_expires_at"] and policy["subscription_expires_at"] <= now():
                raise APIError(403, "订阅已过期")
            quota = self._refresh_quotas(db)[user["id"]]
            if not user["enabled"] or quota["quota_blocked"]:
                raise APIError(403, "用户已停用" if not user["enabled"] else "流量额度已用尽")
            proxies, links, missing = self._subscription_nodes(db, user)
            if not proxies:
                raise APIError(409, "没有可导出的节点，请授权服务器，并更新节点端脚本后同步订阅信息")
            if kind == "clash":
                # JSON flow mappings are valid YAML 1.2; quote names and secrets exactly.
                group_name, number = "PROXY", 2
                proxy_names = {p["name"] for p in proxies}
                while group_name in proxy_names:
                    group_name = "PROXY" + str(number)
                    number += 1
                group = {"name": group_name, "type": "select", "proxies": [p["name"] for p in proxies]}
                replacements = {"proxies": "\n".join("  - " + json.dumps(p, ensure_ascii=False) for p in proxies),
                                "proxy_names": json.dumps(group["proxies"], ensure_ascii=False),
                                "subscription_name": json.dumps(policy["subscription_name"], ensure_ascii=False),
                                "group_name": json.dumps(group_name),
                                "proxy_groups": "  - " + json.dumps(group, ensure_ascii=False),
                                "rules": "  - " + json.dumps("MATCH," + group_name)}
                template = db.execute("SELECT value FROM settings WHERE key='clash_template'").fetchone()[0]
                body = re.sub(r"\{\{(proxies|proxy_names|subscription_name|group_name|proxy_groups|rules)\}\}", lambda match: replacements[match[1]], template).rstrip() + "\n"
                content_type, suffix = "text/yaml; charset=utf-8", "yaml"
            else:
                body = base64.b64encode(("\n".join(links) + "\n").encode("utf-8")).decode("ascii")
                content_type, suffix = "text/plain; charset=utf-8", "txt"
            userinfo = f"upload={quota['quota_up']}; download={quota['quota_down']}"
            if quota["quota_bytes"]:
                userinfo += f"; total={quota['quota_bytes']}"
            if policy["subscription_expires_at"]:
                userinfo += f"; expire={policy['subscription_expires_at']}"
            headers = {"Subscription-Userinfo": userinfo,
                       "Profile-Title": "base64:" + base64.b64encode(policy["subscription_name"].encode("utf-8")).decode("ascii"),
                       "Vary": "User-Agent, Accept",
                       "profile-update-interval": "6", "Content-Disposition": "attachment; filename=\"subscription." + suffix + "\"; filename*=UTF-8''" + urllib.parse.quote(policy["subscription_name"] + "." + suffix, safe="")}
            return body.encode("utf-8"), content_type, headers

    @staticmethod
    def _time_bounds(db):
        offset = int(db.execute("SELECT value FROM settings WHERE key='timezone_offset'").fetchone()[0])
        tz = dt.timezone(dt.timedelta(minutes=offset))
        current = dt.datetime.now(tz)
        today = int(current.replace(hour=0, minute=0, second=0, microsecond=0).timestamp())
        month = int(current.replace(day=1, hour=0, minute=0, second=0, microsecond=0).timestamp())
        return offset, today, month

    @staticmethod
    def _sum(rows):
        up, down = 0, 0
        for row in rows:
            up += int(row[0])
            down += int(row[1])
        return {"up": up, "down": down, "total": up + down}

    @staticmethod
    def _period_usage(db, today, month):
        # Each node/user direction is bounded by its int64 lifetime total.
        # Merge these small groups in Python so cross-node sums stay exact.
        return db.execute("""
            SELECT user_id,SUM(up) up,SUM(down) down,
                   SUM(CASE WHEN ts>=? THEN up ELSE 0 END) today_up,
                   SUM(CASE WHEN ts>=? THEN down ELSE 0 END) today_down
            FROM usage WHERE ts>=? GROUP BY node_id,user_id
        """, (today, today, month))

    @staticmethod
    def _month_period(db, offset, today, selected=None):
        """Calendar months in the configured timezone, bounded by retained detail."""
        tz = dt.timezone(dt.timedelta(minutes=offset))
        current = dt.datetime.fromtimestamp(today, tz)
        latest = current.strftime("%Y-%m")
        cutoff = now() - DETAIL_RETENTION_DAYS * 86400
        oldest = db.execute("SELECT MIN(ts) FROM usage").fetchone()[0]
        first = dt.datetime.fromtimestamp(min(today, max(cutoff, oldest or today)), tz)
        first_index = first.year * 12 + first.month - 1
        last_index = current.year * 12 + current.month - 1
        months = [f"{index // 12:04d}-{index % 12 + 1:02d}" for index in range(last_index, first_index - 1, -1)]
        selected = latest if selected in (None, "latest") else selected
        if not isinstance(selected, str) or selected not in months:
            raise APIError(400, "该月份没有可查询的保留记录，请选择下拉框中的月份")
        year, month = map(int, selected.split("-"))
        start = dt.datetime(year, month, 1, tzinfo=tz)
        end = dt.datetime(year + (month == 12), month % 12 + 1, 1, tzinfo=tz)
        return {"month": selected, "months": months, "latest_month": latest,
                "start": int(start.timestamp()), "end": int(end.timestamp()),
                "partial": start.timestamp() < cutoff,
                "retained_since": dt.datetime.fromtimestamp(cutoff, tz).strftime("%Y-%m-%d %H:%M")}

    def list_users(self, selected_month=None):
        with self.connect() as db:
            offset, today, month = self._time_bounds(db)
            period = self._month_period(db, offset, today, selected_month)
            rows = db.execute("SELECT u.id,u.name,u.enabled,u.deleted,u.origin_node,u.created_at,u.updated_at,COALESCE(p.quota_bytes,0) quota_bytes,COALESCE(p.quota_period,'monthly') quota_period FROM users u LEFT JOIN user_policies p ON p.user_id=u.id WHERE u.deleted=0 ORDER BY u.name COLLATE NOCASE").fetchall()
            result = []
            totals, today_values, month_values, period_values = {}, {}, {}, {}
            for r in db.execute("SELECT user_id,up,down FROM totals"):
                entry = totals.setdefault(r["user_id"], {"up": 0, "down": 0})
                entry["up"] += r["up"]
                entry["down"] += r["down"]
            # Scan once for the selected month and legacy today/current-month fields.
            # Group each direction per node/user to retain exact int64 sums in SQL.
            usage = db.execute("""
                SELECT user_id,
                       SUM(CASE WHEN ts>=? THEN up ELSE 0 END) month_up,
                       SUM(CASE WHEN ts>=? THEN down ELSE 0 END) month_down,
                       SUM(CASE WHEN ts>=? THEN up ELSE 0 END) today_up,
                       SUM(CASE WHEN ts>=? THEN down ELSE 0 END) today_down,
                       SUM(CASE WHEN ts>=? AND ts<? THEN up ELSE 0 END) period_up,
                       SUM(CASE WHEN ts>=? AND ts<? THEN down ELSE 0 END) period_down
                FROM usage WHERE ts>=? GROUP BY node_id,user_id
            """, (month, month, today, today, period["start"], period["end"],
                  period["start"], period["end"], min(month, period["start"])))
            for r in usage:
                uid = r["user_id"]
                today_values[uid] = today_values.get(uid, 0) + r["today_up"] + r["today_down"]
                month_values[uid] = month_values.get(uid, 0) + r["month_up"] + r["month_down"]
                entry = period_values.setdefault(uid, {"period_up": 0, "period_down": 0})
                entry["period_up"] += r["period_up"]
                entry["period_down"] += r["period_down"]
            assignments = {}
            for r in db.execute("SELECT a.user_id,n.id,n.name,n.status,n.revision,n.applied_revision,n.last_seen FROM assignments a JOIN nodes n ON n.id=a.node_id WHERE a.active=1"):
                assignments.setdefault(r["user_id"], []).append({k: r[k] for k in ("id", "name", "status", "revision", "applied_revision", "last_seen")})
            quota_values = self._quota_values(db) if any(row["quota_bytes"] for row in rows) else {}
            for row in rows:
                item = dict(row)
                item["enabled"], item["deleted"] = bool(item["enabled"]), bool(item["deleted"])
                item.update(totals.get(row["id"], {"up": 0, "down": 0}))
                item.update(total=item["up"] + item["down"], today=today_values.get(row["id"], 0), month=month_values.get(row["id"], 0), nodes=assignments.get(row["id"], []))
                item.update(period_values.get(row["id"], {"period_up": 0, "period_down": 0}))
                item["period_total"] = item["period_up"] + item["period_down"]
                item["quota_used"] = item["month"] if item["quota_period"] == "monthly" else item["total"]
                item["quota_blocked"] = bool(item["quota_bytes"] and item["quota_used"] >= item["quota_bytes"])
                if item["quota_bytes"]:
                    item.update(quota_values.get(row["id"], {}))
                result.append(item)
            return {"users": result, "timezone_offset": offset, "period": period,
                    "detail_retention_days": DETAIL_RETENTION_DAYS}

    def user_detail(self, uid):
        user_id_valid(uid)
        with self.connect() as db:
            row = db.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
            if not row:
                raise APIError(404, "用户不存在")
            result = dict(row)
            policy = self._policy(db, uid)
            result.update(quota_bytes=policy["quota_bytes"], quota_period=policy["quota_period"])
            result["enabled"], result["deleted"] = bool(result["enabled"]), bool(result["deleted"])
            result["node_ids"] = [r[0] for r in db.execute("SELECT node_id FROM assignments WHERE user_id=? AND active=1", (uid,))]
            return result

    def list_nodes(self):
        with self.connect() as db:
            result, totals = [], {}
            counts = {r["node_id"]: r["count"] for r in db.execute(
                "SELECT a.node_id,COUNT(*) count FROM assignments a JOIN users u ON u.id=a.user_id "
                "WHERE a.active=1 AND u.deleted=0 GROUP BY a.node_id")}
            for r in db.execute("SELECT node_id,up,down FROM totals"):
                entry = totals.setdefault(r["node_id"], {"up": 0, "down": 0, "total": 0})
                entry["up"] += r["up"]
                entry["down"] += r["down"]
                entry["total"] += r["up"] + r["down"]
            for row in db.execute("SELECT * FROM nodes ORDER BY created_at DESC,id"):
                item = {k: row[k] for k in ("id", "name", "status", "hostname", "revision", "applied_revision", "last_seen", "agent_version", "last_error", "sample_error", "service_running", "last_sample_at", "pending_batches", "created_at", "approved_at", "join_expires")}
                item["online"] = bool(row["last_seen"] >= now() - 60 and row["status"] in ("pending", "active"))
                item["service_running"] = bool(item["service_running"])
                inventory = json.loads(row["inventory"])
                item["inbounds"] = inventory.get("inbounds", [])
                item["pending_users"] = [{"name": u["name"], "uuid_hint": u["uuid"][:8] + "…"} for u in inventory.get("users", [])] if row["status"] == "pending" else []
                item["users_count"] = counts.get(row["id"], 0)
                item.update(totals.get(row["id"], {"up": 0, "down": 0, "total": 0}))
                result.append(item)
            return {"nodes": result, "server_time": now()}

    def overview(self):
        with self.connect() as db:
            offset, today, month = self._time_bounds(db)
            all_totals = self._sum(db.execute("SELECT up,down FROM totals"))
            daily, monthly = {"up": 0, "down": 0, "total": 0}, {"up": 0, "down": 0, "total": 0}
            for r in self._period_usage(db, today, month):
                daily["up"] += r["today_up"]
                daily["down"] += r["today_down"]
                monthly["up"] += r["up"]
                monthly["down"] += r["down"]
            daily["total"] = daily["up"] + daily["down"]
            monthly["total"] = monthly["up"] + monthly["down"]
            nodes = db.execute("SELECT status,last_seen,revision,applied_revision,last_error,sample_error FROM nodes").fetchall()
            users = db.execute("SELECT COUNT(*),COALESCE(SUM(CASE WHEN u.enabled=1 AND COALESCE(p.quota_blocked,0)=0 THEN 1 ELSE 0 END),0) FROM users u LEFT JOIN user_policies p ON p.user_id=u.id WHERE u.deleted=0").fetchone()
            active = [n for n in nodes if n["status"] == "active"]
            return {"version": VERSION, "server_time": now(), "timezone_offset": offset,
                    "users": users[0], "enabled_users": users[1], "nodes": len(active),
                    "online_nodes": sum(n["last_seen"] >= now() - 60 for n in active),
                    "pending_nodes": sum(n["status"] == "pending" for n in nodes),
                    "unsynced_nodes": sum(n["revision"] != n["applied_revision"] for n in active),
                    "error_nodes": sum(bool(n["last_error"] or n["sample_error"]) for n in active),
                    "lifetime": all_totals, "today": daily, "month": monthly,
                    "last_report_at": max((n["last_seen"] for n in nodes), default=0), "detail_retention_days": DETAIL_RETENTION_DAYS}

    def traffic(self, uid=None, node_id=None, days=30, selected_month=None):
        if uid:
            user_id_valid(uid)
        if node_id:
            node_id_valid(node_id)
        days = integer(days, "日期范围", 1, MAX_CHART_DAYS)
        clauses, params = [], []
        if uid:
            clauses.append("u.user_id=?")
            params.append(uid)
        if node_id:
            clauses.append("u.node_id=?")
            params.append(node_id)
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        with self.connect() as db:
            offset, today, month = self._time_bounds(db)
            totals = self._sum(db.execute("SELECT u.up,u.down FROM totals u" + where, params))
            # Dates derive from sample timestamps, not upload arrival timestamps.
            start = today - (days - 1) * 86400
            end = today + 86400
            period = None
            if selected_month is not None:
                period = self._month_period(db, offset, today, selected_month)
                start, end = period["start"], period["end"]
                days = (end - start) // 86400
            range_where = where + (" AND " if where else " WHERE ") + "u.ts>=? AND u.ts<?"
            rows = db.execute(
                "SELECT u.node_id,(u.ts+?)/86400 day_index,SUM(u.up) up,SUM(u.down) down FROM usage u" +
                range_where + " GROUP BY u.node_id,u.user_id,day_index",
                [offset * 60] + params + [start, end])
            values, period_nodes = {}, {}
            for r in rows:
                entry = values.setdefault(r["day_index"], {"up": 0, "down": 0})
                entry["up"] += r["up"]
                entry["down"] += r["down"]
                if period is not None:
                    node_total = period_nodes.setdefault(r["node_id"], {"up": 0, "down": 0})
                    node_total["up"] += r["up"]
                    node_total["down"] += r["down"]
            daily = []
            for i in range(days):
                local_ts = start + i * 86400 + offset * 60
                key = dt.datetime.fromtimestamp(local_ts, dt.timezone.utc).strftime("%Y-%m-%d")
                entry = values.get(local_ts // 86400, {"up": 0, "down": 0})
                daily.append({"date": key, "up": entry["up"], "down": entry["down"], "total": entry["up"] + entry["down"]})
            if period is not None:
                period.update(self._sum((row["up"], row["down"]) for row in daily))
                names = {r["id"]: r["name"] for r in db.execute("SELECT id,name FROM nodes")}
                by_node = [{"id": ident, "name": names[ident], **values,
                            "total": values["up"] + values["down"]}
                           for ident, values in period_nodes.items()]
                by_node.sort(key=lambda node: node["total"], reverse=True)
            else:
                node_totals = {}
                for r in db.execute("SELECT n.id,n.name,u.up,u.down FROM totals u JOIN nodes n ON n.id=u.node_id" + where + " ORDER BY n.id", params):
                    entry = node_totals.setdefault(r["id"], {"id": r["id"], "name": r["name"], "up": 0, "down": 0, "total": 0})
                    entry["up"] += r["up"]
                    entry["down"] += r["down"]
                    entry["total"] += r["up"] + r["down"]
                by_node = sorted(node_totals.values(), key=lambda n: n["total"], reverse=True)
            return {"lifetime": totals, "daily": daily, "by_node": by_node, "timezone_offset": offset,
                    "sample_time_basis": True, "detail_retention_days": DETAIL_RETENTION_DAYS,
                    "period": period}

    def logs(self):
        with self.connect() as db:
            return {"logs": [dict(r) for r in db.execute("SELECT * FROM audit ORDER BY id DESC LIMIT 200")]}

    def settings(self):
        with self.connect() as db:
            return {r[0]: int(r[1]) if r[0] in ("timezone_offset", "activity_detail_days", "activity_summary_days") else r[1] for r in db.execute("SELECT key,value FROM settings")}

    def save_settings(self, data, actor):
        if not isinstance(data, dict):
            raise APIError(400, "设置格式错误")
        with self.transaction() as db:
            if "timezone_offset" in data:
                offset = integer(data["timezone_offset"], "时区偏移", -720, 840)
                if offset % 15:
                    raise APIError(400, "时区偏移必须是 15 分钟的整数倍")
                db.execute("UPDATE settings SET value=? WHERE key='timezone_offset'", (str(offset),))
                self._refresh_quotas(db)
                self.audit(db, actor, "settings.timezone", f"UTC 偏移 {offset} 分钟")
            detail, summary = self._activity_retention(db)
            detail = integer(data.get("activity_detail_days", detail), "行为明细保留天数", 1, 30)
            summary = integer(data.get("activity_summary_days", summary), "行为汇总保留天数", detail, 90)
            for key, value in (("activity_detail_days", detail), ("activity_summary_days", summary)):
                if key in data:
                    db.execute("UPDATE settings SET value=? WHERE key=?", (str(value), key))
                    self.audit(db, actor, "settings.activity", key + "=" + str(value))
            for key, allowed in (("node_name_template", {"server", "inbound", "username", "index"}),
                                 ("clash_template", {"proxies", "proxy_names", "subscription_name", "group_name", "proxy_groups", "rules"})):
                if key not in data:
                    continue
                value = data[key]
                limit = 64000 if key == "clash_template" else 160
                if not isinstance(value, str) or not value.strip() or len(value) > limit or any(ord(c) < 32 and c not in "\n\r\t" for c in value):
                    raise APIError(400, "模板为空、过长或包含无效字符")
                if key == "node_name_template" and any(c in value for c in "\n\r\t"):
                    raise APIError(400, "节点名称模板须为单行文本")
                fields = re.findall(r"\{\{(.*?)\}\}", value)
                if any(field not in allowed for field in fields):
                    raise APIError(400, "模板包含未知占位符")
                if key == "clash_template" and fields.count("proxies") != 1:
                    raise APIError(400, "Clash 模板必须包含一个 {{proxies}} 占位符")
                db.execute("UPDATE settings SET value=? WHERE key=?", (value, key))
                self.audit(db, actor, "settings.subscription", "更新订阅模板")
        return {"ok": True}

    def maintain(self, force=False):
        if not force and time.monotonic() - self.last_maintenance < 600:
            return
        if not self.maintenance_lock.acquire(blocking=False):
            return
        try:
            with self.transaction() as db:
                db.execute("DELETE FROM sessions WHERE expires_at<=?", (now(),))
                db.execute("DELETE FROM usage WHERE rowid IN (SELECT rowid FROM usage WHERE ts<? LIMIT 25000)", (now() - DETAIL_RETENTION_DAYS * 86400,))
                detail, summary = self._activity_retention(db)
                for table, column, days in (("activity_events", "ts", detail), ("activity_receipts", "ts", summary), ("activity_hourly", "hour", summary)):
                    db.execute(f"DELETE FROM {table} WHERE rowid IN (SELECT rowid FROM {table} WHERE {column}<? LIMIT 25000)", (now() - days * 86400,))
                db.execute("DELETE FROM audit WHERE id NOT IN (SELECT id FROM audit ORDER BY id DESC LIMIT 10000)")
            self.last_maintenance = time.monotonic()
        finally:
            self.maintenance_lock.release()

    @contextlib.contextmanager
    def backup(self):
        handle, pathname = tempfile.mkstemp(prefix="ysq-backup-", suffix=".db", dir=self.directory)
        os.close(handle)
        try:
            with self.connect() as src:
                dest = sqlite3.connect(pathname)
                try:
                    src.backup(dest)
                    dest.execute("DELETE FROM sessions")
                    dest.commit()
                finally:
                    dest.close()
            yield Path(pathname)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(pathname)


class RateLimiter:
    def __init__(self):
        self.lock = threading.Lock()
        self.failures = {}
        self.total = []

    def check(self, key):
        stamp = time.monotonic()
        with self.lock:
            self.total = [x for x in self.total if x > stamp - 60]
            if len(self.total) >= 60:
                raise APIError(429, "登录请求过于频繁，请一分钟后重试")
            self.total.append(stamp)
            values = [x for x in self.failures.get(key, []) if x > stamp - 900]
            self.failures[key] = values
            if len(values) >= 8:
                raise APIError(429, "登录失败次数过多，请 15 分钟后重试")
            if len(self.failures) > 5000:
                self.failures = {k: [v for v in times if v > stamp-900] for k, times in self.failures.items() if any(v > stamp-900 for v in times)}

    def fail(self, key):
        with self.lock:
            self.failures.setdefault(key, []).append(time.monotonic())

    def success(self, key):
        with self.lock:
            self.failures.pop(key, None)


class CenterServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64

    def __init__(self, address, store, origin, dev=False, workers=24):
        self.store, self.origin, self.dev = store, origin.rstrip("/"), dev
        if ":" in address[0]:
            self.address_family = socket.AF_INET6
        self.public = urllib.parse.urlsplit(self.origin)
        self.worker_slots = threading.BoundedSemaphore(workers)
        self.wait_slots = threading.BoundedSemaphore(256)
        self.request_context = threading.local()
        self.password_slots = threading.BoundedSemaphore(2)
        self.login_limiter = RateLimiter()
        super().__init__(address, Handler)

    def get_request(self):
        request, address = super().get_request()
        request.settimeout(12)
        return request, address

    def process_request(self, request, client_address):
        if not self.worker_slots.acquire(blocking=False):
            with contextlib.suppress(OSError):
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\nRetry-After: 2\r\n\r\n")
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.worker_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        self.request_context.worker_reserved = True
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.release_worker_slot()

    def release_worker_slot(self):
        if getattr(self.request_context, "worker_reserved", False):
            self.request_context.worker_reserved = False
            self.worker_slots.release()

    def handle_error(self, request, client_address):
        LOG.warning("请求中断或内部异常（客户端 %s）", client_address[0])


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "YSQ-Center"
    sys_version = ""

    def log_message(self, format, *args):
        # Do not log request paths, tokens, cookies, query strings, or submitted secrets.
        if args and isinstance(args[0], str) and " 5" in args[0]:
            LOG.warning("HTTP 请求失败")

    def send_error(self, code, message=None, explain=None):
        self.respond(code, {"error": "请求格式不合法"})

    def respond(self, status, value, headers=None, content_type="application/json; charset=utf-8"):
        body = value if isinstance(value, bytes) else canonical(value).encode("utf-8")
        self.response_headers(status, len(body), content_type, headers)
        if self.command != "HEAD":
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                self.wfile.write(body)

    def response_headers(self, status, length, content_type, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store, private")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header("Connection", "close")
        for key, val in (headers or {}).items():
            self.send_header(key, val)
        self.end_headers()
        self.close_connection = True

    def respond_file(self, path, filename):
        with path.open("rb") as source:
            self.response_headers(200, os.fstat(source.fileno()).st_size, "application/octet-stream", {"Content-Disposition": 'attachment; filename="' + filename + '"'})
            if self.command != "HEAD":
                while True:
                    chunk = source.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)

    def validate_request(self):
        if len(self.path) > 2048 or sum(len(k) + len(v) for k, v in self.headers.items()) > 16384:
            raise APIError(431, "请求头过大")
        if len(self.headers.get_all("Host", [])) != 1:
            raise APIError(400, "Host 请求头不合法")
        if self.headers.get("Host", "").lower() != self.server.public.netloc.lower():
            # Health probe is intentionally allowed locally without the public Host header.
            if not (self.path == "/healthz" and self.headers.get("Host", "").split(":")[0] in ("127.0.0.1", "localhost")):
                raise APIError(400, "域名不匹配，请使用已配置的中控域名访问")
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.scheme or parsed.netloc or "\\" in parsed.path or "%2f" in parsed.path.lower() or "%5c" in parsed.path.lower():
            raise APIError(400, "请求路径不合法")
        return parsed

    def body(self):
        if self.headers.get("Transfer-Encoding"):
            raise APIError(400, "不支持分块请求体，请发送 Content-Length")
        lengths = self.headers.get_all("Content-Length", [])
        if len(lengths) != 1 or not lengths[0].isdigit():
            raise APIError(411, "缺少有效的 Content-Length")
        length = int(lengths[0])
        if length > MAX_BODY:
            raise APIError(413, "请求体过大")
        if self.headers.get("Content-Type", "").split(";")[0].strip().lower() != "application/json":
            raise APIError(415, "请使用 application/json")
        raw = self.rfile.read(length)
        if len(raw) != length:
            raise APIError(400, "请求体不完整")
        try:
            value = json.loads(raw.decode("utf-8"), parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        except (ValueError, UnicodeError, RecursionError):
            raise APIError(400, "JSON 格式不正确")
        if not isinstance(value, dict):
            raise APIError(400, "请求体必须是 JSON 对象")
        return value

    def token(self):
        values = self.headers.get_all("Authorization", [])
        if len(values) != 1 or not values[0].startswith("Bearer "):
            raise APIError(401, "缺少节点令牌")
        return values[0][7:]

    def cookie_token(self):
        try:
            cookie = http.cookies.SimpleCookie()
            cookie.load(self.headers.get("Cookie", ""))
            return cookie[COOKIE_NAME].value if COOKIE_NAME in cookie else ""
        except http.cookies.CookieError:
            return ""

    def require_origin(self):
        if self.headers.get("Origin", "") != self.server.origin:
            raise APIError(403, "请求来源不匹配，请刷新页面后重试")

    def admin(self, mutate=False):
        session = self.server.store.session(self.cookie_token())
        if mutate:
            self.require_origin()
            if not hmac.compare_digest(self.headers.get("X-CSRF-Token", ""), session["csrf"]):
                raise APIError(403, "页面校验已失效，请刷新页面后重试")
        return session

    def cookie_header(self, token, clear=False):
        value = f"{COOKIE_NAME}={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={0 if clear else SESSION_SECONDS}"
        if not self.server.dev:
            value += "; Secure"
        return value

    def client_key(self, username):
        # Only the trusted, same-host reverse proxy may supply X-Real-IP.
        address = self.client_address[0]
        if ipaddress.ip_address(address).is_loopback:
            forwarded = self.headers.get("X-Real-IP", "")
            try:
                address = str(ipaddress.ip_address(forwarded))
            except ValueError:
                pass
        return address + "|" + username.lower()

    def do_GET(self):
        self.dispatch("GET")

    def do_HEAD(self):
        self.dispatch("HEAD")

    def do_POST(self):
        self.dispatch("POST")

    def do_DELETE(self):
        self.dispatch("DELETE")

    def dispatch(self, method):
        try:
            parsed = self.validate_request()
            path, store = parsed.path, self.server.store
            if path in ("/api/agent/sync", "/api/agent/activity", "/api/admin/overview", "/api/admin/activity"):
                store.maintain()
            if method in ("GET", "HEAD"):
                if path == "/healthz":
                    return self.respond(200, {"ok": True, "version": VERSION})
                if path in ("/", "/login"):
                    return self.respond(200, HTML.encode("utf-8"), content_type="text/html; charset=utf-8")
                if path == "/assets/app.css":
                    return self.respond(200, CSS.encode("utf-8"), content_type="text/css; charset=utf-8")
                if path == "/assets/app.js":
                    return self.respond(200, JS.encode("utf-8"), content_type="text/javascript; charset=utf-8")
                if path == "/favicon.svg":
                    return self.respond(200, SITE_ICON_SVG.encode("utf-8"), content_type="image/svg+xml")
                if path == "/favicon.ico":
                    return self.respond(200, SITE_ICON_ICO, content_type="image/x-icon")
                subscription = re.fullmatch(r"/sub/([A-Za-z0-9_-]{43})(?:/(clash|v2ray))?/?", path)
                if subscription:
                    token, kind = subscription.groups()
                    formats = urllib.parse.parse_qs(parsed.query, keep_blank_values=True).get("format", [])
                    if len(formats) > 1 or (kind and formats and formats[0] != kind):
                        raise APIError(400, "请只指定一种订阅格式")
                    kind = kind or (formats[0] if formats else None)
                    body, content_type, headers = store.subscription(token, kind, self.headers.get("User-Agent", ""), self.headers.get("Accept", ""))
                    return self.respond(200, body, headers, content_type)
                session = self.admin()
                if path == "/api/admin/session":
                    return self.respond(200, {"username": session["username"], "csrf": session["csrf"], "version": VERSION, "origin": self.server.origin})
                if path == "/api/admin/overview":
                    return self.respond(200, store.overview())
                if path == "/api/admin/users":
                    query = urllib.parse.parse_qs(parsed.query)
                    return self.respond(200, store.list_users(query.get("month", [None])[0]))
                match = re.fullmatch(r"/api/admin/users/(u_[0-9a-f]{32})", path)
                if match:
                    return self.respond(200, store.user_detail(match[1]))
                match = re.fullmatch(r"/api/admin/users/(u_[0-9a-f]{32})/subscription", path)
                if match:
                    return self.respond(200, store.subscription_info(match[1]))
                if path == "/api/admin/nodes":
                    return self.respond(200, store.list_nodes())
                if path == "/api/admin/subscriptions":
                    return self.respond(200, store.list_subscriptions())
                if path == "/api/admin/activity":
                    return self.respond(200, store.activity(urllib.parse.parse_qs(parsed.query)))
                if path == "/api/admin/logs":
                    return self.respond(200, store.logs())
                if path == "/api/admin/settings":
                    return self.respond(200, store.settings())
                if path == "/api/admin/traffic":
                    query = urllib.parse.parse_qs(parsed.query)
                    try:
                        days = int(query.get("days", ["30"])[0])
                    except ValueError:
                        raise APIError(400, "日期范围不合法")
                    return self.respond(200, store.traffic(query.get("user_id", [None])[0], query.get("node_id", [None])[0], days, query.get("month", [None])[0]))
                if path == "/api/admin/backup":
                    with store.backup() as backup_path:
                        return self.respond_file(backup_path, "ysq-center-backup-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S") + ".db")
                raise APIError(404, "接口不存在")
            data = self.body()
            if path == "/api/auth/login" and method == "POST":
                self.require_origin()
                username = text_value(data.get("username"), "管理员名称", 1, 64)
                password = data.get("password")
                if not isinstance(password, str) or not 1 <= len(password) <= 256:
                    raise APIError(400, "请输入有效密码")
                key = self.client_key(username)
                self.server.login_limiter.check(key)
                if not self.server.password_slots.acquire(blocking=False):
                    raise APIError(429, "正在处理其他登录请求，请稍后重试")
                try:
                    token, value = store.login(username, password)
                except APIError:
                    self.server.login_limiter.fail(key)
                    raise
                finally:
                    self.server.password_slots.release()
                self.server.login_limiter.success(key)
                return self.respond(200, value, {"Set-Cookie": self.cookie_header(token)})
            if method == "POST" and path == "/api/agent/register":
                return self.respond(200, store.register(data))
            if method == "POST" and path == "/api/agent/sync":
                return self.respond(200, store.sync(data, self.token()))
            if method == "POST" and path == "/api/agent/activity":
                return self.respond(200, store.ingest_activity(data, self.token()))
            if method == "POST" and path == "/api/agent/wait":
                token = self.token()
                # Authenticate before dedicating a long-lived notification slot.
                with store.connect() as db:
                    store._authenticated_node(db, data.get("node_id"), token)
                if not self.server.wait_slots.acquire(blocking=False):
                    raise APIError(429, "变更通知连接已满，请稍后重试")
                self.server.release_worker_slot()
                try:
                    return self.respond(200, store.wait_for_changes(data, token))
                finally:
                    self.server.wait_slots.release()
            if method == "POST" and path == "/api/agent/detach":
                return self.respond(200, store.detach(data, self.token()))
            session = self.admin(mutate=True)
            actor = session["username"]
            if method == "POST" and path == "/api/auth/logout":
                store.logout(self.cookie_token())
                return self.respond(200, {"ok": True}, {"Set-Cookie": self.cookie_header("", clear=True)})
            if method == "POST" and path == "/api/admin/password":
                old = data.get("old_password")
                if not isinstance(old, str) or len(old) > 256:
                    raise APIError(400, "当前密码格式不正确")
                store.change_password(actor, old, data.get("new_password"))
                return self.respond(200, {"ok": True}, {"Set-Cookie": self.cookie_header("", clear=True)})
            if method == "POST" and path == "/api/admin/settings":
                return self.respond(200, store.save_settings(data, actor))
            if method == "POST" and path == "/api/admin/nodes":
                return self.respond(201, store.create_node(data.get("name"), actor))
            match = re.fullmatch(r"/api/admin/nodes/(n_[0-9a-f]{32})", path)
            if match and method == "POST":
                return self.respond(200, store.rename_node(match[1], data.get("name"), actor))
            if match and method == "DELETE":
                return self.respond(200, store.delete_node(match[1], actor))
            match = re.fullmatch(r"/api/admin/nodes/(n_[0-9a-f]{32})/(approve|revoke|join-code)", path)
            if match and method == "POST":
                function = {"approve": store.approve_node, "revoke": store.revoke_node, "join-code": store.reissue_join}[match[2]]
                return self.respond(200, function(match[1], actor))
            if method == "POST" and path == "/api/admin/users":
                return self.respond(201, store.save_user(data, actor))
            match = re.fullmatch(r"/api/admin/users/(u_[0-9a-f]{32})/subscription", path)
            if match and method == "POST":
                reset = boolean(data.get("reset", False), "重置订阅链接")
                return self.respond(200, store.subscription_info(match[1], actor, reset, data))
            match = re.fullmatch(r"/api/admin/users/(u_[0-9a-f]{32})", path)
            if match and method == "POST":
                return self.respond(200, store.save_user(data, actor, match[1]))
            if match and method == "DELETE":
                return self.respond(200, store.delete_user(match[1], actor))
            raise APIError(404, "接口不存在")
        except APIError as exc:
            headers = {"Retry-After": "60"} if exc.status == 429 else None
            value = {"error": exc.message}
            if exc.status == 410:
                value.update(protocol=PROTOCOL, detached=True)
            self.respond(exc.status, value, headers)
        except (BrokenPipeError, ConnectionResetError, TimeoutError, socket.timeout):
            self.close_connection = True
        except sqlite3.IntegrityError:
            self.respond(409, {"error": "资料冲突，请刷新后重试"})
        except sqlite3.OperationalError:
            LOG.exception("数据库操作失败")
            self.respond(503, {"error": "数据库暂时不可用，请稍后重试；原请求可安全重试"})
        except Exception:
            LOG.exception("处理请求失败")
            self.respond(500, {"error": "服务暂时异常，请查看中控服务日志"})

# YSQ_CENTER_STDLIB_V1
SITE_ICON_SVG = r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <defs>
    <linearGradient id="blue" x1="32" y1="2" x2="32" y2="62" gradientUnits="userSpaceOnUse">
      <stop stop-color="#3978F6"/>
      <stop offset="1" stop-color="#2354D4"/>
    </linearGradient>
  </defs>
  <rect x="2" y="2" width="60" height="60" rx="17" fill="url(#blue)"/>
  <path d="M41.7061 20.1097 A16 16 0 1 0 41.7061 43.8903" stroke="white" stroke-width="7" stroke-linecap="round"/>
  <circle cx="45" cy="32" r="4" fill="#BFD7FF"/>
</svg>'''
SITE_ICON_ICO = base64.b64decode(
    "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"
    "So8b7udtREBi+fC5PulhQgi3h3TAywuaUraJa5zDX65pc0Zwf8BrbCT3C2wo44CPaUs6XYOkhXSZ+itShENnR1edl8PDkJPj"
    "Q9Ok1G7ppiSRUMTc2VYyjFhmQkY0d0C5jEQ6LkzzwVf+zuvMorzPILyj7IiUIUzpZaTWwSOsvNGW8y8TcjAu1PLtb//Mjfc9"
    "rgJmvSji/lyAFrXoVzOIDxlibLuu42cR1WafmBxb9UhTpzS7+GfS8JgzOfbpPWH10ncJctaJ9brSSTgQHpPp/zG5VDzBMlgW"
    "IPNRLb/LKh8zyhsYaBvmwXZ1w72nrvVjS3ZAq60g/QkCpWAa1qsYtrmuQLrvQIijUpV+d2587QfYSxLdfpzOG2FD0/z6yQem"
    "M0GlkNSqenUGcDfl+5XJ0SE+8LvK5sX/Av5mxiEDrM+tAAAAAElFTkSuQmCCiVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYA"
    "AABXAvmHAAAL/klEQVR4nMVaCWwc1Rn+3puZPb0+cmLnPgjEIVWTQESKkElpC5SrBxuOqhRoE1o1FLVVVIFK3YgzQhRSpHJI"
    "oBKhEGJUSmlLUbncADlEOELAAZxQCIlTHB+73nvmvVf9b2Z2N/bau+b8o9F6d2be+/7///7jvRegmrQr3tauTHzB0kZztite"
    "7Tk2+i3F4nHwjg4m6Nupv1RhVmefBKlOhBAtAAKfKWLOC5yxI4yzfclM3949dzSn6ed4XBkdHZAAU7UrQJqvZ5L+XH5drtXk"
    "7GolcQHjxmzDMsZU+1OJAqQtIaV9kHH2pOPY9+/aUPfGcExjKtDervj69Uy2/ej9UL7luBsZ2DVGIBgUBQdK5JQCE1AVjfHp"
    "hTEwKIMZQWYELEi7YCup7k0kE9e//aepKdcbLiMqKuCDX/Lr/lnBQKTDDARPcbJpKKUccjIDOE3yeYtSUoEMBZhWpA4in98j"
    "Rf6inbc3vBePbzU6OlYVlSih8Vy07Bf9M61IpJObwdkil7TBmKlN82WJUrYRjFnSyfeobLJt5x+nvFdOJ1YesB+3wsqmUy+Z"
    "wbqlTi5pM8YtTcwvVRikEo4VrDedQqYrHI0uPwPIrP89FBhz05SfbTLJxI1WuG6pk03YALOUkprutV7M5xn3Pv2Ll3w4nvGU"
    "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"
    "RK5CYII="
)

HTML = r'''<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light">
  <meta name="theme-color" content="#ffffff">
  <title>Center Panel</title>
  <link rel="icon" href="/favicon.ico?v=5" sizes="16x16 32x32 48x48 64x64">
  <link rel="icon" type="image/svg+xml" href="/favicon.svg?v=5" sizes="any">
  <link rel="stylesheet" href="/assets/app.css">
  <script src="/assets/app.js" defer></script>
</head>
<body>
  <section id="login" class="login-page" hidden>
    <div class="login-side">
      <form id="login-form" class="login-card">
        <div class="brand"><span class="brand-mark" aria-hidden="true"><img src="/favicon.svg?v=5" width="40" height="40" alt=""></span><span>Center<b>Panel</b></span></div>
        <h2>登录</h2>
        <label>管理员账号
          <input name="username" autocomplete="username" required maxlength="64" placeholder="请输入管理员账号">
        </label>
        <label>密码
          <input name="password" type="password" autocomplete="current-password" required maxlength="256" placeholder="请输入密码">
        </label>
        <p id="login-error" class="form-error" role="alert"></p>
        <button class="primary wide" type="submit">登录</button>
        <p class="login-note">忘记密码？请在服务器端重置。</p>
      </form>
    </div>
  </section>

  <div id="app" class="app" hidden>
    <aside class="sidebar">
      <a href="#overview" class="brand" aria-label="Center Panel 总览">
        <span class="brand-mark" aria-hidden="true"><img src="/favicon.svg?v=5" width="40" height="40" alt=""></span>
        <span>Center<b>Panel</b></span>
      </a>
      <div class="nav-heading">工作空间</div>
      <nav id="nav" aria-label="主导航">
        <button type="button" data-view="overview" class="nav-item active">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3.5" y="3.5" width="6.5" height="6.5" rx="1.5"/><rect x="14" y="3.5" width="6.5" height="6.5" rx="1.5"/><rect x="3.5" y="14" width="6.5" height="6.5" rx="1.5"/><rect x="14" y="14" width="6.5" height="6.5" rx="1.5"/></svg>
          <span class="nav-label">总览</span>
        </button>
        <button type="button" data-view="users" class="nav-item">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="9" cy="8" r="3.25"/><path d="M3 20v-2a6 6 0 0 1 12 0v2M16 5a3.25 3.25 0 0 1 0 6.5M17.5 14a5 5 0 0 1 3.5 4.75V20"/></svg>
          <span class="nav-label">用户管理</span>
        </button>
        <button type="button" data-view="nodes" class="nav-item">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3.5" y="3.5" width="17" height="7" rx="2"/><rect x="3.5" y="13.5" width="17" height="7" rx="2"/><path d="M7 7h.01M7 17h.01M11 7h6M11 17h6"/></svg>
          <span class="nav-label">服务器</span>
        </button>
        <button type="button" data-view="subscriptions" class="nav-item">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m10 13 4-4M8 16l-1 1a4.25 4.25 0 0 1-6-6l4-4a4.25 4.25 0 0 1 6 0M16 8l1-1a4.25 4.25 0 0 1 6 6l-4 4a4.25 4.25 0 0 1-6 0" transform="translate(1 -1) scale(.92)"/></svg>
          <span class="nav-label">订阅</span>
        </button>
        <button type="button" data-view="activity" class="nav-item">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 12h4l3-8 4 16 3-8h4"/></svg>
          <span class="nav-label">行为分析</span>
        </button>
        <button type="button" data-view="logs" class="nav-item">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="5" y="3" width="14" height="18" rx="2"/><path d="M9 8h6M9 12h6M9 16h4"/></svg>
          <span class="nav-label">操作记录</span>
        </button>
        <button type="button" data-view="settings" class="nav-item">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 7h7M15 7h5M4 17h3M11 17h9"/><circle cx="13" cy="7" r="2"/><circle cx="9" cy="17" r="2"/></svg>
          <span class="nav-label">设置</span>
        </button>
      </nav>
      <div class="sidebar-bottom">
        <div class="connected"><i aria-hidden="true"></i>中控已连接</div>
        <div id="sidebar-origin" class="sidebar-origin"></div>
        <div class="sidebar-version">Center Panel <span id="version"></span></div>
      </div>
    </aside>

    <main class="main">
      <header class="topbar">
        <div class="breadcrumbs"><span class="breadcrumb">工作台</span><span class="breadcrumb-slash" aria-hidden="true">/</span><span id="crumb">总览</span></div>
        <div class="top-actions">
          <span id="clock" class="muted"></span>
          <span id="account" class="account"></span>
          <button type="button" id="logout" class="text-button">退出</button>
        </div>
      </header>
      <div class="workspace">
        <div class="page-head">
          <div>
            <h1 id="page-title">运行总览</h1>
          </div>
          <div id="page-actions" class="page-actions"></div>
        </div>
        <div id="notice" class="notice" role="status" hidden></div>
        <div id="filter-bar" class="filter-bar" hidden>
          <label class="search-label">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4 4"/></svg>
            <input id="search" placeholder="搜索名称、服务器…" aria-label="搜索名称或服务器">
          </label>
          <label id="month-filter" class="month-picker" hidden>统计月份<select id="user-month" aria-label="用户统计月份"></select></label>
        </div>
        <div id="content"></div>
        <footer class="page-footer">
          <span id="last-refresh">正在获取数据</span>
        </footer>
      </div>
    </main>
  </div>

  <div id="loading" class="loading" role="status">
    <span class="brand-mark" aria-hidden="true"><img src="/favicon.svg?v=5" width="40" height="40" alt=""></span>
    <p>正在连接中控…</p>
  </div>
  <dialog id="modal" aria-labelledby="modal-title">
    <div class="modal-header">
      <div>
        <h2 id="modal-title"></h2>
      </div>
      <button type="button" id="close-modal" class="icon-button" aria-label="关闭">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><path d="m6 6 12 12M18 6 6 18"/></svg>
      </button>
    </div>
    <div id="modal-body"></div>
  </dialog>
  <div id="toast" role="status" aria-live="polite" hidden></div>
</body>
</html>'''

CSS = r'''
:root {
  --bg: #ffffff;
  --panel: #ffffff;
  --ink: #202124;
  --muted: #6b7280;
  --line: #e5e7eb;
  --accent: #2563eb;
  --accent-soft: #f1f5ff;
  --blue: var(--accent);
  --blue-soft: var(--accent-soft);
  --green: #17805c;
  --red: #b85c57;
  --amber: #a9803c;
  --navy: #202124;
  --radius: 14px;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC",
  "Microsoft YaHei", sans-serif;
  color: var(--ink);
  font-size: 14px;
  font-synthesis: none;
  font-variant-numeric: tabular-nums;
  -webkit-font-smoothing: antialiased;
}

* {
  box-sizing: border-box;
}

[hidden] {
  display: none !important;
}

body {
  margin: 0;
  background: var(--bg);
}

button, input, select {
  font: inherit;
}

button, a, input, select {
  -webkit-tap-highlight-color: transparent;
}

button, input, select {
  min-width: 0;
}

button, a, input, select, summary {
  touch-action: manipulation;
}

button {
  padding: 10px 15px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--panel);
  color: var(--ink);
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  transition: background 160ms ease, border-color 160ms ease, color 160ms ease;
}

button:hover {
  background: #f3f3f3;
  border-color: #d6d6d6;
}

button:disabled {
  opacity: .5;
  cursor: wait;
}

button:focus-visible, a:focus-visible, input:focus-visible, select:focus-visible {
  outline: 3px solid #93b4fa;
  outline-offset: 3px;
}

a {
  color: var(--accent);
  text-decoration: none;
}

a:hover {
  color: #1d4ed8;
}

svg {
  display: block;
  flex-shrink: 0;
}

input, select {
  width: 100%;
  padding: 11px 13px;
  border: 1px solid #e0e0e0;
  border-radius: 8px;
  background: #fff;
  color: var(--ink);
  outline: none;
  transition: border-color 160ms ease, box-shadow 160ms ease;
}

input::placeholder {
  color: #a3a3a3;
}

input:focus, select:focus {
  border-color: #8aaef0;
  box-shadow: 0 0 0 3px #2563eb14;
}

label {
  display: block;
  font-size: 12px;
  font-weight: 600;
}

label > input, label > select {
  margin-top: 9px;
}

h1, h2, h3, p {
  margin: 0;
}

h1 {
  font-size: 30px;
  letter-spacing: -1px;
  font-weight: 650;
  line-height: 1.35;
}

h2 {
  font-size: 24px;
  letter-spacing: -.6px;
  font-weight: 650;
}

h3 {
  font-size: 15px;
  font-weight: 650;
}

p {
  line-height: 1.8;
}

strong, b {
  font-weight: 650;
}

.muted {
  color: var(--muted);
  font-weight: 400;
}

.small {
  font-size: 11px;
}

.mono {
  font-family: ui-monospace, SFMono-Regular, Consolas, monospace;
  font-size: 11px;
}

.eyebrow {
  color: var(--accent);
  font-size: 10px;
  font-weight: 650;
  letter-spacing: 2px;
}

.wide {
  width: 100%;
}

.primary {
  background: var(--accent);
  border-color: var(--accent);
  color: #fff;
}

.primary:hover {
  background: #1d4ed8;
  border-color: #1d4ed8;
}

.danger {
  background: #fcf4f2;
  border-color: #f0ded9;
  color: var(--red);
}

.danger:hover {
  background: #f7e9e5;
  border-color: #e7c7c0;
}

.text-button {
  padding: 7px 9px;
  background: transparent;
  border-color: transparent;
  color: var(--muted);
  font-weight: 500;
}

.text-button:hover {
  background: var(--accent-soft);
  border-color: transparent;
  color: var(--accent);
}

.inline-link {
  color: var(--accent);
  font-size: 12px;
  text-underline-offset: 4px;
}

.inline-link:hover {
  text-decoration: underline;
}

.red-text {
  color: var(--red);
}

.brand {
  display: flex;
  align-items: center;
  gap: 12px;
  width: fit-content;
  color: var(--ink);
  font-size: 23px;
  font-weight: 700;
  letter-spacing: 1px;
}

.brand b {
  display: block;
  margin-top: 3px;
  color: var(--muted);
  font-size: 8px;
  font-weight: 500;
  letter-spacing: 1.65px;
}

.brand-mark {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  width: 40px;
  height: 42px;
  border: 1px solid #e4e4e4;
  border-radius: 11px;
  background: var(--accent-soft);
  color: var(--accent);
}

.brand-mark svg {
  width: 26px;
  height: 26px;
}

.app {
  display: flex;
  min-height: 100vh;
}

.sidebar {
  position: fixed;
  inset: 0 auto 0 0;
  z-index: 10;
  display: flex;
  flex-direction: column;
  width: 240px;
  padding: 35px 23px 25px;
  border-right: 1px solid var(--line);
  background: #ffffff;
}

.sidebar .brand {
  margin-left: 8px;
}

.nav-heading {
  margin: 54px 14px 13px;
  color: #a0a0a0;
  font-size: 10px;
  letter-spacing: 2px;
}

.nav-item {
  display: flex;
  align-items: center;
  gap: 13px;
  width: 100%;
  margin: 5px 0;
  padding: 13px 14px;
  border: 1px solid transparent;
  border-radius: 8px;
  background: transparent;
  color: #7d7d7d;
  text-align: left;
  font-size: 13px;
  font-weight: 500;
}

.nav-item svg {
  width: 19px;
  height: 19px;
}

.nav-item:hover {
  background: #f3f3f3;
  border-color: transparent;
  color: var(--ink);
}

.nav-item.active {
  background: #f1f5ff;
  border-color: #e4eafe;
  color: #1d4ed8;
  font-weight: 650;
}

.nav-label {
  line-height: 1.3;
}

.sidebar-bottom {
  margin-top: auto;
  padding: 23px 12px 0;
}

.connected {
  display: flex;
  align-items: center;
  gap: 8px;
  color: #696969;
  font-size: 11px;
}

.connected i {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: #909090;
  box-shadow: 0 0 0 3px #f2f2f2;
}

.sidebar-origin {
  margin: 11px 0 15px;
  color: #989898;
  font-size: 10px;
  line-height: 1.6;
  overflow-wrap: anywhere;
}

.sidebar-version {
  padding-top: 15px;
  border-top: 1px solid var(--line);
  color: #a6a6a6;
  font-size: 10px;
  letter-spacing: .5px;
}

.sidebar-version span {
  margin-left: 6px;
}

.main {
  width: calc(100% - 240px);
  min-width: 0;
  margin-left: 240px;
}

.topbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 20px;
  height: 76px;
  padding: 0 42px;
  border-bottom: 1px solid var(--line);
  background: #ffffff;
  font-size: 11px;
}

.breadcrumbs {
  display: flex;
  align-items: center;
  flex-shrink: 0;
}

.breadcrumb {
  color: #9a9a9a;
}

.breadcrumb-slash {
  margin: 0 14px;
  color: #c3c3c3;
}

#crumb {
  color: #646464;
}

.top-actions {
  display: flex;
  align-items: center;
  gap: 18px;
  min-width: 0;
}

#clock {
  font-size: 10px;
  letter-spacing: .25px;
}

.account {
  max-width: 160px;
  padding: 6px 11px;
  overflow: hidden;
  border: 1px solid #e7e7e7;
  border-radius: 6px;
  background: #f3f3f3;
  color: #717171;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.workspace {
  width: 100%;
  max-width: 1480px;
  margin: 0 auto;
  padding: 40px 42px 22px;
}

.page-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 24px;
  margin-bottom: 32px;
}

.page-head > div:first-child {
  min-width: 0;
}

.page-head h1 {
  margin: 10px 0 8px;
}

.page-head p {
  font-size: 12px;
}

.page-actions {
  display: flex;
  flex-shrink: 0;
  gap: 9px;
}

.page-actions button {
  white-space: nowrap;
}

#content {
  min-width: 0;
}

.cards {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 16px;
  margin-bottom: 24px;
}

.card {
  min-width: 0;
  padding: 23px;
  border: 1px solid var(--line);
  border-radius: var(--radius);
  background: var(--panel);
  box-shadow: 0 2px 3px #33333302;
}

.metric-title {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  color: #7d7d7d;
  font-size: 11px;
}

.metric-icon {
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  width: 28px;
  height: 28px;
  border: 1px solid #ececec;
  border-radius: 8px;
  background: #f8f8f8;
  color: #929292;
  font-size: 16px;
}

.metric-icon svg {
  width: 16px;
  height: 16px;
}

.metric-value {
  margin: 20px 0 15px;
  color: #383838;
  font-size: clamp(25px, 2.25vw, 35px);
  font-weight: 600;
  letter-spacing: -1.3px;
  line-height: 1.15;
}

.metric-value small {
  margin-left: 6px;
  color: #919191;
  font-size: 12px;
  font-weight: 400;
  letter-spacing: 0;
}

.metric-note {
  color: #919191;
  font-size: 10px;
  line-height: 1.7;
}

.metric-note strong {
  color: #737373;
  font-weight: 500;
}

.metric-primary {
  border-color: #e5e7eb;
  background: #ffffff;
}

.metric-primary .metric-value {
  color: #202124;
}

.metric-primary .metric-icon {
  border-color: #e4e4e4;
  background: #eeeeee;
  color: #787878;
}

.section-grid {
  display: grid;
  grid-template-columns: minmax(0, 1.8fr) minmax(260px, 1fr);
  gap: 22px;
  margin-bottom: 24px;
}

.card-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  margin-bottom: 20px;
}

.card-head > div {
  min-width: 0;
}

.card-head p {
  margin-top: 6px;
  color: var(--muted);
  font-size: 10px;
}

.card-head select {
  width: auto;
  margin: 0;
  padding: 7px 10px;
  font-size: 11px;
}

.chart-summary {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 8px 12px;
  margin-bottom: 16px;
}

.chart-summary strong {
  color: #202124;
  font-size: 26px;
  font-weight: 600;
  letter-spacing: -.9px;
}

.chart-summary span {
  color: var(--muted);
  font-size: 10px;
  line-height: 1.7;
}

.chart {
  display: block;
  width: 100%;
  height: auto;
  overflow: visible;
}

.chart-empty {
  padding: 45px 0;
  color: var(--muted);
  text-align: center;
}

.chart-labels {
  display: flex;
  justify-content: space-between;
  gap: 4px;
  margin-top: 12px;
  color: #a0a0a0;
  font-size: 9px;
}

.chart-legend {
  display: flex;
  align-items: center;
  flex-shrink: 0;
  gap: 7px;
  color: #8d8d8d;
  font-size: 10px;
}

.chart-legend i {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--accent);
}

.mini-stat {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 16px 0;
  border-bottom: 1px solid #efefef;
  font-size: 11px;
}

.mini-stat:last-child {
  border-bottom: 0;
  padding-bottom: 2px;
}

.mini-stat strong {
  font-size: 18px;
  font-weight: 600;
}

.status-row {
  display: flex;
  align-items: center;
  gap: 10px;
  color: #747474;
}

.status-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--green);
}

.status-dot.amber {
  background: var(--amber);
}

.status-dot.red {
  background: var(--red);
}

.section-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 15px;
  margin: 29px 0 14px;
}

.section-header span {
  color: var(--muted);
  font-size: 11px;
}

.table-card {
  padding: 0;
  overflow: hidden;
}

.table-scroll {
  max-width: 100%;
  overflow: auto;
  scrollbar-width: thin;
  scrollbar-color: #d4d4d4 transparent;
}

table {
  width: 100%;
  border-collapse: collapse;
  text-align: left;
  font-size: 12px;
  white-space: nowrap;
}

th {
  padding: 15px 22px;
  border-bottom: 1px solid var(--line);
  background: #ffffff;
  color: #929292;
  font-size: 10px;
  font-weight: 500;
  letter-spacing: .4px;
}

td {
  padding: 19px 22px;
  border-bottom: 1px solid #efefef;
  color: #666666;
}

tr:last-child td {
  border-bottom: 0;
}

tbody tr:hover {
  background: #fbfbfb;
}

.cell-title {
  margin-bottom: 5px;
  color: #444444;
  font-size: 12px;
  font-weight: 600;
}

.cell-sub {
  color: #a7a7a7;
  font-size: 10px;
  letter-spacing: .1px;
}

.avatar {
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  width: 34px;
  height: 34px;
  margin-right: 12px;
  border: 1px solid #eaeaea;
  border-radius: 10px;
  background: #f3f3f3;
  color: #7b7b7b;
  font-size: 12px;
  font-weight: 650;
}

.user-cell {
  display: flex;
  align-items: center;
}

.badge {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  padding: 4px 7px;
  border: 1px solid #eaeaea;
  border-radius: 5px;
  background: #f4f4f4;
  color: #7a7a7a;
  font-size: 10px;
  font-weight: 500;
  white-space: nowrap;
}

.badge:before {
  display: inline-block;
  width: 4px;
  height: 4px;
  border-radius: 50%;
  background: currentColor;
  content: "";
}

.badge.amber {
  border-color: #efe6ce;
  background: #faf6eb;
  color: #aa8843;
}

.badge.red {
  border-color: #f0deda;
  background: #fcf2ef;
  color: #b57162;
}

.badge.gray {
  border-color: #e9e9e9;
  background: #f4f4f4;
  color: #979797;
}

.badge.blue {
  border-color: #e5e5e5;
  background: #f3f3f3;
  color: #7f7f7f;
}

.node-tags {
  display: flex;
  flex-wrap: wrap;
  gap: 5px;
  max-width: 230px;
}

.tag {
  display: inline-block;
  max-width: 100%;
  padding: 4px 7px;
  overflow: hidden;
  border: 1px solid #ebebeb;
  border-radius: 5px;
  background: #f8f8f8;
  color: #939393;
  font-size: 10px;
  text-overflow: ellipsis;
}

.table-actions {
  display: flex;
  gap: 2px;
}

.table-actions button {
  padding: 6px 8px;
  border-color: transparent;
  background: transparent;
  color: #777777;
  font-size: 11px;
}

.table-actions button:hover {
  background: #f2f2f2;
}

.table-actions button.red {
  color: var(--red);
}

.empty {
  padding: 56px 25px;
  text-align: center;
}

.empty-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 48px;
  height: 48px;
  margin-bottom: 17px;
  border: 1px solid #e6e6e6;
  border-radius: 13px;
  background: #f3f3f3;
  color: #8e8e8e;
  font-size: 22px;
}

.empty h3 {
  font-size: 14px;
}

.empty p {
  margin: 9px 0 20px;
  color: var(--muted);
  font-size: 12px;
}

.filter-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 20px;
  margin-bottom: 20px;
}

.search-label {
  position: relative;
  width: min(340px, 100%);
}

.search-label svg {
  position: absolute;
  top: 13px;
  left: 13px;
  width: 16px;
  height: 16px;
  color: #9f9f9f;
  pointer-events: none;
}

.search-label input {
  margin: 0;
  padding: 12px 13px 12px 39px;
  font-size: 12px;
}

.checkbox-label {
  display: flex;
  align-items: center;
  gap: 8px;
  color: var(--muted);
  font-size: 11px;
  font-weight: 400;
}

.checkbox-label input {
  flex-shrink: 0;
  width: 15px;
  height: 15px;
  margin: 0;
  accent-color: var(--accent);
}

.notice {
  margin-bottom: 22px;
  padding: 12px 16px;
  border: 1px solid #e9dfc5;
  border-radius: 9px;
  background: #faf7ed;
  color: #967b48;
  font-size: 12px;
  line-height: 1.8;
  overflow-wrap: anywhere;
}

.notice.error {
  border-color: #edd9d5;
  background: #fbf2ef;
  color: #ad6a5e;
}

.page-footer {
  display: flex;
  justify-content: space-between;
  gap: 20px;
  margin-top: 27px;
  padding: 13px 0 6px;
  color: #a6a6a6;
  font-size: 10px;
  line-height: 1.6;
}

.node-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(285px, 100%), 1fr));
  gap: 20px;
}

.node-card .card-head {
  align-items: flex-start;
}

.node-name {
  color: #454545;
  font-size: 16px;
  font-weight: 600;
  overflow-wrap: anywhere;
}

.node-id {
  margin-top: 7px;
  color: #a7a7a7;
  font-size: 10px;
  overflow-wrap: anywhere;
}

.node-metrics {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 15px;
  margin: 23px 0;
}

.node-metrics span {
  color: var(--muted);
  font-size: 10px;
}

.node-metrics strong {
  display: block;
  margin-top: 8px;
  color: #585858;
  font-size: 22px;
  font-weight: 550;
  letter-spacing: -.5px;
}

.node-line {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 15px;
  margin: 12px 0;
  color: var(--muted);
  font-size: 11px;
  line-height: 1.6;
}

.node-line > span {
  flex-shrink: 0;
}

.node-line b {
  min-width: 0;
  color: #717171;
  font-weight: 500;
  text-align: right;
  overflow-wrap: anywhere;
}

.node-buttons {
  display: flex;
  flex-wrap: wrap;
  gap: 7px;
  margin-top: 20px;
  padding-top: 18px;
  border-top: 1px solid var(--line);
}

.node-buttons button {
  padding: 8px 10px;
  font-size: 11px;
}

.node-error {
  max-height: 120px;
  margin-top: 13px;
  padding: 11px;
  overflow: auto;
  border: 1px solid #f0dfd8;
  border-radius: 7px;
  background: #fcf4f0;
  color: #ad7662;
  font-size: 11px;
  line-height: 1.7;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}

.settings-grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  align-items: start;
  gap: 23px;
}

.settings-grid form {
  display: grid;
  gap: 19px;
}

.settings-grid .card-head {
  margin-bottom: 25px;
}

.settings-grid p {
  font-size: 12px;
}

.settings-grid label {
  font-size: 12px;
}

.form-footer {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: flex-end;
  gap: 9px;
  margin-top: 8px;
  padding-top: 21px;
  border-top: 1px solid var(--line);
}

.form-grid {
  display: grid;
  min-width: 0;
  gap: 21px;
}

.form-row {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: 17px;
}

.form-help {
  margin-top: 8px;
  color: var(--muted);
  font-size: 11px;
  font-weight: 400;
  line-height: 1.8;
  overflow-wrap: anywhere;
}

.form-error {
  min-height: 18px;
  color: var(--red);
  font-size: 12px;
  overflow-wrap: anywhere;
}

.password-wrap {
  display: flex;
  align-items: end;
  gap: 7px;
  min-width: 0;
}

.password-wrap input {
  flex: 1;
  min-width: 0;
  margin-top: 9px;
}

.password-wrap button {
  flex-shrink: 0;
  padding: 11px 10px;
  font-size: 11px;
}

.node-choice {
  display: grid;
  gap: 8px;
  max-height: 190px;
  margin-top: 11px;
  overflow: auto;
}

.node-choice label {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 11px 12px;
  border: 1px solid #eaeaea;
  border-radius: 8px;
  background: #f9f9f9;
  font-size: 12px;
  font-weight: 400;
  overflow-wrap: anywhere;
}

.node-choice input {
  flex-shrink: 0;
  width: 16px;
  height: 16px;
  margin: 0;
  accent-color: var(--accent);
}

.node-choice small {
  margin-left: auto;
  color: var(--muted);
  white-space: nowrap;
}

.inline-note {
  padding: 13px 15px;
  border: 1px solid #e8e8e8;
  border-radius: 8px;
  background: #f6f6f6;
  color: #808080;
  font-size: 11px;
  line-height: 1.9;
  overflow-wrap: anywhere;
}

.code-box {
  padding: 15px;
  border: 1px dashed #d0d0d0;
  border-radius: 9px;
  background: #f9f9f9;
  font-family: ui-monospace, SFMono-Regular, Consolas, monospace;
  font-size: 12px;
  line-height: 1.9;
  overflow-wrap: anywhere;
  user-select: all;
}

.copy-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 10px;
  font-size: 12px;
}

.copy-row button {
  padding: 7px 10px;
  font-size: 11px;
}

.steps {
  margin: 0;
  padding-left: 21px;
  color: #868686;
  font-size: 12px;
  line-height: 2.1;
}

.detail-metrics {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 14px;
  margin-bottom: 27px;
}

.detail-metrics > div {
  min-width: 0;
  padding: 17px;
  border: 1px solid #ebebeb;
  border-radius: 10px;
  background: #f8f8f8;
}

.detail-metrics span {
  color: var(--muted);
  font-size: 10px;
}

.detail-metrics strong {
  display: block;
  margin-top: 10px;
  color: #606060;
  font-size: 22px;
  font-weight: 600;
  letter-spacing: -.5px;
  overflow-wrap: anywhere;
}

.truncate {
  max-width: 160px;
  overflow: hidden;
  text-overflow: ellipsis;
}

.log-action {
  color: #7f7f7f;
  font-family: ui-monospace, SFMono-Regular, Consolas, monospace;
  font-size: 11px;
}

.log-detail {
  min-width: 210px;
  white-space: normal;
  line-height: 1.8;
  overflow-wrap: anywhere;
}

dialog {
  width: min(600px, calc(100% - 32px));
  max-height: 90vh;
  max-height: 90dvh;
  padding: 29px;
  border: 1px solid #e2e2e2;
  border-radius: 16px;
  background: #fff;
  color: var(--ink);
  box-shadow: 0 24px 100px #33333330;
}

dialog.large {
  width: min(880px, calc(100% - 32px));
}

dialog::backdrop {
  background: #11182754;
  backdrop-filter: blur(3px);
}

.modal-header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 18px;
  margin-bottom: 27px;
}

.modal-header > div {
  min-width: 0;
}

.modal-header h2 {
  margin-top: 9px;
  font-size: 21px;
  overflow-wrap: anywhere;
}

.icon-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  width: 32px;
  height: 32px;
  padding: 0;
  border-radius: 8px;
  background: #f8f8f8;
  color: #9b9b9b;
}

.icon-button svg {
  width: 17px;
  height: 17px;
}

.loading {
  display: flex;
  align-items: center;
  justify-content: center;
  flex-direction: column;
  gap: 20px;
  min-height: 100vh;
  color: var(--muted);
  font-size: 12px;
}

#toast {
  position: fixed;
  bottom: 28px;
  left: 50%;
  z-index: 100;
  max-width: calc(100% - 32px);
  padding: 13px 20px;
  transform: translateX(-50%);
  border: 1px solid #626262;
  border-radius: 9px;
  background: #474747;
  color: #f8f8f8;
  box-shadow: 0 8px 30px #3131311f;
  font-size: 12px;
  line-height: 1.6;
  overflow-wrap: anywhere;
}

#toast.error {
  border-color: #aa7767;
  background: #a76a59;
}

.login-page {
  display: grid;
  grid-template-columns: 1.05fr 1fr;
  min-height: 100vh;
  background: #fff;
}

.login-story {
  position: relative;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  padding: 49px 65px;
  border-right: 1px solid #e5e5e5;
  background: #ffffff;
}

.login-story:after {
  position: absolute;
  right: -150px;
  bottom: -220px;
  width: 520px;
  height: 520px;
  border: 1px solid #e3e3e3;
  border-radius: 50%;
  box-shadow: 0 0 0 65px #ebebeb66, 0 0 0 130px #eeeeee66;
  content: "";
  pointer-events: none;
}

.login-story .brand {
  position: relative;
  z-index: 1;
}

.login-story .brand-mark {
  border-color: #dbdbdb;
  background: #ececec;
}

.story-copy {
  position: relative;
  z-index: 1;
  margin: auto 0;
  padding: 80px 0;
}

.story-copy > .eyebrow {
  color: #919191;
  font-size: 10px;
}

.story-copy h1 {
  margin: 27px 0 24px;
  color: #4c4c4c;
  font-size: clamp(36px, 3.5vw, 54px);
  font-weight: 550;
  letter-spacing: -1.8px;
  line-height: 1.45;
}

.story-copy p {
  color: #959595;
  font-size: 14px;
  line-height: 2;
}

.story-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 18px 24px;
  max-width: 330px;
  margin-top: 42px;
  color: #8a8a8a;
  font-size: 11px;
}

.story-grid span:before {
  display: inline-block;
  width: 4px;
  height: 4px;
  margin: 0 10px 2px 0;
  border-radius: 50%;
  background: #a4a4a4;
  content: "";
}

.story-foot {
  position: relative;
  z-index: 1;
  color: #a4a4a4;
  font-size: 9px;
  letter-spacing: 2px;
}

.login-side {
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 60px;
}

.login-card {
  width: 100%;
  max-width: 350px;
}

.login-card > .eyebrow {
  font-size: 9px;
  letter-spacing: 2.5px;
}

.login-card h2 {
  margin: 17px 0 9px;
  color: #444444;
  font-size: 31px;
  font-weight: 600;
}

.login-card > p.muted {
  margin-bottom: 37px;
  font-size: 12px;
}

.login-card label {
  margin-top: 24px;
  color: #7a7a7a;
  font-size: 11px;
}

.login-card input {
  padding: 14px;
  border-color: #e4e4e4;
  background: #fdfdfd;
  font-size: 12px;
}

.login-card .primary {
  display: flex;
  justify-content: space-between;
  margin-top: 12px;
  padding: 14px 16px;
  font-size: 12px;
}

.login-card .primary span {
  font-size: 16px;
  line-height: 1;
}

.login-card .form-error {
  margin-top: 10px;
}

.login-note {
  margin-top: 24px;
  color: #a9a9a9;
  font-size: 10px;
  line-height: 1.9;
}

@media (min-width: 1600px) {
  .workspace {
    padding-top: 48px;
  }

  .card {
    padding: 27px;
  }

  .table-card {
    padding: 0;
  }

  .metric-value {
    font-size: 37px;
  }

  .chart {
    height: auto;
  }

}

@media (max-width: 1200px) {
  .workspace {
    padding: 33px 28px 20px;
  }

  .topbar {
    padding: 0 28px;
  }

  .cards {
    gap: 13px;
  }

  .card {
    padding: 20px;
  }

  .table-card {
    padding: 0;
  }

  .section-grid {
    grid-template-columns: minmax(0, 1.5fr) minmax(240px, 1fr);
    gap: 18px;
  }

  .login-story {
    padding: 42px;
  }

  .login-side {
    padding: 42px;
  }

}

@media (max-width: 1050px) {
  .cards {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .metric-value {
    font-size: 31px;
  }

  .section-grid {
    grid-template-columns: 1fr;
  }

  .settings-grid {
    grid-template-columns: 1fr;
  }

  .page-head {
    align-items: flex-start;
    gap: 18px;
  }

  .page-actions {
    padding-top: 7px;
  }

  .page-actions button {
    padding: 9px 12px;
    font-size: 11px;
  }

  #clock {
    display: none;
  }

}

@media (max-width: 900px) {
  .sidebar {
    width: 90px;
    padding: 28px 11px;
  }

  .sidebar .brand {
    margin: 0 auto;
  }

  .sidebar .brand > span:last-child, .nav-heading, .sidebar-bottom {
    display: none;
  }

  .sidebar nav {
    margin-top: 38px;
  }

  .nav-item {
    flex-direction: column;
    justify-content: center;
    gap: 8px;
    margin: 8px 0;
    padding: 12px 4px;
    font-size: 10px;
  }

  .nav-item svg {
    width: 20px;
    height: 20px;
  }

  .main {
    width: calc(100% - 90px);
    margin-left: 90px;
  }

  .login-story {
    padding: 34px;
  }

  .login-side {
    padding: 34px;
  }

  .story-grid {
    gap: 17px 13px;
    font-size: 10px;
  }

  .story-foot {
    font-size: 8px;
    letter-spacing: 1.4px;
  }

}

@media (max-width: 640px) {
  .app {
    display: block;
  }

  .sidebar {
    position: sticky;
    top: 0;
    width: 100%;
    padding: 7px 10px;
    border-right: 0;
    border-bottom: 1px solid var(--line);
    background: #fffffff5;
    backdrop-filter: blur(12px);
  }

  .sidebar .brand {
    display: none;
  }

  .sidebar nav {
    display: grid;
    grid-template-columns: repeat(7, minmax(0, 1fr));
    gap: 5px;
    margin: 0;
  }

  .nav-item {
    width: 100%;
    margin: 0;
    padding: 8px 2px;
    gap: 6px;
    border-radius: 7px;
    font-size: 10px;
  }

  .nav-item svg {
    width: 18px;
    height: 18px;
  }

  .main {
    width: 100%;
    margin-left: 0;
  }

  .topbar {
    height: 55px;
    padding: 0 19px;
    gap: 12px;
    font-size: 10px;
  }

  .breadcrumb-slash {
    margin: 0 10px;
  }

  .top-actions {
    gap: 7px;
  }

  .account {
    max-width: 105px;
    padding: 5px 8px;
    font-size: 10px;
  }

  .top-actions .text-button {
    padding: 7px 5px;
    font-size: 10px;
  }

  .workspace {
    padding: 26px 18px 14px;
  }

  .page-head {
    flex-wrap: wrap;
    gap: 16px;
    margin-bottom: 25px;
  }

  .page-head h1 {
    margin: 9px 0 7px;
    font-size: 27px;
  }

  .page-head p {
    font-size: 11px;
  }

  .page-actions {
    width: 100%;
    padding-top: 0;
  }

  .page-actions button {
    padding: 9px 13px;
  }

  .cards {
    gap: 11px;
    margin-bottom: 18px;
  }

  .card {
    padding: 18px;
    border-radius: 11px;
  }

  .table-card {
    padding: 0;
  }

  .cards > .card {
    padding: 16px;
  }

  .metric-title {
    font-size: 10px;
  }

  .metric-icon {
    width: 24px;
    height: 24px;
    border-radius: 7px;
    font-size: 14px;
  }

  .metric-value {
    margin: 17px 0 13px;
    font-size: 25px;
    letter-spacing: -1px;
  }

  .metric-value small {
    margin-left: 4px;
    font-size: 10px;
  }

  .metric-note {
    font-size: 9px;
  }

  .section-grid {
    gap: 17px;
    margin-bottom: 20px;
  }

  .card-head {
    gap: 10px;
  }

  .card-head h3 {
    font-size: 14px;
  }

  .card-head p {
    font-size: 10px;
  }

  .chart {
    height: auto;
  }

  .chart-labels {
    font-size: 8px;
  }

  .chart-legend {
    gap: 5px;
    font-size: 9px;
  }

  .mini-stat {
    padding: 15px 0;
  }

  .section-header {
    margin-top: 25px;
  }

  .section-header h3 {
    font-size: 14px;
  }

  td, th {
    padding: 15px 17px;
  }

  .filter-bar {
    flex-direction: column;
    align-items: flex-start;
    gap: 14px;
  }

  .search-label {
    width: 100%;
  }

  .page-footer {
    flex-wrap: wrap;
    gap: 5px 16px;
    margin-top: 22px;
    font-size: 9px;
  }

  .node-grid {
    grid-template-columns: minmax(0, 1fr);
    gap: 16px;
  }

  .node-buttons {
    gap: 6px;
  }

  .node-buttons button {
    padding: 8px 9px;
  }

  .form-row {
    grid-template-columns: minmax(0, 1fr);
  }

  .detail-metrics {
    gap: 8px;
  }

  .detail-metrics > div {
    padding: 12px 10px;
  }

  .detail-metrics span {
    font-size: 9px;
  }

  .detail-metrics strong {
    font-size: clamp(12px, 3.5vw, 16px);
    letter-spacing: -.4px;
    white-space: nowrap;
  }

  dialog {
    padding: 22px;
    border-radius: 12px;
  }

  .modal-header h2 {
    font-size: 19px;
  }

  .modal-header .eyebrow {
    font-size: 8px;
    letter-spacing: 1.4px;
  }

  .form-footer {
    gap: 7px;
  }

  .form-footer button {
    padding: 9px 12px;
    font-size: 11px;
  }

  .login-page {
    display: block;
    background: #fafafa;
  }

  .login-story {
    min-height: 190px;
    padding: 25px 27px;
    border-right: 0;
    border-bottom: 1px solid #e5e5e5;
  }

  .login-story .brand {
    font-size: 20px;
  }

  .login-story .brand b {
    font-size: 7px;
  }

  .login-story .brand-mark {
    width: 35px;
    height: 37px;
  }

  .story-copy {
    margin: 25px 0 0;
    padding: 0;
  }

  .story-copy h1 {
    margin: 0;
    font-size: 25px;
    line-height: 1.5;
    letter-spacing: -.8px;
  }

  .story-copy h1 br {
    display: none;
  }

  .story-copy > .eyebrow, .story-copy p, .story-grid, .story-foot {
    display: none;
  }

  .login-side {
    padding: 34px 24px 40px;
  }

  .login-card {
    max-width: 390px;
    padding: 27px 25px;
    border: 1px solid #e6e6e6;
    border-radius: 14px;
    background: #fff;
  }

  .login-card h2 {
    font-size: 27px;
  }

  .login-card > p.muted {
    margin-bottom: 26px;
  }

  .login-card label {
    margin-top: 21px;
  }

  .login-note {
    margin-top: 21px;
  }

}

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation: none !important;
    transition: none !important;
    scroll-behavior: auto !important;
  }

}

/* White surfaces with restrained accents; traffic directions remain distinct. */
:root { --upload: #2563eb; --download: #64748b; }
.brand-mark { width: 40px; height: 40px; border: 0; border-radius: 0; background: transparent; }
.brand-mark img { display: block; width: 100%; height: 100%; }
.login-page { grid-template-columns: minmax(0, 1fr); place-items: center; padding: 32px 20px; }
.login-side { width: min(100%, 380px); padding: 0; }
.login-card { width: 100%; max-width: none; }
.login-card .brand { margin-bottom: 30px; }
.login-card h2 { margin: 0 0 24px; }
.modal-header h2 { margin-top: 0; }
.page-footer { justify-content: flex-end; }
.detail-metrics .traffic-up { color: var(--upload); }
.detail-metrics .traffic-down { color: var(--download); }
.metric-primary .metric-icon { background: #f8fafc; color: var(--accent); }
.main, .workspace, .login-page, .login-story, .login-side { background: #fff; }
.card { box-shadow: 0 2px 12px #11182704; }
.month-picker { display: flex; align-items: center; gap: 10px; white-space: nowrap; color: var(--muted); font-weight: 500; }
.month-picker select { width: auto; min-width: 164px; margin: 0; background: #fff; font-size: 12px; color: var(--ink); }
.table-heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 20px 22px; border-bottom: 1px solid var(--line); }
.table-heading p, .table-heading span { font-size: 11px; color: var(--muted); }
.table-heading p { margin-top: 5px; }
.traffic-up { color: var(--upload); }
.traffic-down { color: var(--download); }
.traffic-number { font-variant-numeric: tabular-nums; white-space: nowrap; }
.period-caption { margin: 12px 2px 0; color: var(--muted); font-size: 11px; line-height: 1.8; }
.is-loading { opacity: .5; pointer-events: none; }
.traffic-toolbar { display: flex; justify-content: space-between; align-items: center; gap: 16px; margin-bottom: 20px; }
.traffic-toolbar p { font-size: 11px; color: var(--muted); margin-top: 5px; }
.traffic-legend { display: flex; gap: 16px; align-items: center; font-size: 11px; color: var(--muted); }
.traffic-legend span { display: inline-flex; align-items: center; gap: 6px; }
.traffic-legend i { display: inline-block; width: 15px; height: 3px; border-radius: 2px; background: var(--upload); }
.traffic-legend .download i { background: var(--download); }
#traffic-status { margin-bottom: 12px; font-size: 12px; }
@media (max-width: 900px) {
  .filter-bar { flex-wrap: wrap; }
}
@media (max-width: 640px) {
  .month-picker { width: 100%; justify-content: space-between; }
  .month-picker select { flex: 1; max-width: 210px; }
  .table-heading { padding: 17px 15px; align-items: flex-start; }
  .traffic-toolbar { align-items: stretch; flex-direction: column; }
  .users-table, .users-table tbody { display: block; width: 100%; }
  .users-table thead { display: none; }
  .users-table tbody tr { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; padding: 18px 15px; border-bottom: 1px solid var(--line); }
  .users-table tbody tr:last-child { border-bottom: 0; }
  .users-table td { display: block; padding: 0; border: 0; min-width: 0; white-space: normal; }
  .users-table td:nth-child(-n+3), .users-table td:last-child { grid-column: 1 / -1; }
  .users-table td[data-label] { padding: 10px 0; font-size: 12px; font-variant-numeric: tabular-nums; }
  .users-table td[data-label]::before { content: attr(data-label); display: block; margin-bottom: 7px; color: var(--muted); font-size: 10px; font-weight: 400; }
  .users-table .node-tags { max-width: none; }
  .users-table .table-actions { justify-content: flex-end; border-top: 1px solid var(--line); padding-top: 8px; }
}

/* Compact light theme. Keep data surfaces white; use color for hierarchy. */
:root {
  --bg: #f2f5fa;
  --panel: #ffffff;
  --ink: #20304a;
  --muted: #697b94;
  --line: #dfe6f0;
  --accent: #3164df;
  --accent-soft: #eaf0ff;
  --green: #16846b;
  --amber: #a46b16;
  --red: #b94d5c;
  --radius: 10px;
  --upload: #3164df;
  --download: #138797;
}
.main, .workspace { background: var(--bg); }
.sidebar { width: 208px; padding: 24px 14px 18px; background: #f8faff; }
.sidebar .brand { margin-left: 6px; }
.brand { gap: 9px; font-size: 21px; }
.brand-mark { width: 34px; height: 34px; }
.nav-heading { margin: 30px 12px 10px; color: #8593aa; }
.nav-item { padding: 10px 12px; margin: 4px 0; gap: 10px; color: #60738f; }
.nav-item:hover { background: #edf2fc; }
.nav-item.active { background: #e4edff; border-color: #d5e2ff; color: #2455ca; box-shadow: inset 3px 0 #3164df; }
.sidebar-bottom { padding: 16px 10px 0; }
.connected i { background: var(--green); box-shadow: 0 0 0 3px #e0f4ec; }
.sidebar-origin { margin: 8px 0 10px; }
.sidebar-version { padding-top: 10px; letter-spacing: 0; }
.main { width: calc(100% - 208px); margin-left: 208px; }
.topbar { height: 52px; padding: 0 24px; background: #ffffffd9; }
.top-actions { gap: 12px; }
.account { padding: 4px 9px; background: #eef3fc; border-color: #dfe7f5; color: #577097; }
.workspace { max-width: 1600px; padding: 22px 24px 14px; }
.page-head { gap: 16px; margin-bottom: 18px; align-items: center; }
.page-head h1 { margin: 0; font-size: 24px; letter-spacing: -.6px; }
.page-actions { gap: 7px; padding-top: 0; }
button, .page-actions button { padding: 7px 11px; min-height: 32px; font-size: 12px; border-radius: 7px; }
button:hover { background: #eef3fc; border-color: #cbd8ed; }
.primary { box-shadow: 0 2px 4px #3164df18; }
input, select { padding: 7px 10px; min-height: 34px; border-color: #d9e2ef; border-radius: 7px; font-size: 13px; }
label > input, label > select, .password-wrap input { margin-top: 6px; }
.checkbox-label input, .node-choice input { min-height: 0; }
.filter-bar { gap: 14px; margin-bottom: 12px; }
.search-label { width: min(280px, 100%); }
.search-label input { padding: 7px 10px 7px 33px; }
.search-label svg { top: 9px; left: 11px; width: 15px; height: 15px; color: #8192ac; }
.month-picker { gap: 8px; }
.month-picker select { min-width: 154px; }
.notice { padding: 8px 12px; margin-bottom: 14px; border-radius: 7px; line-height: 1.6; background: #fff7e8; border-color: #f0dfb9; color: #96691f; }
.cards { gap: 12px; margin-bottom: 16px; }
.card { padding: 16px; border-color: var(--line); box-shadow: 0 2px 5px #24416b04; }
.table-card { padding: 0; }
.metric-title { color: #657993; font-size: 12px; }
.metric-value { margin: 10px 0 8px; color: var(--ink); font-size: 28px; letter-spacing: -.8px; }
.metric-icon { width: 26px; height: 26px; border: 0; background: #eaf0ff; color: #3164df; border-radius: 7px; }
.metric-note { color: #72829a; }
.metric-primary { background: linear-gradient(120deg, #315fdb, #447bed); border-color: #3868df; }
.metric-primary .metric-title, .metric-primary .metric-note { color: #e2ebff; }
.metric-primary .metric-value { color: #fff; }
.metric-primary .metric-icon { background: #ffffff24; color: #fff; border: 0; }
.cards > .card:nth-child(3) .metric-icon { background: #e4f5ee; color: #16846b; }
.cards > .card:nth-child(4) .metric-icon { background: #e8f4f8; color: #138797; }
.section-grid { gap: 16px; margin-bottom: 16px; }
.card-head { margin-bottom: 12px; gap: 12px; }
.card-head h3, .section-header h3, .table-heading h3 { font-size: 14px; }
.card-head p { margin-top: 4px; }
.chart-summary { margin-bottom: 10px; }
.chart-summary strong { font-size: 23px; }
.chart-labels { margin-top: 7px; color: #8393aa; }
.mini-stat { padding: 12px 0; border-color: #e9eef6; }
.mini-stat strong { font-size: 17px; color: #304969; }
.section-header { margin: 18px 0 10px; }
.table-heading { padding: 12px 16px; gap: 12px; background: linear-gradient(100deg, #f2f6ff, #fafcff); }
th { padding: 10px 14px; background: #f5f8fd; color: #61738e; font-size: 11px; font-weight: 600; }
td { padding: 11px 14px; color: #51637e; border-color: #eaf0f7; }
tbody tr:nth-child(even) { background: #fbfcff; }
tbody tr:hover { background: #f0f5ff; }
.cell-title { margin-bottom: 3px; color: #2c3d57; font-size: 13px; }
.cell-sub { color: #8b9ab0; }
.avatar { width: 30px; height: 30px; border-radius: 8px; background: #eaf0ff; border-color: #dce6fc; color: #426bc7; }
.user-cell { gap: 9px; }
.badge { padding: 3px 6px; background: #eaf7f1; color: #26806b; border-color: #d6ecdf; }
.badge:before { background: currentColor; }
.badge.gray { color: #768399; background: #f0f3f8; border-color: #e2e7ef; }
.badge.amber { color: #9e701f; background: #fff6df; border-color: #f1e3ba; }
.badge.red { color: #b45260; background: #fff0f1; border-color: #f2dce0; }
.badge.blue { color: #416ec9; background: #edf3ff; border-color: #dae6fc; }
.node-tags { gap: 4px; max-width: 250px; }
.tag { padding: 3px 6px; background: #f0f4fc; border-color: #e3eaf6; color: #6981a5; }
.table-actions { gap: 3px; }
.table-actions button { min-height: 28px; padding: 5px 7px; color: #516b95; }
.table-actions button.red { color: #b45260; }
.table-actions button:hover { background: #e4edff; }
.page-footer { margin-top: 12px; padding: 6px 0 0; color: #8898b0; }
.node-grid { gap: 14px; grid-template-columns: repeat(auto-fill, minmax(min(270px, 100%), 1fr)); }
.node-card .card-head { margin-bottom: 12px; }
.node-name { font-size: 15px; color: #304969; }
.node-id { margin-top: 4px; }
.node-metrics { margin: 14px 0; gap: 12px; padding: 10px 12px; background: #f2f6fd; border-radius: 7px; }
.node-metrics strong { margin-top: 5px; font-size: 20px; color: #365c99; }
.node-line { margin: 8px 0; gap: 12px; }
.node-buttons { margin-top: 12px; padding-top: 12px; gap: 6px; }
.node-buttons button { padding: 6px 9px; }
.node-error { padding: 8px 10px; margin-top: 10px; }
.settings-grid { gap: 16px; }
.settings-grid form, .form-grid { gap: 13px; }
.settings-grid .card-head { margin-bottom: 16px; }
.form-row { gap: 12px; }
.form-footer { padding-top: 12px; margin-top: 4px; gap: 7px; }
.form-help { margin-top: 6px; line-height: 1.6; }
.password-wrap button { min-height: 34px; padding: 7px 10px; }
.node-choice { margin-top: 8px; gap: 6px; }
.node-choice label { padding: 8px 10px; background: #f5f8fd; border-color: #e0e8f4; }
.inline-note { padding: 9px 12px; background: #f0f5ff; border-color: #dfe8fa; color: #6680a6; line-height: 1.65; }
.code-box { padding: 11px; background: #f3f7ff; border-color: #cad9f3; }
dialog { width: min(540px, calc(100% - 32px)); padding: 20px; border-radius: 12px; border-color: #dce5f3; }
dialog.large { width: min(800px, calc(100% - 32px)); }
.modal-header { margin-bottom: 18px; gap: 12px; }
.modal-header h2 { margin: 0; font-size: 19px; }
.icon-button { width: 30px; height: 30px; min-height: 30px; padding: 0; background: #eef3fc; }
.traffic-toolbar { margin-bottom: 14px; gap: 12px; }
.detail-metrics { gap: 10px; margin-bottom: 18px; }
.detail-metrics > div { padding: 11px 13px; background: #f0f5ff; border-color: #dce7fb; border-radius: 8px; }
.detail-metrics > div:nth-child(2) { background: #eef8fa; border-color: #d8ecef; }
.detail-metrics > div:nth-child(3) { background: #f4f6fb; border-color: #e2e7f1; }
.detail-metrics strong { margin-top: 6px; font-size: 20px; }
.empty { padding: 30px 16px; }
.login-page { background: radial-gradient(ellipse at 50% 20%, #e8efff, #f3f6fb 65%); }
.login-side { width: min(100%, 390px); background: transparent; }
.login-card { padding: 28px; background: #fff; border: 1px solid #dfe7f4; border-radius: 14px; box-shadow: 0 12px 45px #345a9810; }
.login-card .brand { margin-bottom: 22px; }
.login-card h2 { margin-bottom: 18px; font-size: 23px; }
.login-card label { margin-top: 16px; }
.login-card input { padding: 9px 11px; min-height: 38px; }
.login-card .primary { justify-content: center; margin-top: 18px; padding: 9px 12px; min-height: 38px; }
.login-note { margin-top: 18px; }
@media (max-width: 1100px) and (min-width: 901px) {
  .workspace { padding: 20px 18px 12px; }
  .topbar { padding: 0 18px; }
}
@media (max-width: 900px) and (min-width: 641px) {
  .sidebar { width: 74px; padding: 20px 8px; }
  .sidebar nav { margin-top: 24px; }
  .nav-item { padding: 10px 3px; gap: 6px; font-size: 10px; }
  .main { width: calc(100% - 74px); margin-left: 74px; }
  .workspace { padding: 18px; }
  .topbar { padding: 0 18px; }
}
@media (max-width: 640px) {
  .sidebar { width: 100%; padding: 5px 8px; background: #f8fafff5; }
  .sidebar nav { margin: 0; }
  .nav-item { padding: 7px 2px; margin: 0; gap: 5px; font-size: 10px; }
  .nav-item.active { box-shadow: inset 0 -2px #3164df; }
  .main { width: 100%; margin-left: 0; }
  .topbar { height: 44px; padding: 0 14px; }
  .top-actions { gap: 6px; }
  .workspace { padding: 16px 12px 12px; }
  .page-head { flex-wrap: wrap; gap: 10px; margin-bottom: 14px; }
  .page-head h1 { font-size: 22px; }
  .page-actions { width: auto; }
  .page-actions button { padding: 7px 10px; font-size: 11px; min-height: 36px; }
  input, select { min-height: 38px; }
  .search-label, .month-picker { width: 100%; }
  .search-label svg { top: 11px; }
  .filter-bar { gap: 10px; }
  .notice { padding: 8px 10px; font-size: 11px; }
  .cards, .section-grid { gap: 10px; margin-bottom: 12px; }
  .card { padding: 12px; }
  .table-card { padding: 0; }
  .metric-title { font-size: 11px; }
  .metric-value { font-size: 24px; margin: 9px 0 6px; }
  .metric-note { font-size: 10px; }
  .metric-icon { width: 23px; height: 23px; }
  .table-heading { padding: 10px 12px; }
  .users-table tbody tr { gap: 7px; padding: 12px; }
  .users-table td { padding: 0; }
  .users-table td[data-label] { padding: 6px 0; }
  .users-table td[data-label]::before { margin-bottom: 4px; }
  .users-table .table-actions { padding-top: 6px; }
  .table-actions button { min-height: 36px; padding: 7px 10px; }
  .node-grid { gap: 12px; }
  .node-buttons button, .form-footer button { min-height: 36px; }
  .node-line { font-size: 12px; }
  dialog { padding: 16px; max-height: 92dvh; }
  .modal-header h2 { font-size: 18px; }
  .detail-metrics { gap: 7px; }
  .detail-metrics > div { padding: 10px 8px; }
  .detail-metrics strong { font-size: 15px; }
  .traffic-toolbar { gap: 10px; }
  .login-card { padding: 24px; }
}

.metric-directions { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; margin-top: 8px; font-size: 10px; }
.metric-directions > span { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
.metric-directions strong { font-size: 12px; font-weight: 600; letter-spacing: 0; white-space: nowrap; }
.metric-primary .metric-directions > span { color: #e2ebff; }
.metric-primary .metric-directions strong { color: #fff; }
.mini-stat.monthly-stat { display: block; }
.monthly-summary { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
.monthly-stat .metric-directions strong { font-size: 12px; color: inherit; }
.traffic-legend { flex-wrap: wrap; gap: 6px 14px; }
@media (max-width: 640px) {
  .metric-directions { gap: 5px; }
  .metric-directions strong { font-size: 11px; }
}

.subscription-summary { display:flex; justify-content:space-between; gap:12px; margin-bottom:12px; color:var(--muted); font-size:12px; }
.subscription-link .table-actions { align-items:center; gap:10px; }
.subscription-link .code-box { padding:9px 11px; font-size:11px; line-height:1.65; }
.subscription-link .copy-row { margin-bottom:6px; }
.subscription-download-row { display:flex; align-items:center; gap:10px; margin-top:12px; }
.subscription-download-row label { color:var(--muted); font-size:11px; font-weight:400; }
.subscription-download-row select { width:auto; min-width:0; flex:1; max-width:190px; }
.subscription-download-row a { margin-left:auto; }
.subscription-settings { margin-top:16px; padding-top:14px; border-top:1px solid var(--line); }
.subscription-settings .form-footer { justify-content:space-between; flex-wrap:wrap; }
.subscription-templates { margin-top:16px; }
.subscription-templates textarea { display:block; width:100%; min-width:0; min-height:154px; margin-top:6px; padding:10px 12px; border:1px solid #d9e2ef; border-radius:7px; background:#fff; color:var(--ink); font-family:ui-monospace,SFMono-Regular,Consolas,monospace; font-size:11px; font-weight:400; line-height:1.7; resize:vertical; }
.subscription-templates textarea:focus { outline:3px solid #2563eb14; border-color:#8aaef0; }
.subscription-templates summary { cursor:pointer; font-size:13px; font-weight:600; }
.subscription-templates form { margin-top:14px; }
.subscriptions-table td { padding-top:12px; padding-bottom:12px; }
@media (max-width:640px) {
  #subscription-list .table-scroll { overflow:visible; }
  .subscriptions-table, .subscriptions-table tbody { display:block; width:100%; white-space:normal; }
  .subscriptions-table thead { display:none; }
  .subscriptions-table tbody tr { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:7px 12px; padding:12px; border-bottom:1px solid var(--line); }
  .subscriptions-table tbody tr:last-child { border-bottom:0; }
  .subscriptions-table td { display:block; min-width:0; margin:0; padding:0; border:0; white-space:normal; overflow-wrap:anywhere; font-size:12px; }
  .subscriptions-table td:first-child { grid-column:1; grid-row:1; align-self:center; font-size:14px; }
  .subscriptions-table td:nth-child(5) { grid-column:2; grid-row:1; justify-self:end; }
  .subscriptions-table td:nth-child(2) { grid-column:1 / -1; grid-row:2; }
  .subscriptions-table td:nth-child(3) { grid-column:1; grid-row:3; }
  .subscriptions-table td:nth-child(4) { grid-column:2; grid-row:3; font-size:11px; }
  .subscriptions-table td[data-label]::before { content:attr(data-label); display:block; margin-bottom:3px; color:var(--muted); font-size:10px; font-weight:400; }
  .subscriptions-table td:nth-child(2)::before { display:inline; margin-right:7px; }
  .subscriptions-table td:last-child { grid-column:1 / -1; grid-row:4; padding-top:7px; border-top:1px solid var(--line); }
  .subscriptions-table .table-actions { justify-content:flex-end; }
  .subscriptions-table .table-actions button { min-height:34px; }
}

.activity-filters {display:flex;align-items:end;gap:10px;margin-bottom:16px;flex-wrap:wrap}
.activity-filters label {margin:0;min-width:130px;flex:1;font-size:12px;color:var(--muted);gap:5px;display:flex;flex-direction:column}
.activity-filters select,.activity-filters input {min-height:36px;width:100%;font-size:13px}
.activity-filters .activity-search {flex:1.4}
.activity-filters button {min-height:36px}
.activity-metrics .card {padding:16px 18px;min-height:100px}
.activity-metrics .metric-value {font-size:28px;margin-top:8px}
.activity-last {font-size:16px;font-weight:650;margin-top:18px;font-variant-numeric:tabular-nums}
.activity-health {padding:10px 14px;background:#fffbeb;border:1px solid #fde6a0;border-radius:10px;margin-bottom:14px;font-size:12px;color:#8c611c}
.activity-health>div {display:flex;gap:12px;line-height:1.8;flex-wrap:wrap}
.activity-health strong {min-width:110px}
.activity-chart {margin-bottom:16px}
.activity-chart .card-head {display:flex;justify-content:space-between}
.activity-bars {display:flex;gap:3px;height:110px;align-items:stretch;padding-top:8px}
.activity-bar {flex:1;display:flex;align-items:end;background:#f6f9fe;border-radius:4px;min-width:2px}
.activity-bar svg {display:block;width:100%;height:100%}
.activity-metrics .metric-value.red {color:#b45260}
.activity-chart-axis {display:flex;justify-content:space-between;font-size:11px;color:var(--muted);margin-top:8px}
.activity-rankings {display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:16px}
.activity-ranking {padding:16px 18px}
.activity-ranking .card-head {margin-bottom:8px}
.activity-rank-row {display:flex;align-items:center;gap:10px;padding:6px 0;font-size:12px}
.activity-rank-row>.mono {flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.activity-rank-index {color:#94a3b8;width:14px;font-size:11px}
.activity-rank-row strong {font-variant-numeric:tabular-nums;color:#4672d9}
.activity-no-data {padding:16px 0;font-size:12px}
.activity-table {min-width:850px}
.activity-table td {padding-top:10px;padding-bottom:10px;vertical-align:top}
.activity-table td:first-child {white-space:nowrap;font-size:12px}
.activity-table .mono {font-size:12px}
.activity-target {max-width:350px}
.activity-target>.mono {overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:330px}
.activity-message {overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:330px}
.activity-pagination {padding:10px 16px;display:flex;align-items:center;justify-content:space-between;border-top:1px solid var(--line)}
.activity-pagination>div {display:flex;gap:6px}
.activity-pagination button {font-size:12px;padding:5px 10px}
@media(max-width:700px){.activity-rankings{grid-template-columns:1fr;gap:10px}.activity-filters label{min-width:calc(50% - 10px)}.activity-filters .activity-search{flex-basis:70%;min-width:0}.activity-metrics .card{min-height:90px;padding:12px}.activity-metrics .metric-value{font-size:24px}.activity-last{font-size:13px}}

'''

JS = r'''
'use strict';
const $=id=>document.getElementById(id);
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const state={activity:null,activityFilter:{user_id:'',node_id:'',hours:24,q:'',page:1},view:'overview',session:null,users:[],nodes:[],subscriptions:[],overview:null,chart:null,logs:[],settings:{timezone_offset:480},settingsLoaded:false,settingsDirty:false,activityRetentionDirty:false,templatesDirty:false,userMonth:'',userPeriod:null,trafficTask:null,trafficUser:null,subscriptionTask:null,syncFollowup:null,epoch:0,refreshTask:null,requests:new Set(),toast:null};
const REFRESH_MS=15000, REQUEST_TIMEOUT_MS=15000;
const views={overview:['运行总览','总览'],users:['用户管理','用户管理'],nodes:['服务器','服务器'],subscriptions:['订阅','订阅'],activity:['行为分析','行为分析'],logs:['操作记录','操作记录'],settings:['设置','设置']};
function bytes(value){let n=Number(value||0);if(!Number.isFinite(n))return '—';const units=['B','KiB','MiB','GiB','TiB','PiB'];let i=0;while(n>=1024&&i<units.length-1){n/=1024;i++;}return (i?n.toFixed(n>=100?1:2):Math.round(n))+' '+units[i];}
function stamp(value){if(!value)return '尚未上报';return new Date(Number(value)*1000+Number(state.settings.timezone_offset||0)*60000).toISOString().slice(0,19).replace('T',' ');}
function relative(value){if(!value)return '尚未上报';let s=Math.max(0,Math.floor(Date.now()/1000-Number(value)));if(s<10)return '刚刚';if(s<60)return s+' 秒前';if(s<3600)return Math.floor(s/60)+' 分钟前';if(s<86400)return Math.floor(s/3600)+' 小时前';return Math.floor(s/86400)+' 天前';}
function tzName(){const o=Number(state.settings.timezone_offset||0);return 'UTC'+(o>=0?'+':'−')+Math.floor(Math.abs(o)/60)+((Math.abs(o)%60)?':'+String(Math.abs(o)%60).padStart(2,'0'):'');}
function toast(message,error=false){clearTimeout(state.toast);$('toast').textContent=message;$('toast').className=error?'error':'';$('toast').hidden=false;state.toast=setTimeout(()=>$('toast').hidden=true,5000);}
function cancelled(){const error=new Error('请求已取消');error.name='AbortError';return error;}
function cancelRequests(){state.epoch++;clearSyncFollowup();for(const controller of state.requests)controller.abort();state.requests.clear();state.refreshTask=null;}
async function api(path,method='GET',body,{signal}={}){
  const epoch=state.epoch,controller=new AbortController(),headers={};let timedOut=false;
  const abort=()=>controller.abort();
  if(signal?.aborted)throw cancelled();
  signal?.addEventListener('abort',abort,{once:true});state.requests.add(controller);
  const timer=setTimeout(()=>{timedOut=true;controller.abort();},REQUEST_TIMEOUT_MS);
  try{
    if(method!=='GET'){headers['Content-Type']='application/json';if(state.session)headers['X-CSRF-Token']=state.session.csrf;}
    const response=await fetch(path,{method,headers,body:method==='GET'?undefined:JSON.stringify(body||{}),credentials:'same-origin',cache:'no-store',signal:controller.signal});
    let data;try{data=await response.json();}catch(error){if(controller.signal.aborted)throw error;throw new Error('接口 '+path+' 返回 HTTP '+response.status+'（'+(response.headers.get('content-type')||'未知类型')+'），不是 JSON，请检查中控日志或反向代理。');}
    if(epoch!==state.epoch||controller.signal.aborted)throw cancelled();
    if(!response.ok){if(response.status===401&&path!=='/api/auth/login')showLogin();throw new Error(data.error||'请求未完成');}
    return data;
  }catch(error){
    if(epoch!==state.epoch)throw cancelled();
    if(timedOut)throw new Error('请求超时，请检查网络后重试。');
    if(controller.signal.aborted)throw cancelled();
    throw error;
  }finally{clearTimeout(timer);signal?.removeEventListener('abort',abort);state.requests.delete(controller);}
}
function showLogin(){cancelRequests();Object.assign(state,{activity:null,activityFilter:{user_id:'',node_id:'',hours:24,q:'',page:1},session:null,users:[],nodes:[],subscriptions:[],overview:null,chart:null,logs:[],settings:{timezone_offset:480},settingsLoaded:false,settingsDirty:false,activityRetentionDirty:false,templatesDirty:false,userMonth:'',userPeriod:null});$('app').hidden=true;$('loading').hidden=true;$('login').hidden=false;closeModal();}
function showApp(){cancelRequests();$('login').hidden=true;$('loading').hidden=true;$('app').hidden=false;$('account').textContent=state.session.username;$('version').textContent=state.session.version;$('sidebar-origin').textContent=location.host;const selected=location.hash.slice(1);state.view=views[selected]?selected:'overview';setView(state.view,false);}
function empty(title,description='',action=''){return `<div class="empty"><span class="empty-icon">◫</span><h3>${esc(title)}</h3>${description?`<p>${esc(description)}</p>`:''}${action}</div>`;}
function badge(label,color=''){return `<span class="badge ${color}">${esc(label)}</span>`;}
function nodeBadge(node){if(node.status==='created')return badge('等待接入','gray');if(node.status==='pending')return badge('自动接管中','amber');if(node.status==='revoked')return badge('已撤销','gray');if(node.status==='detached')return badge('已解绑','gray');if(!node.online)return badge('离线','gray');if(node.last_error)return badge('配置失败','red');if(node.revision!==node.applied_revision)return badge('待同步','amber');return badge('在线');}
function userNodes(user){return user.nodes.length?`<div class="node-tags">${user.nodes.map(n=>`<span class="tag" title="${esc(n.name)}">${esc(n.name)}</span>`).join('')}</div>`:'<span class="muted small">未分配</span>';}
function userStatus(user){const pending=user.nodes.some(n=>n.status==='active'&&(n.revision!==n.applied_revision||n.last_seen<Date.now()/1000-60));return (user.enabled?(user.quota_blocked?badge('额度用尽','amber'):badge('已启用')):badge('已禁用','gray'))+(pending?' '+badge('待节点确认','amber'):'');}
function userRows(users,compact=false){
  return users.map(user=>`<tr>
    <td><div class="user-cell"><span class="avatar">${esc(user.name.slice(0,1).toUpperCase())}</span><div><div class="cell-title">${esc(user.name)}</div><div class="cell-sub">${user.quota_bytes?`${bytes(user.quota_used)} / ${bytes(user.quota_bytes)} · ${user.quota_period==='monthly'?'本月':'累计'}`:esc(user.id.slice(0,14))+'…'}</div></div></div></td>
    <td>${userNodes(user)}</td><td>${userStatus(user)}</td>
    <td class="traffic-number traffic-up" data-label="↑ 上传">${bytes(compact?user.up:user.period_up)}</td>
    <td class="traffic-number traffic-down" data-label="↓ 下载">${bytes(compact?user.down:user.period_down)}</td>
    <td class="traffic-number" data-label="合计"><strong>${bytes(compact?user.total:user.period_total)}</strong></td>
    <td><div class="table-actions"><button data-action="activity-user" data-id="${user.id}">分析</button><button data-action="traffic" data-id="${user.id}">流量</button><button data-action="subscription" data-id="${user.id}">订阅</button>${compact?'':`
      <button data-action="quota-user" data-id="${user.id}">额度</button>
      <button data-action="edit-user" data-id="${user.id}">编辑</button>
      <button data-action="toggle-user" data-id="${user.id}">${user.enabled?'禁用':'启用'}</button>
      <button data-action="delete-user" data-id="${user.id}" class="red">删除</button>`}</div></td>
  </tr>`).join('');
}
function trafficDirections(value){return `<div class="metric-directions"><span class="traffic-up">↑ 上传<strong>${bytes(value.up)}</strong></span><span class="traffic-down">↓ 下载<strong>${bytes(value.down)}</strong></span></div>`;}
function renderOverview(){const o=state.overview;if(!o){$('content').innerHTML=empty('正在读取数据…');return;}const activeUsers=state.users.filter(u=>!u.deleted).sort((a,b)=>b.total-a.total).slice(0,5);$('content').innerHTML=`<div class="cards"><div class="card metric-primary"><div class="metric-title">累计用户流量<span class="metric-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 16 11 10l4 4 5-8M15 6h5v5M4 4v16h16"/></svg></span></div><div class="metric-value">${bytes(o.lifetime.total)}</div>${trafficDirections(o.lifetime)}</div><div class="card"><div class="metric-title">今日流量<span class="metric-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="8.5"/><path d="M12 7v5l3.5 2"/></svg></span></div><div class="metric-value">${bytes(o.today.total)}</div>${trafficDirections(o.today)}</div><div class="card"><div class="metric-title">在线服务器<span class="metric-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3.5" y="3.5" width="17" height="7" rx="2"/><rect x="3.5" y="13.5" width="17" height="7" rx="2"/><path d="M7 7h.01M7 17h.01M11 7h6M11 17h6"/></svg></span></div><div class="metric-value">${o.online_nodes}<small>/ ${o.nodes} 台</small></div>${o.pending_nodes?`<div class="metric-note">${o.pending_nodes} 台待接入</div>`:''}</div><div class="card"><div class="metric-title">代理用户<span class="metric-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="9" cy="8" r="3.25"/><path d="M3 20v-2a6 6 0 0 1 12 0v2M16 5a3.25 3.25 0 0 1 0 6.5M17.5 14a5 5 0 0 1 3.5 4.75V20"/></svg></span></div><div class="metric-value">${o.users}<small>位</small></div><div class="metric-note"><strong>${o.enabled_users} 位启用</strong> · ${o.users-o.enabled_users} 位禁用</div></div></div><div class="section-grid"><section class="card"><div class="card-head"><div><h3>近 7 天流量</h3></div></div><div id="overview-chart"></div></section><section class="card"><div class="card-head"><div><h3>运行状态</h3></div></div><div class="mini-stat"><span class="status-row"><i class="status-dot"></i>在线服务器</span><strong>${o.online_nodes}<small class="muted small"> / ${o.nodes}</small></strong></div><div class="mini-stat"><span class="status-row"><i class="status-dot amber"></i>配置待生效</span><strong>${o.unsynced_nodes}</strong></div><div class="mini-stat"><span class="status-row"><i class="status-dot red"></i>应用或采集异常</span><strong>${o.error_nodes}</strong></div><div class="mini-stat monthly-stat"><div class="monthly-summary"><span class="muted">本月累计</span><strong>${bytes(o.month.total)}</strong></div>${trafficDirections(o.month)}</div></section></div><div class="section-header"><h3>用户流量排行</h3><button class="text-button" data-view="users">查看全部 →</button></div><section class="card table-card">${activeUsers.length?`<div class="table-scroll"><table class="users-table"><thead><tr><th>用户</th><th>授权服务器</th><th>状态</th><th>累计上传</th><th>累计下载</th><th>合计</th><th>操作</th></tr></thead><tbody>${userRows(activeUsers,true)}</tbody></table></div>`:empty('还没有用户','','<button class="primary" data-action="new-node">接入服务器</button>')}</section>`;drawChart('overview-chart',state.chart?.daily||[],true);}
function drawChart(target, rows, split=false) {
  const el = $(target);
  if (!el) return;
  el.chartRows = rows; el.chartSplit = split;
  const width = Math.max(240, el.clientWidth || 640), height = width < 400 ? 170 : 180;
  const left = width < 400 ? 52 : 60, right = 12, top = 18, bottom = 20;
  const series = split ? [{key:'up',label:'上传',color:'var(--upload)'},{key:'down',label:'下载',color:'var(--download)'}] : [{key:'total',label:'合计',color:'var(--accent)'}];
  const peak = Math.max(0,...series.flatMap(item=>rows.map(row=>Number(row[item.key])||0)));
  const max = Math.max(1,peak), total = rows.reduce((sum,row)=>sum+(Number(row.total)||0),0);
  const baseline = height-bottom, plotHeight = baseline-top;
  const grid = [0,.25,.5,.75,1].map(fraction=>{
    const y=baseline-fraction*plotHeight;
    return `<line x1="${left}" x2="${width-right}" y1="${y}" y2="${y}" stroke="var(--line)" stroke-dasharray="3 5"/><text x="${left-10}" y="${y+3}" text-anchor="end" fill="var(--muted)" font-size="10">${bytes(fraction*peak)}</text>`;
  }).join('');
  const plots = series.map(item=>{
    const points=rows.map((row,index)=>[left+index*(width-left-right)/Math.max(1,rows.length-1),baseline-(Number(row[item.key])||0)/max*plotHeight]);
    const line=points.map((point,index)=>`${index?'L':'M'}${point[0].toFixed(2)},${point[1].toFixed(2)}`).join(' ');
    const area=points.length?`${line} L${points.at(-1)[0]},${baseline} L${points[0][0]},${baseline} Z`:'';
    const markers=points.map((point,index)=>`<circle cx="${point[0]}" cy="${point[1]}" r="${index===points.length-1?3.5:2}" fill="var(--panel)" stroke="${item.color}" stroke-width="1.7"><title>${esc(rows[index].date)} · ${item.label} ${bytes(rows[index][item.key])}</title></circle>`).join('');
    return `<defs><linearGradient id="${target}-${item.key}-fill" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="${item.color}" stop-opacity="0.1"/><stop offset="100%" stop-color="${item.color}" stop-opacity="0.01"/></linearGradient></defs><path d="${area}" fill="url(#${target}-${item.key}-fill)"/><path d="${line}" fill="none" stroke="${item.color}" stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round"/>${markers}`;
  }).join('');
  el.innerHTML=`
    <div class="chart-summary"><strong>${bytes(total)}</strong>${split?`<div class="traffic-legend"><span><i></i>上传 ${bytes(rows.reduce((sum,row)=>sum+(Number(row.up)||0),0))}</span><span class="download"><i></i>下载 ${bytes(rows.reduce((sum,row)=>sum+(Number(row.down)||0),0))}</span></div>`:`<span>本期合计 · 日均 ${bytes(total/Math.max(1,rows.length))}</span>`}</div>
    <svg class="chart" viewBox="0 0 ${width} ${height}" role="img" aria-label="${esc(rows.length+' 天'+(split?'上传与下载':'流量')+'趋势，合计 '+bytes(total))}">${grid}${plots}</svg>
    <div class="chart-labels"><span>${esc(rows[0]?.date||'—')}</span><span>${peak?(split?'单向峰值 ':'峰值 ')+bytes(peak):'暂无上报流量'}</span><span>${esc(rows.at(-1)?.date||'—')}</span></div>`;
}
function monthLabel(value){if(!/^\d{4}-\d{2}$/.test(value||''))return '本月';const [year,month]=value.split('-');return `${year} 年 ${Number(month)} 月`;}
function monthOptions(period){return (period?.months||[]).map(month=>`<option value="${esc(month)}" ${month===period.month?'selected':''}>${monthLabel(month)}${month===period.latest_month?' · 本月':''}</option>`).join('');}
function periodNote(period){return period?.partial?'<p class="period-caption">此月部分明细已超过 100 天保留期，合计可能不完整。</p>':'';}
function renderUsers(){
  const query=$('search').value.toLowerCase();
  const users=state.users.filter(user=>!user.deleted&&(!query||user.name.toLowerCase().includes(query)||user.nodes.some(node=>node.name.toLowerCase().includes(query))));
  const period=state.userPeriod;
  $('user-month').innerHTML=monthOptions(period);
  $('user-month').disabled=!period;
  $('content').innerHTML=`<section class="card table-card">
    <div class="table-heading"><div><h3>${monthLabel(period?.month)} · 用户流量</h3></div><span>${users.length} 位用户</span></div>
    ${users.length?`<div class="table-scroll"><table class="users-table"><thead><tr><th>用户</th><th>授权服务器</th><th>状态</th><th>↑ 上传</th><th>↓ 下载</th><th>合计</th><th>操作</th></tr></thead><tbody>${userRows(users)}</tbody></table></div>`:empty(query?'没有匹配的用户':'还没有用户','','<button class="primary" data-action="new-user">新增用户</button>')}
    </section>${periodNote(period)}`;
}
function renderNodes(){const q=$('search').value.toLowerCase();const nodes=state.nodes.filter(n=>!q||n.name.toLowerCase().includes(q)||n.hostname.toLowerCase().includes(q));$('content').innerHTML=nodes.length?`<div class="node-grid">${nodes.map(n=>`<section class="card node-card"><div class="card-head"><div><div class="node-name">${esc(n.name)}</div><div class="node-id">${esc(n.hostname||n.id.slice(0,18)+'…')}</div></div>${nodeBadge(n)}</div><div class="node-metrics"><div><span>累计用户流量</span><strong>${bytes(n.total)}</strong></div><div><span>已分配用户</span><strong>${n.status==='pending'?n.pending_users.length:n.users_count}<small class="muted small"> 位</small></strong></div></div><div class="node-line"><span>最后心跳</span><b title="${stamp(n.last_seen)}">${relative(n.last_seen)}</b></div><div class="node-line"><span>配置版本</span><b>${n.applied_revision} / ${n.revision}${n.revision!==n.applied_revision?' · 待生效':''}</b></div><div class="node-line"><span>代理服务</span><b>${n.status==='created'?'等待接入':n.service_running?'运行中':'未运行 / 尚未报告'}</b></div><div class="node-line"><span>待上传批次</span><b>${n.pending_batches}</b></div>${n.last_error?`<div class="node-error">配置：${esc(n.last_error)}</div>`:''}${n.sample_error?`<div class="node-error">采集：${esc(n.sample_error)}</div>`:''}<div class="node-buttons">${n.status==='created'?`<button class="primary" data-action="join-code" data-id="${n.id}">重新生成接入码</button>`:''}<button data-action="rename-node" data-id="${n.id}">改名</button><button data-action="node-detail" data-id="${n.id}">详情</button><button class="danger" data-action="delete-node" data-id="${n.id}">删除</button></div></section>`).join('')}</div>`:`<section class="card">${empty(q?'没有匹配的服务器':'还没有服务器','','<button class="primary" data-action="new-node">添加服务器</button>')}</section>`;}
function subscriptionStatus(data){return data.subscription_enabled===false?badge('已失效','gray'):data.subscription_expired?badge('已过期','amber'):!data.enabled?badge('用户已禁用','gray'):data.quota_blocked?badge('额度用尽','amber'):badge('有效');}
function filteredSubscriptions(){
  const query=$('search').value.toLowerCase();
  return state.subscriptions.filter(item=>!query||(item.name+' '+(item.subscription_name||'plzquick')).toLowerCase().includes(query));
}
function subscriptionRows(rows=filteredSubscriptions()){
  return rows.length?`<div class="table-scroll"><table class="subscriptions-table"><thead><tr><th>用户</th><th>订阅名称</th><th>节点</th><th>过期时间（${tzName()}）</th><th>状态</th><th>操作</th></tr></thead><tbody>${rows.map(item=>`<tr><td class="cell-title">${esc(item.name)}</td><td data-label="订阅">${esc(item.subscription_name||'plzquick')}</td><td data-label="节点">${item.nodes_count}</td><td data-label="过期时间">${item.subscription_expires_at?stamp(item.subscription_expires_at):'永不过期'}</td><td>${subscriptionStatus(item)}</td><td><div class="table-actions"><button data-action="subscription" data-id="${esc(item.id)}">链接与设置</button></div></td></tr>`).join('')}</tbody></table></div>`:empty($('search').value?'没有匹配的订阅':'还没有用户订阅');
}
function renderSubscriptions(listOnly=false){
  const rows=filteredSubscriptions();
  if(listOnly){$('subscription-list').innerHTML=subscriptionRows(rows);$('subscription-count').textContent=rows.length+' 个';return;}
  $('content').innerHTML=`<section class="card table-card"><div class="table-heading"><h3>用户订阅</h3><span id="subscription-count">${rows.length} 个</span></div><div id="subscription-list">${subscriptionRows(rows)}</div></section><details class="card subscription-templates"><summary>订阅模板</summary><form id="subscription-template-form" class="form-grid"><label>节点名称模板<input name="node_name_template" value="${esc(state.settings.node_name_template||'{{server}} · {{inbound}}')}" maxlength="300" required></label><p class="form-help">{{server}} 服务器 · {{inbound}} 入口 · {{username}} 用户 · {{index}} 序号</p><label>Clash / Mihomo 模板<textarea name="clash_template" rows="9" required spellcheck="false">${esc(state.settings.clash_template||'')}</textarea></label><p class="form-help">{{proxies}} 节点列表 · {{proxy_names}} 节点名称 · {{subscription_name}} 订阅名称 · {{group_name}} 策略组名 · {{proxy_groups}} 策略组 · {{rules}} 规则</p><div class="form-footer"><button type="submit" class="primary">保存模板</button></div></form></details>`;
}
function activityPath(){return 'activity?'+Object.entries(state.activityFilter).map(([key,value])=>encodeURIComponent(key)+'='+encodeURIComponent(value)).join('&');}
function activityBars(data){
  const step=([1,3,6,12,24,72].find(n=>n>=data.hours/48)||72)*3600, bins=new Map();
  const first=Math.floor(data.since/step)*step,last=Math.floor(Date.now()/1000/step)*step;
  for(let at=first;at<=last;at+=step)bins.set(at,0);
  for(const row of data.hourly){const at=Math.floor(row.hour/step)*step;bins.set(at,(bins.get(at)||0)+row.connections);}
  const max=Math.max(1,...bins.values());
  return `<div class="activity-bars" aria-label="连接发起次数趋势">${[...bins].map(([at,count])=>{const h=Math.max(count?2:0,count/max*100);return `<div class="activity-bar" title="${esc(stamp(at))} · ${count} 次"><svg viewBox="0 0 10 100" preserveAspectRatio="none" aria-hidden="true"><rect x="0" y="${100-h}" width="10" height="${h}" rx="1" fill="#568ded"/></svg></div>`;}).join('')}</div><div class="activity-chart-axis"><span>${esc(stamp(first).slice(5,16))}</span><span>${esc(stamp(last).slice(5,16))} · ${tzName()}</span></div>`;
}
function renderActivity(bodyOnly=false){
  const data=state.activity,filter=state.activityFilter;
  const options=(rows,selected)=>rows.map(row=>`<option value="${esc(row.id)}" ${row.id===selected?'selected':''}>${esc(row.name)}</option>`).join('');
  if(!bodyOnly){
    $('content').innerHTML=`<form id="activity-filter-form" class="activity-filters"><label>用户<select name="user_id"><option value="">全部用户</option>${options(data?.users||state.users,filter.user_id)}</select></label><label>服务器<select name="node_id"><option value="">全部服务器</option>${options(data?.nodes||state.nodes,filter.node_id)}</select></label><label>时间<select name="hours">${[[24,'近 24 小时'],[168,'近 7 天'],[720,'近 30 天'],[2160,'近 90 天']].map(([value,label])=>`<option value="${value}" ${Number(filter.hours)===value?'selected':''}>${label}</option>`).join('')}</select></label><label class="activity-search">明细目标<input name="q" value="${esc(filter.q)}" maxlength="100" placeholder="域名或目标 IP"></label><button type="submit" class="primary">查询</button></form><div id="activity-body"></div>`;
  }
  if(!data){$('activity-body').innerHTML=empty('正在读取行为记录…');return;}
  // Populate initially empty selectors after the first fetch, without replacing
  // draft filter values on the 15-second refresh.
  for(const [name,rows] of [['user_id',data.users],['node_id',data.nodes]]){
    const select=$('activity-filter-form')?.elements.namedItem(name);
    if(select&&select.options?.length===1)select.insertAdjacentHTML('beforeend',options(rows,filter[name]));
  }
  const s=data.summary,pages=Math.max(1,Math.ceil(data.total/data.page_size));
  const ranking=(title,rows)=>`<section class="card activity-ranking"><div class="card-head"><h3>${title}</h3></div>${rows.length?rows.map((row,index)=>`<div class="activity-rank-row"><span class="activity-rank-index">${index+1}</span><span class="mono" title="${esc(row.name)}">${esc(row.name)}</span><strong>${row.count.toLocaleString()}</strong></div>`).join(''):'<div class="activity-no-data muted">暂无连接记录</div>'}</section>`;
  const warnings=data.telemetry.filter(row=>row.error||row.dropped||row.gaps||row.pending>800||!row.received_at||Date.now()/1000-row.received_at>90);
  $('activity-body').innerHTML=`<div class="cards activity-metrics"><div class="card metric-primary"><div class="metric-title">发起连接</div><div class="metric-value">${s.connections.toLocaleString()}</div></div><div class="card"><div class="metric-title">明确错误</div><div class="metric-value ${s.errors?'red':''}">${s.errors.toLocaleString()}</div></div><div class="card"><div class="metric-title">来源 IP <span class="muted small">· 明细期</span></div><div class="metric-value">${s.source_ips.toLocaleString()}</div></div><div class="card"><div class="metric-title">最近行为</div><div class="activity-last">${s.last_at?esc(stamp(s.last_at)):'暂无'}</div></div></div>
    ${warnings.length?`<div class="activity-health">${warnings.map(row=>`<div><strong>${esc(row.name)}</strong><span>${!row.received_at?'待上传：请更新 VPS 脚本并同步':Date.now()/1000-row.received_at>90?'行为上报中断':row.error?esc(row.error):row.gaps||row.dropped?'已记录裁剪或缓存缺口':'行为记录上传积压'}${row.pending?' · 待上传 '+row.pending+' 条':''}${row.dropped?' · 缓存丢弃 '+row.dropped+' 条':''}${row.gaps?' · 日志缺口 '+row.gaps+' 次':''}</span></div>`).join('')}</div>`:''}
    <section class="card activity-chart"><div class="card-head"><h3>连接趋势</h3><span class="muted small">${esc(stamp(data.since).slice(5,16))} 起</span></div>${activityBars(data)}</section>
    <div class="activity-rankings">${ranking('常用目标 · 明细期',data.targets)}${ranking('来源 IP · 明细期',data.sources)}</div>
    <section class="card table-card activity-event-card"><div class="table-heading"><h3>行为明细 <span class="muted small">${data.total.toLocaleString()} 条</span></h3><span class="muted small">${esc(stamp(data.detail_since).slice(5,16))} 起 · 保留 ${data.detail_days} 天</span></div>${data.events.length?`<div class="table-scroll"><table class="activity-table"><thead><tr><th>时间（${tzName()}）</th><th>用户 / 服务器</th><th>来源 IP</th><th>目标</th><th>类型</th></tr></thead><tbody>${data.events.map(row=>`<tr><td class="mono">${esc(stamp(row.ts).slice(5))}</td><td><div class="cell-title">${esc(row.user_name)}</div><div class="cell-sub">${esc(row.node_name)}${row.inbound?' · '+esc(row.inbound):''}</div></td><td class="mono">${esc(row.source_ip||'—')}</td><td class="activity-target"><div class="mono" title="${esc(row.target)}">${esc(row.target||'—')}${row.port?':'+row.port:''}</div>${row.message?`<div class="cell-sub activity-message" title="${esc(row.message)}">${esc(row.message)}</div>`:''}</td><td>${row.kind==='connection'?badge((row.network||'TCP').toUpperCase(),'blue'):row.kind==='error'?badge('错误','red'):badge('缺口','amber')}</td></tr>`).join('')}</tbody></table></div>`:empty(filter.q?'没有匹配的目标':'暂无行为记录')}
    <div class="activity-pagination"><span class="muted small">第 ${data.page} / ${pages} 页</span><div><button data-action="activity-prev" ${data.page<=1?'disabled':''}>上一页</button><button data-action="activity-next" ${data.page>=pages?'disabled':''}>下一页</button></div></div></section>`;
}

function renderLogs(){$('content').innerHTML=`<section class="card table-card">${state.logs.length?`<div class="table-scroll"><table><thead><tr><th>时间（${tzName()}）</th><th>操作者</th><th>操作</th><th>详情</th></tr></thead><tbody>${state.logs.map(l=>`<tr><td>${stamp(l.ts)}</td><td class="mono">${esc(l.actor.length>18?l.actor.slice(0,16)+'…':l.actor)}</td><td class="log-action">${esc(l.action)}</td><td class="log-detail">${esc(l.detail)}</td></tr>`).join('')}</tbody></table></div>`:empty('暂无操作记录')}</section>`;}
function renderSettings(){$('content').innerHTML=`<div class="settings-grid"><section class="card"><div class="card-head"><div><h3>修改管理员密码</h3><p>修改后，所有已登录会话都会退出。</p></div></div><form id="password-form"><label>当前密码<input name="old_password" type="password" required autocomplete="current-password" maxlength="256"></label><label>新密码<input name="new_password" type="password" required minlength="12" maxlength="256" autocomplete="new-password" placeholder="至少 12 个字符"></label><label>再次输入新密码<input name="confirm_password" type="password" required minlength="12" maxlength="256" autocomplete="new-password"></label><div class="form-footer"><button class="primary" type="submit">更新密码</button></div></form></section><div class="form-grid"><section class="card"><div class="card-head"><div><h3>数据备份</h3></div></div><p class="muted">备份包含代理认证资料，请妥善保管。</p><div class="form-footer"><a class="inline-link" href="/api/admin/backup">下载数据库备份 ↓</a></div></section><section class="card"><div class="card-head"><div><h3>统计时区</h3></div></div><form id="timezone-form"><label>时区偏移（分钟）<input name="timezone_offset" type="number" min="-720" max="840" step="15" value="${Number(state.settings.timezone_offset)}" required></label><p class="form-help">UTC+8 = 480；UTC = 0。明细保留 100 天，累计永久保留。</p><div class="form-footer"><button type="submit">保存时区</button></div></form></section><section class="card"><div class="card-head"><h3>行为记录保留</h3></div><form id="activity-retention-form"><div class="form-row"><label>明细（天）<input name="activity_detail_days" type="number" min="1" max="30" value="${Number(state.settings.activity_detail_days||7)}" required></label><label>汇总（天）<input name="activity_summary_days" type="number" min="1" max="90" value="${Number(state.settings.activity_summary_days||90)}" required></label></div><div class="form-footer"><button type="submit">保存期限</button></div></form></section></div></div>`;}
function render() {
  let status = state.view === 'overview' ? state.overview : null;
  if (state.view === 'nodes' || state.view === 'users') {
    const active = state.nodes.filter(node => node.status === 'active');
    status = {
      pending_nodes: state.nodes.filter(node => node.status === 'pending').length,
      unsynced_nodes: active.filter(node => node.revision !== node.applied_revision).length,
      error_nodes: active.filter(node => node.last_error || node.sample_error).length
    };
  }
  const messages = [];
  if (status?.pending_nodes) messages.push(`${status.pending_nodes} 台服务器正在完成自动接入。`);
  if (status?.unsynced_nodes) messages.push(`${status.unsynced_nodes} 台服务器的配置等待同步。`);
  if (status?.error_nodes) messages.push(`${status.error_nodes} 台服务器需要处理，请查看服务器详情。`);
  $('notice').hidden = !messages.length;
  $('notice').className = 'notice';
  $('notice').textContent = messages.join(' ');
  ({overview: renderOverview, users: renderUsers, nodes: renderNodes, subscriptions:renderSubscriptions, activity:renderActivity, logs: renderLogs, settings: renderSettings}[state.view])();
}
function setView(view,fetchNow=true){
  if(!views[view])return;
  if(fetchNow&&view===state.view)return refresh(true);
  clearSyncFollowup();state.refreshTask?.controller.abort();state.refreshTask=null;state.view=view;state.settingsDirty=false;state.activityRetentionDirty=false;state.templatesDirty=false;location.hash=view;
  const [title,crumb]=views[view];$('page-title').textContent=title;$('crumb').textContent=crumb;
  document.querySelectorAll('#nav button').forEach(b=>b.classList.toggle('active',b.dataset.view===view));$('filter-bar').hidden=!['users','nodes','subscriptions'].includes(view);$('month-filter').hidden=view!=='users';$('search').value='';
  const searchLabel=view==='subscriptions'?'搜索用户名或订阅名称':view==='nodes'?'搜索服务器名称或主机名':'搜索用户名或服务器';$('search').placeholder=searchLabel;$('search').ariaLabel=searchLabel;
  $('page-actions').innerHTML=view==='users'?'<button class="primary" data-action="new-user">＋ 新增用户</button>':view==='nodes'?'<button class="primary" data-action="new-node">＋ 添加服务器</button>':view==='overview'?'<button data-action="refresh">刷新</button><button class="primary" data-action="new-node">＋ 接入服务器</button>':'';
  render();if(fetchNow)return refresh(true);
}
async function refresh(force=false){
  if(!state.session||(!force&&(document.hidden||$('modal').open||state.view==='settings')))return false;
  if(state.refreshTask){if(!force)return false;state.refreshTask.controller.abort();}
  const task={view:state.view,epoch:state.epoch,controller:new AbortController()};state.refreshTask=task;
  const paths={overview:['overview','users','traffic?days=7'],users:[state.userMonth?'users?month='+encodeURIComponent(state.userMonth):'users','nodes'],nodes:['nodes'],subscriptions:['subscriptions'],activity:[activityPath()],logs:['logs'],settings:['settings']}[task.view].slice();
  if(!state.settingsLoaded&&!paths.includes('settings'))paths.push('settings');
  try{
    const results=await Promise.all(paths.map(path=>api('/api/admin/'+path,'GET',undefined,{signal:task.controller.signal})));
    if(task!==state.refreshTask||task.epoch!==state.epoch||task.view!==state.view||!state.session)return false;
    paths.forEach((path,index)=>{
      const data=results[index];
      if(path==='overview')state.overview=data;else if(path.split('?')[0]==='users'){state.users=data.users;state.userPeriod=data.period||null;}else if(path==='nodes')state.nodes=data.nodes;else if(path==='subscriptions')state.subscriptions=data.subscriptions;else if(path.split('?')[0]==='activity')state.activity=data;else if(path==='logs')state.logs=data.logs;else if(path==='settings'){state.settings=data;state.settingsLoaded=true;}else state.chart=data;
      if(Number.isFinite(data.timezone_offset)){state.settings={...state.settings,timezone_offset:data.timezone_offset};state.settingsLoaded=true;}
    });
    if(task.view==='settings'){
      const input=$('timezone-form')?.elements.namedItem('timezone_offset');if(input&&!state.settingsDirty)input.value=state.settings.timezone_offset;
      if(!state.activityRetentionDirty){for(const key of ['activity_detail_days','activity_summary_days']){const input=$('activity-retention-form')?.elements.namedItem(key);if(input)input.value=state.settings[key];}}
      $('notice').hidden=true;
    }else if(task.view==='subscriptions'){
      renderSubscriptions(true);
      if(!state.templatesDirty){const form=$('subscription-template-form');for(const key of ['node_name_template','clash_template']){const input=form?.elements.namedItem(key);if(input)input.value=state.settings[key]||'';}}
    }else if(task.view==='activity')renderActivity(true);else render();
    $('last-refresh').textContent='更新于 '+stamp(Math.floor(Date.now()/1000)).slice(11)+' · '+tzName();$('clock').textContent=stamp(Math.floor(Date.now()/1000)).slice(0,10);
    return true;
  }catch(error){
    task.controller.abort();
    if(error.name!=='AbortError'&&task===state.refreshTask&&task.epoch===state.epoch&&state.session){$('notice').hidden=false;$('notice').className='notice error';$('notice').textContent=error.message;}
    return false;
  }finally{if(state.refreshTask===task){state.refreshTask=null;$('content').classList.toggle('is-loading',false);}}
}
function modal(title,body,large=false){$('modal-title').textContent=title;$('modal-body').innerHTML=body;$('modal').className=large?'large':'';if(!$('modal').open)$('modal').showModal();}
function clearSyncFollowup(){if(state.syncFollowup){clearTimeout(state.syncFollowup.timer);state.syncFollowup.controller?.abort();state.syncFollowup=null;}}
function followSync(){
  clearSyncFollowup();if(!['users','nodes','overview'].includes(state.view))return;
  const task={epoch:state.epoch,view:state.view,remaining:8,timer:null,controller:null};state.syncFollowup=task;
  const check=async()=>{
    if(state.syncFollowup!==task||task.epoch!==state.epoch||task.view!==state.view||document.hidden||$('modal').open||!state.session){clearSyncFollowup();return;}
    task.controller=new AbortController();
    try{
      const data=await api('/api/admin/nodes','GET',undefined,{signal:task.controller.signal});
      if(state.syncFollowup!==task||task.epoch!==state.epoch||task.view!==state.view)return;
      state.nodes=data.nodes;
      const pending=data.nodes.some(node=>node.status==='active'&&node.revision!==node.applied_revision);
      if(task.view==='overview'){if(!pending)await refresh(true);}else if(task.view==='nodes')renderNodes();else{
        const versions=new Map(data.nodes.map(node=>[node.id,node]));
        for(const user of state.users)user.nodes=user.nodes.map(node=>({...node,...(versions.get(node.id)||{})}));renderUsers();
      }
      if(!pending||--task.remaining<=0){clearSyncFollowup();return;}
      task.timer=setTimeout(check,1200);
    }catch(error){if(state.syncFollowup===task)clearSyncFollowup();}
  };
  task.timer=setTimeout(check,800);
}
function clearTraffic(){state.trafficTask?.controller.abort();state.trafficTask=null;state.trafficUser=null;}
function clearSubscription(){state.subscriptionTask?.controller.abort();state.subscriptionTask=null;}
function closeModal(){clearTraffic();clearSubscription();if($('modal').open)$('modal').close();$('modal-body').innerHTML='';}
function localDateTime(value){if(!value)return '';const date=new Date(Number(value)*1000);return new Date(date.getTime()-date.getTimezoneOffset()*60000).toISOString().slice(0,16);}
function renderSubscription(data){
  const origin=(state.session.origin||location.origin).replace(/\/$/,'');
  const allowed=data.enabled&&!data.quota_blocked&&data.nodes_count>0&&data.subscription_enabled!==false&&!data.subscription_expired;
  const url=origin+data.url;
  const links=`<section class="subscription-link"><div class="copy-row"><strong>订阅链接</strong><button data-action="copy" data-target="sub-universal">复制链接</button></div><div class="code-box" id="sub-universal">${esc(url)}</div>${allowed?`<div class="subscription-download-row"><label for="subscription-format">下载格式</label><select id="subscription-format"><option value="clash">Clash / Mihomo</option><option value="v2ray">V2Ray</option></select><a id="subscription-download" class="inline-link" data-url="${esc(url)}" href="${esc(url+'?format=clash')}" download>下载</a></div>`:''}</section>`;
  const warning=data.subscription_enabled===false?'订阅已失效':data.subscription_expired?'订阅已过期':!data.enabled?'用户已禁用':data.quota_blocked?'流量额度已用尽':'';
  modal(data.name+' · 订阅',`<div class="subscription-summary"><span>${data.nodes_count} 个节点</span><span>${data.quota_period==='monthly'?'每月额度':'累计额度'}</span></div>
    ${warning?`<div class="notice">${warning}</div>`:''}
    <div class="detail-metrics"><div><span>已用</span><strong>${bytes(data.quota_used)}</strong></div><div><span>额度</span><strong>${data.quota_bytes?bytes(data.quota_bytes):'不限'}</strong></div><div><span>剩余</span><strong>${data.quota_remaining===null?'不限':bytes(data.quota_remaining)}</strong></div></div>
    <div class="form-grid">${links}</div>
    ${data.missing.length?`<p class="form-help">以下入口缺少订阅信息，请更新节点端脚本并同步：${data.missing.map(esc).join('、')}</p>`:''}
    ${data.quota_reset&&data.quota_bytes?`<p class="form-help">下次重置：${stamp(data.quota_reset)}（${tzName()}）</p>`:''}
    <form id="subscription-form" data-id="${esc(data.id)}" class="form-grid subscription-settings"><div class="form-row"><label>订阅名称<input name="subscription_name" value="${esc(data.subscription_name||'plzquick')}" maxlength="80" required></label><label>过期时间（本机时区）<input name="subscription_expires_at" type="datetime-local" value="${localDateTime(data.subscription_expires_at)}"></label></div><label class="checkbox-label"><input name="subscription_enabled" type="checkbox" ${data.subscription_enabled!==false?'checked':''}>启用订阅链接</label><div class="form-footer"><button type="button" class="danger" data-action="invalidate-subscription" data-id="${esc(data.id)}" ${data.subscription_enabled===false?'disabled':''}>立即失效</button><button type="submit" class="primary">保存设置</button></div></form>
    <p class="form-help">到期或失效仅停止订阅更新，已导入节点仍可连接；停用用户可撤销连接授权。</p>
    <div class="form-footer"><button class="danger" data-action="reset-subscription" data-id="${esc(data.id)}">重置订阅链接</button><button data-action="close-modal">关闭</button></div>`);
}
async function showSubscription(uid,update=null){
  clearSubscription();const task={controller:new AbortController(),epoch:state.epoch};state.subscriptionTask=task;
  modal('用户订阅','<p role="status">正在读取订阅…</p>');
  try{
    const body=update===true?{reset:true}:update;
    const data=await api('/api/admin/users/'+encodeURIComponent(uid)+'/subscription',body?'POST':'GET',body||undefined,{signal:task.controller.signal});
    if(state.subscriptionTask!==task||task.epoch!==state.epoch||!$('modal').open)return false;
    renderSubscription(data);state.subscriptions=state.subscriptions.map(item=>item.id===uid?data:item);if(state.view==='subscriptions')renderSubscriptions(true);return true;
  }catch(error){if(error.name!=='AbortError'&&state.subscriptionTask===task&&$('modal').open)$('modal-body').innerHTML=`<p class="form-error">${esc(error.message)}</p>`;return false;}
  finally{if(state.subscriptionTask===task)state.subscriptionTask=null;}
}
function userForm(user=null){const active=state.nodes.filter(n=>n.status==='active');modal(user?'编辑用户':'新增用户',`<form id="user-form" class="form-grid" data-id="${esc(user?.id||'')}"><label>用户名<input name="name" value="${esc(user?.name||'')}" pattern="[A-Za-z0-9]{1,32}" maxlength="32" required placeholder="例如 alice"><p class="form-help">1–32 位英文字母或数字。</p></label><div class="form-row"><label>UUID<div class="password-wrap"><input id="user-uuid" name="uuid" type="password" value="${esc(user?.uuid||'')}" autocomplete="off" placeholder="留空自动生成"><button type="button" data-action="show-secret" data-target="user-uuid">显示</button></div></label><label>TUIC 密码<div class="password-wrap"><input id="user-tuic" name="tuic_pass" type="password" value="${esc(user?.tuic_pass||'')}" autocomplete="off" placeholder="留空自动生成"><button type="button" data-action="show-secret" data-target="user-tuic">显示</button></div></label></div><div class="form-row"><label>流量额度（GiB）<input name="quota_gib" type="number" min="0" max="8388607" step="any" required value="${Number(user?.quota_bytes||0)/1073741824}"></label><label>额度周期<select name="quota_period"><option value="monthly" ${!user||user.quota_period==='monthly'?'selected':''}>每月重置</option><option value="total" ${user?.quota_period==='total'?'selected':''}>累计总额</option></select></label></div><p class="form-help">上传＋下载合计，0 为不限额。</p><label class="checkbox-label"><input name="enabled" type="checkbox" ${!user||user.enabled?'checked':''}>启用此用户</label><div><label>授权服务器</label><div class="node-choice">${active.length?active.map(n=>`<label><input type="checkbox" name="node_ids" value="${n.id}" ${user?.node_ids.includes(n.id)?'checked':''}>${esc(n.name)}<small>${n.online?'在线':'离线'}</small></label>`).join(''):'<p class="muted small">暂无服务器，可稍后授权。</p>'}</div></div>${user?'<p class="inline-note">修改认证资料后，需同步更新客户端。</p>':''}<div class="form-footer">${user?`<button type="button" class="danger" data-action="reset-user" data-id="${user.id}">重置认证凭据</button>`:''}<button type="button" data-action="close-modal">取消</button><button type="submit" class="primary">保存用户</button></div></form>`);}
function newNode(){modal('添加服务器',`<form id="node-form" class="form-grid"><label>服务器名称<input name="name" required maxlength="80" placeholder="例如 香港 01"></label><p class="inline-note">接入码 10 分钟内有效。</p><div class="form-footer"><button type="button" data-action="close-modal">取消</button><button type="submit" class="primary">生成连接信息</button></div></form>`);}
function showJoin(data){const connectLine=(state.session.origin||location.origin).replace(/\/$/,'')+'|'+data.join_code;modal('连接 '+data.name,`<div class="form-grid"><div><div class="copy-row"><span>一键连接信息</span><button class="primary" data-action="copy" data-target="join-line">复制整句</button></div><div id="join-line" class="code-box">${esc(connectLine)}</div><p class="form-help">有效期至 ${stamp(data.expires_at)}（${tzName()}）。</p></div><div class="inline-note">在节点执行 <strong>ysq</strong> →「中控连接管理」→「HTTPS 连接中控」，粘贴上方连接信息。</div><div class="form-footer"><button class="primary" data-action="join-done">完成</button></div></div>`);}
function renameNode(node){if(!node)return;modal('修改服务器名称',`<form id="rename-node-form" data-id="${esc(node.id)}" class="form-grid"><label>服务器名称<input name="name" value="${esc(node.name)}" maxlength="80" required autofocus></label><div class="form-footer"><button type="button" data-action="close-modal">取消</button><button type="submit" class="primary">保存名称</button></div></form>`);}
function renderTraffic(user,data){
  const period=data.period;
  modal((user?.name||'用户')+' · 月度流量',`
    <div class="traffic-toolbar"><div><h3>${monthLabel(period.month)}</h3><p>${tzName()}</p></div><label class="month-picker">统计月份<select id="traffic-month" aria-label="详情统计月份">${monthOptions(period)}</select></label></div>
    <p id="traffic-status" class="form-error" role="status" hidden></p>
    <div id="traffic-data"><div class="detail-metrics">
      <div><span>月度上传</span><strong class="traffic-up">${bytes(period.up)}</strong></div>
      <div><span>月度下载</span><strong class="traffic-down">${bytes(period.down)}</strong></div>
      <div><span>月度合计</span><strong>${bytes(period.total)}</strong></div>
    </div><div class="card-head"><div><h3>每日流量</h3></div></div><div id="detail-chart"></div>
    <div class="section-header"><h3>服务器流量</h3></div>
    ${data.by_node.length?`<div class="table-scroll"><table><thead><tr><th>服务器</th><th>上传</th><th>下载</th><th>合计</th></tr></thead><tbody>${data.by_node.map(node=>`<tr><td>${esc(node.name)}</td><td class="traffic-up">${bytes(node.up)}</td><td class="traffic-down">${bytes(node.down)}</td><td><strong>${bytes(node.total)}</strong></td></tr>`).join('')}</tbody></table></div>`:'<p class="muted small">此月没有上报记录。</p>'}
    ${periodNote(period)}<p class="form-help">历史累计：上传 ${bytes(data.lifetime.up)} · 下载 ${bytes(data.lifetime.down)} · 合计 ${bytes(data.lifetime.total)}。</p></div>`,true);
  const today=stamp(Date.now()/1000).slice(0,10);
  drawChart('detail-chart',data.daily.filter(row=>row.date<=today),true);
}
async function showTraffic(uid,selectedMonth){
  selectedMonth=selectedMonth||(state.view==='users'?state.userMonth:'')||'latest';
  state.trafficTask?.controller.abort();
  const task={uid,controller:new AbortController(),epoch:state.epoch};state.trafficTask=task;
  const user=state.users.find(user=>user.id===uid);
  if(state.trafficUser!==uid||!$('modal').open)modal((user?.name||'用户')+' · 月度流量','<p id="traffic-status" role="status">正在读取流量…</p>',true);
  state.trafficUser=uid;
  const status=$('traffic-status');if(status){status.hidden=false;status.textContent='正在读取流量…';}
  if($('traffic-data'))$('traffic-data').hidden=true;
  try{
    const data=await api('/api/admin/traffic?user_id='+encodeURIComponent(uid)+'&month='+encodeURIComponent(selectedMonth),'GET',undefined,{signal:task.controller.signal});
    if(task!==state.trafficTask||task.epoch!==state.epoch||!$('modal').open)return false;
    if(Number.isFinite(data.timezone_offset))state.settings.timezone_offset=data.timezone_offset;
    renderTraffic(user,data);return true;
  }catch(error){
    if(error.name!=='AbortError'&&task===state.trafficTask&&$('modal').open){const status=$('traffic-status');if(status){status.hidden=false;status.textContent=error.message;}}
    return false;
  }finally{if(state.trafficTask===task)state.trafficTask=null;}
}
function nodeDetail(n){modal(n.name+' · 详情',`<div class="form-grid"><div>${nodeBadge(n)}</div><div class="node-line"><span>服务器 ID</span><b class="mono">${esc(n.id)}</b></div><div class="node-line"><span>主机名</span><b>${esc(n.hostname||'—')}</b></div><div class="node-line"><span>Agent 版本</span><b>${esc(n.agent_version||'—')}</b></div><div class="node-line"><span>最后心跳</span><b>${stamp(n.last_seen)}</b></div><div class="node-line"><span>最后采集</span><b>${stamp(n.last_sample_at)}</b></div><div class="node-line"><span>已应用 / 目标版本</span><b>${n.applied_revision} / ${n.revision}</b></div>${n.last_error?`<div class="node-error">${esc(n.last_error)}</div>`:''}${n.sample_error?`<div class="node-error">${esc(n.sample_error)}</div>`:''}<div><h3>注册时的入口信息</h3>${n.inbounds.length?`<div class="table-scroll"><table><thead><tr><th>名称</th><th>类型</th><th>端口</th></tr></thead><tbody>${n.inbounds.map(i=>`<tr><td>${esc(i.name)}</td><td>${esc(i.type)}</td><td>${Number(i.port)}</td></tr>`).join('')}</tbody></table></div>`:'<p class="muted small">注册时没有入口节点。</p>'}</div>${['revoked','detached'].includes(n.status)?'<p class="inline-note">中控已停止接受此服务器的同步。服务器上保留的代理配置可能仍在运行，需在节点本机确认。</p>':''}<div class="form-footer"><button data-action="close-modal">关闭</button></div></div>`);}
async function action(button){
  const key=button.dataset.action,id=button.dataset.id;if(!key)return;
  if(['show-secret','copy','close-modal','join-done'].includes(key)){
    if(key==='show-secret'){const input=$(button.dataset.target);input.type=input.type==='password'?'text':'password';button.textContent=input.type==='password'?'显示':'隐藏';}
    if(key==='copy'){const text=$(button.dataset.target).textContent;try{await navigator.clipboard.writeText(text);toast('已复制');}catch{toast('请选中文本后手动复制');}}
    if(key==='close-modal')closeModal();if(key==='join-done'){closeModal();setView('nodes');}return;
  }
  button.disabled=true;
  try{
    if(key==='refresh'&&await refresh(true))toast('已刷新');
    if(key==='new-user'){state.nodes=(await api('/api/admin/nodes')).nodes;userForm();}
    if(key==='new-node')newNode();
    if(key==='edit-user'||key==='quota-user'){const [user,nodes]=await Promise.all([api('/api/admin/users/'+id),api('/api/admin/nodes')]);state.nodes=nodes.nodes;userForm(user);if(key==='quota-user')document.querySelector('#user-form input[name="quota_gib"]')?.focus();}
    if(key==='activity-user'){
      state.activityFilter={...state.activityFilter,user_id:id,page:1};state.activity=null;
      await setView('activity');
    }
    if(key==='activity-prev'||key==='activity-next'){
      state.activityFilter.page=Math.max(1,(state.activity?.page||1)+(key==='activity-next'?1:-1));await refresh(true);
    }
    if(key==='traffic')await showTraffic(id);
    if(key==='subscription')await showSubscription(id);
    if(key==='reset-subscription'&&confirm('重置后旧订阅链接立即失效，继续？'))await showSubscription(id,true);
    if(key==='invalidate-subscription'&&await showSubscription(id,{subscription_enabled:false}))toast('订阅链接已失效');
    if(key==='toggle-user'){const u=state.users.find(x=>x.id===id);if(!u.enabled||confirm('禁用 '+u.name+'？')){await api('/api/admin/users/'+id,'POST',{enabled:!u.enabled});toast('用户状态已保存');await refresh(true);followSync();}}
    if(key==='delete-user'){const u=state.users.find(x=>x.id===id);if(confirm('彻底删除 '+u.name+'？用户、流量记录和订阅链接将一并清除。')){await api('/api/admin/users/'+id,'DELETE',{});toast('用户和相关数据已删除');await refresh(true);followSync();}}
    if(key==='reset-user'&&confirm('重置 UUID 和 TUIC 密码？此用户所有客户端都需要更新认证资料。')){await api('/api/admin/users/'+id,'POST',{reset_credentials:true});userForm(await api('/api/admin/users/'+id));toast('认证凭据已重置，请更新客户端');await refresh(true);}
    if(key==='join-code')showJoin(await api('/api/admin/nodes/'+id+'/join-code','POST',{}));
    if(key==='rename-node')renameNode(state.nodes.find(n=>n.id===id));if(key==='node-detail')nodeDetail(state.nodes.find(n=>n.id===id));
    if(key==='delete-node'&&confirm('彻底删除这台服务器？流量记录和用户绑定将清除，VPS 联网后自动解绑中控。')){await api('/api/admin/nodes/'+id,'DELETE',{});toast('服务器和相关数据已删除');await refresh(true);}
  }catch(error){if(error.name!=='AbortError')toast(error.message,true);}finally{button.disabled=false;}
}
document.addEventListener('click',event=>{const button=event.target.closest('button');if(!button)return;if(button.dataset.view){setView(button.dataset.view);return;}if(button.dataset.action)action(button);});
document.addEventListener('submit',async event=>{
  const form=event.target;if(!['login-form','user-form','node-form','rename-node-form','password-form','timezone-form','subscription-form','subscription-template-form','activity-filter-form','activity-retention-form'].includes(form.id))return;
  event.preventDefault();const submit=form.querySelector('button[type="submit"]');if(submit)submit.disabled=true;
  try{
    const data=new FormData(form);
    if(form.id==='login-form'){$('login-error').textContent='';state.session=await api('/api/auth/login','POST',{username:data.get('username'),password:data.get('password')});state.session.origin=location.origin;form.reset();showApp();await refresh(true);}
    if(form.id==='user-form'){const gib=Number(data.get('quota_gib'));const quota=Math.round(gib*1073741824);if(!Number.isFinite(gib)||gib<0||!Number.isSafeInteger(quota))throw new Error('请输入有效的流量额度');const body={quota_bytes:quota,quota_period:data.get('quota_period')||'monthly',name:data.get('name'),uuid:data.get('uuid'),tuic_pass:data.get('tuic_pass'),enabled:data.has('enabled'),node_ids:data.getAll('node_ids')};const result=await api('/api/admin/users'+(form.dataset.id?'/'+form.dataset.id:''),'POST',body);closeModal();toast('用户设置已保存');await refresh(true);if(result.requires_sync)followSync();}
    if(form.id==='subscription-form'){
      const expiration=data.get('subscription_expires_at'),expires=expiration?Math.floor(new Date(expiration).getTime()/1000):0;
      if(!Number.isSafeInteger(expires)||expires<0)throw new Error('请输入有效的过期时间');
      if(await showSubscription(form.dataset.id,{subscription_name:data.get('subscription_name'),subscription_enabled:data.has('subscription_enabled'),subscription_expires_at:expires}))toast('订阅设置已保存');
    }
    if(form.id==='activity-filter-form'){
      state.activityFilter={user_id:data.get('user_id')||'',node_id:data.get('node_id')||'',hours:Number(data.get('hours')),q:data.get('q')||'',page:1};
      await refresh(true);
    }
    if(form.id==='activity-retention-form'){
      const body={activity_detail_days:Number(data.get('activity_detail_days')),activity_summary_days:Number(data.get('activity_summary_days'))};
      await api('/api/admin/settings','POST',body);state.settings={...state.settings,...body};state.activityRetentionDirty=Object.keys(body).some(key=>Number(form.elements.namedItem(key).value)!==body[key]);toast('行为保留期限已保存');
    }
    if(form.id==='subscription-template-form'){
      const body={node_name_template:data.get('node_name_template'),clash_template:data.get('clash_template')};
      await api('/api/admin/settings','POST',body);state.settings={...state.settings,...body};state.settingsLoaded=true;state.templatesDirty=false;toast('订阅模板已保存');
    }
    if(form.id==='node-form'){const result=await api('/api/admin/nodes','POST',{name:data.get('name')});showJoin(result);await refresh(true);}
    if(form.id==='rename-node-form'){await api('/api/admin/nodes/'+form.dataset.id,'POST',{name:data.get('name')});closeModal();toast('服务器名称已更新');await refresh(true);}
    if(form.id==='password-form'){if(data.get('new_password')!==data.get('confirm_password'))throw new Error('两次输入的新密码不一致');await api('/api/admin/password','POST',{old_password:data.get('old_password'),new_password:data.get('new_password')});showLogin();toast('密码已更新，请重新登录');}
    if(form.id==='timezone-form'){
      const offset=Number(data.get('timezone_offset'));await api('/api/admin/settings','POST',{timezone_offset:offset});
      state.settings={...state.settings,timezone_offset:offset};state.settingsLoaded=true;
      state.settingsDirty=Number(form.elements.namedItem('timezone_offset').value)!==offset;
      toast('统计时区已更新');await refresh(true);
    }
  }catch(error){if(error.name!=='AbortError'){if(form.id==='login-form')$('login-error').textContent=error.message;else toast(error.message,true);}}
  finally{if(submit)submit.disabled=false;}
});
$('logout').addEventListener('click',async()=>{try{await api('/api/auth/logout','POST',{});showLogin();}catch(error){if(error.name!=='AbortError')toast(error.message,true);}});
$('close-modal').addEventListener('click',closeModal);$('modal').addEventListener('click',e=>{if(e.target===$('modal')){const r=$('modal').getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)closeModal();}});
$('search').addEventListener('input',()=>state.view==='users'?renderUsers():state.view==='subscriptions'?renderSubscriptions(true):renderNodes());
window.addEventListener('hashchange',()=>{const view=location.hash.slice(1);if(state.session&&views[view]&&view!==state.view)setView(view);});
let chartResizeTimer;
window.addEventListener('resize',()=>{
  clearTimeout(chartResizeTimer);
  chartResizeTimer=setTimeout(()=>{
    for(const id of ['overview-chart','detail-chart']){
      const chart=$(id);if(chart?.chartRows)drawChart(id,chart.chartRows,chart.chartSplit);
    }
  },120);
});

$('modal').addEventListener('close',()=>{clearTraffic();clearSubscription();});
document.addEventListener('change',event=>{
  if(event.target.id==='user-month'){
    state.userMonth=event.target.value===state.userPeriod?.latest_month?'':event.target.value;
    $('content').classList.toggle('is-loading',true);refresh(true);
  }
  if(event.target.id==='traffic-month'&&state.trafficUser)showTraffic(state.trafficUser,event.target.value);
  if(event.target.id==='subscription-format'){
    const link=$('subscription-download');if(link)link.href=link.dataset.url+'?format='+encodeURIComponent(event.target.value);
  }
});
document.addEventListener('input',event=>{if(event.target.form?.id==='timezone-form')state.settingsDirty=true;if(event.target.form?.id==='activity-retention-form')state.activityRetentionDirty=true;if(event.target.form?.id==='subscription-template-form')state.templatesDirty=true;});
document.addEventListener('visibilitychange',()=>{if(document.hidden){state.refreshTask?.controller.abort();clearSyncFollowup();}else if(!$('modal').open&&state.view!=='settings')refresh(true);});
(async()=>{try{state.session=await api('/api/admin/session');showApp();await refresh(true);}catch(error){if(error.name!=='AbortError')showLogin();}})();
setInterval(()=>refresh(false),REFRESH_MS);
'''


def normalize_origin(value, dev=False):
    parsed = urllib.parse.urlsplit(value)
    if parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/"):
        raise ValueError("--origin 必须是完整域名来源，不能包含路径、查询参数或认证资料")
    if parsed.scheme not in ("https", "http") or not parsed.hostname:
        raise ValueError("--origin 必须包含 https://")
    try:
        parsed.port
    except ValueError:
        raise ValueError("--origin 端口不合法")
    if parsed.scheme != "https":
        if not dev or parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
            raise ValueError("生产环境 --origin 必须使用 HTTPS；HTTP 仅允许 --dev 的本机地址")
    if dev and parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError("--dev 只能配合本机 origin，不能用于公网域名")
    return f"{parsed.scheme}://{parsed.netloc}".rstrip("/")


def main(argv=None):
    parser = argparse.ArgumentParser(description="YSQ 单文件中控（Python 标准库 / SQLite / 内置网页）")
    parser.add_argument("--data-dir", default="/var/lib/ysq-center", help="数据库目录（默认 /var/lib/ysq-center）")
    parser.add_argument("--host", default="127.0.0.1", help="只允许回环地址，供同机 Nginx 代理")
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--origin", default="https://panel.eulmo.com", help="浏览器和 Agent 使用的公开 HTTPS 来源")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--init-admin", metavar="USER", help="创建管理员后退出")
    group.add_argument("--reset-admin", metavar="USER", help="重置管理员密码并注销会话后退出")
    group.add_argument("--check", action="store_true", help="检查数据库与管理员；无管理员退出码 3")
    parser.add_argument("--dev", action="store_true", help="仅本机测试：允许 HTTP origin 和非 Secure Cookie")
    parser.add_argument("--version", action="version", version=VERSION)
    args = parser.parse_args(argv)
    os.umask(0o077)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        if not ipaddress.ip_address(args.host).is_loopback:
            raise ValueError("中控只允许监听回环地址。请由 Nginx 对外提供 HTTPS。")
        if not 1 <= args.port <= 65535:
            raise ValueError("监听端口必须是 1–65535")
        origin = normalize_origin(args.origin, args.dev)
        store = Store(args.data_dir)
        if args.init_admin or args.reset_admin:
            password = os.environ.pop("YSQ_ADMIN_PASSWORD", None)
            if password is None:
                password = getpass.getpass("管理员密码（至少 12 个字符）: ")
                if password != getpass.getpass("再次输入密码: "):
                    raise ValueError("两次密码不一致")
            store.initialize_admin(args.init_admin or args.reset_admin, password, reset=bool(args.reset_admin))
            del password
            print("管理员已创建。" if args.init_admin else "管理员密码已重置，原会话已注销。")
            return 0
        if args.check:
            with store.connect() as db:
                checks = [r[0] for r in db.execute("PRAGMA quick_check")]
                foreign = db.execute("PRAGMA foreign_key_check").fetchone()
            if checks != ["ok"] or foreign:
                raise ValueError("数据库一致性检查未通过")
            if not store.has_admin():
                print("数据库结构正常，但尚未创建管理员。", flush=True)
                return 3
            print("数据库检查通过，管理员已配置。")
            return 0
        if not store.has_admin():
            raise ValueError("尚未创建管理员。请先执行 --init-admin admin；不会开放匿名初始化页面。")
        server = CenterServer((args.host, args.port), store, origin, args.dev)
        def stop_server(signum, frame):
            threading.Thread(target=server.shutdown, daemon=True).start()
        signal.signal(signal.SIGTERM, stop_server)
        signal.signal(signal.SIGINT, stop_server)
        LOG.info("YSQ %s 已启动：HTTP %s:%s；公开地址 %s", VERSION, args.host, args.port, origin)
        if args.dev:
            LOG.warning("本机开发模式已启用，仅用于本机验证")
        try:
            server.serve_forever(poll_interval=0.5)
        finally:
            server.server_close()
        return 0
    except (APIError, ValueError, OSError, sqlite3.Error, RuntimeError) as exc:
        LOG.error("%s", str(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
