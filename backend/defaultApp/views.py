from django.db import connection
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response


@api_view(['GET'])
@permission_classes([AllowAny])
def health(request):
    """Liveness + database reachability, unauthenticated.

    Deliberately public: tools/verify.sh, tools/sync-django.sh, tools/deploy.sh
    and tools/app-health-check.sh all poll it, and two of those run where no
    credential exists (a systemd timer on the server, a load balancer). It is
    the one endpoint that opts out of the project-wide default permission, so
    it says `AllowAny` explicitly rather than inheriting anything.

    It opens a database cursor rather than returning a constant, because a
    constant reports the *process*. A container whose database is gone answers
    a static health check with 200 and every real request with 500, which is
    exactly the state a watchdog must not read as healthy.
    """
    with connection.cursor() as cursor:
        cursor.execute('SELECT 1')
        cursor.fetchone()
    return Response({'status': 'ok'})
