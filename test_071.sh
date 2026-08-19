#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Standalone recreation of blktests nvme/070:
#   "test nvme-fc marginal path handling with fcloop"
#
# This script sets up an NVMe-oF FC loopback target with 2 host ports
# and 4 target ports (2 per host port), connects the host, runs fio I/O,
# exercises marginal path failover/failback across three iopolicies
# (numa, queue-depth, round-robin), then tears everything down.
#
# Requires: root, nvme-cli, fio, loop device support, kernel modules
#   nvmet, nvme-fc, nvme-fcloop (with set_marginal_rport support)
#
# Usage:
#   sudo ./test_057.sh
#
# ---------------------------------------------------------------------------
# How this test uses drivers/nvme/target:
#
# 1. Module loading:
#    - nvmet        (NVMe target core, provides configfs at /sys/kernel/config/nvmet)
#    - nvme-fc      (NVMe-oF FC host transport)
#    - nvme-fcloop  (virtual FC loopback LLDD, bridges host and target in-memory)
#
# 2. fcloop port creation (via sysfs /sys/class/fcloop/ctl/):
#    - Two local ports are created (add_local_port) representing virtual FC HBAs
#    - Four target ports are created (add_target_port), one per NVMe port
#    - Four remote ports are created (add_remote_port), each linked to its
#      local port and cross-linked to the corresponding target port
#    - Ports 0-1 are paired with host port 0 (local port 0)
#    - Ports 2-3 are paired with host port 1 (local port 1)
#
# 3. NVMe target configfs setup (/sys/kernel/config/nvmet/):
#    - A subsystem is created with a namespace backed by a loop block device
#    - Four ports (port 0-3) are created, each configured with trtype=fc and
#      traddr pointing to the corresponding fcloop target/remote port pair
#    - The subsystem is linked to all four ports
#    - A host entry is created and allowed access to the subsystem
#    - ANA group 1 is configured on each port:
#      ports on host_port 0 (ports 0-1) = optimized
#      ports on host_port 1 (ports 2-3) = non-optimized
#
# 4. Host-side connection:
#    - nvme connect is called four times (once per port), creating four
#      NVMe-oF FC controllers.  The NVMe multipath layer aggregates them.
#
# 5. Marginal path testing:
#    - fio runs random verified writes against the multipath NVMe namespace
#    - For each iopolicy (numa, queue-depth, round-robin), the test exercises
#      marginal path transitions:
#      * Set all ports online (verify state and usage)
#      * Set one host's ports marginal (verify failover)
#      * Set all ports marginal (verify at least one still in use)
#      * Recover non-optimized ports first, then optimized
#      * Set all online, then all marginal again
#      * Recover optimized ports first, then non-optimized
#    - The host-side marginal notifications (via fcloop set_marginal_rport)
#      cause the multipath layer to re-route I/O
#    - fio continues running throughout; test passes if no I/O errors occur
#
# 6. Teardown:
#    - nvme disconnect removes all controllers
#    - configfs entries are removed (subsystem, namespaces, ports, hosts)
#    - fcloop remote/target/local ports are deleted via sysfs
#    - The loop block device and backing file are cleaned up
# ---------------------------------------------------------------------------

INTERACTIVE=""
VERBOSE=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		-i) INTERACTIVE="-i"; shift ;;
		-v) VERBOSE="-v"; shift ;;
		*)  echo "  Invalid argument \"$1\""; exit 2 ;;
	esac
done

set -euo pipefail

verbose_print() {
	if [[ -n "${VERBOSE}" ]]; then
		echo "$@" >&2
	fi
}

TIMEOUT=10

# ── Tunables ────────────────────────────────────────────────────────────────

IMG_SIZE="1G"
FIO_RUNTIME="7m"
FIO_RAMP="10"
NUM_PORTS=4
NUM_HOST_PORTS=2

# ── Identity constants (matching blktests defaults) ─────────────────────────

SESSION_NAME="test_071_mon"
SUBSYSNQN="blktests-subsystem-1"
SUBSYS_UUID="91fdba0d-f87b-4c25-b80f-db7be1418b9e"
HOSTID="0f01fb42-9f7f-4856-b0b3-51e60b8de349"
HOSTNQN="nqn.2014-08.org.nvmexpress:uuid:${HOSTID}"

LOCAL_WWNN_BASE=0x10001100aa000001
LOCAL_WWPN_BASE=0x20001100aa000001
REMOTE_WWNN_BASE=0x10001100ab000001
REMOTE_WWPN_BASE=0x20001100ab000001

NVMET_CFS="/sys/kernel/config/nvmet"
LOOPCTL="/sys/devices/virtual/fcloop/ctl"

TMPDIR=""
LOOP_DEV=""

declare -A PORT_TO_HOST

# ── Helper functions ───────────────────────────────────────────────────────

next_step() {
	if [[ ! -z "$INTERACTIVE" ]]; then
        echo ""
        echo -n "Type e to exit, any key to continue: "
        read line
        case "$line" in
                e|E) echo "exit"
                        exit 1
                ;;
                *) echo ""
						return 0
				;;
        esac
	fi
}

