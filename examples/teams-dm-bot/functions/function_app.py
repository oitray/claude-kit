"""Azure Functions receiver for the Teams DM bot (bootstrap-only)."""
import base64
import datetime
import json
import logging
import os
from urllib.parse import urlparse

import azure.functions as func
import jwt  # PyJWT, includes RS256 support
import requests
from azure.data.tables import TableServiceClient

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

BF_OPENID_URL = "https://login.botframework.com/v1/.well-known/openidconfiguration"
_jwks_cache: dict = {}

CONN = os.environ.get("AzureWebJobsStorage", "")
TABLE_NAME = "TeamsBotConvRef"

# Trusted Microsoft Bot Connector service URL hosts. Source: Microsoft Learn
# Bot Framework REST authentication docs.
TRUSTED_SERVICE_URL_HOSTS = (
    "smba.trafficmanager.net",
    "webchat.botframework.com",
    "directline.botframework.com",
)


def _is_trusted_service_url(url: str) -> bool:
    if not url or not isinstance(url, str):
        return False
    try:
        p = urlparse(url)
    except Exception:
        return False
    if p.scheme != "https" or not p.hostname:
        return False
    return any(p.hostname == h or p.hostname.endswith("." + h) for h in TRUSTED_SERVICE_URL_HOSTS)


def _table_client():
    svc = TableServiceClient.from_connection_string(CONN)
    try:
        svc.create_table(TABLE_NAME)
    except Exception:
        pass
    return svc.get_table_client(TABLE_NAME)


def _validate_bf_token(token: str, expected_aud: str, activity: dict) -> bool:
    """Verify BF JWT: signature + iss + aud + exp + serviceUrl trust binding.

    See Microsoft Learn — "Authentication for bots" / Bot Framework REST
    authentication. The activity.serviceUrl must resolve to a trusted Bot
    Connector host, and (for tokens carrying it) the serviceurl claim must
    match activity.serviceUrl exactly.
    """
    try:
        header = jwt.get_unverified_header(token)
    except jwt.PyJWTError:
        return False
    kid = header.get("kid")
    global _jwks_cache
    if not _jwks_cache:
        oidc = requests.get(BF_OPENID_URL, timeout=5).json()
        jwks = requests.get(oidc["jwks_uri"], timeout=5).json()
        _jwks_cache = {"issuer": oidc["issuer"], "keys": {k["kid"]: k for k in jwks["keys"]}}
    jwk = _jwks_cache["keys"].get(kid)
    if not jwk:
        return False
    try:
        public_key = jwt.algorithms.RSAAlgorithm.from_jwk(json.dumps(jwk))
        claims = jwt.decode(
            token,
            public_key,
            algorithms=["RS256"],
            audience=expected_aud,
            issuer=_jwks_cache["issuer"],
        )
    except jwt.PyJWTError as e:
        logging.warning("JWT signature/claims validation failed: %s", e)
        return False

    service_url = (activity or {}).get("serviceUrl")
    if not _is_trusted_service_url(service_url):
        logging.warning("Activity serviceUrl not trusted: %r", service_url)
        return False
    claim_service_url = claims.get("serviceurl")
    if claim_service_url and claim_service_url != service_url:
        logging.warning("serviceurl claim mismatch: claim=%r activity=%r",
                        claim_service_url, service_url)
        return False
    return True


@app.route(route="api/messages", methods=["POST"])
def bot_messages(req: func.HttpRequest) -> func.HttpResponse:
    auth = req.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return func.HttpResponse("Missing bearer", status_code=401)
    try:
        activity = req.get_json()
    except ValueError:
        return func.HttpResponse("Invalid JSON", status_code=400)
    if not _validate_bf_token(auth[7:], os.environ["BOT_APP_ID"], activity):
        return func.HttpResponse("Invalid token", status_code=401)
    if activity.get("type") in ("message", "conversationUpdate"):
        conv = activity.get("conversation") or {}
        ref = {
            "conversationId": conv.get("id"),
            "serviceUrl": activity.get("serviceUrl"),
            "tenantId": ((activity.get("channelData") or {}).get("tenant") or {}).get("id"),
            "user": {
                "aadObjectId": (activity.get("from") or {}).get("aadObjectId"),
                "name": (activity.get("from") or {}).get("name"),
                "id": (activity.get("from") or {}).get("id"),
            } if activity.get("from") else None,
            "capturedAt": datetime.datetime.utcnow().isoformat() + "Z",
        }
        if ref["conversationId"] and ref["serviceUrl"]:
            tc = _table_client()
            tc.upsert_entity({
                "PartitionKey": "conv",
                "RowKey": "current",
                "Payload": json.dumps(ref),
            })
    return func.HttpResponse("", status_code=200)


@app.route(route="conv-ref", methods=["GET"])
def fetch_conv_ref(req: func.HttpRequest) -> func.HttpResponse:
    provided = req.headers.get("X-Setup-Secret", "")
    if provided != os.environ.get("SETUP_SECRET", ""):
        return func.HttpResponse("Forbidden", status_code=403)
    tc = _table_client()
    try:
        entity = tc.get_entity(partition_key="conv", row_key="current")
    except Exception:
        return func.HttpResponse("No conversation reference cached yet", status_code=404)
    return func.HttpResponse(
        entity["Payload"],
        status_code=200,
        mimetype="application/json",
    )
