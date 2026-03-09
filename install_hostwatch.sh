#!/usr/bin/env bash
set -euo pipefail

# === Instala HostWatch: agente de monitoramento de hardware/containers com alertas por e-mail ===
# Caminhos padrão
BIN="/usr/local/bin/hostwatch.sh"
CONF_DIR="/etc/hostwatch"
CONF_FILE="${CONF_DIR}/hostwatch.conf"
STATE_DIR="/var/lib/hostwatch"
UNIT_SERVICE="/etc/systemd/system/hostwatch.service"
UNIT_TIMER="/etc/systemd/system/hostwatch.timer"

# 1) Dependências
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y jq coreutils util-linux procps grep gawk sed curl \
                   smartmontools lm-sensors mdadm mailutils bsd-mailx

# 2) Diretórios e permissões
mkdir -p "$CONF_DIR" "$STATE_DIR"
chmod 750 "$CONF_DIR" "$STATE_DIR"

# 3) Configuração padrão
if [ ! -f "$CONF_FILE" ]; then
  cat > "$CONF_FILE" <<'EOF'
# =========================
# HostWatch Configuration
# =========================
# Editar e ajustar conforme ambiente.

# --- Identificação ---
HOST_ALIAS=""                 # Opcional: nome amigável do host (se vazio, usa hostname)

# --- E-mail (via /usr/bin/mail) ---
ALERT_EMAIL="alerts@example.com"   # <- Altere para seu e-mail de recebimento
MAIL_SUBJECT_PREFIX="[HostWatch]"

# Observação: 'mail' usa o MTA local. Se não tiver postfix/exim configurado,
# você pode instalar e configurar 'msmtp' e mapear /usr/sbin/sendmail para msmtp
# ou ajustar mailutils para usar SMTP relay externo.

# --- Frequência e supressão ---
COOLDOWN_SECONDS=300          # Não reenviar e-mails idênticos por (segundos)
INCLUDE_JOURNAL_LINES=80      # Linhas do journalctl (prioridade 0-3) no corpo do alerta
INCLUDE_DOCKER_LOG_MINUTES=2  # Linhas recentes de logs de containers problemáticos (em minutos)

# --- Thresholds ---
CPU_LOAD_PER_CORE=2.0         # alerta se loadavg(1 min) > (n_cores * este valor)
MEM_MIN_AVAIL_MB=512          # alerta se memória disponível < este valor (MB)
DISK_USAGE_PCT=90             # alerta se uso de partição >= %
INODE_USAGE_PCT=90            # alerta se uso de inodes >= %

# --- Checagens ---
CHECK_SMART=1                 # 1=habilita smartctl (S.M.A.R.T) em /dev/sd?
CHECK_RAID=1                  # 1=habilita checagem mdadm (arrays RAID)
CHECK_SENSORS=1               # 1=habilita sensors (temperaturas), alerta se crit/ALARM
CHECK_DMESG_ERRORS=1          # 1=inclui erros recentes do kernel no alerta (resumo)

# --- Containers ---
CHECK_DOCKER=1                # 1=verificar containers Docker
CHECK_PODMAN=1                # 1=verificar containers Podman
CONTAINER_IGNORE_REGEX="(portainer|watchtower)"   # Regex de nomes a ignorar
# Considera problemático se: exited/restarting/unhealthy
EOF
  chmod 640 "$CONF_FILE"
fi

# 4) Script principal
cat > "$BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONF_FILE="/etc/hostwatch/hostwatch.conf"
STATE_DIR="/var/lib/hostwatch"
LAST_ALERT_SHA="${STATE_DIR}/last_alert.sha1"
LAST_ALERT_TS="${STATE_DIR}/last_alert.ts"