list_subsys_interactive () {
	if [[ ! -z "$INTERACTIVE" ]]; then
		nvme list-subsys /dev/${NS}
	fi
}

die() {
	echo "FAIL: $*" >&2
	exit 1
}

remote_wwnn() {
	printf "0x%08x" $(( REMOTE_WWNN_BASE + $1 ))
}

remote_wwpn() {
	printf "0x%08x" $(( REMOTE_WWPN_BASE + $1 ))
}

host_wwnn() {
	printf "0x%08x" $(( LOCAL_WWNN_BASE + $1 ))
}

host_wwpn() {
	printf "0x%08x" $(( LOCAL_WWPN_BASE + $1 ))
}

fc_traddr() {
	printf "nn-%s:pn-%s" "$(remote_wwnn "$1")" "$(remote_wwpn "$1")"
}

fc_host_traddr() {
	local host_port=${1:-0}

	printf "nn-%s:pn-%s" "$(host_wwnn "$host_port")" "$(host_wwpn "$host_port")"
}

get_fc_host_port() {
	local port=$1

	echo "${PORT_TO_HOST[${port}]}"
}

# ── fcloop port management ─────────────────────────────────────────────────

fcloop_add_lport() {
	echo "wwnn=$1,wwpn=$2" > "${LOOPCTL}/add_local_port"
}

fcloop_del_lport() {
	[[ -f "${LOOPCTL}/del_local_port" ]] || return 0
	echo "wwnn=$1,wwpn=$2" > "${LOOPCTL}/del_local_port"
}

fcloop_add_tport() {
	echo "wwnn=$1,wwpn=$2" > "${LOOPCTL}/add_target_port"
}

fcloop_del_tport() {
	[[ -f "${LOOPCTL}/del_target_port" ]] || return 0
	echo "wwnn=$1,wwpn=$2" > "${LOOPCTL}/del_target_port"
}

fcloop_add_rport() {
	# $1=local_wwnn $2=local_wwpn $3=remote_wwnn $4=remote_wwpn
	echo "wwnn=$3,wwpn=$4,lpwwnn=$1,lpwwpn=$2,roles=0x60" \
		> "${LOOPCTL}/add_remote_port"
}

fcloop_del_rport() {
	[[ -f "${LOOPCTL}/del_remote_port" ]] || return 0
	echo "wwnn=$3,wwpn=$4" > "${LOOPCTL}/del_remote_port"
}

fcloop_set_rport_marginal() {
	# $1=wwnn $2=wwpn $3=marginal (0 or 1)
	echo "wwnn=$1,wwpn=$2,marginal=$3" \
		> /sys/class/fcloop/ctl/set_marginal_rport
}

# ── NVMe target configfs helpers ───────────────────────────────────────────

create_subsystem() {
	local cfs="${NVMET_CFS}/subsystems/${SUBSYSNQN}"

	mkdir -p "${cfs}"
	echo 0 > "${cfs}/attr_allow_any_host"
}

create_namespace() {
	local blkdev="$1"
	local cfs="${NVMET_CFS}/subsystems/${SUBSYSNQN}"
	local ns_path="${cfs}/namespaces/1"

	mkdir -p "${ns_path}"
	echo "${blkdev}" > "${ns_path}/device_path"
	echo "${SUBSYS_UUID}" > "${ns_path}/device_uuid"
	echo 1 > "${ns_path}/enable"
}

create_port() {
	local portnum="$1"
	local host_port="${2:-0}"
	local portcfs="${NVMET_CFS}/ports/${portnum}"

	# Create fcloop target and remote ports for this port number
	fcloop_add_tport "$(remote_wwnn "$portnum")" "$(remote_wwpn "$portnum")"
	fcloop_add_rport "$(host_wwnn "$host_port")" "$(host_wwpn "$host_port")" \
		"$(remote_wwnn "$portnum")" "$(remote_wwpn "$portnum")"

	# Create the NVMe target port in configfs
	mkdir -p "${portcfs}"
	echo "fc"                        > "${portcfs}/addr_trtype"
	echo "$(fc_traddr "$portnum")"   > "${portcfs}/addr_traddr"
	echo "fc"                        > "${portcfs}/addr_adrfam"

	# Track port-to-host mapping
	PORT_TO_HOST["${portnum}"]="${host_port}"
}

link_subsystem_to_port() {
	local portnum="$1"
	ln -sf "${NVMET_CFS}/subsystems/${SUBSYSNQN}" \
		"${NVMET_CFS}/ports/${portnum}/subsystems/${SUBSYSNQN}"
}

create_host() {
	local host_path="${NVMET_CFS}/hosts/${HOSTNQN}"

	mkdir -p "${host_path}"
	ln -sf "${host_path}" \
		"${NVMET_CFS}/subsystems/${SUBSYSNQN}/allowed_hosts/${HOSTNQN}"
}

setup_port_ana() {
	local portnum="$1"
	local anagrpid="$2"
	local anastate="$3"
	local anapath="${NVMET_CFS}/ports/${portnum}/ana_groups/${anagrpid}"

	if [[ ! -d "${anapath}" ]]; then
		if (( anagrpid == 1 )); then
			die "ANA not supported (ana_groups/1 missing)"
		fi
		mkdir -p "${anapath}"
	fi
	echo "${anastate}" > "${anapath}/ana_state"
}

