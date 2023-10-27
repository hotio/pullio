#!/bin/bash

COMPOSE_BINARY="${COMPOSE_BINARY:-$(which 'docker-compose')}"
DOCKER_BINARY="${DOCKER_BINARY:-$(which 'docker')}"
CACHE_LOCATION=/tmp
TAG=""
DEBUG=""
CURRENT_VERSION=0.0.6
LATEST_VERSION=$(curl -fsSL "https://api.github.com/repos/hotio/pullio/releases" | jq -r .[0].tag_name)

if ! docker compose version >/dev/null 2>&1; then
  echo "Using docker-compose V1"
  COMPOSE_V2="0"
else
  echo "Using docker compose V2"
  COMPOSE_V2="1"
fi

while [ "$1" != "" ]; do
    PARAM=$(printf "%s\n" $1 | awk -F= '{print $1}')
    VALUE=$(printf "%s\n" $1 | sed 's/^[^=]*=//g')
    if [[ $VALUE == "$PARAM" ]]; then
        shift
        VALUE=$1
    fi
    case $PARAM in
        --tag)
            [[ -n $VALUE ]] && [[ $VALUE != "--"* ]] && TAG=".$VALUE"
            ;;
        --debug)
            [[ $VALUE != "--"* ]] && DEBUG="${VALUE:-debug}"
            ;;
    esac
    shift
done

echo "Running with \"DEBUG=$DEBUG\" and \"TAG=$TAG\"."
echo "Current version: ${CURRENT_VERSION}"
echo "Latest version: ${LATEST_VERSION}"

compose_pull_wrapper() {
    cd "$1" || exit 1
    if [[ -z ${COMPOSE_BINARY} ]]; then
        if [[ "${COMPOSE_V2}" == "1" ]]; then
            "${DOCKER_BINARY}" compose pull "$2"
        else
            "${DOCKER_BINARY}" run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$1:$1" -w="$1" linuxserver/docker-compose pull "$2"
        fi
    else
        if [[ "${COMPOSE_V2}" == "1" ]]; then
            "${DOCKER_BINARY}" compose pull "$2"
        else
            "${COMPOSE_BINARY}" pull "$2"
        fi
    fi
}

compose_up_wrapper() {
    cd "$1" || exit 1
    if [[ -z ${COMPOSE_BINARY} ]]; then
        if [[ "${COMPOSE_V2}" == "1" ]]; then
            "${DOCKER_BINARY}" compose up -d --always-recreate-deps "$2"
        else
            "${DOCKER_BINARY}" run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$1:$1" -w="$1" linuxserver/docker-compose up -d --always-recreate-deps "$2"
        fi
    else
        if [[ "${COMPOSE_V2}" == "1" ]]; then
            "${DOCKER_BINARY}" compose up -d --always-recreate-deps "$2"
        else
            "${COMPOSE_BINARY}" up -d --always-recreate-deps "$2"
        fi
    fi
}


send_discord_notification() {
    if [[ "${LATEST_VERSION}" != "${CURRENT_VERSION}" ]]; then
        footer_text="Powered by Pullio (update available)"
    else
        footer_text="Powered by Pullio"
    fi
    extra=""
    if [[ -n $3 ]] && [[ -n $4 ]] && [[ -n $7 ]] && [[ -n $8 ]]; then
        v_ind=">" && [[ ${3} == "${4}" ]] && v_ind="="
        r_ind=">" && [[ ${7} == "${8}" ]] && r_ind="="
        extra=',
            {
            "name": "Version",
            "value": "```\n'${3}'\n ='$v_ind' '${4}'```"
            },
            {
            "name": "Revision (Git SHA)",
            "value": "```\n'${7:0:6}'\n ='$r_ind' '${8:0:6}'```"
            }'
    fi
    d_ind=">" && [[ ${9} == "${10}" ]] && d_ind="="
    author_url="${12}" && [[ -z ${12} ]] && author_url="https://github.com/hotio/pullio/raw/master/pullio.png"
    json='{
    "embeds": [
        {
        "description": "'${1}'",
        "color": '${11:-768753}',
        "fields": [
            {
            "name": "Image",
            "value": "```'${5}'```"
            },
            {
            "name": "Image ID",
            "value": "```\n'${9:0:11}'\n ='$d_ind' '${10:0:11}'```"
            }'$extra'
        ],
        "author": {
            "name": "'${2}'",
            "url": "'${13}'",
            "icon_url": "'${author_url}'"
        },
        "footer": {
            "text": "'${footer_text}'"
        },
        "timestamp": "'$(date -u +'%FT%T.%3NZ')'"
        }
    ],
    "username": "Pullio",
    "avatar_url": "https://github.com/hotio/pullio/raw/master/pullio.png"
    }'
    curl -fsSL -H "User-Agent: Pullio" -H "Content-Type: application/json" -d "${json}" "${6}"
}