# Carrega conf
if [ -f "$CONF_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONF_FILE"
else
  echo "Config file not found: $CONF_FILE" >&2
  exit 1
fi

HOSTNAME_ACTUAL="$(hostname -f 2>/dev/null || hostname)"
HOST_DISPLAY="${HOST_ALIAS:-$HOSTNAME_ACTUAL}"
NOW="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"

alerts=()

add_alert() {
  alerts+=("$1")
}

# --------- Helpers ----------
pct() {
  # usa bc se existir, senão awk
  awk "BEGIN{printf \"%.2f\", ($1/$2)*100}"
}

trim() { awk '{$1=$1;print}' <<<"$1"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# --------- Hardware: CPU load ----------
CORES="$(nproc 2>/dev/null || echo 1)"
LOAD1="$(awk '{print $1}' /proc/loadavg)"
MAX_LOAD_ALLOWED=$(awk -v core="$CORES" -v mult="${CPU_LOAD_PER_CORE:-2.0}" 'BEGIN{printf "%.2f", core*mult}')
awk "BEGIN{exit !($LOAD1 > $MAX_LOAD_ALLOWED)}" || true
if awk "BEGIN{exit !($LOAD1 > $MAX_LOAD_ALLOWED)}"; then
  add_alert "High load: ${LOAD1} > ${MAX_LOAD_ALLOWED} (cores=${CORES})"
fi

# --------- Hardware: Memória ----------
MEM_AVAILABLE_KB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
MEM_AVAILABLE_MB=$(( MEM_AVAILABLE_KB / 1024 ))
if [ "${MEM_AVAILABLE_MB}" -lt "${MEM_MIN_AVAIL_MB:-512}" ]; then
  add_alert "Low available memory: ${MEM_AVAILABLE_MB} MB < ${MEM_MIN_AVAIL_MB} MB"
fi

# --------- Hardware: Disco/partições ----------
while read -r fs size used avail usep mount; do
  # usar df -P -T? Aqui: df -hP não dá números; preferir em blocos
  :
done < /dev/null

# Usa df em blocos para cálculo seguro
while read -r _fs _blocks _used _avail _usep _mount; do
  usep_num="${_usep%%%}"
  if [ "$usep_num" -ge "${DISK_USAGE_PCT:-90}" ]; then
    add_alert "High disk usage: ${_mount} at ${_usep}"
  fi
done < <(df -P --output=source,blocks,used,avail,pcent,target | tail -n +2)

# Inodes
while read -r _fs _inodes _iused _ifree _iusep _mount; do
  iusep_num="${_iusep%%%}"
  if [ "$iusep_num" -ge "${INODE_USAGE_PCT:-90}" ]; then
    add_alert "High inode usage: ${_mount} at ${_iusep}"
  fi
done < <(df -Pi --output=source,inodes,iused,iavail,ipcent,target | tail -n +2)

# --------- SMART ----------
if [ "${CHECK_SMART:-1}" -eq 1 ] && have_cmd smartctl; then
  while read -r name type; do
    [ "$type" = "disk" ] || continue
    dev="/dev/${name}"
    if smartctl -H "$dev" >/tmp/smarth.$$ 2>/dev/null; then
      status="$(awk -F: '/SMART overall-health self-assessment test result:/ {print $2}' /tmp/smarth.$$ | xargs)"
      if [ -z "$status" ]; then
        # NVMe?
        if smartctl -H -d nvme "$dev" >/tmp/smarth.$$ 2>/dev/null; then
          status="$(awk -F: '/SMART overall-health self-assessment test result:/ {print $2}' /tmp/smarth.$$ | xargs)"
        fi
      fi
      if echo "$status" | grep -qiE 'failed|BAD'; then
        add_alert "SMART failure on ${dev}: ${status}"
      fi
    fi
  done < <(lsblk -dn -o NAME,TYPE 2>/dev/null)
fi

# --------- RAID mdadm ----------
if [ "${CHECK_RAID:-1}" -eq 1 ] && have_cmd mdadm; then
  while read -r md; do
    [ -e "$md" ] || continue
    if mdadm --detail "$md" >/tmp/md.$$ 2>/dev/null; then
      if grep -q "State :.*degraded" /tmp/md.$$; then
        add_alert "RAID array degraded: ${md}"
      fi
    fi
  done < <(ls /dev/md* 2>/dev/null | tr ' ' '\n' | grep -E '^/dev/md[0-9]+' || true)
fi

# --------- Temperaturas (lm-sensors) ----------
if [ "${CHECK_SENSORS:-1}" -eq 1 ] && have_cmd sensors; then
  sensors_out="$(sensors 2>/dev/null || true)"
  if echo "$sensors_out" | grep -qE 'ALARM|crit'; then
    add_alert "Sensor alert: temperature critical/ALARM detected"
  fi
fi

# --------- dmesg/journal erros críticos ----------
journal_snippet=""
if [ "${CHECK_DMESG_ERRORS:-1}" -eq 1 ] && have_cmd journalctl; then
  journal_snippet="$(journalctl -p 0..3 -n ${INCLUDE_JOURNAL_LINES:-80} --no-pager 2>/dev/null || true)"
  if [ -n "$journal_snippet" ]; then
    # Não gera alerta por si só; entra no corpo se houver outros problemas
    :
  fi
fi

# --------- Containers (Docker/Podman) ----------
container_problems=()

check_runtime() {
  local runtime="$1"
  local ps_cmd="$1 ps --format {{.ID}}^^{{.Names}}^^{{.Status}} 2>/dev/null"
  eval $ps_cmd | while IFS='^^' read -r id name status; do
    [ -z "$id" ] && continue
    if [ -n "${CONTAINER_IGNORE_REGEX:-}" ] && echo "$name" | grep -Eq "$CONTAINER_IGNORE_REGEX"; then
      continue
    fi
    # Status flags
    if echo "$status" | grep -qi 'Exited'; then
      echo "${runtime}:${name}:${id}:exited:${status}"
      continue
    fi
    if echo "$status" | grep -qi 'Restarting'; then
      echo "${runtime}:${name}:${id}:restarting:${status}"
      continue
    fi
    # Health (unhealthy)
    if "$1" inspect --format '{{json .State.Health.Status}}' "$id" >/tmp/h.$$ 2>/dev/null; then
      health="$(cat /tmp/h.$$ | tr -d '"')"
      if [ "$health" = "unhealthy" ]; then
        echo "${runtime}:${name}:${id}:unhealthy:${status}"
      fi
    fi
  done
}

if [ "${CHECK_DOCKER:-1}" -eq 1 ] && have_cmd docker; then
  while read -r line; do
    [ -z "$line" ] && continue
    container_problems+=("$line")
  done < <(check_runtime docker || true)
fi

if [ "${CHECK_PODMAN:-1}" -eq 1 ] && have_cmd podman; then
  while read -r line; do
    [ -z "$line" ] && continue
    container_problems+=("$line")
  done < <(check_runtime podman || true)
fi

if [ "${#container_problems[@]}" -gt 0 ]; then
  add_alert "Container issues detected: ${#container_problems[@]} problematic container(s)."
fi

# --------- Monta corpo do alerta (se houver) ----------
if [ "${#alerts[@]}" -eq 0 ]; then
  exit 0
fi

{
  echo "Host: ${HOST_DISPLAY}"
  echo "When: ${NOW}"
  echo
  echo "Summary:"
  for a in "${alerts[@]}"; do
    echo " - $a"
  done

  # Detalhes de container
  if [ "${#container_problems[@]}" -gt 0 ]; then
    echo
    echo "Containers:"
    for c in "${container_problems[@]}"; do
      # runtime:name:id:flag:status
      IFS=':' read -r runtime name id flag status <<<"$c"
      echo " - [$runtime] $name ($id) => $flag | $status"
    done
    # Logs recentes dos containers problemáticos
    if [ -n "${INCLUDE_DOCKER_LOG_MINUTES:-}" ]; then
      echo
      echo "Recent container logs (last ${INCLUDE_DOCKER_LOG_MINUTES}m):"
      for c in "${container_problems[@]}"; do
        IFS=':' read -r runtime name id flag status <<<"$c"
        echo "----- ${runtime} logs ${name} (${id}) -----"
        if have_cmd "$runtime"; then
          "$runtime" logs --since "${INCLUDE_DOCKER_LOG_MINUTES}m" "$id" 2>&1 | tail -n 200 || echo "(no recent logs)"
        fi
      done
    fi
  fi

  # Journal crítico
  if [ -n "$journal_snippet" ]; then
    echo
    echo "Journal (critical to error, last ${INCLUDE_JOURNAL_LINES:-80} lines):"
    echo "$journal_snippet"
  fi

  echo
  echo "Disk usage:"
  df -hP | sed '1,1!b; s/^/  /' -e '1!s/^/  /'

  echo
  echo "Top processes (by CPU, 10):"
  ps -eo pid,ppid,comm,%cpu,%mem --sort=-%cpu | head -n 11 | sed 's/^/  /'

} > /tmp/hostwatch_body.$$

BODY="$(cat /tmp/hostwatch_body.$$)"
SUBJECT="${MAIL_SUBJECT_PREFIX:-[HostWatch]} ${HOST_DISPLAY} ALERT"

# Supressão por hash + cooldown
NEW_SHA="$(printf '%s' "$BODY" | sha1sum | awk '{print $1}')"
LAST_SHA="$(cat "$LAST_ALERT_SHA" 2>/dev/null || true)"
NOW_TS="$(date +%s)"
LAST_TS="$(cat "$LAST_ALERT_TS" 2>/dev/null || echo 0)"

SEND=1
if [ "$NEW_SHA" = "$LAST_SHA" ]; then
  elapsed=$(( NOW_TS - LAST_TS ))
  if [ "$elapsed" -lt "${COOLDOWN_SECONDS:-300}" ]; then
    SEND=0
  fi
fi

if [ "$SEND" -eq 1 ]; then
  # Envia email
  if [ -n "${ALERT_EMAIL:-}" ]; then
    printf '%s\n' "$BODY" | mail -s "$SUBJECT" "$ALERT_EMAIL" || true
  fi
  printf '%s' "$NEW_SHA" > "$LAST_ALERT_SHA"
  printf '%s' "$NOW_TS" > "$LAST_ALERT_TS"
fi

rm -f /tmp/hostwatch_body.$$
exit 0
EOF
chmod 750 "$BIN"

# 5) systemd units
cat > "$UNIT_SERVICE" <<'EOF'
[Unit]
Description=HostWatch monitor (hardware, containers, critical logs)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hostwatch.sh
User=root
Group=root
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

[Install]
WantedBy=multi-user.target
EOF

cat > "$UNIT_TIMER" <<'EOF'
[Unit]
Description=Run HostWatch every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=60s
AccuracySec=10s
Unit=hostwatch.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 6) Ativa
systemctl daemon-reload
systemctl enable --now hostwatch.timer

echo "=============================================="
echo "HostWatch instalado."
echo "Edite o e-mail de alerta em: ${CONF_FILE}"
echo "Verifique o status: systemctl status hostwatch.timer"
echo "Forçar um run:        systemctl start hostwatch.service"
echo "Logs últimos runs:    journalctl -u hostwatch.service -n 50 --no-pager"
echo "=============================================="

