#!/bin/sh

cd app

echo "Collecting static files"
python manage.py collectstatic --no-input -v 0

echo "Running migrations"
python manage.py makemigrations main
python manage.py migrate

# echo "Django superuser must be create manually with python manage.py createsuperuser"
echo "from django.contrib.auth import get_user_model; User = get_user_model(); User.objects.create_superuser('admin', 'gbournique@gmail.com', 'admin')" | python manage.py shell || true

echo "Starting webserver"
gunicorn portfolio.wsgi:application --bind 0.0.0.0:8080 
