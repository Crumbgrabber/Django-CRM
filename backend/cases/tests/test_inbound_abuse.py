"""What keeps an inbound address from being abused: SES's verdicts on ticket
addresses, the per-address and per-sender limits, the bound on recorded drops,
and audit rows a later email can never rewrite."""

from __future__ import annotations

from datetime import timedelta
from unittest.mock import patch

import pytest
from django.utils import timezone

from cases import inbound_views
from cases.inbound import limits, pipeline
from cases.inbound.leads import ingest_lead
from cases.inbound.parser import parse_raw_email
from cases.inbound.pipeline import ingest
from cases.models import Case, EmailMessage, InboundMailbox
from cases.tests.test_inbound_email import MAILBOXES_URL, _make_mailbox, _raw_email
from common.models import Attachments


def _parsed(verdict="", **fields):
    parsed = parse_raw_email(_raw_email(**fields))
    parsed.spam_verdict = verdict
    return parsed


def _with_file(verdict=""):
    raw = (
        "From: Customer <user@example.com>\r\n"
        "To: support@acme.com\r\n"
        "Subject: Invoice\r\n"
        "Date: Sat, 9 May 2026 12:00:00 +0000\r\n"
        "Message-ID: <file@example.com>\r\n"
        "MIME-Version: 1.0\r\n"
        'Content-Type: multipart/mixed; boundary="b"\r\n\r\n'
        "--b\r\nContent-Type: text/plain\r\n\r\nSee attached.\r\n"
        "--b\r\nContent-Type: application/pdf\r\n"
        'Content-Disposition: attachment; filename="invoice.pdf"\r\n'
        "Content-Transfer-Encoding: base64\r\n\r\nJVBERi0xLjQK\r\n--b--\r\n"
    )
    parsed = parse_raw_email(raw)
    parsed.spam_verdict = verdict
    return parsed


def _accept(mailbox, n, sender=None):
    return ingest(
        _parsed(message_id=f"<{n}@x>", from_=sender or f"p{n}@example.com"), mailbox
    )


class TestSesVerdict:
    @pytest.mark.parametrize(
        ("receipt", "verdict"),
        [
            (
                {"spamVerdict": {"status": "FAIL"}, "virusVerdict": {"status": "FAIL"}},
                "virus",
            ),
            ({"spamVerdict": {"status": "FAIL"}}, "spam"),
            ({"dmarcVerdict": {"status": "FAIL"}, "dmarcPolicy": "reject"}, "spoofed"),
            (
                {"dmarcVerdict": {"status": "FAIL"}, "dmarcPolicy": "quarantine"},
                "spoofed",
            ),
            ({"dmarcVerdict": {"status": "FAIL"}, "dmarcPolicy": "none"}, ""),
            ({"dmarcVerdict": {"status": "FAIL"}}, ""),
            ({"dmarcVerdict": {"status": "GRAY"}, "dmarcPolicy": "reject"}, ""),
            (
                {"spamVerdict": {"status": "PASS"}, "dmarcVerdict": {"status": "PASS"}},
                "",
            ),
            ({"spamVerdict": "FAIL", "dmarcVerdict": "FAIL"}, ""),
        ],
    )
    def test_the_verdict(self, receipt, verdict):
        assert inbound_views._ses_verdict(receipt) == verdict


class TestTicketVerdicts:
    def test_a_clean_email_keeps_its_file(self, org_a):
        result = ingest(_with_file(), _make_mailbox(org_a))

        assert result.created_case is True
        assert Attachments.objects.filter(org=org_a).count() == 1

    @pytest.mark.parametrize("verdict", ["spam", "virus", "spoofed"])
    def test_a_flagged_email_opens_no_ticket_and_keeps_no_file(self, org_a, verdict):
        result = ingest(_with_file(verdict), _make_mailbox(org_a))

        assert result.dropped is True
        assert result.drop_reason == verdict
        assert result.case is None
        assert not Case.objects.filter(org=org_a).exists()
        assert not Attachments.objects.filter(org=org_a).exists()
        row = EmailMessage.objects.get(org=org_a)
        assert (row.drop_reason, row.case) == (verdict, None)

    def test_a_spoofed_reply_never_lands_on_the_ticket(self, org_a):
        mailbox = _make_mailbox(org_a)
        case = ingest(_parsed(message_id="<first@x>"), mailbox).case
        reply = _parsed(
            "spoofed",
            message_id="<reply@x>",
            in_reply_to="<first@x>",
            body="Please send the refund to my new account.",
        )

        assert ingest(reply, mailbox).drop_reason == "spoofed"
        assert list(case.email_messages.values_list("message_id", flat=True)) == [
            "first@x"
        ]

    def test_a_lead_address_drops_a_spoofed_email(self, org_a):
        mailbox = _make_mailbox(org_a, creates=InboundMailbox.CREATES_LEADS)

        assert ingest_lead(_parsed("spoofed"), mailbox).drop_reason == "spoofed"


