#!/bin/bash

# Change to workspace
cd ${__DATA__}/docker

# Define some constants
BREADCRUMB_FILE="breadcrumb"
BREADCRUMB_IMAGE_KEY="tag"

IMAGES="images"
IMAGE_CREATE_API="create"
CONTAINERS="containers"
CONTAINER_CREATE_API="create"
CONTAINER_START_API="start"
CONTAINER_QUERY_API="json"
CONTAINER_KILL_API="kill"
CONTAINER_RESTART_API="restart"

TRACE_FILE="/tmp/trace$$.txt"
CURL_OPTIONS="--silent --http1.0 --trace ${TRACE_FILE}"

CONTAINER_PORT=3000

# Properties that can be overridden by options
HOST_PORT=8080
DEBUG=0

usage () {
  echo "Usage: `basename $0` [(-c|--container_cloud) container_cloud] [(-p|--port) port] [image]"
}

restart_previous () {
  if [ "${PREV_ID}" != "" ]; then
    echo "Restarting previous version (${PREV_ID})"
    curl ${CURL_OPTIONS} --request POST \
      --header "Content-Length: 0" \
      ${CONTAINER_CLOUD}/${CONTAINERS}/${PREV_ID}/${CONTAINER_RESTART_API}
  fi
}

remove_previous () {
  if [ "${PREV_ID}" != "" ]; then
    echo "Removing previous version (container: ${PREV_ID})"
    # first query so we can find the image it is based on
    PREV_CNTR=`curl ${CURL_OPTIONS} ${CONTAINER_CLOUD}/${CONTAINERS}/$PREV_ID/${CONTAINER_QUERY_API}`
    curl ${CURL_OPTIONS} --request DELETE ${CONTAINER_CLOUD}/${CONTAINERS}/${PREV_ID}

    PREV_IMG_ID=`echo $PREV_CNTR | sed 's/.*\"\(Image\)\":\"\([^"]*\)\".*/\2/'`
    echo "Removing previous version (image: ${PREV_IMG_ID})"
    curl ${CURL_OPTIONS} --request DELETE ${CONTAINER_CLOUD}/${IMAGES}/${PREV_IMG_ID}
  fi
}

# read image tag from breadcrumb file
if [ -e "${BREADCRUMB_FILE}" ]; then
  echo "Reading image tag from: ${BREADCRUMB_FILE}"
  echo "----"
  cat ${BREADCRUMB_FILE}
  echo "----"
  IMAGE=`cat ${BREADCRUMB_FILE} | grep ${BREADCRUMB_IMAGE_KEY} | sed 's/.*=\(.*\)/\1/'`
  echo "Read image tag = ${IMAGE}"
fi

# allow command line to override values
while [ $# -ge 1 ]
do
key="${1}"
shift
case ${key} in
  -c|--container_cloud)
  CONTAINER_CLOUD="${1}"
  shift
  ;;
  -p|--port)
  HOST_PORT="${1}"
  shift
  ;;
  -d|--debug)
  DEBUG=1
  ;;
  *)
  IMAGE="${key}"
  ;;
esac
done

# validate that the necessary inputs are defined
if [ -z ${IMAGE} ]; then
  usage
  exit 1
fi
if [ -z ${CONTAINER_CLOUD} ]; then
  usage
  exit 1
fi

# Identify tag
IMG=`echo "${IMAGE}" | sed 's/\(.*\):\([0-9]\+\)$/\1/'` 
TAG=`echo "${IMAGE}" | sed 's/\(.*\):\([0-9]\+\)$/\2/'`
echo "Extracted registry/namespace/repository = ${IMG}"
echo "Extracted tag = ${TAG}"

# Pull the image from the registry
echo "Pulling image..."
IMAGE_CREATE_RESPONSE=`curl ${CURL_OPTIONS} --request POST \
  ${CONTAINER_CLOUD}/${IMAGES}/${IMAGE_CREATE_API} \
  --data-urlencode "fromImage=${IMG}" \
  --data-urlencode "tag=${TAG}"`

# show result
echo "============"
echo ${IMAGE_CREATE_RESPONSE}
echo "============"

