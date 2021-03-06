#!/bin/bash

shipard_cmd_stdout() {
  ssh_cmd "${GENESIS_NAME}" docker run -t --network host -v "${GENESIS_WORK_DIR}:/work" -e OS_AUTH_URL=http://keystone.ucp.svc.cluster.local:80/v3 -e OS_USERNAME=shipyard -e OS_USER_DOMAIN_NAME=default -e OS_PASSWORD="${SHIPYARD_PASSWORD}" -e OS_PROJECT_DOMAIN_NAME=default -e OS_PROJECT_NAME=service --entrypoint /usr/local/bin/shipyard "${IMAGE_SHIPYARD_CLI}" $* 2>&1
}

shipyard_cmd() {
  if [[ ! -z "${LOG_FILE}" ]]
  then
    set -o pipefail
    shipard_cmd_stdout $* | tee -a "${LOG_FILE}"
    set +o pipefail
  else
    shipard_cmd_stdout $*
  fi
}

drydock_cmd_stdout() {
  ssh_cmd "${GENESIS_NAME}" docker run -t --network host -v "${GENESIS_WORK_DIR}:/work" -e DD_URL=http://drydock-api.ucp.svc.cluster.local:9000 -e OS_AUTH_URL=http://keystone.ucp.svc.cluster.local:80/v3 -e OS_USERNAME=shipyard -e OS_USER_DOMAIN_NAME=default -e OS_PASSWORD="${SHIPYARD_PASSWORD}" -e OS_PROJECT_DOMAIN_NAME=default -e OS_PROJECT_NAME=service --entrypoint /usr/local/bin/drydock "${IMAGE_DRYDOCK_CLI}" $* 2>&1
}
drydock_cmd() {
  if [[ ! -z "${LOG_FILE}" ]]
  then
    set -o pipefail
    drydock_cmd_stdout $* | tee -a "${LOG_FILE}"
    set +o pipefail
  else
    drydock_cmd_stdout $*
  fi
}

# Create a shipyard action
# and poll until completion
shipyard_action_wait() {
  action=$1
  timeout=${2:-3600}
  poll_time=${3:-60}

  if [[ $action == "update_site" ]]
  then
    options="--allow-intermediate-commits"
  else
    options=""
  fi

  end_time=$(date -d "+${timeout} seconds" +%s)

  log "Starting Shipyard action ${action}, will timeout in ${timeout} seconds."

  ACTION_ID=$(shipyard_cmd create action ${options} "${action}")
  ACTION_ID=$(echo "${ACTION_ID}" | grep -oE 'action/[0-9A-Z]+')

  while true;
  do
    if [[ $(date +%s) -ge ${end_time} ]]
    then
      log "Shipyard action ${action} did not complete in ${timeout} seconds."
      return 2
    fi
    RESULT=$(shipyard_cmd --output-format=raw describe "${ACTION_ID}")
    ACTION_STATUS=$(echo "${RESULT}" | jq -r '.action_lifecycle')
    ACTION_RESULT=$(echo "${RESULT}" | jq -r '.dag_status')

    if [[ "${ACTION_STATUS}" == "Complete" ]]
    then
      if [[ "${ACTION_RESULT}" == "success" ]]
      then
        log "Shipyard action ${action} success!"
        return 0
      else
        log "Shipyard action ${action} completed with result ${ACTION_RESULT}"
        echo "${RESULT}" | jq >> "${LOG_FILE}"
        return 1
      fi
    else
      sleep "${poll_time}"
    fi
  done
}

# Re-use the ssh key from ssh-config
# for MAAS-deployed nodes
collect_ssh_key() {
  mkdir -p "${GATE_DEPOT}"
  if [[ ! -r ${SSH_CONFIG_DIR}/id_rsa.pub ]]
  then
    ssh_keypair_declare
  fi

  cat << EOF > ${GATE_DEPOT}/airship_ubuntu_ssh_key.yaml
---
schema: deckhand/Certificate/v1
metadata:
  schema: metadata/Document/v1
  name: ubuntu_ssh_key
  layeringDefinition:
    layer: site
    abstract: false
  storagePolicy: cleartext
data: |-
EOF
  cat ${SSH_CONFIG_DIR}/id_rsa.pub | sed -e 's/^/  /' >> ${GATE_DEPOT}/airship_ubuntu_ssh_key.yaml
}

