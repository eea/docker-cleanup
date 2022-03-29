#!/bin/bash

debug() {
  if [ $DEBUG ]; then
    echo "DEBUG:" "$@"
  fi
}

info() {
  echo "=>" "$@"
}

#
# Returns 1 if pattern matches. Returns $3 if not.
#
checkPatterns() {
    keepit=$3
    if [ -n "$1" ]; then
        for PATTERN in $(echo $1 | tr "," "\n"); do
        if [[ "$2" =~ ^${PATTERN} ]]; then
            debug "Matches $PATTERN - keeping"
            keepit=1
        else
            debug "No match for $PATTERN"
        fi
        done
    fi
    return $keepit
}

# Remove Images. Read the IDs from the file ToBeCleaned
# Uses tags if the image has one or more
removeImages() {
    if [ -s ToBeCleaned ]; then
        info "Start to clean $(cat ToBeCleaned | wc -l) images"
        for image in $(cat ToBeCleaned)
        do
            tags=$(docker inspect --format='{{range $tag := .RepoTags}}{{$tag}}  {{end}}' $image)
            if [[ -n "$tags" ]]; then
                docker rmi $tags
            else
                docker rmi $image 2>/dev/null
            fi
        done
        (( DIFF_LAYER=${ALL_LAYER_NUM}- $(docker images -a | tail -n +2 | wc -l) ))
        (( DIFF_IMG=$(cat ImageIdList | wc -l) - $(docker images | tail -n +2 | wc -l) ))
        if [ ! ${DIFF_LAYER} -gt 0 ]; then
                DIFF_LAYER=0
        fi
        if [ ! ${DIFF_IMG} -gt 0 ]; then
                DIFF_IMG=0
        fi
        info "Done! ${DIFF_IMG} images and ${DIFF_LAYER} layers have been cleaned."
    else
        info "No images need to be cleaned"
    fi
}

if [ ! -e "/var/run/docker.sock" ]; then
    echo "Cannot find docker socket(/var/run/docker.sock), please check the command!"
    exit 1
fi

if docker version >/dev/null; then
    echo "Docker is running properly"
else
    echo "Cannot run docker binary at /usr/bin/docker"
    echo "Please check if the docker binary is mounted correctly"
    exit 1
fi


if [ "${CLEAN_PERIOD}" == "**None**" ]; then
    info "CLEAN_PERIOD not defined, use the default value."
    CLEAN_PERIOD=1800
fi

if [ "${DELAY_TIME}" == "**None**" ]; then
    info "DELAY_TIME not defined, use the default value."
    DELAY_TIME=1800
fi

if [ "${KEEP_IMAGES}" == "**None**" ]; then
    unset KEEP_IMAGES
fi

if [ "${KEEP_CONTAINERS}" == "**None**" ]; then
    unset KEEP_CONTAINERS
fi
if [ "${KEEP_CONTAINERS}" == "**All**" ]; then
    KEEP_CONTAINERS="."
fi

if [ "${KEEP_CONTAINERS_NAMED}" == "**None**" ]; then
    unset KEEP_CONTAINERS_NAMED
fi
if [ "${KEEP_CONTAINERS_NAMED}" == "**All**" ]; then
    KEEP_CONTAINERS_NAMED="."
fi

if [ "${KEEP_VOLUMES}" == "**None**" ]; then
    unset KEEP_VOLUMES
fi
if [ "${KEEP_VOLUMES}" == "**All**" ]; then
    KEEP_VOLUMES="."
fi

if [ "${LOOP}" != "false" ]; then
    LOOP=true
fi

if [ "${DEBUG}" == "0" ]; then
    unset DEBUG
fi

if [ $DEBUG ]; then echo DEBUG ENABLED; fi

info "Run the clean script every ${CLEAN_PERIOD} seconds and delay ${DELAY_TIME} seconds to clean."

