"""This module defines the Django models Item and Category to manage blog posts"""
import json
import logging
from pathlib import Path
from typing import NoReturn

import boto3
from django.conf import settings
from django.contrib.auth.models import User
from django.db import models
from django.utils import timezone
from django.utils.text import slugify

from app.config import SES_IDENTITY_ARN

from .mixins import BaseModelMixin

HTML_TEMPLATE_PATH = Path(__file__).resolve().parent / "item_content_template.html"
THUMBNAIL_SUFFIX = "_resized"

logger = logging.getLogger(__name__)


class Category(models.Model, BaseModelMixin):
    """Django model to manage blog post categories"""

    id = models.AutoField(primary_key=True)
    category_name = models.CharField(
        max_length=200, unique=True, verbose_name="Nom de la catégorie"
    )
    summary = models.TextField()
    image = models.ImageField(
        upload_to=settings.UPLOADS_FOLDER_PATH, verbose_name="Photo"
    )
    category_slug = models.SlugField(max_length=50, unique=True)

    @classmethod
    def create(cls, kwargs) -> "Category":
        """
        Instantiate a Category objects using dictionaries.
        Usage: new_category = Category.create(datadict)
        """
        return cls(**kwargs)

    # pylint: disable=signature-differs
    def save(self, *args, **kwargs):
        """Any modification on the item attributes before saving the object."""
        self.image = self.resize_image(self.image)
        self.category_slug = slugify(self.category_name)
        super().save(*args, **kwargs)

    def __str__(self):
        """User-friendly string representation of the object"""
        return self.category_name

    def __repr__(self):
        """User-friendly string representation of the object"""
        return (
            f"Category=(id={self.id},category_name={self.category_name}"
            f",category_slug={self.category_slug})"
        )

    class Meta:
        verbose_name = "Catégorie"
        verbose_name_plural = "Catégories"
        app_label = "main"


class Item(models.Model, BaseModelMixin):
    """Django model to manage blog post items"""

    id = models.AutoField(primary_key=True)
    item_name = models.CharField(
        max_length=200, unique=True, verbose_name="Nom de la recette"
    )
    summary = models.CharField(max_length=200)
    image = models.ImageField(
        upload_to=settings.UPLOADS_FOLDER_PATH, verbose_name="Photo"
    )
    # Resized image used for cards in email notifications
    image_thumbnail = models.ImageField(
        upload_to=settings.UPLOADS_FOLDER_PATH, default=""
    )
    with open(HTML_TEMPLATE_PATH) as f:
        content = models.TextField(default=f.read(), verbose_name="Contenu")
    date_published = models.DateTimeField("date published", default=timezone.now)
    item_slug = models.SlugField(max_length=50, unique=True)
    category_name = models.ForeignKey(
        Category, default=1, verbose_name="Catégorie", on_delete=models.SET_DEFAULT,
    )
    views = models.IntegerField(default=0)

    @classmethod
    def create(cls, kwargs: dict) -> "Item":
        """Instantiate Item objects using dictionaries. Used by tests"""
        return cls(**kwargs)

    # pylint: disable=signature-differs
    def save(self, *args, **kwargs):
        """Any modification on the item attributes before saving the object."""
        self.image_thumbnail = self.resize_image(self.image, suffix=THUMBNAIL_SUFFIX)
        self.item_slug = slugify(self.item_name)
        super().save(*args, **kwargs)
        self.notify_registered_users()

    def increment_views(self):
        """Instance method to increment the views variable"""
        self.views += 1
        self.save()

    def __str__(self):
        """User-friendly string representation of the object"""
        return self.item_name

    def __repr__(self):
        """User-friendly string representation of the object"""
        return (
            f"Item=(id={self.id},item_name={self.item_name},item_slug={self.item_slug})"
        )

    def notify_registered_users(self) -> NoReturn:
        """
        Notify users via AWS SES.
        Registered emails must be manually added as SES verified identifies from
        within the AWS Console, because of the limited / sandbox environment.
        For a production use case, raise a ticket with AWS.
        """
        ses_client = boto3.client("ses")

        destinations = [
            {
                "Destination": {"ToAddresses": [user.email],},
                "ReplacementTemplateData": json.dumps(
                    {
                        "base_url": "https://tari.kitchen",  # TODO: remove hardcoded base url
                        "item_name": self.item_name,
                        "item_url_path": f"/items/{self.category_name.category_slug}/{self.item_slug}",
                        "recette_image_url_path": f"{Path(self.image_thumbnail.url).with_suffix('')}{THUMBNAIL_SUFFIX}.jpg",
                        "username": user.username.title(),
                        "email": user.email,
                    }
                ),
            }
            for user in User.objects.all()
        ]

        if not SES_IDENTITY_ARN:
            logger.info(
                f"SES_IDENTITY_ARN not set, therefore email notifications are disabled."
            )
            return

        try:
            response = ses_client.send_bulk_templated_email(
                Source="tari-alerts@tari.kitchen",
                SourceArn=SES_IDENTITY_ARN,
                ReplyToAddresses=[],
                DefaultTags=[],
                Template="ItemCreatedNotification",  # TODO: remove hardcoded TemplateName
                DefaultTemplateData='{ "base_url":"https://tari.kitchen" }',  # TODO: remove hardcoded base url
                Destinations=destinations,
            )
            logger.info(f"SES notification was successful. response: {response}")
        except Exception as ses_err:
            logger.error(f"Failed to send SES email notification: {repr(ses_err)}")

    class Meta:
        verbose_name = "Recettes"
        verbose_name_plural = "Recettes"
        app_label = "main"
