#!/bin/bash
# This script is used to configure and run Consul on an AWS server.

set -e

readonly AWS_ASG_TAG_KEY="aws:autoscaling:groupName"

readonly CONSUL_CONFIG_FILE="default.json"
readonly CONSUL_GOSSIP_ENCRYPTION_CONFIG_FILE="gossip-encryption.json"
readonly CONSUL_RPC_ENCRYPTION_CONFIG_FILE="rpc-encryption.json"
readonly SUPERVISOR_CONFIG_PATH="/etc/supervisor/conf.d/run-consul.conf"

readonly EC2_INSTANCE_METADATA_URL="http://169.254.169.254/latest/meta-data"
readonly EC2_INSTANCE_DYNAMIC_DATA_URL="http://169.254.169.254/latest/dynamic"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"

readonly MAX_RETRIES=30
readonly SLEEP_BETWEEN_RETRIES_SEC=10

readonly DEFAULT_AUTOPILOT_CLEANUP_DEAD_SERVERS="true"
readonly DEFAULT_AUTOPILOT_LAST_CONTACT_THRESHOLD="200ms"
readonly DEFAULT_AUTOPILOT_MAX_TRAILING_LOGS="250"
readonly DEFAULT_AUTOPILOT_SERVER_STABILIZATION_TIME="10s"
readonly DEFAULT_AUTOPILOT_REDUNDANCY_ZONE_TAG="az"
readonly DEFAULT_AUTOPILOT_DISABLE_UPGRADE_MIGRATION="false"

function print_usage {
  echo
  echo "Usage: run-consul [OPTIONS]"
  echo
  echo "This script is used to configure and run Consul on an AWS server."
  echo
  echo "Options:"
  echo
  echo -e "  --server\t\tIf set, run in server mode. Optional. Exactly one of --server or --client must be set."
  echo -e "  --client\t\tIf set, run in client mode. Optional. Exactly one of --server or --client must be set."
  echo -e "  --cluster-tag-key\tAutomatically form a cluster with Instances that have this tag key and the tag value in --cluster-tag-value. Optional."
  echo -e "  --cluster-tag-value\tAutomatically form a cluster with Instances that have the tag key in --cluster-tag-key and this tag value. Optional."
  echo -e "  --datacenter\t\tThe name of the datacenter Consul is running in. Optional. If not specified, will default to AWS region name."
  echo -e "  --config-dir\t\tThe path to the Consul config folder. Optional. Default is the absolute path of '../config', relative to this script."
  echo -e "  --data-dir\t\tThe path to the Consul data folder. Optional. Default is the absolute path of '../data', relative to this script."
  echo -e "  --log-dir\t\tThe path to the Consul log folder. Optional. Default is the absolute path of '../log', relative to this script."
  echo -e "  --bin-dir\t\tThe path to the folder with Consul binary. Optional. Default is the absolute path of the parent folder of this script."
  echo -e "  --user\t\tThe user to run Consul as. Optional. Default is to use the owner of --config-dir."
  echo -e "  --enable-gossip-encryption\t\tEnable encryption of gossip traffic between nodes. Optional. Must also specify --gossip-encryption-key."
  echo -e "  --gossip-encryption-key\t\tThe key to use for encrypting gossip traffic. Optional. Must be specified with --enable-gossip-encryption."
  echo -e "  --enable-rpc-encryption\t\tEnable encryption of RPC traffic between nodes. Optional. Must also specify --ca-file-path, --cert-file-path and --key-file-path."
  echo -e "  --ca-path\t\tPath to the directory of CA files used to verify outgoing connections. Optional. Must be specified with --enable-rpc-encryption."
  echo -e "  --cert-file-path\tPath to the certificate file used to verify incoming connections. Optional. Must be specified with --enable-rpc-encryption and --key-file-path."
  echo -e "  --key-file-path\tPath to the certificate key used to verify incoming connections. Optional. Must be specified with --enable-rpc-encryption and --cert-file-path."
  echo -e "  --environment\t\tA single environment variable in the key/value pair form 'KEY=\"val\"' to pass to Consul as environment variable when starting it up. Repeat this option for additional variables. Optional."
  echo -e "  --skip-consul-config\tIf this flag is set, don't generate a Consul configuration file. Optional. Default is false."
  echo
  echo "Options for Consul Autopilot:"
  echo
  echo -e "  --autopilot-cleanup-dead-servers\tSet to true or false to control the automatic removal of dead server nodes periodically and whenever a new server is added to the cluster. Defaults to $DEFAULT_AUTOPILOT_CLEANUP_DEAD_SERVERS. Optional."
  echo -e "  --autopilot-last-contact-threshold\tControls the maximum amount of time a server can go without contact from the leader before being considered unhealthy. Must be a duration value such as 10s. Defaults to $DEFAULT_AUTOPILOT_LAST_CONTACT_THRESHOLD. Optional."
  echo -e "  --autopilot-max-trailing-logs\t\tControls the maximum number of log entries that a server can trail the leader by before being considered unhealthy. Defaults to $DEFAULT_AUTOPILOT_MAX_TRAILING_LOGS. Optional."
  echo -e "  --autopilot-server-stabilization-time\tControls the minimum amount of time a server must be stable in the 'healthy' state before being added to the cluster. Only takes effect if all servers are running Raft protocol version 3 or higher. Must be a duration value such as 30s. Defaults to $DEFAULT_AUTOPILOT_SERVER_STABILIZATION_TIME. Optional."
  echo -e "  --autopilot-redundancy-zone-tag\t\t(Enterprise-only) This controls the -node-meta key to use when Autopilot is separating servers into zones for redundancy. Only one server in each zone can be a voting member at one time. If left blank, this feature will be disabled. Defaults to $DEFAULT_AUTOPILOT_REDUNDANCY_ZONE_TAG. Optional."
  echo -e "  --autopilot-disable-upgrade-migration\t(Enterprise-only) If this flag is set, this will disable Autopilot's upgrade migration strategy in Consul Enterprise of waiting until enough newer-versioned servers have been added to the cluster before promoting any of them to voters. Defaults to $DEFAULT_AUTOPILOT_DISABLE_UPGRADE_MIGRATION. Optional."
  echo -e "  --autopilot-upgrade-version-tag\t\t(Enterprise-only) That tag to be used to override the version information used during a migration. Optional."
  echo
  echo
  echo "Example:"
  echo
  echo "  run-consul --server --config-dir /custom/path/to/consul/config"
}