class TestRowsAreNeverRewritten:
    def test_a_reused_message_id_leaves_the_first_email_on_its_ticket(self, org_a):
        mailbox = _make_mailbox(org_a)
        first = ingest(_parsed(message_id="<same@x>", body="Real request"), mailbox)
        forged = _parsed(
            message_id="<same@x>",
            body="Forged",
            extra_headers="Auto-Submitted: auto-replied",
        )

        ingest(forged, mailbox)

        row = EmailMessage.objects.get(org=org_a, message_id="same@x")
        assert row.case == first.case
        assert row.drop_reason == ""
        assert "Real request" in row.body_text

    def test_a_concurrent_delivery_leaves_no_second_ticket(self, org_a):
        mailbox = _make_mailbox(org_a)
        winner = Case.objects.create(org=org_a, name="First delivery", status="New")
        real_find = pipeline.find_existing_case

        def recorded_meanwhile(parsed, org):
            # The other delivery commits its row after this one's `prior` check.
            EmailMessage.objects.create(
                org=org,
                case=winner,
                mailbox=mailbox,
                message_id=parsed.message_id,
                from_address=parsed.from_address,
                received_at=parsed.received_at,
            )
            return real_find(parsed, org)

        with patch.object(pipeline, "find_existing_case", recorded_meanwhile):
            result = ingest(_with_file(), mailbox)

        assert result.case == winner
        assert result.created_case is False
        assert list(Case.objects.filter(org=org_a)) == [winner]
        assert not Attachments.objects.filter(org=org_a).exists()


class TestDailyLimit:
    @pytest.fixture(autouse=True)
    def two_a_day(self, settings):
        settings.INBOUND_EMAIL_DAILY_LIMIT = 2

    def test_past_the_limit_an_email_is_refused_and_not_recorded(self, org_a):
        mailbox = _make_mailbox(org_a)
        assert _accept(mailbox, 1).created_case
        assert _accept(mailbox, 2).created_case

        result = _accept(mailbox, 3)

        assert (result.drop_reason, result.email_message) == ("daily_limit", None)
        assert EmailMessage.objects.filter(org=org_a).count() == 2
        assert Case.objects.filter(org=org_a).count() == 2

    def test_dropped_mail_does_not_use_up_the_day(self, org_a):
        mailbox = _make_mailbox(org_a)
        for n in (1, 2, 3):
            ingest(_parsed("spam", message_id=f"<s{n}@x>"), mailbox)

        assert _accept(mailbox, 1).created_case

    def test_yesterdays_mail_does_not_count(self, org_a):
        mailbox = _make_mailbox(org_a)
        _accept(mailbox, 1)
        _accept(mailbox, 2)
        EmailMessage.objects.filter(org=org_a).update(
            created_at=timezone.now() - timedelta(hours=25)
        )

        assert _accept(mailbox, 3).created_case

    def test_each_address_has_its_own_limit(self, org_a):
        full = _make_mailbox(org_a)
        _accept(full, 1)
        _accept(full, 2)
        other = _make_mailbox(org_a, address="sales@acme.com")

        assert _accept(other, 3).created_case

    def test_drops_are_recorded_only_up_to_the_limit(self, org_a):
        mailbox = _make_mailbox(org_a)
        for n in (1, 2):
            ingest(_parsed("spam", message_id=f"<s{n}@x>"), mailbox)

        result = ingest(_parsed("spam", message_id="<s3@x>"), mailbox)

        assert (result.drop_reason, result.email_message) == ("spam", None)
        assert EmailMessage.objects.filter(org=org_a).count() == 2
        # Accepted mail still has its whole day.
        assert _accept(mailbox, 1).created_case


