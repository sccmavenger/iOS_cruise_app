#!/usr/bin/env python3
"""Reads everything App Store Connect has to say about CruiseLAN. Read-only.

Pulls, in order:
  1. App Store version states (including any review rejection state).
  2. Beta App Review submission states for recent builds.
  3. TestFlight tester feedback: screenshot submissions and crash submissions.
  4. Build processing states and any missing-compliance flags.

Resolution Center messages (the prose App Review writes when rejecting) have no public
API endpoint. When a version shows a rejected state, this says so and points at the web
UI rather than pretending it can read the text.

    python3 Tools/asc/review_feedback.py --config Tools/asc/config.json
"""
import argparse
import json
import pathlib

from asc_fill import BUNDLE_ID, Client


def show(title):
    print(f"\n{'=' * 72}\n{title}\n{'=' * 72}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    client = Client(json.loads(pathlib.Path(args.config).read_text()))

    app = client.get(f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"][0]
    app_id = app["id"]
    print(f"App: {app['attributes'].get('name')}  ({BUNDLE_ID})  id={app_id}")

    # 1. Version states ----------------------------------------------------
    show("App Store versions")
    versions = client.get(
        f"/v1/apps/{app_id}/appStoreVersions?limit=10"
        "&fields[appStoreVersions]=versionString,appStoreState,appVersionState,createdDate,reviewType"
    )["data"]
    rejected_states = {"REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED", "INVALID_BINARY"}
    flagged = []
    for version in versions:
        attributes = version["attributes"]
        state = attributes.get("appVersionState") or attributes.get("appStoreState")
        print(f"  {attributes.get('versionString'):8} {state:28} created {attributes.get('createdDate')}")
        if state in rejected_states:
            flagged.append((attributes.get("versionString"), state, version["id"]))

    if flagged:
        show("REJECTED / NEEDS ATTENTION")
        for version_string, state, version_id in flagged:
            print(f"  {version_string}: {state}")
            # Review details carry the contact info and notes, not the rejection prose.
            detail = client.get(f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail", ok_missing=True)
            if detail and detail.get("data"):
                notes = detail["data"]["attributes"].get("notes")
                print(f"    review notes we supplied: {notes!r}")
            print("    Apple's rejection message is only in Resolution Center (no public API).")

    # 2. Beta App Review (TestFlight external testing) ----------------------
    # `betaAppReviewSubmissions` requires filtering by a specific build, so fetch the
    # builds first and ask per build.
    recent_builds = client.get(
        f"/v1/builds?filter[app]={app_id}&limit=8&sort=-version"
        "&fields[builds]=version,processingState,expired,usesNonExemptEncryption"
    )["data"]

    show("Beta App Review submissions")
    any_submission = False
    for build in recent_builds:
        result = client.get(
            f"/v1/betaAppReviewSubmissions?filter[build]={build['id']}"
            "&fields[betaAppReviewSubmissions]=betaReviewState,submittedDate",
            ok_missing=True,
        )
        for submission in (result or {}).get("data", []):
            any_submission = True
            attributes = submission["attributes"]
            print(f"  build {build['attributes'].get('version'):>3}"
                  f" {attributes.get('betaReviewState'):22} submitted {attributes.get('submittedDate')}")
    if not any_submission:
        print("  none — internal-only testing needs no beta review")

    # 3. Tester feedback ----------------------------------------------------
    show("TestFlight feedback — screenshots")
    screenshots = client.get(
        f"/v1/apps/{app_id}/betaFeedbackScreenshotSubmissions?limit=50"
        "&include=build,tester&sort=-createdDate",
        ok_missing=True,
    )
    if not screenshots or not screenshots.get("data"):
        print("  none")
    else:
        for item in screenshots["data"]:
            attributes = item["attributes"]
            print(f"  {attributes.get('createdDate')}  device={attributes.get('deviceModel')}"
                  f" os={attributes.get('osVersion')}")
            if attributes.get("comment"):
                print(f"    comment: {attributes['comment']}")
            for image in attributes.get("screenshots", []) or []:
                print(f"    image: {image.get('url')}")

    show("TestFlight feedback — crashes")
    crashes = client.get(
        f"/v1/apps/{app_id}/betaFeedbackCrashSubmissions?limit=50"
        "&include=build,tester&sort=-createdDate",
        ok_missing=True,
    )
    if not crashes or not crashes.get("data"):
        print("  none")
    else:
        for item in crashes["data"]:
            attributes = item["attributes"]
            print(f"  {attributes.get('createdDate')}  device={attributes.get('deviceModel')}"
                  f" os={attributes.get('osVersion')}")
            if attributes.get("comment"):
                print(f"    comment: {attributes['comment']}")

    # 4. Build health -------------------------------------------------------
    show("Builds")
    builds = client.get(
        f"/v1/builds?filter[app]={app_id}&limit=12&sort=-version"
        "&include=preReleaseVersion"
        "&fields[builds]=version,processingState,expired,usesNonExemptEncryption,preReleaseVersion"
        "&fields[preReleaseVersions]=version"
    )
    trains = {
        item["id"]: item["attributes"].get("version")
        for item in builds.get("included", [])
    }
    for build in builds["data"]:
        attributes = build["attributes"]
        train_ref = (build.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}).get("id")
        encryption = attributes.get("usesNonExemptEncryption")
        flag = "" if encryption is not None else "  <-- missing export compliance answer"
        print(f"  {trains.get(train_ref, '?'):6} ({attributes.get('version'):>3})"
              f" {attributes.get('processingState'):12}"
              f" expired={str(attributes.get('expired')):5}{flag}")


if __name__ == "__main__":
    main()