# ── ANA state transition functions ─────────────────────────────────────────

# Initial / failback state:
#   port 0 = optimized, port 1 = non-optimized, ports 2+ = inaccessible
ana_failback() {
	local portno=0
	local p
	for p in "$@"; do
		if (( portno == 0 )); then
			setup_port_ana "$p" 1 "optimized"
		elif (( portno == 1 )); then
			setup_port_ana "$p" 1 "non-optimized"
		else
			setup_port_ana "$p" 1 "inaccessible"
		fi
		portno=$(( portno + 1 ))
	done
}

# Failover state:
#   port 2 = optimized, port 3 = non-optimized, ports 0-1 = inaccessible
ana_failover() {
	local portno=0
	local p
	for p in "$@"; do
		if (( portno == 2 )); then
			setup_port_ana "$p" 1 "optimized"
		elif (( portno == 3 )); then
			setup_port_ana "$p" 1 "non-optimized"
		else
			setup_port_ana "$p" 1 "inaccessible"
		fi
		portno=$(( portno + 1 ))
	done
}

setup_nvmet_port_marginal() {
	local port="$1"
	local state="$2"

	if [[ "${state}" == "live" ]]; then
		fcloop_set_rport_marginal "$(remote_wwnn "$port")" \
			"$(remote_wwpn "$port")" 0
	elif [[ "${state}" == "marginal" ]]; then
		fcloop_set_rport_marginal "$(remote_wwnn "$port")" \
			"$(remote_wwpn "$port")" 1
	else
		die "setup_nvmet_port_marginal: invalid state: ${state}"
	fi
}

# ── Connect / disconnect ───────────────────────────────────────────────────

nvme_connect_port() {
	local portnum="$1"
	local host_port="${PORT_TO_HOST[${portnum}]}"

	nvme connect \
		--transport fc \
		--traddr "$(fc_traddr "$portnum")" \
		--host-traddr "$(fc_host_traddr "$host_port")" \
		--nqn "${SUBSYSNQN}" \
		--hostnqn="${HOSTNQN}" \
		--hostid="${HOSTID}" \
		2>/dev/null
}

nvme_disconnect() {
	nvme disconnect --nqn "${SUBSYSNQN}" 2>/dev/null | grep -o "disconnected.*" || true
}

# ── Find the multipath namespace by UUID ───────────────────────────────────

find_nvme_ns() {
	local uuid ns
	for ns in /sys/block/nvme*; do
		[[ "${ns}" =~ nvme[0-9]+n[0-9]+$ ]] || continue
		[[ -e "${ns}/uuid" ]] || continue
		uuid=$(cat "${ns}/uuid")
		if [[ "${uuid}" == "${SUBSYS_UUID}" ]]; then
			basename "${ns}"
			return 0
		fi
	done
	return 1
}

wait_for_ns() {
	local ns="" i
	for (( i = 0; i < 50; i++ )); do
		ns=$(find_nvme_ns 2>/dev/null) && break
		sleep 0.2
	done
	if [[ -z "${ns}" ]]; then
		die "namespace with uuid ${SUBSYS_UUID} did not appear"
	fi
	echo "${ns}"
}

make_tmux_session() {
	cat << EOF >> test_071_tmux.sh
#!/bin/bash
tmux new-session -d -s "$SESSION_NAME" "watch -t -d 'nvme list-subsys /dev/${NS}'"
tmux split-window -v -t "$SESSION_NAME" "iostat -x ID $(cat /proc/diskstats | grep "${CTRL}" | awk '{print $3}'  | sed -z 's/\n/ /g') 4"
tmux split-window -v -t "$SESSION_NAME" "watch -t -d 'grep . /sys/class/nvme-subsystem/nvme-subsys${SUBSYS_N}/nvme*/${CTRL}*/inflight'"
tmux split-window -v -t "$SESSION_NAME" "watch -t -d 'grep . /sys/class/nvme-subsystem/nvme-subsys${SUBSYS_N}/nvme*/state'"
sleep 1
echo ""
echo "Using \"tmux attach\" to connect to tmux session"
echo ""
sleep 1
tmux attach
EOF
	chmod 777 test_071_tmux.sh
	echo ""
	echo "Use \"sudo ./test_071_tmux.sh\" to start tmux in separate window"
	echo ""
}

create_tmux_session() {
	rm -f test_071_tmux.sh
	if [[ ! -z "$INTERACTIVE" ]]; then
		make_tmux_session
	fi
}

# ── Marginal path helpers (from nvme/070) ──────────────────────────────────

_subsys_rport_addr() {
	local RPORT=$1

	cat "$RPORT"/address
}

_subsys_get_port() {
	local RPORT=$1
	local port
	local address
	verbose_print "_subsys_get_port ${RPORT}"
	address=$(_subsys_rport_addr "$RPORT")
	port=$(echo "$address" | sed -n 's/.*pn-\(.*\),.*/\1/p')
	echo $(( port - $(remote_wwpn 0) ))
}

