"""Tests for core.

Two of these test the SETTINGS rather than a view, which is unusual and
deliberate: the fail-closed rules in config/settings.py are the kind of thing
that gets loosened during a debugging session and never tightened again, and
nothing else in the repo would notice.
"""

from django.conf import settings
from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient


class HealthTests(TestCase):
    def test_health_is_public_and_reports_ok(self):
        # No credential: this endpoint is polled by a systemd timer and a load
        # balancer, neither of which has one.
        response = APIClient().get('/api/health/')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {'status': 'ok'})


class FailClosedTests(SimpleTestCase):
    def test_default_permission_is_authenticated(self):
        # DRF's own default is AllowAny, so an unset value here makes every
        # view you forget about public.
        self.assertEqual(
            settings.REST_FRAMEWORK['DEFAULT_PERMISSION_CLASSES'],
            ['rest_framework.permissions.IsAuthenticated'],
        )

    def test_allowed_hosts_is_not_a_wildcard(self):
        # '*' disables the Host header check, which is what makes cache
        # poisoning and poisoned password-reset links possible.
        self.assertNotIn('*', settings.ALLOWED_HOSTS)
