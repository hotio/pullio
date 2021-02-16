#!/bin/bash

COMPOSE_BINARY="$(which docker-compose)"
DOCKER_BINARY="$(which docker)"
CACHE_LOCATION=/tmp
DEBUG="$1"

compose_pull_wrapper() {
    if [[ -z ${COMPOSE_BINARY} ]]; then
        "${DOCKER_BINARY}" run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$1:$1" -w="$1" linuxserver/docker-compose pull "$2"
    else
        cd "$1" || exit 1
        "${COMPOSE_BINARY}" pull "$2"
    fi
}

compose_up_wrapper() {
    if [[ -z ${COMPOSE_BINARY} ]]; then
        "${DOCKER_BINARY}" run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$1:$1" -w="$1" linuxserver/docker-compose up -d "$2"
    else
        cd "$1" || exit 1
        "${COMPOSE_BINARY}" up -d "$2"
    fi
}

send_notification() {
    extra=""
    if [[ -n $3 ]] && [[ -n $4 ]] && [[ -n $7 ]] && [[ -n $8 ]]; then
        v_ind="" && [[ $3 != "$4" ]] && v_ind=" *"
        rev_ind="" && [[ $7 != "$8" ]] && rev_ind=" *"
        extra=',
            {
            "name": "Version'$v_ind'",
            "value": "```\nold: '${3:----}'\nnew: '${4:----}'```"
            },
            {
            "name": "Revision'$rev_ind'",
            "value": "```\nold: '${7:----}'\nnew: '${8:----}'```"
            }'
    fi
    json='{
    "embeds": [
        {
        "title": "'${1}'",
        "color": '${9:-768753}',
        "fields": [
            {
            "name": "Container",
            "value": "```'${2}'```"
            },
            {
            "name": "Image",
            "value": "```'${5}'```"
            }'$extra'
        ],
        "footer": {
            "text": "Powered by Pullio"
        },
        "timestamp": "'$(date -u +'%FT%T.%3NZ')'"
        }
    ]
    }'
    curl -fsSL -H "Content-Type: multipart/form-data" -F "payload_json=${json}" "${6}"
}

sum="$(sha1sum "$0" | awk '{print $1}')"

mapfile -t containers < <("${DOCKER_BINARY}" ps --format '{{.Names}}' | sort -k1 | awk '{ print $1 }')

for i in "${!containers[@]}"; do
    IFS=" " read -r container_name <<< "${containers[i]}"
    echo "$container_name: Checking..."

    image_name=$("${DOCKER_BINARY}" inspect --format='{{.Config.Image}}' "$container_name")
    container_image_digest=$("${DOCKER_BINARY}" inspect --format='{{.Image}}' "$container_name")

    docker_compose_version=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "com.docker.compose.version" }}' "$container_name")
    docker_compose_workdir=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container_name")

    old_opencontainers_image_version=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.opencontainers.image.version" }}' "$container_name")
    old_opencontainers_image_revision=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$container_name")

    pullio_update=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio.update" }}' "$container_name")
    pullio_notify=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio.notify" }}' "$container_name")
    pullio_discord_webhook=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio.discord.webhook" }}' "$container_name")
    pullio_script_update=($("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio.script.update" }}' "$container_name"))
    pullio_script_notify=($("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio.script.notify" }}' "$container_name"))
    pullio_registry_authfile=$("${DOCKER_BINARY}" inspect --format='{{ index .Config.Labels "org.hotio.pullio.registry.authfile" }}' "$container_name")

    if [[ ( -n $docker_compose_version ) && ( $pullio_update == true || $pullio_notify == true ) ]]; then
        [[ -f $pullio_registry_authfile ]] && jq -r .password < "$pullio_registry_authfile" | "${DOCKER_BINARY}" login --username "$(jq -r .username < "$pullio_registry_authfile")" --password-stdin "$(jq -r .registry < "$pullio_registry_authfile")"

        compose_pull_wrapper "$docker_compose_workdir" "${container_name}"

        image_digest=${DEBUG}$("${DOCKER_BINARY}" image inspect --format='{{.Id}}' "${image_name}")
        new_opencontainers_image_version=$("${DOCKER_BINARY}" image inspect --format='{{ index .Config.Labels "org.opencontainers.image.version" }}' "$image_name")
        new_opencontainers_image_revision=$("${DOCKER_BINARY}" image inspect --format='{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$image_name")

        if [[ "${image_digest}" != "$container_image_digest" ]] && [[ $pullio_notify == true ]] && [[ $pullio_update != true ]]; then
            touch "$CACHE_LOCATION/$sum-$container_name.notified"
            notified_digest=$(cat "$CACHE_LOCATION/$sum-$container_name.notified")
            if [[ $notified_digest != "$image_digest" ]]; then
                echo "$container_name: Update available"
                [[ -n "${pullio_script_notify[*]}" ]] && echo "$container_name: Executing notify script" && "${pullio_script_notify[@]}"
                send_notification "Update available" "$container_name" "$old_opencontainers_image_version" "$new_opencontainers_image_version" "$image_name" "$pullio_discord_webhook" "$old_opencontainers_image_revision" "$new_opencontainers_image_revision"
                echo "$image_digest" > "$CACHE_LOCATION/$sum-$container_name.notified"
            fi
        fi

        if [[ "${image_digest}" != "$container_image_digest" ]] && [[ $pullio_update == true ]]; then
            [[ -n "${pullio_script_update[*]}" ]] && "${DOCKER_BINARY}" stop "${container_name}" && echo "$container_name: Executing update script" && "${pullio_script_update[@]}"
            if compose_up_wrapper "$docker_compose_workdir" "${container_name}"; then
                "${DOCKER_BINARY}" image prune --force
                if [[ $pullio_notify == true ]]; then
                    echo "$container_name: Update completed"
                    send_notification "Updated container" "$container_name" "$old_opencontainers_image_version" "$new_opencontainers_image_version" "$image_name" "$pullio_discord_webhook" "$old_opencontainers_image_revision" "$new_opencontainers_image_revision" 3066993
                fi
            else
                send_notification "Updating container failed!" "$container_name" "$old_opencontainers_image_version" "$new_opencontainers_image_version" "$image_name" "$pullio_discord_webhook" "$old_opencontainers_image_revision" "$new_opencontainers_image_revision" 15158332
            fi
        fi
    fi
done