function log {
  local -r level="$1"
  local -r message="$2"
  local -r timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  >&2 echo -e "${timestamp} [${level}] [$SCRIPT_NAME] ${message}"
}

function log_info {
  local -r message="$1"
  log "INFO" "$message"
}

function log_warn {
  local -r message="$1"
  log "WARN" "$message"
}

function log_error {
  local -r message="$1"
  log "ERROR" "$message"
}

# Based on code from: http://stackoverflow.com/a/16623897/483528
function strip_prefix {
  local -r str="$1"
  local -r prefix="$2"
  echo "${str#$prefix}"
}

function assert_not_empty {
  local -r arg_name="$1"
  local -r arg_value="$2"

  if [[ -z "$arg_value" ]]; then
    log_error "The value for '$arg_name' cannot be empty"
    print_usage
    exit 1
  fi
}

function lookup_path_in_instance_metadata {
  local -r path="$1"
  curl --silent --show-error --location "$EC2_INSTANCE_METADATA_URL/$path/"
}

function lookup_path_in_instance_dynamic_data {
  local -r path="$1"
  curl --silent --show-error --location "$EC2_INSTANCE_DYNAMIC_DATA_URL/$path/"
}

function get_instance_ip_address {
  lookup_path_in_instance_metadata "local-ipv4"
}

function get_instance_id {
  lookup_path_in_instance_metadata "instance-id"
}

function get_instance_region {
  lookup_path_in_instance_dynamic_data "instance-identity/document" | jq -r ".region"
}

function get_instance_tags {
  local -r instance_id="$1"
  local -r instance_region="$2"
  local tags=""
  local count_tags=""

  log_info "Looking up tags for Instance $instance_id in $instance_region"
  for (( i=1; i<="$MAX_RETRIES"; i++ )); do
    tags=$(aws ec2 describe-tags \
      --region "$instance_region" \
      --filters "Name=resource-type,Values=instance" "Name=resource-id,Values=${instance_id}")
    count_tags=$(echo $tags | jq -r ".Tags? | length")
    if [[ "$count_tags" -gt 0 ]]; then
      log_info "This Instance $instance_id in $instance_region has Tags."
      echo "$tags"
      return
    else
      log_warn "This Instance $instance_id in $instance_region does not have any Tags."
      log_warn "Will sleep for $SLEEP_BETWEEN_RETRIES_SEC seconds and try again."
      sleep "$SLEEP_BETWEEN_RETRIES_SEC"
    fi
  done

  log_error "Could not find Instance Tags for $instance_id in $instance_region after $MAX_RETRIES retries."
  exit 1
}

