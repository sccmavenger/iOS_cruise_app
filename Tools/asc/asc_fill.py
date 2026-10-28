#!/usr/bin/env python3
"""Fill in CruiseLAN's App Store Connect listing through the App Store Connect API.

What it does (idempotent: safe to run again):
  1. Finds the app by bundle id; sets content rights.
  2. App info: name, subtitle, privacy policy URL, categories, age rating answers.
  3. App Store version: creates or reuses VERSION, sets copyright and release type,
     attaches the matching processed build.
  4. Version localization (en-US): description, keywords, promotional text, support URL.
  5. App Review details: contact and notes.
  6. Uploads the 6.9" iPhone screenshots (replacing any already there).
  7. With --submit: creates a review submission and submits it for review.

Not available in Apple's public API: the App Privacy questionnaire. Set
"Data Not Collected" once in App Store Connect › App Privacy (one click).

Usage:
  python3 Tools/asc/asc_fill.py --config Tools/asc/config.json [--submit]

Config (JSON):
  {
    "key_id": "ABC123DEFG",
    "issuer_id": "00000000-0000-0000-0000-000000000000",
    "key_path": "~/.appstoreconnect/private_keys/AuthKey_ABC123DEFG.p8",
    "support_url": "https://…/support.html",
    "privacy_policy_url": "https://…/privacy.html",
    "review_contact": {"first_name": "", "last_name": "", "phone": "", "email": ""}
  }
"""
import argparse
import hashlib
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

import jwt  # PyJWT, with `cryptography` for ES256

API = "https://api.appstoreconnect.apple.com"
ROOT = pathlib.Path(__file__).resolve().parents[2]
BUNDLE_ID = "com.dannyguillory.cruiselan"
VERSION = "2.0"
BUILD = "26"
LOCALE = "en-US"
SCREENSHOT_DIR = ROOT / "docs/app-store/screenshots"
SCREENSHOT_DISPLAY_TYPE = "APP_IPHONE_67"  # The 6.7"/6.9" iPhone slot; accepts 1320 × 2868.

APP_INFO = {
    "name": "CruiseLAN",
    "subtitle": "Offline chat & games nearby",
    "primary_category": "SOCIAL_NETWORKING",
    "secondary_category": "GAMES",
    "secondary_subcategory": "GAMES_BOARD",
}

PROMO = ("No Wi-Fi plan? No problem. Chat and play Chess, Checkers, Color Match, Connect Four, "
         "and Tic-Tac-Toe with people nearby, with no internet, accounts, or ads.")
KEYWORDS = "offline,chat,cruise,nearby,no wifi,games,chess,checkers,family,local,bluetooth,multiplayer,travel"
COPYRIGHT = "2026 Danny Guillory"

# Age rating answers (see docs/app-store/SUBMISSION.md §4). Booleans not listed are False;
# every content-frequency question is NONE.
AGE_TRUE = {"userGeneratedContent", "messagingAndChat"}
AGE_FREQUENCY_FIELDS = {
    "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons",
    "horrorOrFearThemes", "matureOrSuggestiveThemes", "medicalOrTreatmentInformation",
    "profanityOrCrudeHumor", "sexualContentGraphicAndNudity", "sexualContentOrNudity",
    "violenceCartoonOrFantasy", "violenceRealistic", "violenceRealisticProlongedGraphicOrSadistic",
}
AGE_BOOLEAN_FIELDS = {
    "advertising", "ageAssurance", "gambling", "healthOrWellnessTopics", "lootBox", "messagingAndChat",
    "parentalControls", "socialMedia", "unrestrictedWebAccess", "userGeneratedContent",
}
AGE_SKIP = {"kidsAgeBand", "ageRatingOverride", "ageRatingOverrideV2", "koreaAgeRatingOverride",
            "developerAgeRatingInfoUrl"}


def section(text: str, heading: str) -> str:
    """Pulls a fenced block that follows `heading` in SUBMISSION.md, so copy lives in one place."""
    doc = (ROOT / "docs/app-store/SUBMISSION.md").read_text()
    start = doc.index(heading)
    block_start = doc.index("```\n", start) + 4
    return doc[block_start:doc.index("\n```", block_start)].strip()


