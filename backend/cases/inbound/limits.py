"""How much mail one inbound address takes.

The limits count accepted emails only, so junk that is dropped anyway (spam,
auto-replies) never locks a customer out. Dropped emails are recorded up to
the same daily number, which bounds the rows a flood can write. Mail past a
limit is refused and not recorded. Counts use the row's `created_at`, never
the email's Date header, which the sender writes.
"""

from __future__ import annotations

from datetime import timedelta

from django.conf import settings
from django.utils import timezone

from cases.models import EmailMessage, InboundMailbox

# Ticket addresses only: a lead portal sends every enquiry from one address.
SENDER_HOURLY_LIMIT = 20


def daily_limit() -> int:
    return settings.INBOUND_EMAIL_DAILY_LIMIT


def _received(mailbox: InboundMailbox, hours: int):
    return EmailMessage.objects.filter(
        org_id=mailbox.org_id,
        mailbox=mailbox,
        direction="inbound",
        created_at__gte=timezone.now() - timedelta(hours=hours),
    )


def daily_limit_reached(mailbox: InboundMailbox) -> bool:
    return _received(mailbox, 24).filter(drop_reason="").count() >= daily_limit()


def sender_limit_reached(mailbox: InboundMailbox, sender: str) -> bool:
    if not sender:
        return False
    accepted = _received(mailbox, 1).filter(drop_reason="", from_address=sender)
    return accepted.count() >= SENDER_HOURLY_LIMIT


def may_record_drop(mailbox: InboundMailbox) -> bool:
    return _received(mailbox, 24).exclude(drop_reason="").count() < daily_limit()
