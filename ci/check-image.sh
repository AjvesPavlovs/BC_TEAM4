#!/bin/sh
set -eu

mode=${1:-verify}
case "$mode" in
    verify) ;;
    publish)
        : "${DOCKERHUB_USER:?Team registry user is required}"
        : "${DOCKERHUB_TOKEN:?Team registry token is required}"
        printf '%s\n' "${DOCKERHUB_REPO:?Team registry repository is required}" |
            grep -Eq '^[a-z0-9][a-z0-9_-]*/[a-z0-9][a-z0-9._-]*$'
        ;;
    *) exit 2 ;;
esac

scratch=$(mktemp -d)
# An isolated Docker config also keeps the publish credentials off the agent host.
export DOCKER_CONFIG="$scratch"
run_id=${scratch##*.}
local_image="slice-sip-ci:$run_id"
container=
image=
cleanup() {
    if [ -n "$container" ]; then
        docker stop "$container" >/dev/null 2>&1 || true
    fi
    if [ -n "$image" ]; then
        docker image rm "$image" >/dev/null 2>&1 || true
    fi
    docker image rm "$local_image" >/dev/null 2>&1 || true
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

docker build --pull --platform linux/amd64 -t "$local_image" .
container=$(docker run -d --rm "$local_image")
# Share only the test container's network namespace. No host port is published.
docker run --rm --network "container:$container" curlimages/curl:8.17.0 \
    --fail --silent --show-error --retry 8 --retry-connrefused \
    --retry-delay 2 --max-time 10 http://127.0.0.1/ -o /dev/null
echo 'NGINX HTTP smoke check passed'

if [ "$mode" = publish ]; then
    image="docker.io/$DOCKERHUB_REPO:${CI_PIPELINE_NUMBER:?}-${CI_COMMIT_SHA:?}-$run_id"
    printf '%s' "$DOCKERHUB_TOKEN" | docker login --username "$DOCKERHUB_USER" --password-stdin
    docker tag "$local_image" "$image"
    docker push --platform linux/amd64 "$image" > "$scratch/push.log" || {
        cat "$scratch/push.log" >&2
        exit 1
    }
    cat "$scratch/push.log"
    digest=$(awk '$2 == "digest:" {print $3}' "$scratch/push.log")
    printf '%s\n' "$digest" | grep -Eq '^sha256:[a-f0-9]{64}$'
    printf 'docker.io/%s@%s\n' "$DOCKERHUB_REPO" "$digest" > .woodpecker-release-image
fi