_rport_set_iopolicy() {
	local RPORT=$1
	local POLICY=$2

	verbose_print "_rport_set_iopolicy $RPORT to $POLICY"
	echo "$POLICY" | sudo tee "$RPORT"/iopolicy > /dev/null
}

_rport_set_marginal() {
	local RPORT=$1
	verbose_print "_rport_set_marginal ${RPORT}"
	setup_nvmet_port_marginal "$(_subsys_get_port "$RPORT")" "marginal"
}

_rport_set_online() {
	local RPORT=$1
	verbose_print "_rport_set_online ${RPORT}"
	setup_nvmet_port_marginal "$(_subsys_get_port "$RPORT")" "live"
}

_rport_is_online_raw() {
	local RPORT=$1
	verbose_print "_rport_is_online_raw ${RPORT}"
	verbose_print "$(grep . ${RPORT}/state)"
	[[ "$(cat "$RPORT"/state)" == "live" ]]
}

_rport_is_marginal_raw() {
	local RPORT=$1
	verbose_print "_rport_is_marginal_raw ${RPORT}"
	verbose_print "$(grep . ${RPORT}/state)"
	[[ "$(cat "$RPORT"/state)" == "marginal" ]]
}

_rport_in_use_raw() {
	local SUBSYS_PATH=$1
	sleep 2
	verbose_print "_rport_in_use_raw ${SUBSYS_PATH}"
	[[ "$(cat "$SUBSYS_PATH"/nvme*/stat | awk '{print $9}')" != "0" ]]
}

_rport_is_optimized() {
	local SUBSYS_PATH=$1
	verbose_print "_rport_is_optimized ${SUBSYS_PATH}"
	verbose_print "$(grep . ${SUBSYS_PATH}/nvme*/ana_state)"
	[[ "$(cat "$SUBSYS_PATH"/nvme*/ana_state)" == "optimized" ]]
}

_rport_is_online() {
	local RPORT=$1
	local -i time_passed=0
	for (( time_passed=0; time_passed < TIMEOUT; time_passed++ )); do
		_rport_is_online_raw "$RPORT" && return 0 || true
		sleep 1
	done
	return 1
}

_rport_is_marginal() {
	local RPORT=$1
	local -i time_passed=0
	for (( time_passed=0; time_passed < TIMEOUT; time_passed++ )); do
		_rport_is_marginal_raw "$RPORT" && return 0 || true
		sleep 1
	done
	return 1
}

_rport_in_use() {
	local RPORT=$1
	local -i time_passed=0
	for (( time_passed=0; time_passed < TIMEOUT; time_passed++ )); do
		_rport_in_use_raw "$RPORT" && return 0 || true
		sleep 1
	done
	return 1
}

_rport_not_in_use() {
	local RPORT=$1
	local -i time_passed=0
	for (( time_passed=0; time_passed < TIMEOUT; time_passed++ )); do
		_rport_in_use_raw "$RPORT" || return 0
		sleep 1
	done
	return 1
}

_rport_check_online() {
	local RPORT=$1
	local STATE=$2

	if [[ "$STATE" == "Online" ]]; then
		if ! _rport_is_online "$RPORT"; then
			echo  FC port \("$RPORT"\) is not online, expteced online.
			next_step
			return 1
		fi
	else
		if ! _rport_is_marginal "$RPORT"; then
			echo FC port \("$RPORT"\) is not marginal, expteced marginal.
			next_step
			return 1
		fi
	fi
}

_rport_check_use() {
	local RPORT=$1
	local STATE=$2

	if [[ "$STATE" == "Online" ]]; then
		if ! _rport_in_use "$RPORT" ; then
			echo FC port on \("$RPORT"\) is not being used, expected use.
			next_step
			return 1
		fi
	else
		if ! _rport_not_in_use "$RPORT" ; then
			echo FC port on \("$RPORT"\) is being used, expected no use.
			next_step
			return 1
		fi
	fi
}

_rport_check_use_opt() {
	local RPORT=$1

	if _rport_is_optimized "$RPORT"; then
		_rport_check_use "$RPORT" "Online" || return 1
	else
		_rport_check_use "$RPORT" "Marginal" || return 1
	fi
}

_rport_check() {
	local RPORT=$1
	local STATE=$2

	_rport_check_online "$RPORT" "$STATE" || return 1
	_rport_check_use "$RPORT" "$STATE"
}

_rport_num_in_use() {
	local -a RPORTS_PATHS=("$@")
	local -i num_in_use=0

	for subsys_path in "${RPORTS_PATHS[@]}"; do
		_rport_in_use_raw "$subsys_path" || continue
		num_in_use=$((num_in_use + 1))
	done

	echo "$num_in_use"
}

_rport_check_one_use() {
	local STATE=$1
	shift
	local -a RPORTS_PATHS=("$@")
	local -i time_passed=0
	local -i count_in_use=0

	for (( time_passed=0; time_passed < TIMEOUT; time_passed++ )); do
		count_in_use=$(_rport_num_in_use "${RPORTS_PATHS[@]}")
		if [ $count_in_use -eq 1 ]; then
			return 0
		fi
		sleep 1
	done

	if [ $count_in_use -gt 1 ]; then
		echo More than one FC port is being used, expected only one in use when all are "$STATE" in numa mode.
		next_step
		return 1
	fi

	echo No FC ports are being used, expected atleast one in use when all are "$STATE" in numa mode.
	next_step
	return 1
}

