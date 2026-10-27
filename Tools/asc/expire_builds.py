#!/usr/bin/env python3
"""Expires old TestFlight builds of CruiseLAN so testers only install the latest, without
ever breaking external testing. Expiring can't be undone, but it doesn't touch the App Store
version.

Kept, always:
- the newest build;
- every build waiting for or in Beta App Review (expiring one withdraws it);
- the newest build approved for external testers (Ring 1's public link), until a newer build
  has been approved. External groups can only install approved builds, and Apple's review
  takes up to a day, so expiring the approved one leaves the public link saying "not
  available for testing" until the next approval. That happened on 2026-10-16.

    python3 Tools/asc/expire_builds.py --config Tools/asc/config.json [--dry-run]
"""
import argparse
import json
import pathlib

from asc_fill import BUNDLE_ID, Client

APPROVED = {"BETA_APPROVED", "IN_BETA_TESTING"}
IN_REVIEW = {"WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    client = Client(json.loads(pathlib.Path(args.config).read_text()))

    app = client.get(f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"][0]
    response = client.get(f"/v1/builds?filter[app]={app['id']}&limit=200&include=preReleaseVersion,buildBetaDetail"
                          "&fields[builds]=version,expired,processingState,preReleaseVersion,buildBetaDetail"
                          "&fields[preReleaseVersions]=version&fields[buildBetaDetails]=externalBuildState")
    included = response.get("included", [])
    versions = {item["id"]: item["attributes"]["version"] for item in included if item["type"] == "preReleaseVersions"}
    external = {item["id"]: item["attributes"].get("externalBuildState") for item in included if item["type"] == "buildBetaDetails"}
    builds = []
    for build in response["data"]:
        version_id = (build["relationships"]["preReleaseVersion"]["data"] or {}).get("id")
        detail_id = (build["relationships"]["buildBetaDetail"]["data"] or {}).get("id")
        builds.append((int(build["attributes"]["version"]), versions.get(version_id, "?"), external.get(detail_id), build))
    builds.sort(key=lambda entry: entry[0])
    if not builds:
        raise SystemExit("No builds found")

    keep = {builds[-1][0]: "newest"}
    for number, _, state, build in builds:
        if state in IN_REVIEW and not build["attributes"]["expired"]:
            keep.setdefault(number, f"external: {state}")
    approved = [entry for entry in builds if entry[2] in APPROVED and not entry[3]["attributes"]["expired"]]
    if approved:
        keep.setdefault(approved[-1][0], "serving external testers until a newer build is approved")

    for number, version, state, build in builds:
        label = f"{version} ({number})"
        if number in keep:
            print(f"Keeping {label}: {keep[number]}")
            continue
        if build["attributes"]["expired"]:
            print(f"Already expired: {label}")
            continue
        if args.dry_run:
            print(f"Would expire: {label} (external: {state})")
            continue
        client.patch(f"/v1/builds/{build['id']}",
                     {"data": {"type": "builds", "id": build["id"], "attributes": {"expired": True}}})
        print(f"Expired: {label}")


if __name__ == "__main__":
    main()
