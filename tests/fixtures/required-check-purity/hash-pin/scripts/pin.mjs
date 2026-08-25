#!/usr/bin/env node
// Fixture: exact equality against a downloaded binary's sha256. This is a
// pin, not a shared counter every PR must edit. The purity lint must stay
// quiet.
const expectedSha = "8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198";
const got = process.argv[2];
if (got !== expectedSha) {
  console.error("sha256 mismatch");
  process.exit(1);
}