test_set_all_online() {
	local IOPOLICY=$1
	shift
	local -a RPORTS_PATHS=("$@")

	for subsys_path in "${RPORTS_PATHS[@]}"; do
		_rport_set_online "$subsys_path" || return 1
		_rport_check_online "$subsys_path" Online || return 1
	done

	if [ "$IOPOLICY" == "numa" ]; then
		_rport_check_one_use "online" "${RPORTS_PATHS[@]}" || return 1
	else
		for subsys_path in "${RPORTS_PATHS[@]}"; do
			_rport_check_use_opt "$subsys_path" || return 1
		done
	fi
}

test_set_one_host_marginal() {
	local HOST=$1
	shift
	local -a ARGS=("$@")
	local RPORTS_CNT="$(( $# / 2 ))"
	local PATHS_POS
	local HOSTS_POS

	for (( PATHS_POS=0; PATHS_POS < RPORTS_CNT; PATHS_POS++ )); do
		HOSTS_POS="$(( RPORTS_CNT + PATHS_POS ))"
		if [[ "${ARGS[$HOSTS_POS]}" == "$HOST" ]]; then
			_rport_set_marginal "${ARGS[$PATHS_POS]}" || return 1
		fi
	done

	for (( PATHS_POS=0; PATHS_POS < RPORTS_CNT; PATHS_POS++ )); do
		HOSTS_POS="$(( RPORTS_CNT + PATHS_POS ))"
		if [[ "${ARGS[$HOSTS_POS]}" == "$HOST" ]]; then
			_rport_check "${ARGS[$PATHS_POS]}" "Marginal" || return 1
		else
			_rport_check_online "${ARGS[$PATHS_POS]}" "Online" || return 1
			_rport_check_use_opt "${ARGS[$PATHS_POS]}" || return 1
		fi
	done
}

test_set_all_marginal() {
	local -a RPORTS_PATHS=("$@")

	for subsys_path in "${RPORTS_PATHS[@]}"; do
		_rport_set_marginal "$subsys_path" || return 1
		_rport_check_online "$subsys_path" Marginal || return 1
	done

	if [ "$IOPOLICY" == "numa" ]; then
		_rport_check_one_use "marginal" "${RPORTS_PATHS[@]}" || return 1
	else
		for subsys_path in "${RPORTS_PATHS[@]}"; do
			_rport_check_use_opt "$subsys_path" Marginal || return 1
		done
	fi
}

test_set_one_non_optimized_online() {
	local -a RPORTS_PATHS=("$@")

	local next_marginal=0
	for subsys_path in "${RPORTS_PATHS[@]}"; do
		if ! _rport_is_optimized "$subsys_path"; then
			if [ $next_marginal == 1 ]; then
				_rport_check "$subsys_path" Marginal || return 1
				break
			fi
			_rport_set_online "$subsys_path" || return 1
			_rport_check "$subsys_path" Online || return 1
			next_marginal=1
		fi
	done
	for subsys_path in "${RPORTS_PATHS[@]}"; do
		if _rport_is_optimized "$subsys_path"; then
			_rport_check "$subsys_path" Marginal || return 1
		fi
	done
}

test_set_all_non_optimized_online() {
	local IOPOLICY=$1
	shift
	local -a RPORTS_PATHS=("$@")

	local numa_in_use=0
	for subsys_path in "${RPORTS_PATHS[@]}"; do
		if _rport_is_optimized "$subsys_path"; then
			_rport_check "$subsys_path" Marginal || return 1
		else
			_rport_set_online "$subsys_path" || return 1
			if [ "$IOPOLICY" == "numa" ] && [ $numa_in_use == 0 ]; then
				_rport_check "$subsys_path" Online || return 1
				numa_in_use=1
			elif [ "$IOPOLICY" == "numa" ] && [ $numa_in_use == 1 ]; then
				_rport_check_online "$subsys_path" Online || return 1
				_rport_check_use "$subsys_path" Marginal || return 1
			else
				_rport_check "$subsys_path" Online || return 1
			fi
		fi
	done

}

set_one_optimized_online() {
	local -a RPORTS_PATHS=("$@")

	local next_marginal=0
	for subsys_path in "${RPORTS_PATHS[@]}"; do
		if _rport_is_optimized "$subsys_path"; then
			if [ $next_marginal == 1 ]; then
				_rport_check "$subsys_path" Marginal || return 1
				break
			fi
			_rport_set_online "$subsys_path" || return 1
			_rport_check "$subsys_path" Online || return 1
			next_marginal=1
		fi
	done
}

test_set_all_non_one_optimized_online() {
	local -a RPORTS_PATHS=("$@")

	set_one_optimized_online "${RPORTS_PATHS[@]}" || return 1

	for subsys_path in "${RPORTS_PATHS[@]}"; do
		if ! _rport_is_optimized "$subsys_path"; then
			_rport_check_online "$subsys_path" Online || return 1
			_rport_check_use "$subsys_path" Marginal || return 1
		fi
	done

}

