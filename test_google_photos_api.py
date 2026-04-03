#!/usr/bin/env python3
"""
Simple smoke test for the Google Photos Library API.

This script:
1. Runs an OAuth installed-app flow using your Google OAuth client.
2. Creates a new app-created album.
3. Uploads a generated BMP, or a real local image if --file is provided.
4. Creates a media item from the upload token and adds it to the album.
5. Lists a few app-created albums to confirm read access works.

Setup:
    pip install requests google-auth google-auth-oauthlib

Usage:
    python test_google_photos_api.py --client-secrets client_secret.json
    python test_google_photos_api.py --client-secrets client_secret.json --file C:\path\to\photo.jpg
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import struct
import sys
from datetime import datetime, timezone
from pathlib import Path

import requests
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow


SCOPES = [
    "https://www.googleapis.com/auth/photoslibrary.appendonly",
    "https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata",
]

UPLOAD_URL = "https://photoslibrary.googleapis.com/v1/uploads"
CREATE_ALBUM_URL = "https://photoslibrary.googleapis.com/v1/albums"
BATCH_CREATE_URL = "https://photoslibrary.googleapis.com/v1/mediaItems:batchCreate"
LIST_ALBUMS_URL = "https://photoslibrary.googleapis.com/v1/albums?pageSize=5"

def load_or_create_credentials(client_secrets: Path, token_file: Path) -> Credentials:
    if token_file.exists():
        creds = Credentials.from_authorized_user_file(str(token_file), SCOPES)
    else:
        creds = None

    if creds and creds.valid:
        return creds

    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())
    else:
        flow = InstalledAppFlow.from_client_secrets_file(str(client_secrets), SCOPES)
        creds = flow.run_local_server(port=0)

    token_file.write_text(creds.to_json(), encoding="utf-8")
    return creds


def auth_headers(creds: Credentials, **extra: str) -> dict[str, str]:
    headers = {"Authorization": f"Bearer {creds.token}"}
    headers.update(extra)
    return headers


def fail(response: requests.Response, action: str) -> None:
    print(f"{action} failed: HTTP {response.status_code}", file=sys.stderr)
    try:
        print(json.dumps(response.json(), indent=2), file=sys.stderr)
    except ValueError:
        print(response.text, file=sys.stderr)
    raise SystemExit(1)


def create_album(creds: Credentials, title: str) -> str:
    response = requests.post(
        CREATE_ALBUM_URL,
        headers=auth_headers(creds, **{"Content-Type": "application/json"}),
        json={"album": {"title": title}},
        timeout=30,
    )
    if not response.ok:
        fail(response, "Album creation")
    data = response.json()
    return data["id"]


def upload_bytes(
    creds: Credentials, filename: str, media_bytes: bytes, content_type: str
) -> str:
    response = requests.post(
        UPLOAD_URL,
        headers=auth_headers(
            creds,
            **{
                "Content-Type": "application/octet-stream",
                "X-Goog-Upload-Content-Type": content_type,
                "X-Goog-Upload-File-Name": filename,
                "X-Goog-Upload-Protocol": "raw",
            },
        ),
        data=media_bytes,
        timeout=60,
    )
    if not response.ok:
        fail(response, "Byte upload")
    return response.text.strip()


def create_media_item(
    creds: Credentials, album_id: str, upload_token: str, filename: str
) -> dict:
    response = requests.post(
        BATCH_CREATE_URL,
        headers=auth_headers(creds, **{"Content-Type": "application/json"}),
        json={
            "albumId": album_id,
            "newMediaItems": [
                {
                    "description": "API smoke test image",
                    "simpleMediaItem": {
                        "uploadToken": upload_token,
                        "fileName": filename,
                    },
                }
            ],
        },
        timeout=60,
    )
    if not response.ok:
        fail(response, "Media item creation")
    data = response.json()
    result = data["newMediaItemResults"][0]
    status = result.get("status", {})
    if status and status.get("code", 0) != 0:
        print("Media item creation returned an API error:", file=sys.stderr)
        print(json.dumps(result, indent=2), file=sys.stderr)
        raise SystemExit(1)
    return result["mediaItem"]


def list_albums(creds: Credentials) -> list[dict]:
    response = requests.get(
        LIST_ALBUMS_URL,
        headers=auth_headers(creds),
        timeout=30,
    )
    if not response.ok:
        fail(response, "Album listing")
    return response.json().get("albums", [])


def generate_test_bmp(width: int = 512, height: int = 512) -> bytes:
    row_stride = width * 3
    row_padding = (4 - (row_stride % 4)) % 4
    pixel_rows = bytearray()

    for y in range(height - 1, -1, -1):
        for x in range(width):
            red = (x * 255) // max(width - 1, 1)
            green = (y * 255) // max(height - 1, 1)
            blue = 160
            pixel_rows.extend((blue, green, red))
        pixel_rows.extend(b"\x00" * row_padding)

    pixel_data = bytes(pixel_rows)
    file_size = 14 + 40 + len(pixel_data)
    pixel_offset = 14 + 40

    file_header = struct.pack(
        "<2sIHHI",
        b"BM",
        file_size,
        0,
        0,
        pixel_offset,
    )
    dib_header = struct.pack(
        "<IIIHHIIIIII",
        40,
        width,
        height,
        1,
        24,
        0,
        len(pixel_data),
        2835,
        2835,
        0,
        0,
    )
    return file_header + dib_header + pixel_data


def load_media_payload(file_path: Path | None, stamp: str) -> tuple[str, bytes, str]:
    if file_path is not None:
        payload = file_path.read_bytes()
        content_type = (
            mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
        )
        return file_path.name, payload, content_type

    filename = f"smoke-test-{stamp}.bmp"
    return filename, generate_test_bmp(), "image/bmp"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--client-secrets",
        default="client_secret.json",
        help="Path to the OAuth client secrets JSON downloaded from Google Cloud.",
    )
    parser.add_argument(
        "--token-file",
        default="google_photos_token.json",
        help="Where to cache the OAuth access/refresh token.",
    )
    parser.add_argument(
        "--file",
        help="Optional local image file to upload instead of the generated BMP.",
    )
    args = parser.parse_args()

    client_secrets = Path(args.client_secrets).expanduser().resolve()
    token_file = Path(args.token_file).expanduser().resolve()
    file_path = Path(args.file).expanduser().resolve() if args.file else None

    if not client_secrets.exists():
        print(f"Missing client secrets file: {client_secrets}", file=sys.stderr)
        return 2
    if file_path is not None and not file_path.exists():
        print(f"Missing media file: {file_path}", file=sys.stderr)
        return 2

    creds = load_or_create_credentials(client_secrets, token_file)
    if not creds.valid:
        creds.refresh(Request())

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    album_title = f"API Smoke Test {stamp}"
    filename, media_bytes, content_type = load_media_payload(file_path, stamp)

    print("Creating album...")
    album_id = create_album(creds, album_title)
    print(f"Album created: {album_id}")

    print("Uploading image bytes...")
    upload_token = upload_bytes(creds, filename, media_bytes, content_type)
    print("Upload token received.")

    print("Creating media item...")
    media_item = create_media_item(creds, album_id, upload_token, filename)
    print(f"Media item created: {media_item['id']}")
    print(f"Product URL: {media_item.get('productUrl', '<none>')}")

    print("Listing app-created albums...")
    albums = list_albums(creds)
    print(f"Found {len(albums)} album(s) in the first page of results.")
    for album in albums:
        print(f"- {album['title']} [{album['id']}]")

    print("\nSmoke test completed successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