trap '{ echo "User Interupt."; exit 1; }' SIGINT
trap '{ echo "SIGTERM received, exiting."; exit 0; }' SIGTERM
while [ 1 ]
do
    debug "Starting loop"

    # Cleanup unused volumes
    # If KEEP_VOLUMES is a . then all volumes are kept and there is no need to check.
    if [ "${KEEP_VOLUMES}" != "." ]; then
      if [[ $(docker version --format '{{(index .Server.Version)}}' | grep -E '^[01]\.[012345678]\.') ]]; then
        info "Removing unused volumes using 'docker-cleanup-volumes.sh' script"
        /docker-cleanup-volumes.sh
      else
        info "Removing unused volumes using native 'docker volume' command"
        for volume in $(docker volume ls -f dangling=true | awk '$1 == "local" {print $2}'); do
          keepit=0
          checkPatterns "${KEEP_VOLUMES}" "${volume}" $keepit
          keepit=$?
          if [[ $keepit -eq 0 ]]; then
            info "Deleting unused volume ${volume}"
            docker volume rm "${volume}"
          fi
        done
      fi
    else
      info "Configured to not clean volumes"
    fi


    # Cleanup blocked non-rancher containers
    # If CLEAN_NON_RANCHER is not YES then all containers are kept and there is no need to check.
    if [[ "${CLEAN_NON_RANCHER}" != "YES" ]]; then
        info "Removing blocked containers using 'docker-cleanup-containers.sh' script"
        /docker-cleanup-containers.sh
    else
      info "Configured to not clean containers"
    fi


    IFS='
 '

    # Cleanup exited/dead containers
    if [[ "${KEEP_CONTAINERS}" == "." || "${KEEP_CONTAINERS_NAMED}" == "." ]]; then
      info "Configured to not clean containers"
    else
      info "Removing exited/dead containers"
      EXITED_CONTAINERS_IDS="`docker ps -a -q -f status=exited -f status=dead | xargs echo`"
      for CONTAINER_ID in $EXITED_CONTAINERS_IDS; do
        CONTAINER_IMAGE=$(docker inspect --format='{{(index .Config.Image)}}' $CONTAINER_ID)
        CONTAINER_NAME=$(docker inspect --format='{{(index .Name)}}' $CONTAINER_ID)
        debug "Check container image $CONTAINER_IMAGE named $CONTAINER_NAME"
        keepit=0
        checkPatterns "${KEEP_CONTAINERS}" "${CONTAINER_IMAGE}" $keepit
        keepit=$?
        checkPatterns "${KEEP_CONTAINERS_NAMED}" "${CONTAINER_NAME}" $keepit
        keepit=$?
        if [[ $keepit -eq 0 ]]; then
          info "Removing stopped container $CONTAINER_ID"
          docker rm -v $CONTAINER_ID
        fi
      done
      unset CONTAINER_ID
    fi
    info "Removing unused images"

    # Get all containers in "created" state
    rm -f CreatedContainerIdList
    docker ps -a -q -f status=created | sort > CreatedContainerIdList

    # Get all image ID
    ALL_LAYER_NUM=$(docker images -a | tail -n +2 | wc -l)
    docker images -q --no-trunc | sort -u -o ImageIdList
    CONTAINER_ID_LIST=$(docker ps -aq --no-trunc)
    # Get Image ID that is used by a containter
    rm -f ContainerImageIdList
    touch ContainerImageIdList
    for CONTAINER_ID in ${CONTAINER_ID_LIST}; do
        LINE=$(docker inspect ${CONTAINER_ID} | grep "\"Image\": \"\(sha256:\)\?[0-9a-fA-F]\{64\}\"")
        IMAGE_ID=$(echo ${LINE} | awk -F '"' '{print $4}')
        echo "${IMAGE_ID}" >> ContainerImageIdList
    done
    sort -u ContainerImageIdList -o ContainerImageIdList

    # Remove the images being used by containers from the delete list
    comm -23 ImageIdList ContainerImageIdList > ToBeCleanedImageIdList

    # Remove those reserved images from the delete list
    if [ -n "${KEEP_IMAGES}" ]; then
      rm -f KeepImageIdList
      touch KeepImageIdList
      # This looks to see if anything matches the regexp
      docker images --no-trunc | (
        while read repo tag image junk; do
          keepit=0
          debug "Check image $repo:$tag"
          checkPatterns "${KEEP_IMAGES}" "${repo}:${tag}" $keepit
          keepit=$?
          if [[ $keepit -eq 1 ]]; then
            debug "Marking image $repo:$tag to keep"
            echo $image >> KeepImageIdList
          fi
        done
      )
      # This explicitly looks for the images specified
      arr=$(echo ${KEEP_IMAGES} | tr "," "\n")
      for x in $arr
      do
          debug "Identifying image $x"
          docker inspect $x 2>/dev/null| grep "\"Id\": \"\(sha256:\)\?[0-9a-fA-F]\{64\}\"" | head -1 | awk -F '"' '{print $4}'  >> KeepImageIdList
      done
      sort KeepImageIdList -o KeepImageIdList
      comm -23 ToBeCleanedImageIdList KeepImageIdList > ToBeCleanedImageIdList2
      mv ToBeCleanedImageIdList2 ToBeCleanedImageIdList
    fi

    # Wait before cleaning containers and images
    info "Waiting ${DELAY_TIME} seconds before cleaning"
    sleep ${DELAY_TIME} & wait

    # Remove created containers that haven't managed to start within the DELAY_TIME interval
    rm -f CreatedContainerToClean
    comm -12 CreatedContainerIdList <(docker ps -a -q -f status=created | sort) > CreatedContainerToClean
    if [ -s CreatedContainerToClean ]; then
        info "Start to clean $(cat CreatedContainerToClean | wc -l) created/stuck containers"
        debug "Removing unstarted containers"
        docker rm -v $(cat CreatedContainerToClean)
    fi

    # Remove images being used by containers from the delete list again. This prevents the images being pulled from deleting
    CONTAINER_ID_LIST=$(docker ps -aq --no-trunc)
    rm -f ContainerImageIdList
    touch ContainerImageIdList
    for CONTAINER_ID in ${CONTAINER_ID_LIST}; do
        LINE=$(docker inspect ${CONTAINER_ID} | grep "\"Image\": \"\(sha256:\)\?[0-9a-fA-F]\{64\}\"")
        IMAGE_ID=$(echo ${LINE} | awk -F '"' '{print $4}')
        echo "${IMAGE_ID}" >> ContainerImageIdList
    done
    sort ContainerImageIdList -o ContainerImageIdList
    comm -23 ToBeCleanedImageIdList ContainerImageIdList > ToBeCleaned

    removeImages

    rm -f ToBeCleanedImageIdList ContainerImageIdList ToBeCleaned ImageIdList KeepImageIdList

    # Run forever or exit after the first run depending on the value of $LOOP
    [ "${LOOP}" == "true" ] || break

    info "Next clean will be started in ${CLEAN_PERIOD} seconds"
    sleep ${CLEAN_PERIOD} & wait
done
