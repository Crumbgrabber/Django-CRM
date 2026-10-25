"""Emails SES stored in S3 instead of sending inside the notification.

SES's SNS action carries at most 150 KB of email and bounces anything larger.
Its S3 action stores the whole email (SES receives up to 40 MB) and notifies the
same topic with only the object's location. The catch-all reads it from the one
bucket `INBOUND_EMAIL_S3_BUCKET` names, never from a bucket a notification names
on its own.
"""

from __future__ import annotations

import json
import logging

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from django.conf import settings

logger = logging.getLogger(__name__)

# SES refuses larger mail at the SMTP stage, so this only guards the read.
MAX_STORED_EMAIL = 40 * 1024 * 1024
_GONE = {"NoSuchKey", "404"}


class StoredEmailUnavailable(Exception):
    """A read that may succeed when SNS delivers the notification again."""


def stored_bucket() -> str:
    return (getattr(settings, "INBOUND_EMAIL_S3_BUCKET", "") or "").strip()


def _client(region: str | None):
    return boto3.client("s3", region_name=region)


def stored_email(message: str, topic_arn: str) -> bytes | None:
    """The raw email an S3 action's notification points at, or None.

    None when `message` is not an S3 action's notification, names a bucket other
    than the configured one, or points at an email that is gone or too large;
    the last two are logged, since a redelivery would not help. Raises
    `StoredEmailUnavailable` for a failure worth retrying. The bucket's region
    is the pinned topic's, because a receipt rule publishes in its own region.
    """
    try:
        action = json.loads(message)["receipt"]["action"]
    except (ValueError, TypeError, KeyError):
        return None
    if not isinstance(action, dict) or action.get("type") != "S3":
        return None
    bucket = stored_bucket()
    key = action.get("objectKey")
    if not bucket or action.get("bucketName") != bucket:
        logger.warning(
            "Stored email refused: bucket %r is not the configured one",
            action.get("bucketName") or "",
        )
        return None
    if not isinstance(key, str) or not key:
        return None
    parts = topic_arn.split(":")
    region = parts[3] if len(parts) == 6 and parts[3] else None
    try:
        stored = _client(region).get_object(Bucket=bucket, Key=key)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") in _GONE:
            logger.warning("Stored email %s is gone", key)
            return None
        raise StoredEmailUnavailable(str(exc)) from exc
    except BotoCoreError as exc:
        raise StoredEmailUnavailable(str(exc)) from exc
    body = stored["Body"]
    try:
        if (stored.get("ContentLength") or 0) > MAX_STORED_EMAIL:
            logger.warning("Stored email %s is over %d bytes", key, MAX_STORED_EMAIL)
            return None
        raw = body.read(MAX_STORED_EMAIL + 1)
    except BotoCoreError as exc:
        raise StoredEmailUnavailable(str(exc)) from exc
    finally:
        body.close()
    if len(raw) > MAX_STORED_EMAIL:
        logger.warning("Stored email %s is over %d bytes", key, MAX_STORED_EMAIL)
        return None
    return raw
