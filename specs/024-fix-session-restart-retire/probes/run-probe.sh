#!/bin/sh
# 024 Fase 0 — sonda del discriminador.
#
# Pregunta que responde, MIDIENDO contra systemd real:
#   1. ¿Se ejecuta ExecStop SOLO cuando systemd detiene el servicio, y no
#      cuando el proceso principal sale por su cuenta?
#   2. ¿Qué valores entrega systemd a ExecStopPost en cada caso
#      ($SERVICE_RESULT / $EXIT_CODE / $EXIT_STATUS)?
#
# Usa una unit de USUARIO desechable. No toca el agente ni requiere sudo.
set -u

D="$HOME/sp-probe"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="sp-probe.service"
LOG="$D/probe.log"

mkdir -p "$D" "$UNIT_DIR"

# ── el proceso principal ────────────────────────────────────────────────────
# MODE=hold      : imita a Claude Code — atrapa SIGTERM y sale 0
# MODE=selfexit  : sale solo con 0 tras ~2s (imita "la sesion termino")
# MODE=failexit  : sale solo con 3
# MODE=notrap    : IGNORA SIGTERM -> systemd tiene que mandarle SIGKILL
cat > "$D/probe-main.sh" <<'EOF'
#!/bin/sh
MODE="${1:-hold}"
case "$MODE" in
  notrap) trap '' TERM ;;
  *)      trap 'exit 0' TERM ;;
esac
case "$MODE" in
  selfexit) sleep 2 & wait $!; exit 0 ;;
  failexit) sleep 2 & wait $!; exit 3 ;;
esac
while : ; do sleep 1 & wait $! ; done
EOF

# ── el registrador de los hooks ─────────────────────────────────────────────
cat > "$D/probe-log.sh" <<'EOF'
#!/bin/sh
printf '%s | %-12s | SERVICE_RESULT=%-8s | EXIT_CODE=%-8s | EXIT_STATUS=%s\n' \
  "$(date -u +%H:%M:%S)" "$1" \
  "${SERVICE_RESULT:-<unset>}" "${EXIT_CODE:-<unset>}" "${EXIT_STATUS:-<unset>}" \
  >> "$PROBE_LOG"
exit 0
EOF

chmod +x "$D/probe-main.sh" "$D/probe-log.sh"

write_unit() {
  cat > "$UNIT_DIR/$UNIT" <<EOF
[Unit]
Description=024 discriminator probe

[Service]
Type=simple
Environment=PROBE_LOG=$LOG
ExecStart=$D/probe-main.sh $1
ExecStop=$D/probe-log.sh EXECSTOP
ExecStopPost=$D/probe-log.sh EXECSTOPPOST
Restart=no
TimeoutStopSec=3
EOF
  systemctl --user daemon-reload
}

banner() {
  printf '\n===== CASO %s =====\n' "$1"
  : > "$LOG"
}

show() {
  if [ -s "$LOG" ]; then cat "$LOG"; else echo "(los hooks no escribieron nada)"; fi
  printf -- '-- ExecStop corrio?: '
  grep -q EXECSTOP' ' "$LOG" 2>/dev/null && echo "SI" || echo "NO"
}

# ── CASO A: el proceso sale SOLO con codigo 0 ("la sesion termino") ─────────
banner "A · el proceso sale SOLO (exit 0)"
write_unit selfexit
systemctl --user start "$UNIT"
sleep 5
show

# ── CASO B: systemctl stop, con el proceso atrapando SIGTERM ───────────────
banner "B · systemctl stop (el proceso atrapa TERM y sale 0)"
write_unit hold
systemctl --user start "$UNIT"
sleep 2
systemctl --user stop "$UNIT"
sleep 2
show

# ── CASO C: systemctl restart ──────────────────────────────────────────────
banner "C · systemctl restart (el proceso atrapa TERM y sale 0)"
write_unit hold
systemctl --user start "$UNIT"
sleep 2
systemctl --user restart "$UNIT"
sleep 2
systemctl --user stop "$UNIT" 2>/dev/null
sleep 1
show

# ── CASO D: el proceso sale SOLO con codigo != 0 ───────────────────────────
banner "D · el proceso sale SOLO (exit 3)"
write_unit failexit
systemctl --user start "$UNIT"
sleep 5
show

# ── CASO E: no atrapa TERM -> systemd lo mata con SIGKILL ──────────────────
banner "E · systemctl stop contra un proceso que IGNORA TERM"
write_unit notrap
systemctl --user start "$UNIT"
sleep 2
systemctl --user stop "$UNIT"
sleep 5
show

# ── limpieza ───────────────────────────────────────────────────────────────
printf '\n===== limpieza =====\n'
systemctl --user stop "$UNIT" 2>/dev/null
rm -f "$UNIT_DIR/$UNIT"
systemctl --user daemon-reload
rm -rf "$D"
echo "unit desechable eliminada; agente NO tocado"