send_generic_webhook() {
    json='{
    "container": "'${2}'",
    "image": "'${5}'",
    "avatar": "'${11}'",
    "old_image_id": "'${9}'",
    "new_image_id": "'${10}'",
    "old_version": "'${3}'",
    "new_version": "'${4}'",
    "old_revision": "'${7}'",
    "new_revision": "'${8}'",
    "type": "'${1}'",
    "url": "'${12}'",
    "timestamp": "'$(date -u +'%FT%T.%3NZ')'"
    }'
    curl -fsSL -H "User-Agent: Pullio" -H "Content-Type: application/json" -d "${json}" "${6}"
}

export_env_vars() {
    export PULLIO_CONTAINER=${1}
    export PULLIO_IMAGE=${2}
    export PULLIO_AVATAR=${3}
    export PULLIO_OLD_IMAGE_ID=${4}
    export PULLIO_NEW_IMAGE_ID=${5}
    export PULLIO_OLD_VERSION=${6}
    export PULLIO_NEW_VERSION=${7}
    export PULLIO_OLD_REVISION=${8}
    export PULLIO_NEW_REVISION=${9}
    export PULLIO_COMPOSE_SERVICE=${10}
    export PULLIO_COMPOSE_WORKDIR=${11}
    export PULLIO_AUTHOR_URL=${13}
}

sum="$(sha1sum "$0" | awk '{print $1}')"

mapfile -t containers < <("${DOCKER_BINARY}" ps --format '{{.Names}}' | sort -k1 | awk '{ print $1 }')

