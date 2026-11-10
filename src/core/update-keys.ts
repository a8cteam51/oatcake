// Ed25519 public keys (raw 32 bytes, base64) that may sign the update manifest, latest.json.
// The private key is the OATCAKE_UPDATE_KEY secret used by the Release workflow (README › Releasing).
// To replace the key, add the new public key here and ship a release signed with the old one
// before releases are signed with the new one. scripts/sign-manifest.mjs reads this file too.
export const UPDATE_PUBLIC_KEYS = ["FQF4wZO3mslNx4xt76rEW5y28nlAeEfKQyIm0wAWPh0="];