# Create body of POST request to create container
CREATE_PROPERTIES_FILE="/tmp/create$$.tmp"
printf "{\n" > ${CREATE_PROPERTIES_FILE}
printf "  \"Image\": \"${IMAGE}\",\n" >> ${CREATE_PROPERTIES_FILE}
printf "  \"AttachStdin\":false,\n" >> ${CREATE_PROPERTIES_FILE}
printf "  \"Tty\":false,\n" >> ${CREATE_PROPERTIES_FILE}
# cf. http://stackoverflow.com/questions/20428302/binding-a-port-to-a-host-interface-using-the-rest-api
# cf. https://github.com/docker/docker/issues/3039
printf "  \"ExposedPorts\":{\"${CONTAINER_PORT}/tcp\": {}}\n" >> ${CREATE_PROPERTIES_FILE}
printf "}\n" >> ${CREATE_PROPERTIES_FILE}

echo ""
echo "Create Properties File:"
echo "============"
cat ${CREATE_PROPERTIES_FILE}
echo "============"

if [ ${DEBUG} -eq 0 ]; then 
  # stop and kill any previous version; TODO which is the right "previous" ?
  PREV_ID=`curl ${CURL_OPTIONS} ${CONTAINER_CLOUD}/${CONTAINERS}/${CONTAINER_QUERY_API} | grep ${IMG} | sed 's/.*\"Id\":\"\([^"]*\)".*/\1/'`
  echo "Found current version running with id: ${PREV_ID}"
  PREV_ID=`echo ${PREV_ID} | sed 's/^\(............\).*/\1/'`
  echo "Id shortened to: ${PREV_ID}"

  if [ "${PREV_ID}" != "" ]; then
    echo "Killing current version (${PREV_ID})..."
    echo "curl ${CURL_OPTIONS} --request POST ${CONTAINER_CLOUD}/${CONTAINERS}/${PREV_ID}/${CONTAINER_KILL_API}"
    curl ${CURL_OPTIONS} --request POST \
      --header "Content-Length: 0" \
      ${CONTAINER_CLOUD}/${CONTAINERS}/${PREV_ID}/${CONTAINER_KILL_API}
    # cat ${TRACE_FILE}
    echo "Killed previous verison"
  fi

  # create container
  echo "Creating container..."
  CREATE_RESULT=`curl ${CURL_OPTIONS} --request POST \
    --header "Content-Type: application/json" \
    ${CONTAINER_CLOUD}/${CONTAINERS}/${CONTAINER_CREATE_API} \
    --data @${CREATE_PROPERTIES_FILE}`
  
  echo "Container create result:"
  echo "============"
  echo ${CREATE_RESULT}
  echo "============"

  CONTAINER_ID=`echo "${CREATE_RESULT}" | grep Id | sed 's/[^:]*:"\([^"]*\)".*/\1/'`
  if [ -z ${CONTAINER_ID} ]; then
    restart_previous
    echo "Terminating"
    exit 1
  fi
  
  echo "Created container id: ${CONTAINER_ID}"

  # Create body of POST request to start container
  START_PROPERTIES_FILE="/tmp/start$$.tmp"
  printf "{\n" > ${START_PROPERTIES_FILE}
  printf "  \"PortBindings\":{ \"${CONTAINER_PORT}/tcp\": [{ \"HostPort\": \"${HOST_PORT}\" }] }\n" >> ${START_PROPERTIES_FILE}
  printf "}\n" >> ${START_PROPERTIES_FILE}

  echo "Start Properties File:"
  echo "============"
  cat ${START_PROPERTIES_FILE}
  echo "============"

  # start container
  echo "Starting container..."
  START_RESULT=`curl ${CURL_OPTIONS} --request POST \
    --header "Content-Type: application/json" \
    ${CONTAINER_CLOUD}/${CONTAINERS}/${CONTAINER_ID}/${CONTAINER_START_API} \
    --data @${START_PROPERTIES_FILE}`
  
  echo "Container start result:"
  echo "============"
  echo "${START_RESULT}"
  echo "============"
  
  # if fail to start, clean up the container
  if [[ ${START_RESULT} == Cannot* ]]; then
    echo "Error starting container"
    # clean up
    curl ${CURL_OPTIONS} --request DELETE ${CONTAINER_CLOUD}/${CONTAINERS}/${CONTAINER_ID}
    # and restart previous container
    restart_previous
    exit 1
  fi

  # A new container was created and started, remove the previous one
  remove_previous
  # output resulting container
  echo "{\"container\":\"${CONTAINER_ID}\"}" > $__STATUS__/out
    
fi
# cleanup request bodies
/bin/rm -f ${CREATE_PROPERTIES_FILE} ${START_PROPERTIES_FILE} ${TRACE_FILE}

exit 0