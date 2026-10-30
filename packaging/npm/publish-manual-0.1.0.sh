#!/bin/bash
# OPERATOR ONLY: Valen runs this after the reviewed v0.1.0 draft exists, using his login and OTP prompts.
set -euo pipefail
[[ $# == 1 ]] || { printf '%s\n' 'Usage: publish-manual-0.1.0.sh NEW_OUTPUT_DIRECTORY' >&2; exit 1; }
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
helper="$script_dir/manual-release.mjs"
artifact_dir=$(node -e 'console.log(require("node:path").resolve(process.argv[1]))' "$1")
cd "$script_dir/../.."

check_owner() {
  if ! publisher_account=$(npm whoami --registry=https://registry.npmjs.org); then
    printf '%s\n' 'Stopped: npm identity unavailable. Run npm login yourself, then rerun. Contact the release lead if you do not own legios; do not switch scopes.' >&2
    return 1
  fi
  if ! npm org ls legios --json --registry=https://registry.npmjs.org | node "$helper" owner "$publisher_account"; then
    printf '%s\n' 'Stopped: not a verified owner of legios. Contact the release lead. No scope fallback.' >&2
    return 1
  fi
}

# First operational step: authenticated organization ownership, before login or downloads.
check_owner
printf '%s\n' 'Your npm account must have 2FA set to "authorization and writes".' \
  'Confirm that setting in npm. Enter OTPs only at npm prompts; this script never accepts or stores an OTP.'
read -r -p 'Type 2fa-ready after checking that setting (anything else stops): ' two_factor_ready
[[ "$two_factor_ready" == 2fa-ready ]] || exit 1
npm login --registry=https://registry.npmjs.org
check_owner # Login can change the account.

# 0.1.0 is a manual publish without npm provenance, including when user npmrc defaults request it.
export NPM_CONFIG_PROVENANCE=false npm_config_provenance=false
# Pin both the default and scoped registry; an existing @legios registry setting cannot redirect publication.
registry_args=(--registry=https://registry.npmjs.org --@legios:registry=https://registry.npmjs.org)
node "$helper" prepare "$artifact_dir"
node "$helper" ready "$artifact_dir"

check_published() {
  local package_name=$1 attempt
  for attempt in 1 2 3 4 5 6 7 8; do
    if node "$helper" verify "$artifact_dir" "$package_name" "$publisher_account"; then return 0; fi
    sleep 2
  done
  printf '%s\n' "Verification failed for $package_name. Stop before the next publish; contact the release lead." >&2
  return 1
}

# Platforms first, launcher last. npm asks for the OTP; no token or OTP argument is embedded.
npm publish "$artifact_dir/tarballs/legios-blackice-darwin-arm64-0.1.0.tgz" --access public --ignore-scripts "${registry_args[@]}"
check_published '@legios/blackice-darwin-arm64'
npm publish "$artifact_dir/tarballs/legios-blackice-darwin-x64-0.1.0.tgz" --access public --ignore-scripts "${registry_args[@]}"
check_published '@legios/blackice-darwin-x64'
npm publish "$artifact_dir/tarballs/legios-blackice-linux-x64-0.1.0.tgz" --access public --ignore-scripts "${registry_args[@]}"
check_published '@legios/blackice-linux-x64'
npm publish "$artifact_dir/tarballs/legios-blackice-linux-arm64-0.1.0.tgz" --access public --ignore-scripts "${registry_args[@]}"
check_published '@legios/blackice-linux-arm64'
npm publish "$artifact_dir/tarballs/legios-blackice-0.1.0.tgz" --access public --ignore-scripts "${registry_args[@]}"
check_published '@legios/blackice'
printf '%s\n' 'All five registry integrity and maintainer checks passed; all four downloaded platform binaries match the release.' \
  'Before 0.1.1: configure trusted publishing for all five packages and set publishing access to require 2FA and disallow tokens. This script does not change those settings.'
