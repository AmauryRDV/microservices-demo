import os, json, redis, threading
from datetime import datetime, timezone
from flask import Flask, request, jsonify
from google.cloud import tasks_v2, storage, firestore

app = Flask(__name__)
db = firestore.Client()

# Redis connection (optional, with fallback)
try:
    r = redis.Redis(host=os.environ.get("REDIS_HOST", "127.0.0.1"), port=6379, decode_responses=True, socket_connect_timeout=2)
    r.ping()
    REDIS_AVAILABLE = True
except:
    REDIS_AVAILABLE = False
    r = None
    app.logger.warning("Redis not available, using Firestore as fallback")

# Config from Environment Variables
PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "gcp-ynov")
REGION = os.environ.get("REGION", "europe-west1")
SNAPSHOT_BUCKET = os.environ.get("SNAPSHOT_BUCKET")
TASK_QUEUE = os.environ.get("TASK_QUEUE")
PROCESSOR_URL = os.environ.get("PROCESSOR_URL")
RATE_LIMIT = int(os.environ.get("RATE_LIMIT_PER_MIN", 5))
RATE_WINDOW = 60  # secondes

tasks_client = tasks_v2.CloudTasksClient()
storage_client = storage.Client()

@app.before_request
def rate_limit_middleware():
    """Phase 4: Middleware for Rate Limiting"""
    if request.path == "/publish" and request.method == "POST":
        player_id = request.headers.get("X-Player-ID", "anonymous")
        doc_ref = db.collection("rate_limits").document(player_id)
        
        @firestore.transactional
        def check_and_update(transaction, doc_ref):
            snapshot = doc_ref.get(transaction=transaction)
            now = datetime.now(timezone.utc)
            
            if not snapshot.exists:
                # First request from this player
                transaction.set(doc_ref, {
                    "count": 1,
                    "window_start": now,
                    "last_request": now
                })
                return True
            
            data = snapshot.to_dict()
            window_start = data.get("window_start")
            count = data.get("count", 0)
            
            # Convert Timestamp to datetime if needed
            if hasattr(window_start, "timestamp"):
                window_start_dt = window_start
            else:
                window_start_dt = datetime.fromtimestamp(window_start, tz=timezone.utc) if isinstance(window_start, float) else window_start
            
            # Check if window expired
            elapsed = (now - window_start_dt).total_seconds()
            if elapsed > RATE_WINDOW:
                # Reset window
                transaction.set(doc_ref, {
                    "count": 1,
                    "window_start": now,
                    "last_request": now
                })
                return True
            
            # Check if rate limit exceeded
            if count >= RATE_LIMIT:
                return False
            
            # Increment counter
            transaction.set(doc_ref, {
                "count": count + 1,
                "window_start": window_start_dt,
                "last_request": now
            })
            return True

        try:
            allowed = check_and_update(db.transaction(), doc_ref)
            if not allowed:
                return jsonify({"error": "Rate limit exceeded", "player_id": player_id}), 429
        except Exception as e:
            app.logger.warning(f"Rate limit check failed: {e}")
            # Fail-open: allow request if rate limit check fails
            pass

@app.route("/publish", methods=["POST"])
def publish():
    data = request.get_json()
    timestamp = datetime.now(timezone.utc).isoformat()
    key = f"event:{os.environ.get('HOSTNAME', 'local')}:{timestamp}"
    
    # Store in Redis if available, otherwise in Firestore
    if REDIS_AVAILABLE and r:
        r.setex(key, 3600, json.dumps(data))
    else:
        db.collection("events").document(key).set({
            "data": data,
            "created_at": datetime.now(timezone.utc)
        })
    
    # Cloud Tasks: Delegate snapshot saving
    if TASK_QUEUE and PROCESSOR_URL:
        parent = tasks_client.queue_path(PROJECT_ID, REGION, TASK_QUEUE)
        task = {
            "http_request": {
                "http_method": tasks_v2.HttpMethod.POST,
                "url": f"{PROCESSOR_URL}/process",
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"redis_key": key}).encode(),
            }
        }
        try:
            tasks_client.create_task(request={"parent": parent, "task": task})
        except Exception as e:
            app.logger.warning(f"Failed to create Cloud Task: {e}")
    
    # Analytics: track usage (async, non-blocking)
    player_id = request.headers.get("X-Player-ID", "anonymous")
    _update_analytics_async(player_id)
    
    return jsonify({"status": "published", "redis_key": key, "data": data})

@app.route("/process", methods=["POST"])
def process():
    """Phase 3: Save to Cloud Storage"""
    body = request.get_json()
    key = body.get("redis_key")
    
    # Try to get from Redis first, then Firestore
    val = None
    if REDIS_AVAILABLE and r:
        val = r.get(key)
    
    if not val:
        # Try Firestore
        doc = db.collection("events").document(key).get()
        if doc.exists:
            val = json.dumps(doc.to_dict().get("data", {}))
    
    if val:
        bucket = storage_client.bucket(SNAPSHOT_BUCKET)
        blob = bucket.blob(f"snapshots/{key}.json")
        blob.upload_from_string(val, content_type="application/json")
        return jsonify({"status": "snapshot_saved", "key": key}), 200
    
    return jsonify({"status": "skipped", "reason": "data not found"}), 200

@app.route("/health")
def health():
    return jsonify({"status": "healthy"})

def _update_analytics_async(player_id: str):
    """Update analytics in background, non-blocking"""
    def _write():
        try:
            doc_ref = db.collection("analytics").document(player_id)
            doc_ref.set({
                "total_requests": firestore.Increment(1),
                "last_seen": datetime.now(timezone.utc),
            }, merge=True)
        except Exception as e:
            app.logger.warning(f"Analytics write failed: {e}")
    threading.Thread(target=_write, daemon=True).start()

@app.route("/analytics")
def analytics():
    """Get analytics and rate limits (requires admin key)"""
    if request.headers.get("X-Admin-Key") != os.environ.get("ADMIN_KEY", "changeme"):
        return jsonify({"error": "Unauthorized"}), 401
    
    results = {}
    for doc in db.collection("analytics").stream():
        data = doc.to_dict()
        # Convert Timestamp objects to ISO format
        if "last_seen" in data:
            data["last_seen"] = data["last_seen"].isoformat() if hasattr(data["last_seen"], 'isoformat') else str(data["last_seen"])
        results[doc.id] = data
    
    quotas = {}
    for doc in db.collection("rate_limits").stream():
        data = doc.to_dict()
        if "window_start" in data and hasattr(data["window_start"], 'isoformat'):
            data["window_start"] = data["window_start"].isoformat()
        if "last_request" in data and hasattr(data["last_request"], 'isoformat'):
            data["last_request"] = data["last_request"].isoformat()
        quotas[doc.id] = data
    
    return jsonify({
        "analytics": results,
        "quotas": quotas
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)