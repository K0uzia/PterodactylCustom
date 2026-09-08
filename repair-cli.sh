#!/usr/bin/env bash
# Répare droits + symlink si "ptero-stack: command not found"
# Usage : sudo bash /opt/ptero-stack/repair-cli.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sed -i 's/\r$//' "${ROOT}/ptero-stack.sh" "${ROOT}/lib/"*.sh "${ROOT}/repair-cli.sh" 2>/dev/null || true
chmod +x "${ROOT}/ptero-stack.sh" "${ROOT}/repair-cli.sh"
chmod +x "${ROOT}/lib/"*.sh 2>/dev/null || true
ln -sfn "${ROOT}/ptero-stack.sh" /usr/local/bin/ptero-stack
echo "OK — lancez : sudo ptero-stack"
echo "   ou : sudo bash ${ROOT}/ptero-stack.sh"
