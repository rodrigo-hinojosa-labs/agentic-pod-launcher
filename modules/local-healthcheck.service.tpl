[Unit]
Description=Healthcheck for Claude Code Remote Control ({{AGENT_NAME}})

[Service]
Type=oneshot
User={{OPERATOR_USER}}
ExecStart={{DEPLOYMENT_WORKSPACE}}/scripts/local/agent-healthcheck.sh
# WARN(1)/DEGRADED(2) are status signals, not unit failures — the script does
# its own notify, so don't accumulate failed units on a degraded login.
SuccessExitStatus=1 2
