// Writes latest.json, a release's signed update manifest, to stdout. Oatcake's updater and
// install.sh read it (see src/core/update.ts). The Release workflow runs it:
//
//   OATCAKE_UPDATE_KEY=… node scripts/sign-manifest.mjs --app out/Oatcake-darwin-arm64/Oatcake.app \
//     --zip Oatcake-v0.2.0-arm64.zip --url https://github.com/…/Oatcake-v0.2.0-arm64.zip [--notes notes.txt]
//
// OATCAKE_UPDATE_KEY is the Ed25519 private key (base64 PKCS#8 DER); `node scripts/sign-manifest.mjs keygen`
// prints a new pair. The manifest is checked against the public keys the app ships
// (src/core/update-keys.ts) before it's written, so a release can't go out signed with a key the app refuses.
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";

const SPKI_ED25519 = Buffer.from("302a300506032b6570032100", "hex");
const fail = (message) => {
  console.error(message);
  process.exit(1);
};

if (process.argv[2] === "keygen") {
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
  console.log(`Private (the OATCAKE_UPDATE_KEY secret): ${privateKey.export({ format: "der", type: "pkcs8" }).toString("base64")}`);
  console.log(`Public (add to src/core/update-keys.ts): ${publicKey.export({ format: "der", type: "spki" }).subarray(SPKI_ED25519.length).toString("base64")}`);
  process.exit(0);
}

const { values } = parseArgs({ options: { app: { type: "string" }, zip: { type: "string" }, url: { type: "string" }, notes: { type: "string" } } });
if (!values.app || !values.zip || !values.url) fail("Usage: node scripts/sign-manifest.mjs --app <Oatcake.app> --zip <zip> --url <zip's address> [--notes <file>]");
if (!process.env.OATCAKE_UPDATE_KEY) fail("OATCAKE_UPDATE_KEY isn't set.");

const plist = (key) =>
  execFileSync("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", path.join(values.app, "Contents", "Info.plist")], { encoding: "utf8" }).trim();
const zip = readFileSync(values.zip);
const payload = Buffer.from(
  JSON.stringify(
    {
      bundleID: plist("CFBundleIdentifier"),
      version: plist("CFBundleShortVersionString"),
      minimumSystemVersion: plist("LSMinimumSystemVersion"),
      published: new Date().toISOString(),
      notes: values.notes ? readFileSync(values.notes, "utf8").trim() : "",
      zip: { name: path.basename(values.zip), url: values.url, sha256: crypto.createHash("sha256").update(zip).digest("hex"), size: zip.length },
    },
    null,
    2,
  ),
);
const privateKey = crypto.createPrivateKey({ key: Buffer.from(process.env.OATCAKE_UPDATE_KEY, "base64"), format: "der", type: "pkcs8" });
const signature = crypto.sign(null, payload, privateKey);

// Check it the way the app will, with the keys it ships.
const shipped = [...readFileSync(new URL("../src/core/update-keys.ts", import.meta.url), "utf8").matchAll(/"([A-Za-z0-9+/]{43}=)"/g)].map((m) => m[1]);
const accepted = shipped.some((raw) =>
  crypto.verify(null, payload, crypto.createPublicKey({ key: Buffer.concat([SPKI_ED25519, Buffer.from(raw, "base64")]), format: "der", type: "spki" }), signature),
);
if (!accepted) fail("OATCAKE_UPDATE_KEY doesn't match any public key in src/core/update-keys.ts.");

process.stdout.write(JSON.stringify({ payload: payload.toString("base64"), signature: signature.toString("base64") }, null, 2) + "\n");
