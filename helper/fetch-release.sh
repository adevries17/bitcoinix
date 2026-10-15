#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils git gnutar gnugrep gnused openssh
set -euo pipefail

# Print a `builtins.fetchTarball` expression for a bitcoinix release, after
# verifying that the release tag is signed by a maintainer key listed in
# helper/release-keys/ssh-allowed-signers.
#
# A release is a signed, annotated git tag and nothing else. The hash is computed
# from the verified git objects, not from a downloaded archive, so the printed
# expression pins the exact tree that was signed.
#
# Env vars (for forks and tests):
#   releaseVersion  release version X.Y.Z without the leading "v" (default: highest release tag)
#   minVersion      refuse a release older than this X.Y.Z, e.g. the currently pinned one.
#                   update-nix-bitcoin sets it to prevent downgrades.
#   repoUrl        git repository to fetch from
#   allowedSigners  path to the allowed signers file
#   revokedKeys     path to the revoked keys file
#   checkDownload   if set, also download the printed url and check that it serves the
#                   verified tree. Needs network access and takes a few seconds more.

scriptDir=$(cd "${BASH_SOURCE[0]%/*}" && pwd)

# stderr: stdout is the expression, usually redirected into nix-bitcoin-release.nix
trap '>&2 echo "Error at ${BASH_SOURCE[0]}:$LINENO"' ERR

