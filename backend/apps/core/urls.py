from django.urls import include, path
from rest_framework.routers import DefaultRouter

from . import views

app_name = 'core'

router = DefaultRouter()

urlpatterns = [
    path('health/', views.health, name='health'),
    path('', include(router.urls)),
]