test_set_one_optimized_online() {
	local -a RPORTS_PATHS=("$@")

	set_one_optimized_online "${RPORTS_PATHS[@]}" || return 1

	for subsys_path in "${RPORTS_PATHS[@]}"; do
		if ! _rport_is_optimized "$subsys_path"; then
			_rport_check "$subsys_path" "Marginal" || return 1
		fi
	done

}

test_set_two_optimized_online() {
	local IOPOLICY=$1
	shift
	local -a RPORTS_PATHS=("$@")

	local numa_in_use=0
	for subsys_path in "${RPORTS_PATHS[@]}"; do
		if _rport_is_optimized "$subsys_path"; then
			_rport_set_online "$subsys_path" || return 1
			if [ "$IOPOLICY" == "numa" ] && [ $numa_in_use == 0 ]; then
				_rport_check "$subsys_path" Online || return 1
				numa_in_use=1
			elif [ "$IOPOLICY" == "numa" ] && [ $numa_in_use == 1 ]; then
				_rport_check_online "$subsys_path" Online || return 1
				_rport_check_use "$subsys_path" Marginal || return 1
			else
				_rport_check "$subsys_path" Online || return 1
			fi
		else
			_rport_check "$subsys_path" Marginal || return 1
		fi
	done

}

run_test() {
	local IOPOLICY=$1
	shift
	local -a ARGS=("$@")
	local RPORTS_CNT="$(( $# / 2 ))"
	local -a RPORTS_PATHS
	local -a RPORTS_HOSTS
	local PATHS_POS
	local HOSTS_POS

	for (( PATHS_POS=0; PATHS_POS < RPORTS_CNT; PATHS_POS++ )); do
		HOSTS_POS="$(( RPORTS_CNT + PATHS_POS ))"
		RPORTS_PATHS+=("${ARGS[$PATHS_POS]}")
		RPORTS_HOSTS+=("${ARGS[$HOSTS_POS]}")
	done


	echo Changing FC links to online
	test_set_all_online "$IOPOLICY" "${RPORTS_PATHS[@]}" \
		&& echo "Set all online: pass" || echo "Set all online: fail"

	test_set_one_host_marginal "${RPORTS_HOSTS[0]}" "${RPORTS_PATHS[@]}" \
		"${RPORTS_HOSTS[@]}" && echo "One host marginal: pass" \
		|| echo "One host marginal: fail"
	test_set_all_marginal "${RPORTS_PATHS[@]}" \
		&& echo "All marginal: pass" || echo "All marginal: fail"

	test_set_one_non_optimized_online "${RPORTS_PATHS[@]}" \
		&& echo "One remote non-optimized online: pass" \
		|| echo "One remote non-optimized online: fail"
	test_set_all_non_optimized_online "$IOPOLICY" "${RPORTS_PATHS[@]}" \
		&& echo "Two remote non-optimized online: pass" \
		|| echo "Two remote non-optimized online: fail"

	test_set_all_non_one_optimized_online "${RPORTS_PATHS[@]}" \
		&& echo "Two remote non-optimized, One remote optimized: pass" \
		|| echo "Two remote non-optimized, One remote optimized: fail"
	test_set_all_online "$IOPOLICY" "${RPORTS_PATHS[@]}" \
		&& echo "Set all online: pass" || echo "Set all online: fail"

	test_set_all_marginal "${RPORTS_PATHS[@]}" \
		&& echo "All marginal: pass" || echo "All marginal: fail"

	test_set_one_optimized_online "${RPORTS_PATHS[@]}" \
		&& echo "One remote optimized online: pass" \
		|| echo "One remote optimized online: fail"
	test_set_two_optimized_online "$IOPOLICY" "${RPORTS_PATHS[@]}" \
		&& echo "Two remote optimized online: pass" \
		|| echo "Two remote optimized online: fail"
	test_set_all_online "$IOPOLICY" "${RPORTS_PATHS[@]}" \
		&& echo "All online: pass" || echo "All online: fail"
}

_nvmet_get_rport() {
	local PORT="$1"

	local dev
	for dev in /sys/class/nvme/nvme*; do
		grep --quiet "io" "$dev/cntrltype" || continue
		[ -e "$dev" ] || continue
		dev="$(basename "$dev")"
		grep --quiet traddr="$(fc_traddr "$PORT")" "/sys/class/nvme/$dev/address" && echo "$dev" || true
	done
}

