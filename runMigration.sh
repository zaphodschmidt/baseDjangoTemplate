#!/bin/bash
sudo docker exec -it gap-sensing-v3-backend-1 python manage.py makemigrations
sudo docker exec -it gap-sensing-v3-backend-1 python manage.py migrate
cd frontend
sudo pnpm generate-api