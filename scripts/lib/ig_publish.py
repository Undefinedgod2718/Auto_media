#!/usr/bin/env python3
"""Instagram Graph API: single image or carousel publish."""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request


def _api(version: str, path: str, token: str, data: dict | None = None, method: str = "GET") -> dict:
    base = f"https://graph.facebook.com/{version}/{path.lstrip('/')}"
    if method.upper() == "GET":
        params = {"access_token": token, **(data or {})}
        url = f"{base}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(url, method="GET")
    else:
        body = urllib.parse.urlencode({**(data or {}), "access_token": token}).encode()
        req = urllib.request.Request(base, data=body, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {"error": {"message": raw}}


def poll_container(version: str, creation_id: str, token: str, max_wait: int, poll_sec: int) -> None:
    elapsed = 0
    while elapsed < max_wait:
        body = _api(version, creation_id, token, {"fields": "status_code,status"})
        err = body.get("error")
        if err:
            raise RuntimeError(err.get("message", str(err)))
        code = body.get("status_code") or body.get("status", "")
        if code in ("FINISHED", "PUBLISHED"):
            return
        if code in ("ERROR", "EXPIRED"):
            raise RuntimeError(f"container {creation_id} status={code} body={body}")
        time.sleep(poll_sec)
        elapsed += poll_sec
    raise TimeoutError(f"timeout waiting for container {creation_id}")


def create_media(
    version: str,
    ig_user: str,
    token: str,
    *,
    image_url: str,
    caption: str | None = None,
    is_carousel_item: bool = False,
    media_type: str | None = None,
    children: str | None = None,
) -> str:
    data: dict[str, str] = {}
    if media_type == "CAROUSEL" and children:
        data["media_type"] = "CAROUSEL"
        data["children"] = children
        if caption:
            data["caption"] = caption
    elif image_url:
        data["image_url"] = image_url
        if caption:
            data["caption"] = caption
    if is_carousel_item:
        data["is_carousel_item"] = "true"
    body = _api(version, f"{ig_user}/media", token, data, method="POST")
    if body.get("error"):
        raise RuntimeError(body["error"].get("message", str(body)))
    cid = body.get("id")
    if not cid:
        raise RuntimeError(f"no creation id: {body}")
    return cid


def media_publish(version: str, ig_user: str, token: str, creation_id: str) -> str:
    body = _api(
        version,
        f"{ig_user}/media_publish",
        token,
        {"creation_id": creation_id},
        method="POST",
    )
    if body.get("error"):
        raise RuntimeError(body["error"].get("message", str(body)))
    return body.get("id", "")


def publish_carousel(
    ig_user: str,
    token: str,
    version: str,
    image_urls: list[str],
    caption: str,
    max_wait: int,
    poll_sec: int,
) -> dict:
    if not image_urls:
        raise ValueError("no image_urls")
    if len(image_urls) == 1:
        cid = create_media(version, ig_user, token, image_url=image_urls[0], caption=caption)
        poll_container(version, cid, token, max_wait, poll_sec)
        post_id = media_publish(version, ig_user, token, cid)
        return {"ok": True, "mode": "single", "creation_id": cid, "post_id": post_id}

    child_ids: list[str] = []
    for url in image_urls[:10]:
        cid = create_media(
            version,
            ig_user,
            token,
            image_url=url,
            is_carousel_item=True,
        )
        poll_container(version, cid, token, max_wait, poll_sec)
        child_ids.append(cid)

    parent = create_media(
        version,
        ig_user,
        token,
        image_url="",
        caption=caption,
        media_type="CAROUSEL",
        children=",".join(child_ids),
    )
    poll_container(version, parent, token, max_wait, poll_sec)
    post_id = media_publish(version, ig_user, token, parent)
    return {
        "ok": True,
        "mode": "carousel",
        "children": child_ids,
        "creation_id": parent,
        "post_id": post_id,
        "slide_count": len(child_ids),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ig-user-id", default=os.environ.get("IG_USER_ID", ""))
    ap.add_argument("--token", default=os.environ.get("META_PAGE_ACCESS_TOKEN", ""))
    ap.add_argument("--version", default=os.environ.get("META_GRAPH_API_VERSION", "v21.0"))
    ap.add_argument("--urls-json", required=True, help='JSON array of image URLs')
    ap.add_argument("--caption-file", required=True)
    ap.add_argument("--max-wait", type=int, default=int(os.environ.get("IG_CONTAINER_MAX_WAIT_SEC", "180")))
    ap.add_argument("--poll-sec", type=int, default=int(os.environ.get("IG_CONTAINER_POLL_SEC", "3")))
    args = ap.parse_args()

    if not args.ig_user_id or not args.token:
        print(json.dumps({"ok": True, "skipped": True, "reason": "IG_USER_ID or META_PAGE_ACCESS_TOKEN unset"}))
        return 0

    urls = json.loads(args.urls_json)
    if not isinstance(urls, list):
        raise SystemExit("urls-json must be a JSON array")
    caption = Path(args.caption_file).read_text(encoding="utf-8").strip()

    result = publish_carousel(
        args.ig_user_id,
        args.token,
        args.version,
        [str(u) for u in urls],
        caption,
        args.max_wait,
        args.poll_sec,
    )
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