repoUrl=${repoUrl:-https://github.com/bitcoinix/bitcoinix}
allowedSigners=${allowedSigners:-$scriptDir/release-keys/ssh-allowed-signers}
revokedKeys=${revokedKeys:-$scriptDir/release-keys/ssh-revoked-keys}

die() { >&2 printf 'Error: %s\n' "$@"; exit 1; }

[[ -f $allowedSigners ]] || die "No allowed signers file at $allowedSigners"
# git only warns about a missing revocation file and then accepts the signature
[[ -f $revokedKeys ]] || die "No revoked keys file at $revokedKeys"
# Make the paths absolute, since git and ssh-keygen run in another directory
[[ $allowedSigners == /* ]] || allowedSigners=$PWD/$allowedSigners
[[ $revokedKeys == /* ]] || revokedKeys=$PWD/$revokedKeys

# The version is interpolated into a Nix expression and a ref name, so constrain it.
# Read from `releaseVersion`, not a generic `version` that may be set for other reasons.
versionRegex='^[0-9]+\.[0-9]+\.[0-9]+$'
version=${releaseVersion:-}

if [[ $version ]]; then
    [[ $version =~ $versionRegex ]] ||
        die "Invalid version: '$version'. Expected X.Y.Z without a leading 'v'."
else
    # Use the tags themselves, not the GitHub `releases/latest` API: that API is
    # unsigned, mutable metadata, so a compromised account could use it to steer
    # users to an older signed release.
    version=$(git ls-remote --tags --refs "$repoUrl" 'v*' \
              | sed -nE 's|.*[[:space:]]refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$|\1|p' \
              | sort -V | tail -1)
    [[ $version ]] || die "No release tags found at $repoUrl"
fi

# Withheld or deleted tags must not move a user back to an older, validly signed release
if [[ ${minVersion:-} ]]; then
    [[ $minVersion =~ $versionRegex ]] ||
        die "Invalid minVersion: '$minVersion'. Expected X.Y.Z without a leading 'v'."
    [[ $(printf '%s\n%s\n' "$minVersion" "$version" | sort -V | head -1) == "$minVersion" ]] ||
        die "Release $version is older than the current release $minVersion. Refusing to downgrade.
To downgrade on purpose, run fetch-release.sh with releaseVersion= and without minVersion."
fi
tag=v$version

tmp=$(mktemp -d)
# Nix store paths are read-only, which `rm -rf` cannot remove
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
repo=$tmp/repo
tree=$tmp/tree
mkdir -p "$tree"

# Run git on the local copy of the tag with the trusted keys only. The invoking
# user's git config is ignored so that neither their allowed signers file nor their
# GPG keyring can widen the trust set. The GPG and X.509 programs are disabled for
# the same reason: GNUPGHOME is not affected by the git config.
# Their global and system gitattributes are ignored too, since export-ignore or
# export-subst there would change the tree that `git archive` hashes. git reads
# $XDG_CONFIG_HOME/git/attributes even without any config, hence core.attributesFile.
# A revoked key is rejected whatever date the tag claims. `valid-before` in the
# allowed signers file is checked against the tag's own date, which the signer
# chooses, so it cannot stop a compromised key.
isolatedGit() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_ATTR_NOSYSTEM=1 \
        git -C "$repo" \
            -c core.attributesFile=/dev/null \
            -c gpg.ssh.allowedSignersFile="$allowedSigners" \
            -c gpg.ssh.revocationFile="$revokedKeys" \
            -c gpg.program=false -c gpg.openpgp.program=false -c gpg.x509.program=false \
            "$@"
}

# Fetch only the release tag. The fetch keeps the user's git config (proxies,
# url rewrites, CA certificates): everything it fetches is verified below.
# The init is isolated, so that an init.templateDir cannot add info/attributes.
mkdir "$repo"
isolatedGit init -q --bare
git -C "$repo" fetch -q --depth 1 "$repoUrl" "+refs/tags/$tag:refs/tags/$tag" ||
    die "No tag $tag at $repoUrl"

# Must be an annotated tag object, not a lightweight tag
[[ $(isolatedGit cat-file -t "refs/tags/$tag") == tag ]] ||
    die "$tag is not an annotated tag object"

tagObject=$(isolatedGit cat-file tag "refs/tags/$tag")
# Headers only, i.e. up to the first empty line
tagHeaders=$(sed -n '/^$/q;p' <<<"$tagObject")

# The signed tag object carries its own name and target type. Checking them blocks
# replaying an older, validly signed tag object under a newer ref name (rollback).
[[ $(sed -nE 's/^tag (.*)$/\1/p' <<<"$tagHeaders" | head -1) == "$tag" ]] ||
    die "Tag object name does not match ref $tag"
[[ $(sed -nE 's/^type (.*)$/\1/p' <<<"$tagHeaders" | head -1) == commit ]] ||
    die "Tag $tag does not point to a commit"

# Releases are SSH-signed. git verify-tag detects the signature type from the
# last signature block in the tag, so check that this block, which ends the tag
# object, is an SSH signature. A header line anywhere in the message is not enough.
lastBegin=$(grep '^-----BEGIN ' <<<"$tagObject" | tail -1 || true)
[[ $lastBegin == '-----BEGIN SSH SIGNATURE-----' &&
   $(tail -1 <<<"$tagObject") == '-----END SSH SIGNATURE-----' ]] ||
    die "Tag $tag does not carry an SSH signature"

if ! isolatedGit verify-tag "$tag" >/dev/null 2>"$tmp/verify.log"; then
    >&2 echo "Error: signature verification failed for tag $tag of $repoUrl"
    >&2 echo "Only keys in $allowedSigners that are not in $revokedKeys are trusted."
    >&2 sed 's/^/  /' "$tmp/verify.log"
    exit 1
fi
>&2 grep -E '^Good' "$tmp/verify.log" || true

commit=$(isolatedGit rev-parse "refs/tags/$tag^{commit}")

# Hash the verified git objects. Without .gitattributes, GitHub's archive of the
# same commit has identical content and `fetchTarball` computes the same NAR hash,
# which makes Nix enforce the verified tree. With them (e.g. export-subst), the
# local `git archive` and GitHub's can differ, so refuse instead of printing a
# hash that may never match. Capture first instead of piping into `grep -q`: under
# pipefail, ls-tree's SIGPIPE after an early match would make the check pass.
files=$(isolatedGit ls-tree -r --name-only "$commit")
if grep -qE '(^|/)\.gitattributes$' <<<"$files"; then
    die "Release $tag contains a .gitattributes file, its hash may not match GitHub's archive"
fi
isolatedGit archive --format=tar "$commit" | tar -x -C "$tree"
hash=$(nix-hash --type sha256 --sri "$tree")

>&2 echo "Fetched and verified release $version ($commit)"

# The url is pinned to the commit, not to the mutable tag name, so moving or
# deleting the tag later cannot change what this expression resolves to.
url=$repoUrl/archive/$commit.tar.gz
# The first line records the version, update-nix-bitcoin reads it back as minVersion
expression=$(cat <<EOF
# bitcoinix release v$version
builtins.fetchTarball {
  url = "$url";
  sha256 = "$hash";
}
EOF
)

if [[ ${checkDownload:-} ]]; then
    # The hash above comes from git objects, so check that the url really serves that
    # tree. Nix skips the download if the hash is already in its store or in its
    # fetcher cache, so evaluate in a throwaway store and cache, without binary caches.
    # `pwd -P`: Nix rejects a store below a symlink (e.g. /var on macOS).
    check=$(mkdir "$tmp/check" && cd "$tmp/check" && pwd -P)
    mkdir "$check/store" "$check/cache"
    if ! XDG_CACHE_HOME=$check/cache nix-instantiate --eval --store "$check/store" \
            --option substituters '' -E "$expression" >/dev/null 2>"$tmp/check.log"; then
        >&2 sed 's/^/  /' "$tmp/check.log"
        die "Could not fetch $url as the verified tree"
    fi
    >&2 echo "Downloaded $url, it matches the verified tree"
fi

echo "$expression"
