"""Django settings.

One entry point, reading os.environ. Every security-relevant setting here
FAILS CLOSED: a missing variable breaks the boot or denies the request, and
never silently picks the permissive option. See CLAUDE.md § Security.
"""

import os
from pathlib import Path

from django.core.exceptions import ImproperlyConfigured

BASE_DIR = Path(__file__).resolve().parent.parent


def env_bool(key, default=False):
    return os.getenv(key, str(default)).strip().lower() in ('1', 'true', 'yes', 'on')


def env_list(key):
    return [item.strip() for item in os.getenv(key, '').split(',') if item.strip()]


# ── Debug ──────────────────────────────────────────────────────────────────
# Defaults to False. An unset variable on a server must not be the thing that
# turns the traceback page on: it renders every setting and the request's
# cookies, which is a credential disclosure, not a debugging convenience.
DEBUG = env_bool('DEBUG', False)

# ── Secret key ─────────────────────────────────────────────────────────────
# Refuses to boot without one when DEBUG is off. A committed fallback is a
# secret in git, and git history is permanent — see CLAUDE.md § Incidents.
SECRET_KEY = os.getenv('SECRET_KEY', '')
if not SECRET_KEY:
    if not DEBUG:
        raise ImproperlyConfigured(
            'SECRET_KEY is not set. Generate one with:\n'
            "  python -c 'from django.core.management.utils import "
            "get_random_secret_key as k; print(k())'"
        )
    SECRET_KEY = 'django-insecure-development-only-never-set-DEBUG-off-with-this'

# ── Hosts ──────────────────────────────────────────────────────────────────
# Empty when unset and DEBUG is off, so Django answers 400 to everything rather
# than serving an unknown Host. `['*']` disables the Host header check
# entirely, which is what makes cache-poisoning and password-reset-link
# poisoning possible.
ALLOWED_HOSTS = env_list('DJANGO_ALLOWED_HOSTS')
if DEBUG and not ALLOWED_HOSTS:
    ALLOWED_HOSTS = ['localhost', '127.0.0.1', '[::1]', '0.0.0.0']  # noqa: S104

# A checkout on a box that a DNS record points at is not a local sandbox. That
# combination once served Django's traceback page publicly — every setting and
# the request's cookies, including a signed-in user's email. Refuse it.
# The noqa below is not a suppression of a real finding: these are Host header
# VALUES to recognise, not an address anything binds to.
_LOCAL_HOSTS = {
    'localhost',
    '127.0.0.1',
    '[::1]',
    '0.0.0.0',  # noqa: S104
    'testserver',
    'backend',
    'nginx',
}
if DEBUG:
    routable = [h for h in ALLOWED_HOSTS if h not in _LOCAL_HOSTS and not h.endswith('.local')]
    if routable:
        raise ImproperlyConfigured(
            f'DEBUG is on and DJANGO_ALLOWED_HOSTS contains routable hosts: '
            f'{", ".join(routable)}. The debug page renders every setting and '
            f'the request cookies. Set DEBUG=false, or point this stack at '
            f'localhost only.'
        )

# ── Applications ───────────────────────────────────────────────────────────
INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'rest_framework',
    'drf_spectacular',
    # Feature apps. See backend/apps/README.md for the blessed-core list and
    # the one-way dependency rule.
    'apps.core',
]

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'whitenoise.middleware.WhiteNoiseMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'config.urls'
WSGI_APPLICATION = 'config.wsgi.application'

# No CORS configuration, and no `django-cors-headers`, deliberately. Vite
# proxies /api in development and nginx serves one origin in production, so
# nothing is ever cross-origin. Adding the package back means maintaining an
# allow-list to solve a problem the topology already solved — and the failure
# mode of getting it wrong (`CORS_ALLOW_ALL_ORIGINS = True`) is worse than the
# inconvenience it removes.

CSRF_TRUSTED_ORIGINS = env_list('CSRF_TRUSTED_ORIGINS')

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

# ── REST framework ─────────────────────────────────────────────────────────
REST_FRAMEWORK = {
    'DEFAULT_SCHEMA_CLASS': 'drf_spectacular.openapi.AutoSchema',
    # Fail closed. A new view is DENIED until it says otherwise; a genuinely
    # public one opts out with an explicit `[AllowAny]`, which is a line a
    # reviewer can see. The DRF default is AllowAny, so leaving this unset
    # makes every endpoint you forget about public.
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authentication.SessionAuthentication',
    ],
    # Cursor, not offset: deep offsets scan, and when rows arrive constantly a
    # user paging a list sees rows shift under them. See CLAUDE.md § Pagination.
    'DEFAULT_PAGINATION_CLASS': 'apps.core.pagination.TimestampCursorPagination',
    'PAGE_SIZE': 50,
}

SPECTACULAR_SETTINGS = {
    'TITLE': os.getenv('PROJECT_TITLE', 'API'),
    'VERSION': '0.1.0',
    'SERVE_INCLUDE_SCHEMA': False,
    # The generated client is the contract; a schema that silently drops an
    # endpoint it could not introspect makes that contract quietly incomplete.
    'ENUM_NAME_OVERRIDES': {},
}

# ── Database ───────────────────────────────────────────────────────────────
# No defaults. `os.getenv('DB_PASSWORD', 'password')` is a footgun: it turns a
# missing variable into a weak credential that works on someone's laptop.
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.environ.get('DB_NAME', ''),
        'USER': os.environ.get('DB_USER', ''),
        'PASSWORD': os.environ.get('DB_PASSWORD', ''),
        'HOST': os.environ.get('DB_HOST', ''),
        'PORT': os.environ.get('DB_PORT', '5432'),
    }
}

AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]

# ── Time ───────────────────────────────────────────────────────────────────
# UTC everywhere, converted only at the display boundary. A cron schedule that
# needs a wall-clock time stores an IANA timezone next to the expression.
LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'UTC'
USE_I18N = True
USE_TZ = True

# ── Static ─────────────────────────────────────────────────────────────────
STATIC_URL = 'static/'
STATIC_ROOT = BASE_DIR / 'static'
STORAGES = {
    'default': {'BACKEND': 'django.core.files.storage.FileSystemStorage'},
    'staticfiles': {'BACKEND': 'whitenoise.storage.CompressedManifestStaticFilesStorage'},
}

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'
DATA_UPLOAD_MAX_MEMORY_SIZE = 52428800

# ── Transport security ─────────────────────────────────────────────────────
# On only when DEBUG is off, because a local stack has no TLS and a secure
# cookie over http is a cookie that never arrives.
if not DEBUG:
    SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True
    SECURE_CONTENT_TYPE_NOSNIFF = True
    SECURE_REFERRER_POLICY = 'same-origin'
    # HSTS is set at the edge (nginx/default.conf) so it covers static assets
    # too, and because a wrong max-age here is not something you can take back.

# ── Logging ────────────────────────────────────────────────────────────────
# Structured to the console. Container logs are the transport, so anything a
# log line contains is readable by anyone with log access — never a token, a
# password, or a raw request body.
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {
        'standard': {
            'format': '{levelname} {asctime} {name} {message}',
            'style': '{',
        },
    },
    'handlers': {
        'console': {'class': 'logging.StreamHandler', 'formatter': 'standard'},
    },
    'root': {'handlers': ['console'], 'level': os.getenv('LOG_LEVEL', 'INFO')},
    'loggers': {
        'django.db.backends': {'level': 'WARNING', 'propagate': True},
    },
}