class TestSenderLimit:
    @pytest.fixture(autouse=True)
    def two_an_hour(self, monkeypatch):
        monkeypatch.setattr(limits, "SENDER_HOURLY_LIMIT", 2)

    def test_a_sender_past_the_limit_is_refused(self, org_a):
        mailbox = _make_mailbox(org_a)
        for n in (1, 2):
            assert _accept(mailbox, n, "flood@example.com").created_case

        result = _accept(mailbox, 3, "Flood <FLOOD@example.com>")

        assert (result.drop_reason, result.email_message) == ("sender_limit", None)
        assert _accept(mailbox, 4, "someone@example.com").created_case

    def test_an_hour_old_mail_does_not_count(self, org_a):
        mailbox = _make_mailbox(org_a)
        for n in (1, 2):
            _accept(mailbox, n, "flood@example.com")
        EmailMessage.objects.filter(org=org_a).update(
            created_at=timezone.now() - timedelta(minutes=61)
        )

        assert _accept(mailbox, 3, "flood@example.com").created_case

    def test_dropped_mail_from_the_sender_does_not_count(self, org_a):
        mailbox = _make_mailbox(org_a)
        for n in (1, 2, 3):
            ingest(
                _parsed(
                    message_id=f"<ooo{n}@x>",
                    from_="flood@example.com",
                    extra_headers="Auto-Submitted: auto-replied",
                ),
                mailbox,
            )

        assert _accept(mailbox, 4, "flood@example.com").created_case

    def test_a_lead_address_has_no_sender_limit(self, org_a):
        mailbox = _make_mailbox(org_a, creates=InboundMailbox.CREATES_LEADS)
        reasons = {
            ingest_lead(
                _parsed(
                    message_id=f"<lead{n}@x>",
                    from_="leads@portal.example",
                    body=f"Name: Buyer {n}\nEmail: buyer{n}@example.com",
                ),
                mailbox,
            ).drop_reason
            for n in range(4)
        }

        assert "sender_limit" not in reasons


class TestMailboxList:
    def _row(self, client, mailbox):
        body = client.get(MAILBOXES_URL).json()
        return body, next(m for m in body["mailboxes"] if m["id"] == str(mailbox.id))

    def test_drops_are_counted_by_kind(self, admin_client, org_a, settings):
        mailbox = _make_mailbox(org_a)
        ingest(_parsed("spam", message_id="<s@x>"), mailbox)
        ingest(_parsed("virus", message_id="<v@x>"), mailbox)
        ingest(_parsed("spoofed", message_id="<f@x>"), mailbox)
        ingest(
            _parsed(message_id="<o@x>", extra_headers="Auto-Submitted: auto-replied"),
            mailbox,
        )
        _accept(mailbox, 1)
        ingest(_parsed("spam", message_id="<old@x>"), mailbox)
        EmailMessage.objects.filter(org=org_a, message_id="old@x").update(
            created_at=timezone.now() - timedelta(days=31)
        )

        body, row = self._row(admin_client, mailbox)

        assert row["drops_last_30d"] == {
            "spam": 1,
            "virus": 1,
            "spoofed": 1,
            "automatic": 1,
        }
        assert row["dropped_last_30d"] == 4
        assert row["limit_reached"] is False
        assert body["daily_limit"] == settings.INBOUND_EMAIL_DAILY_LIMIT

    def test_an_address_at_its_limit_says_so(self, admin_client, org_a, settings):
        settings.INBOUND_EMAIL_DAILY_LIMIT = 1
        full = _make_mailbox(org_a)
        quiet = _make_mailbox(org_a, address="sales@acme.com")
        _accept(full, 1)

        assert self._row(admin_client, full)[1]["limit_reached"] is True
        assert self._row(admin_client, quiet)[1]["limit_reached"] is False
        assert self._row(admin_client, quiet)[1]["dropped_last_30d"] == 0