function get_asg_size {
  local -r asg_name="$1"
  local -r aws_region="$2"
  local asg_json=""

  log_info "Looking up the size of the Auto Scaling Group $asg_name in $aws_region"
  asg_json=$(aws autoscaling describe-auto-scaling-groups --region "$aws_region" --auto-scaling-group-names "$asg_name")
  echo "$asg_json" | jq -r '.AutoScalingGroups[0].DesiredCapacity'
}

function get_cluster_size {
  local -r instance_tags="$1"
  local -r aws_region="$2"

  local asg_name=""
  asg_name=$(get_tag_value "$instance_tags" "$AWS_ASG_TAG_KEY")
  if [[ -z "$asg_name" ]]; then
    log_warn "This EC2 Instance does not appear to be part of an Auto Scaling Group, so cannot determine cluster size. Setting cluster size to 1."
    echo 1
  else
    get_asg_size "$asg_name" "$aws_region"
  fi
}

# Get the value for a specific tag from the tags JSON returned by the AWS describe-tags:
# https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-tags.html
function get_tag_value {
  local -r tags="$1"
  local -r tag_key="$2"

  echo "$tags" | jq -r ".Tags[] | select(.Key == \"$tag_key\") | .Value"
}

function assert_is_installed {
  local -r name="$1"

  if [[ ! $(command -v ${name}) ]]; then
    log_error "The binary '$name' is required by this script but is not installed or in the system's PATH."
    exit 1
  fi
}

# Based on https://stackoverflow.com/a/17841619
function join_by {
  local IFS="$1"
  shift
  echo "$*"
}

function generate_consul_config {
  local -r server="${1}"
  local -r config_dir="${2}"
  local -r user="${3}"
  local -r cluster_tag_key="${4}"
  local -r cluster_tag_value="${5}"
  local -r datacenter="${6}"
  local -r enable_gossip_encryption="${7}"
  local -r gossip_encryption_key="${8}"
  local -r enable_rpc_encryption="${9}"
  local -r ca_path="${10}"
  local -r cert_file_path="${11}"
  local -r key_file_path="${12}"
  local -r cleanup_dead_servers="${13}"
  local -r last_contact_threshold="${14}"
  local -r max_trailing_logs="${15}"
  local -r server_stabilization_time="${16}"
  local -r redundancy_zone_tag="${17}"
  local -r disable_upgrade_migration="${18}"
  local -r upgrade_version_tag=${19}
  local -r config_path="$config_dir/$CONSUL_CONFIG_FILE"

  local instance_id=""
  local instance_ip_address=""
  local instance_region=""
  local ui="false"

  instance_id=$(get_instance_id)
  instance_ip_address=$(get_instance_ip_address)
  instance_region=$(get_instance_region)

  local retry_join_json=""
  if [[ -z "$cluster_tag_key" || -z "$cluster_tag_value" ]]; then
    log_warn "Either the cluster tag key ($cluster_tag_key) or value ($cluster_tag_value) is empty. Will not automatically try to form a cluster based on EC2 tags."
  else
    retry_join_json=$(cat <<EOF
"retry_join": ["provider=aws region=$instance_region tag_key=$cluster_tag_key tag_value=$cluster_tag_value"],
EOF
)
  fi

  local bootstrap_expect=""
  if [[ "$server" == "true" ]]; then
    local instance_tags=""
    local cluster_size=""

    instance_tags=$(get_instance_tags "$instance_id" "$instance_region")
    cluster_size=$(get_cluster_size "$instance_tags" "$instance_region")

    bootstrap_expect="\"bootstrap_expect\": $cluster_size,"
    ui="true"
  fi

  local autopilot_configuration=$(cat <<EOF
"autopilot": {
  "cleanup_dead_servers": $cleanup_dead_servers,
  "last_contact_threshold": "$last_contact_threshold",
  "max_trailing_logs": $max_trailing_logs,
  "server_stabilization_time": "$server_stabilization_time",
  "redundancy_zone_tag": "$redundancy_zone_tag",
  "disable_upgrade_migration": $disable_upgrade_migration,
  "upgrade_version_tag": "$upgrade_version_tag"
},
EOF
)

  local gossip_encryption_configuration=""
  if [[ "$enable_gossip_encryption" == "true" && ! -z "$gossip_encryption_key" ]]; then
    log_info "Creating gossip encryption configuration"
    gossip_encryption_configuration="\"encrypt\": \"$gossip_encryption_key\","
  fi

  local rpc_encryption_configuration=""
  if [[ "$enable_rpc_encryption" == "true" && ! -z "$ca_path" && ! -z "$cert_file_path" && ! -z "$key_file_path" ]]; then
    log_info "Creating RPC encryption configuration"
    rpc_encryption_configuration=$(cat <<EOF
"verify_outgoing": true,
"verify_incoming": true,
"ca_path": "$ca_path",
"cert_file": "$cert_file_path",
"key_file": "$key_file_path",
EOF
)
  fi

  log_info "Creating default Consul configuration"
  local default_config_json=$(cat <<EOF
{
  "advertise_addr": "$instance_ip_address",
  "bind_addr": "$instance_ip_address",
  $bootstrap_expect
  "client_addr": "0.0.0.0",
  "datacenter": "$datacenter",
  "node_name": "$instance_id",
  $retry_join_json
  "server": $server,
  $gossip_encryption_configuration
  $rpc_encryption_configuration
  $autopilot_configuration
  "ui": $ui
}
EOF
)
  log_info "Installing Consul config file in $config_path"
  echo "$default_config_json" | jq '.' > "$config_path"
  chown "$user:$user" "$config_path"
}