for i in "${!containers[@]}"; do
    IFS=" " read -r container_name <<< "${containers[i]}"
    echo "$container_name: Checking..."

    image_name=$("${DOCKER_BINARY}" inspect --format='{{.Config.Image}}' "$container_name")
    container_image_digest=$("${DOCKER_BINARY}" inspect --format='{{.Image}}' "$container_name")

    docker_compose_service=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "com.docker.compose.service" }}' "$container_name")
    docker_compose_version=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "com.docker.compose.version" }}' "$container_name")
    docker_compose_workdir=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container_name")

    old_opencontainers_image_version=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.opencontainers.image.version" }}' "$container_name")
    old_opencontainers_image_revision=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$container_name")

    pullio_update=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio'"${TAG}"'.update" }}' "$container_name")
    pullio_notify=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio'"${TAG}"'.notify" }}' "$container_name")
    pullio_discord_webhook=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio'"${TAG}"'.discord.webhook" }}' "$container_name")
    pullio_generic_webhook=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio'"${TAG}"'.generic.webhook" }}' "$container_name")
    pullio_script_update=($("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio'"${TAG}"'.script.update" }}' "$container_name"))
    pullio_script_notify=($("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio'"${TAG}"'.script.notify" }}' "$container_name"))
    pullio_registry_authfile=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio'"${TAG}"'.registry.authfile" }}' "$container_name")
    pullio_author_avatar=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio'"${TAG}"'.author.avatar" }}' "$container_name")
    pullio_author_url=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio'"${TAG}"'.author.url" }}' "$container_name")

    if [[ ( -n $docker_compose_version ) && ( $pullio_update == true || $pullio_notify == true ) ]]; then
        if [[ -f $pullio_registry_authfile ]]; then
            echo "$container_name: Registry login..."
            jq -r .password < "$pullio_registry_authfile" | "${DOCKER_BINARY}" login --username "$(jq -r .username < "$pullio_registry_authfile")" --password-stdin "$(jq -r .registry < "$pullio_registry_authfile")"
        fi

        echo "$container_name: Pulling image..."
        if ! compose_pull_wrapper "$docker_compose_workdir" "${docker_compose_service}"; then
            echo "$container_name: Pulling failed!"
        fi

        image_digest=${DEBUG}$("${DOCKER_BINARY}" image inspect --format='{{.Id}}' "${image_name}")
        new_opencontainers_image_version=$("${DOCKER_BINARY}" image inspect --format='{{ index .Config.Labels "org.opencontainers.image.version" }}' "$image_name")
        new_opencontainers_image_revision=$("${DOCKER_BINARY}" image inspect --format='{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$image_name")

        status="I've got an update waiting for me.\nGive it to me, please."
        status_generic="update_available"
        color=768753
        if [[ "${image_digest}" != "$container_image_digest" ]] && [[ $pullio_update == true ]]; then
            if [[ -n "${pullio_script_update[*]}" ]]; then
                echo "$container_name: Stopping container..."
                "${DOCKER_BINARY}" stop "${container_name}"
                echo "$container_name: Executing update script..."
                export_env_vars "$container_name" "${image_name}" "${pullio_author_avatar}" "${container_image_digest/sha256:/}" "${image_digest/sha256:/}" "${old_opencontainers_image_version}" "${new_opencontainers_image_version}" "${old_opencontainers_image_revision}" "${new_opencontainers_image_revision}" "${docker_compose_service}" "${docker_compose_workdir}" "${pullio_author_url}"
                "${pullio_script_update[@]}"
            fi
            echo "$container_name: Updating container..."
            if compose_up_wrapper "$docker_compose_workdir" "${docker_compose_service}"; then
                status="I just updated myself.\nFeeling brand spanking new again!"
                status_generic="update_success"
                color=3066993
            else
                echo "$container_name: Updating container failed!"
                status="I tried to update myself.\nIt didn't work out, I might need some help."
                status_generic="update_failure"
                color=15158332
            fi
            rm -f "$CACHE_LOCATION/$sum-$container_name.notified"
        fi

        if [[ "${image_digest}" != "$container_image_digest" ]] && [[ $pullio_notify == true ]]; then
            touch "$CACHE_LOCATION/$sum-$container_name.notified"
            notified_digest=$(cat "$CACHE_LOCATION/$sum-$container_name.notified")
            if [[ $notified_digest != "$image_digest" ]]; then
                if [[ -n "${pullio_script_notify[*]}" ]]; then
                    echo "$container_name: Executing notify script..."
                    export_env_vars "$container_name" "${image_name}" "${pullio_author_avatar}" "${container_image_digest/sha256:/}" "${image_digest/sha256:/}" "${old_opencontainers_image_version}" "${new_opencontainers_image_version}" "${old_opencontainers_image_revision}" "${new_opencontainers_image_revision}" "${docker_compose_service}" "${docker_compose_workdir}" "${pullio_author_url}"
                    "${pullio_script_notify[@]}"
                fi
                if [[ -n "$pullio_discord_webhook" ]]; then
                    echo "$container_name: Sending discord notification..."
                    send_discord_notification "$status" "$container_name" "$old_opencontainers_image_version" "$new_opencontainers_image_version" "$image_name" "$pullio_discord_webhook" "$old_opencontainers_image_revision" "$new_opencontainers_image_revision" "${container_image_digest/sha256:/}" "${image_digest/sha256:/}" "$color" "$pullio_author_avatar" "$pullio_author_url"
                fi
                if [[ -n "$pullio_generic_webhook" ]]; then
                    echo "$container_name: Sending generic webhook..."
                    send_generic_webhook "$status_generic" "$container_name" "$old_opencontainers_image_version" "$new_opencontainers_image_version" "$image_name" "$pullio_generic_webhook" "$old_opencontainers_image_revision" "$new_opencontainers_image_revision" "${container_image_digest/sha256:/}" "${image_digest/sha256:/}" "$pullio_author_avatar" "$pullio_author_url"
                fi
                echo "$image_digest" > "$CACHE_LOCATION/$sum-$container_name.notified"
            fi
        fi
    fi
done

echo "Pruning docker images..."
"${DOCKER_BINARY}" image prune --force
