"""Root URL configuration.

Read this file first when hunting an endpoint. Every app is mounted under
`/api/`, so nginx has one prefix to proxy and the frontend has one prefix to
call — which is what lets the whole stack be same-origin and need no CORS.
"""

from django.contrib import admin
from django.urls import include, path
from drf_spectacular.views import (
    SpectacularAPIView,
    SpectacularRedocView,
    SpectacularSwaggerView,
)

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/', include('apps.core.urls')),
    path('api/schema/', SpectacularAPIView.as_view(), name='schema'),
    path('api/docs/', SpectacularSwaggerView.as_view(url_name='schema'), name='docs'),
    path('api/redoc/', SpectacularRedocView.as_view(url_name='schema'), name='redoc'),
]

# Static files are served by WhiteNoise in every environment, including
# DEBUG — one code path, so "works locally" means the same thing it means on
# the server. `django.conf.urls.static.static()` is a no-op when DEBUG is off,
# which makes it a route that quietly stops existing in production.
