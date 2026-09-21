#!/bin/zsh
# マニュアル（Marp）を PDF にして manual/ と dist/ に置く。要: brew install marp-cli、Google Chrome
set -euo pipefail
cd "$(dirname "$0")"
src="CacaoTrans-マニュアル.md"
pdf="${src%.md}.pdf"
marp --pdf --allow-local-files "$src" -o "$pdf" < /dev/null
cp "$pdf" "../dist/$pdf"
echo "作成: manual/$pdf → dist/$pdf"