function generate_supervisor_config {
  local -r supervisor_config_path="$1"
  local -r consul_config_dir="$2"
  local -r consul_data_dir="$3"
  local -r consul_log_dir="$4"
  local -r consul_bin_dir="$5"
  local -r consul_user="$6"
  shift 6
  local -r environment=("$@")

  log_info "Creating Supervisor config file to run Consul in $supervisor_config_path"
  cat > "$supervisor_config_path" <<EOF
[program:consul]
command=$consul_bin_dir/consul agent -config-dir $consul_config_dir -data-dir $consul_data_dir
stdout_logfile=$consul_log_dir/consul-stdout.log
stderr_logfile=$consul_log_dir/consul-error.log
numprocs=1
autostart=true
autorestart=true
stopsignal=INT
user=$consul_user
environment=$(join_by "," "${environment[@]}")
EOF
}

function start_consul {
  log_info "Reloading Supervisor config and starting Consul"

  supervisorctl reread
  supervisorctl update
}

# Based on: http://unix.stackexchange.com/a/7732/215969
function get_owner_of_path {
  local -r path="$1"
  ls -ld "$path" | awk '{print $3}'
}

function run {
  local server="false"
  local client="false"
  local config_dir=""
  local data_dir=""
  local log_dir=""
  local bin_dir=""
  local user=""
  local cluster_tag_key=""
  local cluster_tag_value=""
  local datacenter=""
  local upgrade_version_tag=""
  local enable_gossip_encryption="false"
  local gossip_encryption_key=""
  local enable_rpc_encryption="false"
  local ca_path=""
  local cert_file_path=""
  local key_file_path=""
  local environment=()
  local skip_consul_config="false"
  local all_args=()
  local cleanup_dead_servers="$DEFAULT_AUTOPILOT_CLEANUP_DEAD_SERVERS"
  local last_contact_threshold="$DEFAULT_AUTOPILOT_LAST_CONTACT_THRESHOLD"
  local max_trailing_logs="$DEFAULT_AUTOPILOT_MAX_TRAILING_LOGS"
  local server_stabilization_time="$DEFAULT_AUTOPILOT_SERVER_STABILIZATION_TIME"
  local redundancy_zone_tag="$DEFAULT_AUTOPILOT_REDUNDANCY_ZONE_TAG"
  local disable_upgrade_migration="$DEFAULT_AUTOPILOT_DISABLE_UPGRADE_MIGRATION"

  while [[ $# > 0 ]]; do
    local key="$1"

    case "$key" in
      --server)
        server="true"
        ;;
      --client)
        client="true"
        ;;
      --config-dir)
        assert_not_empty "$key" "$2"
        config_dir="$2"
        shift
        ;;
      --data-dir)
        assert_not_empty "$key" "$2"
        data_dir="$2"
        shift
        ;;
      --log-dir)
        assert_not_empty "$key" "$2"
        log_dir="$2"
        shift
        ;;
      --bin-dir)
        assert_not_empty "$key" "$2"
        bin_dir="$2"
        shift
        ;;
      --user)
        assert_not_empty "$key" "$2"
        user="$2"
        shift
        ;;
      --cluster-tag-key)
        assert_not_empty "$key" "$2"
        cluster_tag_key="$2"
        shift
        ;;
      --cluster-tag-value)
        assert_not_empty "$key" "$2"
        cluster_tag_value="$2"
        shift
        ;;
      --datacenter)
        assert_not_empty "$key" "$2"
        datacenter="$2"
        shift
        ;;
      --autopilot-cleanup-dead-servers)
        assert_not_empty "$key" "$2"
        cleanup_dead_servers="$2"
        shift
        ;;
      --autopilot-last-contact-threshold)
        assert_not_empty "$key" "$2"
        last_contact_threshold="$2"
        shift
        ;;
      --autopilot-max-trailing-logs)
        assert_not_empty "$key" "$2"
        max_trailing_logs="$2"
        shift
        ;;
      --autopilot-server-stabilization-time)
        assert_not_empty "$key" "$2"
        server_stabilization_time="$2"
        shift
        ;;
      --autopilot-redundancy-zone-tag)
        assert_not_empty "$key" "$2"
        redundancy_zone_tag="$2"
        shift
        ;;
      --autopilot-disable-upgrade-migration)
        disable_upgrade_migration="true"
        shift
        ;;
      --autopilot-upgrade-version-tag)
        assert_not_empty "$key" "$2"
        upgrade_version_tag="$2"
        shift
        ;;
      --enable-gossip-encryption)
        enable_gossip_encryption="true"
        ;;
      --gossip-encryption-key)
        assert_not_empty "$key" "$2"
        gossip_encryption_key="$2"
        shift
        ;;
      --enable-rpc-encryption)
        enable_rpc_encryption="true"
        ;;
      --ca-path)
        assert_not_empty "$key" "$2"
        ca_path="$2"
        shift
        ;;
      --cert-file-path)
        assert_not_empty "$key" "$2"
        cert_file_path="$2"
        shift
        ;;
      --key-file-path)
        assert_not_empty "$key" "$2"
        key_file_path="$2"
        shift
        ;;
      --environment)
        assert_not_empty "$key" "$2"
        environment+=("$2")
        shift
        ;;
      --skip-consul-config)
        skip_consul_config="true"
        ;;
      --help)
        print_usage
        exit
        ;;
      *)
        log_error "Unrecognized argument: $key"
        print_usage
        exit 1
        ;;
    esac

    shift
  done

  if [[ ("$server" == "true" && "$client" == "true") || ("$server" == "false" && "$client" == "false") ]]; then
    log_error "Exactly one of --server or --client must be set."
    exit 1
  fi

  assert_is_installed "supervisorctl"
  assert_is_installed "aws"
  assert_is_installed "curl"
  assert_is_installed "jq"

  if [[ -z "$config_dir" ]]; then
    config_dir=$(cd "$SCRIPT_DIR/../config" && pwd)
  fi

  if [[ -z "$data_dir" ]]; then
    data_dir=$(cd "$SCRIPT_DIR/../data" && pwd)
  fi

  if [[ -z "$log_dir" ]]; then
    log_dir=$(cd "$SCRIPT_DIR/../log" && pwd)
  fi

  if [[ -z "$bin_dir" ]]; then
    bin_dir=$(cd "$SCRIPT_DIR/../bin" && pwd)
  fi

  if [[ -z "$user" ]]; then
    user=$(get_owner_of_path "$config_dir")
  fi

  if [[ -z "$datacenter" ]]; then
    datacenter=$(get_instance_region)
  fi

  if [[ "$skip_consul_config" == "true" ]]; then
    log_info "The --skip-consul-config flag is set, so will not generate a default Consul config file."
  else
    if [[ "$enable_gossip_encryption" == "true" ]]; then
      assert_not_empty "--gossip-encryption-key" "$gossip_encryption_key"
    fi
    if [[ "$enable_rpc_encryption" == "true" ]]; then
      assert_not_empty "--ca-path" "$ca_path"
      assert_not_empty "--cert-file-path" "$cert_file_path"
      assert_not_empty "--key_file_path" "$key_file_path"
    fi

    generate_consul_config "$server" \
      "$config_dir" \
      "$user" \
      "$cluster_tag_key" \
      "$cluster_tag_value" \
      "$datacenter" \
      "$enable_gossip_encryption" \
      "$gossip_encryption_key" \
      "$enable_rpc_encryption" \
      "$ca_path" \
      "$cert_file_path" \
      "$key_file_path" \
      "$cleanup_dead_servers" \
      "$last_contact_threshold" \
      "$max_trailing_logs" \
      "$server_stabilization_time" \
      "$redundancy_zone_tag" \
      "$disable_upgrade_migration" \
      "$upgrade_version_tag"
  fi

  generate_supervisor_config "$SUPERVISOR_CONFIG_PATH" "$config_dir" "$data_dir" "$log_dir" "$bin_dir" "$user" "${environment[@]}"
  start_consul
}

run "$@"
