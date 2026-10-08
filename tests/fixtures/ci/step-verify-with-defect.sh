set -euo pipefail
bash --version | head -1
bats --version
yq --version
jq --version
git --version
tmux -V
docker --version
docker compose version
docker info | head -10