run_tests() {
	local SUBSYS_PATH="$1"
	shift
	local -a PORTS=("$@")
	local -a RPORTS_PATHS
	local -a RPORTS_HOSTS
	local rport

	for port in "${PORTS[@]}"; do
		RPORTS_HOSTS+=("$(get_fc_host_port "$port")")
		rport="$(_nvmet_get_rport "$port")"
		if [ -z "$rport" ]; then
			echo "Could not find rport for port $port"
			return 1
		fi
		if [[ "$( echo "$rport" | sed -n '$=' )" -gt 1 ]]; then
			echo "Port $port has multiple rports with address"
			grep traddr="$(fc_traddr "$port")" /sys/class/nvme/nvme*/address
			return 1
		fi
		RPORTS_PATHS+=( "${SUBSYS_PATH}/$rport")
	done

	local IOPOLICYS="numa queue-depth round-robin"
	for IOPOLICY in $IOPOLICYS; do
		_rport_set_iopolicy "$SUBSYS_PATH" "$IOPOLICY"
		echo "Testing iopolicy: $IOPOLICY"
		run_test "$IOPOLICY" "${RPORTS_PATHS[@]}" "${RPORTS_HOSTS[@]}"
	done
}

_find_nvme_subsys() {
	local subsys=$1
	local subsysnqn
	local subsys_path
	for subsys_path in /sys/class/nvme-subsystem/nvme-subsys*; do
		[ -e "$subsys_path" ] || continue
		subsysnqn="$(cat "${subsys_path}/subsysnqn" 2>/dev/null)"
		if [[ "$subsysnqn" == "$subsys" ]]; then
			echo "$subsys_path"
			return
		fi
	done
}

# ── Cleanup (called on exit) ───────────────────────────────────────────────

cleanup() {
	local p hp

	# Stop fio if still running
	if [[ -n "${FIO_PID:-}" ]] && kill -0 "${FIO_PID}" 2>/dev/null; then
		kill "${FIO_PID}" 2>/dev/null
		wait "${FIO_PID}" 2>/dev/null || true
	fi

	# Disconnect host
	nvme_disconnect 2>/dev/null || true

	# Remove configfs entries
	for (( p = NUM_PORTS - 1; p >= 0; p-- )); do
		rm -f "${NVMET_CFS}/ports/${p}/subsystems/${SUBSYSNQN}" 2>/dev/null || true
		# Remove non-default ANA groups
		for a in "${NVMET_CFS}/ports/${p}/ana_groups/"*; do
			[[ "${a##*/}" == "1" ]] && continue
			rmdir "${a}" 2>/dev/null || true
		done
		rmdir "${NVMET_CFS}/ports/${p}" 2>/dev/null || true
	done

	# Remove namespace and subsystem
	if [[ -d "${NVMET_CFS}/subsystems/${SUBSYSNQN}/namespaces/1" ]]; then
		echo 0 > "${NVMET_CFS}/subsystems/${SUBSYSNQN}/namespaces/1/enable" 2>/dev/null || true
		rmdir "${NVMET_CFS}/subsystems/${SUBSYSNQN}/namespaces/1" 2>/dev/null || true
	fi
	rm -f "${NVMET_CFS}/subsystems/${SUBSYSNQN}/allowed_hosts/${HOSTNQN}" 2>/dev/null || true
	rmdir "${NVMET_CFS}/subsystems/${SUBSYSNQN}" 2>/dev/null || true
	rmdir "${NVMET_CFS}/hosts/${HOSTNQN}" 2>/dev/null || true

	# Remove fcloop ports
	for (( p = NUM_PORTS - 1; p >= 0; p-- )); do
		hp="${PORT_TO_HOST[${p}]:-0}"
		fcloop_del_rport "$(host_wwnn "$hp")" "$(host_wwpn "$hp")" \
			"$(remote_wwnn "$p")" "$(remote_wwpn "$p")" 2>/dev/null || true
		fcloop_del_tport "$(remote_wwnn "$p")" "$(remote_wwpn "$p")" 2>/dev/null || true
	done
	for (( hp = NUM_HOST_PORTS - 1; hp >= 0; hp-- )); do
		fcloop_del_lport "$(host_wwnn "$hp")" "$(host_wwpn "$hp")" 2>/dev/null || true
	done

	# Tear down loop device and temp file
	if [[ -n "${LOOP_DEV}" ]]; then
		losetup -d "${LOOP_DEV}" 2>/dev/null || true
	fi
	if [[ -n "${TMPDIR}" ]]; then
		rm -rf "${TMPDIR}"
	fi

	# Unload modules (best-effort, reverse order)
	modprobe -rq nvme-fcloop 2>/dev/null || true
	modprobe -rq nvme-fc     2>/dev/null || true
	modprobe -rq nvmet       2>/dev/null || true
}

# ── Pre-flight checks ──────────────────────────────────────────────────────

