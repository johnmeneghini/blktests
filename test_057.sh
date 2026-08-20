#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Standalone recreation of blktests nvme/057:
#   "test nvme fabrics controller ANA failover during I/O"
#
# This script sets up an NVMe-oF FC loopback target with 4 ports,
# connects the host, runs fio I/O, exercises ANA failover/failback,
# then tears everything down.
#
# Requires: root, nvme-cli, fio, loop device support, kernel modules
#   nvmet, nvme-fc, nvme-fcloop
#
# Usage:
#   sudo ./test_057.sh
#
# ---------------------------------------------------------------------------
# How blktests nvme/057 uses drivers/nvme/target:
#
# 1. Module loading:
#    - nvmet        (NVMe target core, provides configfs at /sys/kernel/config/nvmet)
#    - nvme-fc      (NVMe-oF FC host transport)
#    - nvme-fcloop  (virtual FC loopback LLDD, bridges host and target in-memory)
#
# 2. fcloop port creation (via sysfs /sys/devices/virtual/fcloop/ctl/):
#    - One local port is created (add_local_port) representing the virtual FC HBA
#    - Four target ports are created (add_target_port), one per NVMe port
#    - Four remote ports are created (add_remote_port), each linked to the local
#      port and cross-linked to the corresponding target port
#    The remote+target port pairs share the same WWNN/WWPN so fcloop internally
#    connects them through an nport nexus, enabling I/O to flow via memory copies.
#
# 3. NVMe target configfs setup (/sys/kernel/config/nvmet/):
#    - A subsystem is created with a namespace backed by a loop block device
#    - Four ports (port 0-3) are created, each configured with trtype=fc and
#      traddr pointing to the corresponding fcloop target/remote port pair
#    - The subsystem is linked to all four ports
#    - A host entry is created and allowed access to the subsystem
#    - ANA group 1 is configured on each port with different ANA states:
#      port 0 = optimized, port 1 = non-optimized, ports 2-3 = inaccessible
#
# 4. Host-side connection:
#    - nvme connect is called four times (once per port), creating four
#      NVMe-oF FC controllers.  The NVMe multipath layer aggregates them.
#
# 5. I/O and ANA state transitions:
#    - fio runs random verified writes against the multipath NVMe namespace
#    - The test flips ANA states (failover): ports 0-1 become inaccessible,
#      port 2 becomes optimized, port 3 becomes non-optimized
#    - After a delay, ANA states flip back (failback) to the original
#    - The host-side ANA change notifications (via RSCN simulation in fcloop
#      and AEN from nvmet) cause the multipath layer to re-route I/O
#    - fio continues running throughout; test passes if no I/O errors occur
#
# 6. Teardown:
#    - nvme disconnect removes all controllers
#    - configfs entries are removed (subsystem, namespaces, ports, hosts)
#    - fcloop remote/target/local ports are deleted via sysfs
#    - The loop block device and backing file are cleaned up
# ---------------------------------------------------------------------------

INTERACTIVE=$1
if [[ -n "${INTERACTIVE}" ]]; then
    if [[ ! "$INTERACTIVE" == "-i" ]]; then
        echo "  Invalid argument \"$1\""
        exit 2
    fi
fi

set -euo pipefail

# ── Tunables ────────────────────────────────────────────────────────────────

IMG_SIZE="1G"
FIO_RUNTIME="7m"
FIO_RAMP="10"
NUM_PORTS=4

# ── Identity constants (matching blktests defaults) ─────────────────────────

SESSION_NAME="test_057_mon"
SUBSYSNQN="blktests-subsystem-1"
SUBSYS_UUID="91fdba0d-f87b-4c25-b80f-db7be1418b9e"
HOSTID="0f01fb42-9f7f-4856-b0b3-51e60b8de349"
HOSTNQN="nqn.2014-08.org.nvmexpress:uuid:${HOSTID}"

