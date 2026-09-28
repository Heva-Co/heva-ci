#!/usr/bin/env bash
# Resolve where build-push builds and pushes, from either input style:
#
#   regions + project_id + repository + image
#       The action builds <region>-docker.pkg.dev/<project_id>/<repository>/<image>
#       for every region. The first region is the one built into.
#
#   image_name (+ push_regions)            [original inputs]
#       Passed through unchanged: image_name is the primary image, and
#       replication keeps its original behaviour.
#
# The regions list may be space-, comma- or newline-separated, or a JSON array.
#
# Writes to $GITHUB_OUTPUT:
#   mode           "regions" or "image_name"
#   primary_image  full path (no tag) of the image built first
#   primary_region region of primary_image (regions mode only)
#   regions        JSON array of every region pushed to, primary first (regions mode only)
#   hosts          comma-separated registry hosts, for configure-docker (regions mode only)
set -euo pipefail

fail() {
  echo "::error::build-push: $1"
  exit 1
}

if [[ -z "${INPUT_REGIONS:-}" ]]; then
  [[ -n "${INPUT_IMAGE_NAME:-}" ]] ||
    fail "set regions (with project_id, repository, image) or image_name"

  # A bare name ("my-service") makes Docker resolve it against Docker Hub, and
  # the push then fails with an unhelpful "insufficient scopes". Warn rather
  # than fail, so a caller that really does push elsewhere keeps working.
  if [[ ! "$INPUT_IMAGE_NAME" =~ ^[a-z0-9-]+-docker\.pkg\.dev/.+ ]]; then
    echo "::warning::build-push: image_name '${INPUT_IMAGE_NAME}' is not an Artifact Registry path (<region>-docker.pkg.dev/<project>/<repo>/<image>). A bare name is pushed to Docker Hub. Consider passing regions, project_id, repository and image instead."
  fi

  {
    echo "mode=image_name"
    echo "primary_image=${INPUT_IMAGE_NAME}"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

[[ -n "${INPUT_IMAGE_NAME:-}" ]] &&
  fail "set either regions (with project_id, repository, image) or image_name, not both"
[[ -n "${INPUT_PUSH_REGIONS:-}" && "${INPUT_PUSH_REGIONS}" != "[]" ]] &&
  fail "push_regions only applies to image_name; list every region in regions instead"
for name in PROJECT_ID REPOSITORY IMAGE; do
  var="INPUT_${name}"
  [[ -n "${!var:-}" ]] || fail "regions needs $(tr 'A-Z' 'a-z' <<< "$name") to build the image path"
done

regions=()
while IFS= read -r region; do
  [[ -z "$region" ]] && continue
  [[ "$region" =~ ^[a-z]+-[a-z]+[0-9]+$ ]] ||
    fail "'${region}' does not look like a GCP region (e.g. us-central1)"
  regions+=("$region")
done < <(
  if [[ "$INPUT_REGIONS" =~ ^[[:space:]]*\[ ]]; then
    jq -r '.[]' <<< "$INPUT_REGIONS"
  else
    tr ', \t' '\n\n\n' <<< "$INPUT_REGIONS"
  fi
)
(( ${#regions[@]} > 0 )) || fail "regions is empty"

primary_region="${regions[0]}"
hosts=$(printf '%s-docker.pkg.dev,' "${regions[@]}")

{
  echo "mode=regions"
  echo "primary_image=${primary_region}-docker.pkg.dev/${INPUT_PROJECT_ID}/${INPUT_REPOSITORY}/${INPUT_IMAGE}"
  echo "primary_region=${primary_region}"
  echo "regions=$(printf '%s\n' "${regions[@]}" | jq -Rnc '[inputs]')"
  echo "hosts=${hosts%,}"
} >> "$GITHUB_OUTPUT"
