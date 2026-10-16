#!/usr/bin/env python3
"""Expires every TestFlight build of CruiseLAN except the newest, so testers can only
install the latest. Expiring can't be undone, but it doesn't touch the App Store version.

    python3 Tools/asc/expire_builds.py --config Tools/asc/config.json [--dry-run]
"""
import argparse
import json
import pathlib

from asc_fill import BUNDLE_ID, Client


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    client = Client(json.loads(pathlib.Path(args.config).read_text()))

    app = client.get(f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"][0]
    response = client.get(f"/v1/builds?filter[app]={app['id']}&limit=200&include=preReleaseVersion"
                          "&fields[builds]=version,expired,processingState,preReleaseVersion"
                          "&fields[preReleaseVersions]=version")
    versions = {item["id"]: item["attributes"]["version"]
                for item in response.get("included", []) if item["type"] == "preReleaseVersions"}
    builds = []
    for build in response["data"]:
        version_id = (build["relationships"]["preReleaseVersion"]["data"] or {}).get("id")
        builds.append((int(build["attributes"]["version"]), versions.get(version_id, "?"), build))
    builds.sort(key=lambda entry: entry[0])
    if not builds:
        raise SystemExit("No builds found")

    latest = builds[-1]
    print(f"Keeping {latest[1]} ({latest[0]})")
    for number, version, build in builds[:-1]:
        label = f"{version} ({number})"
        if build["attributes"]["expired"]:
            print(f"Already expired: {label}")
            continue
        if args.dry_run:
            print(f"Would expire: {label}")
            continue
        client.patch(f"/v1/builds/{build['id']}",
                     {"data": {"type": "builds", "id": build["id"], "attributes": {"expired": True}}})
        print(f"Expired: {label}")


if __name__ == "__main__":
    main()