LOCAL_WWNN="0x10001100aa000001"
LOCAL_WWPN="0x20001100aa000001"
REMOTE_WWNN_BASE=0x10001100ab000001
REMOTE_WWPN_BASE=0x20001100ab000001

NVMET_CFS="/sys/kernel/config/nvmet"
LOOPCTL="/sys/devices/virtual/fcloop/ctl"

TMPDIR=""
LOOP_DEV=""

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

fc_traddr() {
	printf "nn-%s:pn-%s" "$(remote_wwnn "$1")" "$(remote_wwpn "$1")"
}

fc_host_traddr() {
	printf "nn-%s:pn-%s" "$LOCAL_WWNN" "$LOCAL_WWPN"
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
	local portcfs="${NVMET_CFS}/ports/${portnum}"

	# Create fcloop target and remote ports for this port number
	fcloop_add_tport "$(remote_wwnn "$portnum")" "$(remote_wwpn "$portnum")"
	fcloop_add_rport "$LOCAL_WWNN" "$LOCAL_WWPN" \
		"$(remote_wwnn "$portnum")" "$(remote_wwpn "$portnum")"

	# Create the NVMe target port in configfs
	mkdir -p "${portcfs}"
	echo "fc"                        > "${portcfs}/addr_trtype"
	echo "$(fc_traddr "$portnum")"   > "${portcfs}/addr_traddr"
	echo "fc"                        > "${portcfs}/addr_adrfam"
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

# ── Connect / disconnect ───────────────────────────────────────────────────

nvme_connect_port() {
	local portnum="$1"

	nvme connect \
		--transport fc \
		--traddr "$(fc_traddr "$portnum")" \
		--host-traddr "$(fc_host_traddr)" \
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
	cat << EOF >> test_057_tmux.sh
#!/bin/bash
tmux new-session -d -s "$SESSION_NAME" "watch -t -d 'nvme list-subsys /dev/${NS}'"
tmux split-window -v -t "$SESSION_NAME" "iostat -x ID $(cat /proc/diskstats | grep "${CTRL}" | awk '{print $3}'  | sed -z 's/\n/ /g') 4"
tmux split-window -v -t "$SESSION_NAME" "watch -t -d 'grep . /sys/class/nvme-subsystem/nvme-subsys${SUBSYS_N}/nvme*/${CTRL}*/inflight'"
#tmux split-window -v -t "$SESSION_NAME" "watch -t -d 'grep . /sys/class/nvme-subsystem/nvme-subsys${SUBSYS_N}/nvme*/state'"
sleep 1
echo ""
echo "Using \"tmux attach\" to connect to tmux session"
echo ""
sleep 1
tmux attach
EOF
	chmod 777 test_057_tmux.sh
	echo ""
	echo "Use \"sudo ./test_057_tmux.sh\" to start tmux in separate window"
	echo ""
	echo "Use \"xterm -e sudo fio --name=80Grandreadwrite --filename /dev/${NS} --rw=randrw --bs=4096 --direct=1 --unlink=0 --iodepth=32 --ioengine=libaio --scramble_buffers=1 --randrepeat=1 --norandommap --size=80G --time_based=1 --runtime=86400s &\""
	echo ""
}

create_tmux_session() {
	rm -f test_071_tmux.sh
	if [[ ! -z "$INTERACTIVE" ]]; then
		make_tmux_session
	fi
}


# ── Cleanup (called on exit) ───────────────────────────────────────────────

cleanup() {
	local p

	echo "cleanup"
	if [[ ! -z "$INTERACTIVE" ]]; then
		echo "Stop FIO"
		next_step
	else
		# Stop fio if still running
		if [[ -n "${FIO_PID:-}" ]] && kill -0 "${FIO_PID}" 2>/dev/null; then
			kill "${FIO_PID}" 2>/dev/null
			wait "${FIO_PID}" 2>/dev/null || true
		fi
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
		fcloop_del_rport "$LOCAL_WWNN" "$LOCAL_WWPN" \
			"$(remote_wwnn "$p")" "$(remote_wwpn "$p")" 2>/dev/null || true
		fcloop_del_tport "$(remote_wwnn "$p")" "$(remote_wwpn "$p")" 2>/dev/null || true
	done
	fcloop_del_lport "$LOCAL_WWNN" "$LOCAL_WWPN" 2>/dev/null || true

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

echo "Running nvme/057 - test nvme fabrics controller ANA failover during I/O"

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

# ── 3. Create fcloop local port ───────────────────────────────────────────

fcloop_add_lport "$LOCAL_WWNN" "$LOCAL_WWPN"
echo "  Local port created: nn=${LOCAL_WWNN} pn=${LOCAL_WWPN}"

# ── 4. Create NVMe target subsystem and namespace ─────────────────────────

create_subsystem
create_namespace "${LOOP_DEV}"
echo "  Subsystem created: ${SUBSYSNQN}, ns=1 on ${LOOP_DEV}"

# ── 5. Create 4 FC ports (fcloop tport+rport + configfs port) ─────────────

PORTS=()
for (( p = 0; p < NUM_PORTS; p++ )); do
	create_port "$p"
	link_subsystem_to_port "$p"
	PORTS+=("$p")
	echo "  Port ${p} created: traddr=$(fc_traddr "$p")"
done

# ── 6. Create host entry and allow access ─────────────────────────────────

create_host
echo "  Host allowed: ${HOSTNQN}"
next_step

# ── 7. Set initial ANA states (failback: port0=opt, port1=non-opt, rest=inacc) ─

ana_failback "${PORTS[@]}"
echo "  ANA initial state set (failback)"
next_step

# ── 8. Connect host to all 4 ports ────────────────────────────────────────

for p in "${PORTS[@]}"; do
	nvme_connect_port "$p"
done
echo "  Connected to ${NUM_PORTS} ports"
next_step

# Wait for the multipath namespace to appear
NS=$(wait_for_ns)
echo "  Namespace found: /dev/${NS}"
CTRL="${NS::-2}"
echo "  Controller found: ${CTRL}"
SUBSYS_N="${CTRL:4}"
echo "  SubsysN: ${SUBSYS_N}"

# ── 9. Start fio background I/O ──────────────────────────────────────────

if [[ -z "$INTERACTIVE" ]]; then
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
fi

create_tmux_session

next_step

# ── 10. ANA failover ─────────────────────────────────────────────────────

echo "ANA failover"
ana_failover "${PORTS[@]}"
if [[ -z "$INTERACTIVE" ]]; then
nvme list-subsys /dev/${NS}
sleep 2
fi

next_step

# ── 11. ANA failback ─────────────────────────────────────────────────────

echo "ANA failback"
ana_failback "${PORTS[@]}"
if [[ -z "$INTERACTIVE" ]]; then
nvme list-subsys /dev/${NS}
sleep 2
fi

next_step

# ── 10. ANA failover ─────────────────────────────────────────────────────

echo "ANA failover"
ana_failover "${PORTS[@]}"
if [[ -z "$INTERACTIVE" ]]; then
nvme list-subsys /dev/${NS}
sleep 2
fi

next_step

# ── 11. ANA failback ─────────────────────────────────────────────────────

echo "ANA failback"
ana_failback "${PORTS[@]}"
if [[ -z "$INTERACTIVE" ]]; then
nvme list-subsys /dev/${NS}
sleep 2
fi

# ── 12. Stop fio ─────────────────────────────────────────────────────────

if [[ -z "$INTERACTIVE" ]]; then
	if kill -0 "${FIO_PID}" 2>/dev/null; then
		kill "${FIO_PID}" 2>/dev/null
		wait "${FIO_PID}" 2>/dev/null || true
	fi
	unset FIO_PID
else
	echo "Stop FIO"
	next_step
fi

# ── 13. Disconnect and tear down ─────────────────────────────────────────

nvme_disconnect

echo "Test complete"
