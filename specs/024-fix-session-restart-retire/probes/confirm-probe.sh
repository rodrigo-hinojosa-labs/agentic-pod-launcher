#!/bin/sh
# 024 Fase 0 — pasada CONFIRMATORIA.
#
# La primera pasada sugirio el discriminador: dentro de ExecStop, $EXIT_CODE
# esta DEFINIDO si el proceso ya habia salido solo, y VACIO si la parada la
# inicia systemd. Esta pasada verifica que sea estable y no un artefacto de
# timing, repitiendo cada caso 3 veces y agregando la variante Restart=always,
# que es la que usa la unit real del agente.
set -u

D="$HOME/sp-probe2"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="sp-probe2.service"
LOG="$D/probe.log"
mkdir -p "$D" "$UNIT_DIR"

cat > "$D/probe-main.sh" <<'EOF'
#!/bin/sh
MODE="${1:-hold}"
trap 'exit 0' TERM
[ "$MODE" = "selfexit" ] && { sleep 2 & wait $!; exit 0; }
while : ; do sleep 1 & wait $! ; done
EOF

# Lo unico que registramos es la señal candidata: ¿EXIT_CODE definido en ExecStop?
cat > "$D/probe-log.sh" <<'EOF'
#!/bin/sh
if [ "$1" = "EXECSTOP" ]; then
  if [ -n "${EXIT_CODE:-}" ]; then V="DEFINIDO(${EXIT_CODE})"; else V="VACIO"; fi
  printf '  ExecStop -> EXIT_CODE %s\n' "$V" >> "$PROBE_LOG"
else
  printf '  ExecStopPost -> SERVICE_RESULT=%s EXIT_CODE=%s\n' \
    "${SERVICE_RESULT:-<unset>}" "${EXIT_CODE:-<unset>}" >> "$PROBE_LOG"
fi
exit 0
EOF
chmod +x "$D/probe-main.sh" "$D/probe-log.sh"

write_unit() {
  cat > "$UNIT_DIR/$UNIT" <<EOF
[Unit]
Description=024 confirm probe
[Service]
Type=simple
Environment=PROBE_LOG=$LOG
ExecStart=$D/probe-main.sh $1
ExecStop=$D/probe-log.sh EXECSTOP
ExecStopPost=$D/probe-log.sh EXECSTOPPOST
Restart=$2
RestartSec=1
TimeoutStopSec=3
EOF
  systemctl --user daemon-reload
}

run_case() {
  label="$1"; mode="$2"; restart="$3"; action="$4"
  printf '\n--- %s (Restart=%s) ---\n' "$label" "$restart"
  i=1
  while [ "$i" -le 3 ]; do
    : > "$LOG"
    write_unit "$mode" "$restart"
    systemctl --user reset-failed "$UNIT" 2>/dev/null
    systemctl --user start "$UNIT" 2>/dev/null
    sleep 2
    [ "$action" = "stop" ] && systemctl --user stop "$UNIT"
    [ "$action" = "restart" ] && systemctl --user restart "$UNIT"
    sleep 3
    systemctl --user stop "$UNIT" 2>/dev/null
    printf ' repeticion %s:\n' "$i"
    grep 'ExecStop ->' "$LOG" | head -1 || echo "  (ExecStop no corrio)"
    i=$((i+1))
  done
}

echo "=== ESPERADO: 'sale solo' -> DEFINIDO ; parada de systemd -> VACIO ==="
run_case "A · el proceso sale SOLO"     selfexit no      none
run_case "B · systemctl stop"           hold     no      stop
run_case "C · systemctl restart"        hold     no      restart
run_case "D · sale SOLO, Restart=always" selfexit always none
run_case "E · restart, Restart=always"   hold     always  restart

printf '\n=== limpieza ===\n'
systemctl --user stop "$UNIT" 2>/dev/null
rm -f "$UNIT_DIR/$UNIT"; systemctl --user daemon-reload; rm -rf "$D"
echo "limpio; agente NO tocado"
