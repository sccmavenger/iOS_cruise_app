#!/usr/bin/env python3
"""Adds a processed build to an external TestFlight group (Ring 1 by default), sets its
"What to Test", and submits it for Beta App Review, so the group's public link always has a
build on its way. External testers can only install builds Apple has approved.

    python3 Tools/asc/send_to_external.py --config Tools/asc/config.json --build 25 \
        [--group "Ring 1"] [--whats-new "text"]

Run after the upload has finished processing, and before expire_builds.py.
"""
import argparse
import json
import pathlib

from asc_fill import BUNDLE_ID, Client


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--group", default="Ring 1")
    parser.add_argument("--whats-new")
    args = parser.parse_args()
    client = Client(json.loads(pathlib.Path(args.config).read_text()))

    app = client.get(f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"][0]
    builds = client.get(f"/v1/builds?filter[app]={app['id']}&filter[version]={args.build}")["data"]
    if not builds:
        raise SystemExit(f"Build {args.build} not found (still processing?)")
    build = builds[0]
    if build["attributes"].get("processingState") != "VALID":
        raise SystemExit(f"Build {args.build} is {build['attributes'].get('processingState')}, not VALID yet")

    groups = client.get(f"/v1/apps/{app['id']}/betaGroups?limit=50")["data"]
    group = next((g for g in groups if g["attributes"]["name"] == args.group), None)
    if group is None:
        raise SystemExit(f"No group named {args.group!r}: {[g['attributes']['name'] for g in groups]}")

    in_group = {b["id"] for b in client.get(f"/v1/betaGroups/{group['id']}/builds?limit=200")["data"]}
    if build["id"] in in_group:
        print(f"Build {args.build} already in {args.group}")
    else:
        client.post(f"/v1/betaGroups/{group['id']}/relationships/builds",
                    {"data": [{"type": "builds", "id": build["id"]}]})
        print(f"Added build {args.build} to {args.group}")

    if args.whats_new:
        locs = client.get(f"/v1/builds/{build['id']}/betaBuildLocalizations")["data"]
        if locs:
            client.patch(f"/v1/betaBuildLocalizations/{locs[0]['id']}",
                         {"data": {"type": "betaBuildLocalizations", "id": locs[0]["id"],
                                   "attributes": {"whatsNew": args.whats_new}}})
        else:
            client.post("/v1/betaBuildLocalizations",
                        {"data": {"type": "betaBuildLocalizations",
                                  "attributes": {"locale": "en-US", "whatsNew": args.whats_new},
                                  "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}})
        print("What to Test set")

    existing = client.get(f"/v1/betaAppReviewSubmissions?filter[build]={build['id']}")["data"]
    if existing:
        print(f"Already submitted for review: {existing[0]['attributes']['betaReviewState']}")
    else:
        client.post("/v1/betaAppReviewSubmissions",
                    {"data": {"type": "betaAppReviewSubmissions",
                              "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}})
        print(f"Submitted build {args.build} for Beta App Review")


if __name__ == "__main__":
    main()