class Client:
    def __init__(self, config: dict):
        read = lambda name: pathlib.Path(config[name]).expanduser().read_text().strip()
        key = pathlib.Path(config["key_path"]).expanduser().read_text()
        # Ids can be given inline or as paths to files holding them (keeps secrets out of the repo).
        key_id = config.get("key_id") or read("key_id_file")
        issuer = config.get("issuer_id") or read("issuer_id_file")
        self.key, self.key_id, self.issuer = key, key_id, issuer
        self._token, self._expires = None, 0

    def token(self) -> str:
        if time.time() > self._expires - 60:
            now = int(time.time())
            self._expires = now + 15 * 60
            self._token = jwt.encode({"iss": self.issuer, "iat": now, "exp": self._expires, "aud": "appstoreconnect-v1"},
                                     self.key, algorithm="ES256", headers={"kid": self.key_id, "typ": "JWT"})
        return self._token

    def request(self, method: str, path: str, body=None, ok_missing=False):
        url = path if path.startswith("http") else API + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method,
                                     headers={"Authorization": f"Bearer {self.token()}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            if ok_missing and error.code == 404:
                return None
            raise SystemExit(f"{method} {path} failed ({error.code}):\n{detail}")

    get = lambda self, path, **kw: self.request("GET", path, **kw)
    post = lambda self, path, body: self.request("POST", path, body)
    patch = lambda self, path, body: self.request("PATCH", path, body)
    delete = lambda self, path: self.request("DELETE", path)


def editable(items, state_key):
    """App infos and versions that can still be edited."""
    editable_states = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
                       "WAITING_FOR_REVIEW", "INVALID_BINARY", "READY_FOR_REVIEW"}
    return [item for item in items if item["attributes"].get(state_key) in editable_states]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--submit", action="store_true", help="Submit for App Review when everything is filled in")
    args = parser.parse_args()
    config = json.loads(pathlib.Path(args.config).read_text())
    api = Client(config)

    description = section("", "**Description (4000):**")
    review_notes = section("", "**Notes (paste):**")

    # 1. App
    apps = api.get(f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not apps:
        raise SystemExit(f"No app with bundle id {BUNDLE_ID}")
    app_id = apps[0]["id"]
    print(f"App {app_id}: {apps[0]['attributes']['name']}")
    api.patch(f"/v1/apps/{app_id}", {"data": {"type": "apps", "id": app_id,
              "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}})

    # 2. App info, localization, categories, age rating
    infos = api.get(f"/v1/apps/{app_id}/appInfos")["data"]
    info = (editable(infos, "appStoreState") or editable(infos, "state") or infos)[0]
    info_id = info["id"]
    api.patch(f"/v1/appInfos/{info_id}", {"data": {"type": "appInfos", "id": info_id, "relationships": {
        "primaryCategory": {"data": {"type": "appCategories", "id": APP_INFO["primary_category"]}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": APP_INFO["secondary_category"]}},
        "secondarySubcategoryOne": {"data": {"type": "appCategories", "id": APP_INFO["secondary_subcategory"]}},
    }}})
    print("Categories set")

    info_locs = api.get(f"/v1/appInfos/{info_id}/appInfoLocalizations")["data"]
    info_loc = next((loc for loc in info_locs if loc["attributes"]["locale"] == LOCALE), None)
    info_attrs = {"name": APP_INFO["name"], "subtitle": APP_INFO["subtitle"]}
    if config.get("privacy_policy_url"):
        info_attrs["privacyPolicyUrl"] = config["privacy_policy_url"]
    if info_loc:
        api.patch(f"/v1/appInfoLocalizations/{info_loc['id']}",
                  {"data": {"type": "appInfoLocalizations", "id": info_loc["id"], "attributes": info_attrs}})
    else:
        api.post("/v1/appInfoLocalizations", {"data": {"type": "appInfoLocalizations",
                 "attributes": {"locale": LOCALE, **info_attrs},
                 "relationships": {"appInfo": {"data": {"type": "appInfos", "id": info_id}}}}})
    print("Name, subtitle" + (", privacy policy URL" if "privacyPolicyUrl" in info_attrs else "") + " set")

    rating = api.get(f"/v1/appInfos/{info_id}/ageRatingDeclaration")["data"]
    answers = {}
    for key, value in rating["attributes"].items():
        if key in AGE_SKIP:
            continue
        if key in AGE_FREQUENCY_FIELDS:
            answers[key] = "NONE"
        elif isinstance(value, bool) or (value is None and key in AGE_BOOLEAN_FIELDS):
            answers[key] = key in AGE_TRUE
    api.patch(f"/v1/ageRatingDeclarations/{rating['id']}",
              {"data": {"type": "ageRatingDeclarations", "id": rating["id"], "attributes": answers}})
    print(f"Age rating answered ({len(answers)} questions)")

    # 3. Version and build
    versions = api.get(f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS")["data"]
    version = next((v for v in editable(versions, "appStoreState")), None)
    if version is None:
        version = api.post("/v1/appStoreVersions", {"data": {"type": "appStoreVersions",
                           "attributes": {"platform": "IOS", "versionString": VERSION},
                           "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]
    version_id = version["id"]
    api.patch(f"/v1/appStoreVersions/{version_id}", {"data": {"type": "appStoreVersions", "id": version_id,
              "attributes": {"versionString": VERSION, "copyright": COPYRIGHT, "releaseType": "AFTER_APPROVAL"}}})
    print(f"Version {VERSION} ({version_id}) ready")

    for attempt in range(40):
        builds = api.get(f"/v1/builds?filter[app]={app_id}&filter[version]={BUILD}"
                         f"&filter[preReleaseVersion.version]={VERSION}")["data"]
        if builds and builds[0]["attributes"]["processingState"] == "VALID":
            break
        print("Waiting for build processing…")
        time.sleep(30)
    else:
        raise SystemExit(f"Build {VERSION} ({BUILD}) isn't processed yet; run again later.")
    api.patch(f"/v1/appStoreVersions/{version_id}/relationships/build",
              {"data": {"type": "builds", "id": builds[0]["id"]}})
    print(f"Build {VERSION} ({BUILD}) attached")

    # 4. Version localization
    locs = api.get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")["data"]
    loc = next((l for l in locs if l["attributes"]["locale"] == LOCALE), None)
    loc_attrs = {"description": description, "keywords": KEYWORDS, "promotionalText": PROMO}
    if config.get("support_url"):
        loc_attrs["supportUrl"] = config["support_url"]
    if loc:
        api.patch(f"/v1/appStoreVersionLocalizations/{loc['id']}",
                  {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": loc_attrs}})
        loc_id = loc["id"]
    else:
        loc_id = api.post("/v1/appStoreVersionLocalizations", {"data": {"type": "appStoreVersionLocalizations",
                          "attributes": {"locale": LOCALE, **loc_attrs},
                          "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})["data"]["id"]
    print("Description, keywords, promotional text" + (", support URL" if "supportUrl" in loc_attrs else "") + " set")

    # 5. App Review details
    contact = dict(config.get("review_contact", {}))
    # Optionally reuse the private App Review contact from another app on the same account.
    if config.get("review_contact_from_app"):
        for other in api.get(f"/v1/apps/{config['review_contact_from_app']}/appStoreVersions?limit=5")["data"]:
            found = api.get(f"/v1/appStoreVersions/{other['id']}/appStoreReviewDetail", ok_missing=True)
            if found and found.get("data") and found["data"]["attributes"].get("contactPhone"):
                attrs = found["data"]["attributes"]
                contact = {"first_name": attrs["contactFirstName"], "last_name": attrs["contactLastName"],
                           "phone": attrs["contactPhone"], "email": attrs["contactEmail"]}
                break
    review_attrs = {"notes": review_notes, "demoAccountRequired": False}
    for field, key in [("contactFirstName", "first_name"), ("contactLastName", "last_name"),
                       ("contactPhone", "phone"), ("contactEmail", "email")]:
        if contact.get(key):
            review_attrs[field] = contact[key]
    detail = api.get(f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail", ok_missing=True)
    if detail and detail.get("data"):
        api.patch(f"/v1/appStoreReviewDetails/{detail['data']['id']}",
                  {"data": {"type": "appStoreReviewDetails", "id": detail["data"]["id"], "attributes": review_attrs}})
    else:
        api.post("/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": review_attrs,
                 "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})
    print("App Review notes" + (" and contact" if len(review_attrs) > 2 else "") + " set")

    # 6. Screenshots
    sets = api.get(f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")["data"]
    shot_set = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == SCREENSHOT_DISPLAY_TYPE), None)
    if shot_set:
        for old in api.get(f"/v1/appScreenshotSets/{shot_set['id']}/appScreenshots")["data"]:
            api.delete(f"/v1/appScreenshots/{old['id']}")
    else:
        shot_set = api.post("/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets",
                            "attributes": {"screenshotDisplayType": SCREENSHOT_DISPLAY_TYPE},
                            "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}})["data"]
    for path in sorted(SCREENSHOT_DIR.glob("*.png")):
        data = path.read_bytes()
        shot = api.post("/v1/appScreenshots", {"data": {"type": "appScreenshots",
                        "attributes": {"fileName": path.name, "fileSize": len(data)},
                        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": shot_set["id"]}}}}})["data"]
        for op in shot["attributes"]["uploadOperations"]:
            chunk = data[op["offset"]:op["offset"] + op["length"]]
            headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
            urllib.request.urlopen(urllib.request.Request(op["url"], data=chunk, method=op["method"], headers=headers))
        api.patch(f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
                  "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
        print(f"Uploaded {path.name}")

    missing = [name for name, value in [("support URL", config.get("support_url")),
               ("privacy policy URL", config.get("privacy_policy_url")),
               ("review contact phone/email", contact.get("phone") and contact.get("email"))] if not value]
    print("\nStill needed before submitting: App Privacy › 'Data Not Collected' (web only)"
          + ("; " + ", ".join(missing) if missing else ""))

    # 7. Submit
    if args.submit:
        if missing:
            raise SystemExit("Not submitting: fill in " + ", ".join(missing))
        submission = api.post("/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions",
                              "attributes": {"platform": "IOS"},
                              "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]
        api.post("/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
                 "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission["id"]}},
                 "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})
        api.patch(f"/v1/reviewSubmissions/{submission['id']}", {"data": {"type": "reviewSubmissions",
                  "id": submission["id"], "attributes": {"submitted": True}}})
        print("Submitted for App Review")


if __name__ == "__main__":
    main()