preflight() {
	if (( EUID != 0 )); then
		die "must be run as root"
	fi

	for prog in nvme fio losetup udevadm; do
		command -v "$prog" &>/dev/null || die "required program not found: $prog"
	done
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════

preflight
trap cleanup EXIT

echo "Running nvme/070 - test nvme-fc marginal path handling"

# ── 1. Create backing store ────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
IMG="${TMPDIR}/img"
truncate -s "${IMG_SIZE}" "${IMG}"
LOOP_DEV=$(losetup -f --show "${IMG}")
echo "  Backing device: ${LOOP_DEV}"

# ── 2. Load kernel modules ────────────────────────────────────────────────

modprobe -q nvmet
modprobe -q nvme-fc
modprobe -q nvme-fcloop
echo "  Modules loaded"

# ── 3. Create fcloop local ports (one per host port) ─────────────────────

for (( hp = 0; hp < NUM_HOST_PORTS; hp++ )); do
	fcloop_add_lport "$(host_wwnn "$hp")" "$(host_wwpn "$hp")"
	echo "  Local port ${hp} created: nn=$(host_wwnn "$hp") pn=$(host_wwpn "$hp")"
done

# ── 4. Check for set_marginal_rport support ──────────────────────────────

if [[ ! -w /sys/class/fcloop/ctl/set_marginal_rport ]]; then
	die "fcloop does not support set_marginal_rport"
fi
echo "  set_marginal_rport supported"

# ── 5. Create NVMe target subsystem and namespace ─────────────────────────

create_subsystem
create_namespace "${LOOP_DEV}"
echo "  Subsystem created: ${SUBSYSNQN}, ns=1 on ${LOOP_DEV}"

# ── 6. Create 4 FC ports (2 per host port) ───────────────────────────────

PORTS=()
# First 2 ports on host_port 0
for (( p = 0; p < NUM_PORTS / NUM_HOST_PORTS; p++ )); do
	create_port "$p" 0
	link_subsystem_to_port "$p"
	PORTS+=("$p")
	echo "  Port ${p} created: host_port=0 traddr=$(fc_traddr "$p")"
done
# Next 2 ports on host_port 1
for (( p = NUM_PORTS / NUM_HOST_PORTS; p < NUM_PORTS; p++ )); do
	create_port "$p" 1
	link_subsystem_to_port "$p"
	PORTS+=("$p")
	echo "  Port ${p} created: host_port=1 traddr=$(fc_traddr "$p")"
done

# ── 7. Create host entry and allow access ─────────────────────────────────

create_host
echo "  Host allowed: ${HOSTNQN}"

# ── 8. Set ANA states (host_port 0 = optimized, host_port 1 = non-optimized) ─

first_host0=0
first_host1=0
for p in "${PORTS[@]}"; do
	setup_port_ana "$p" 1 "non-optimized"
	if [[ $(get_fc_host_port "${p}") == 0 ]]; then
		if [[ $first_host0 -eq 1 ]]; then continue; fi
		first_host0=1
	else
		if [[ $first_host1 -eq 1 ]]; then continue; fi
		first_host1=1
	fi
	setup_port_ana "$p" 1 "optimized"
done
echo "  ANA states set (one optimized per host port, rest non-optimized)"

# ── 9. Connect host to all 4 ports ────────────────────────────────────────

for p in "${PORTS[@]}"; do
	nvme_connect_port "$p"
done
echo "  Connected to ${NUM_PORTS} ports"

# Wait for the multipath namespace to appear
NS=$(wait_for_ns)
echo "  Namespace found: /dev/${NS}"
CTRL="${NS::-2}"
echo "  Controller found: ${CTRL}"
SUBSYS_N="${CTRL:4}"
echo "  SubsysN: ${SUBSYS_N}"

# ── 10. Start fio background I/O ──────────────────────────────────────────

echo "Starting background I/O"
fio --name=verify \
	--rw=randwrite \
	--direct=1 \
	--ioengine=libaio \
	--bs=4k \
	--iodepth=16 \
	--verify=crc32c \
	--verify_state_save=0 \
	--filename="/dev/${NS}" \
	--group_reporting \
	--ramp_time="${FIO_RAMP}" \
	--time_based \
	--runtime="${FIO_RUNTIME}" \
	--output="${TMPDIR}/fio.log" > /dev/null 2>&1 &
FIO_PID=$!
echo "  fio started (pid=${FIO_PID}), runtime=${FIO_RUNTIME}"

sleep 1

create_tmux_session

next_step

# ── 11. Run marginal path tests ──────────────────────────────────────────

echo "Run marginal path tests"
run_tests "$(_find_nvme_subsys "${SUBSYSNQN}")" "${PORTS[@]}"

list_subsys_interactive

# ── 12. ANA failover ─────────────────────────────────────────────────────

echo "ANA failover"
ana_failover "${PORTS[@]}"

list_subsys_interactive

# ── 13. Run marginal path tests ──────────────────────────────────────────

echo "Run marginal path tests after ANA failover"
run_tests "$(_find_nvme_subsys "${SUBSYSNQN}")" "${PORTS[@]}"

list_subsys_interactive

# ── 14. ANA failback ─────────────────────────────────────────────────────

echo "ANA failback"
ana_failback "${PORTS[@]}"

list_subsys_interactive

# ── 15. Run marginal path tests ──────────────────────────────────────────

echo "Run marginal path tests after ANA failback"
run_tests "$(_find_nvme_subsys "${SUBSYSNQN}")" "${PORTS[@]}"

list_subsys_interactive

# ── 16. Stop fio ─────────────────────────────────────────────────────────

echo "Stopping background I/O"
if kill -0 "${FIO_PID}" 2>/dev/null; then
	kill "${FIO_PID}" 2>/dev/null
	wait "${FIO_PID}" 2>/dev/null || true
fi
unset FIO_PID

# ── 17. Disconnect and tear down ─────────────────────────────────────────

nvme_disconnect

echo "Test complete"
