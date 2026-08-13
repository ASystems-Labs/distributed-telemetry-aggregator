import os, sqlite3, hmac, hashlib, logging
from datetime import datetime, timezone
from flask import Flask, request, jsonify, g

app = Flask(__name__)
DB = os.getenv("DLA_DB", "telemetry.db")
API_TOKEN = os.getenv("DLA_API_TOKEN", "change-me")
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
log = logging.getLogger("dla")

def db():
    if "db" not in g:
        g.db = sqlite3.connect(DB)
        g.db.execute("""CREATE TABLE IF NOT EXISTS telemetry(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            node_id TEXT NOT NULL,
            received_at TEXT NOT NULL,
            payload TEXT NOT NULL,
            digest TEXT NOT NULL)""")
        g.db.commit()
    return g.db

@app.teardown_appcontext
def close_db(_):
    conn = g.pop("db", None)
    if conn: conn.close()

def authorized():
    value = request.headers.get("Authorization", "")
    expected = "Bearer " + API_TOKEN
    return hmac.compare_digest(value, expected)

@app.get("/healthz")
def healthz():
    return {"status":"ok"}

@app.post("/api/v1/telemetry")
def telemetry():
    if not authorized():
        return jsonify(error="unauthorized"), 401
    if not request.is_json:
        return jsonify(error="application/json required"), 415
    data = request.get_json(silent=True)
    if not isinstance(data, dict) or not isinstance(data.get("node_id"), str):
        return jsonify(error="invalid payload"), 400
    if len(data["node_id"]) > 128:
        return jsonify(error="node_id too long"), 400
    received = datetime.now(timezone.utc).isoformat()
    raw = request.get_data()
    digest = hashlib.sha256(raw).hexdigest()
    conn = db()
    conn.execute("INSERT INTO telemetry(node_id,received_at,payload,digest) VALUES(?,?,?,?)",
                 (data["node_id"], received, raw.decode("utf-8"), digest))
    conn.commit()
    log.info("telemetry accepted node=%s digest=%s", data["node_id"], digest)
    return jsonify(status="accepted", digest=digest), 202

@app.get("/api/v1/telemetry/<node_id>")
def node_telemetry(node_id):
    if not authorized():
        return jsonify(error="unauthorized"), 401
    rows = db().execute("""SELECT received_at,payload,digest FROM telemetry
                           WHERE node_id=? ORDER BY id DESC LIMIT 100""",(node_id,)).fetchall()
    return jsonify([{"received_at":r[0],"payload":r[1],"digest":r[2]} for r in rows])

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT","5000")))
