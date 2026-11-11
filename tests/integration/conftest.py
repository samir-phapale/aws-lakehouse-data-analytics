"""Shared AWS clients and bucket lookup; tests skip when the <ZONE>_BUCKET variables are not set."""

import os

import boto3
import pytest

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")


@pytest.fixture(scope="session")
def s3_client():
    return boto3.client("s3", region_name=AWS_REGION)


@pytest.fixture(scope="session")
def glue_client():
    return boto3.client("glue", region_name=AWS_REGION)


@pytest.fixture(scope="session")
def bucket():
    """bucket("RAW") -> the RAW_BUCKET variable, or skip the test."""

    def lookup(zone):
        value = os.environ.get(f"{zone}_BUCKET")
        if not value:
            pytest.skip(f"{zone}_BUCKET not set - deploy the environment first")
        return value

    return lookup
