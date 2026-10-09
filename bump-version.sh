#!/bin/zsh
# バージョンを 0.0.1 上げる（例: 3.0.0 → 3.0.1）。配布用ビルド（dist に置くもの）の前に毎回実行する。
# 引数でバージョンを指定すればその値にする（例: ./bump-version.sh 4.0.0）。
set -euo pipefail
cd "$(dirname "$0")"
cur=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml | head -1)
if [[ $# -ge 1 ]]; then
  new=$1
else
  parts=(${(s:.:)cur})
  new="${parts[1]}.${parts[2]}.$(( parts[3] + 1 ))"
fi
month="$(date +%Y) 年 $(( $(date +%m) )) 月"
sed -i '' "s/\"$cur\"/\"$new\"/" project.yml
sed -i '' "s|<string>$cur</string>|<string>$new</string>|" CacaoTrans/Resources/Info-CacaoClaudeTrans.plist CacaoTrans/Resources/Info-CacaoTrans.plist
sed -i '' -e "s/バージョン $cur ／ [0-9]* 年 [0-9]* 月/バージョン $new ／ $month/" \
          -e "s/CacaoTrans-$cur\.dmg/CacaoTrans-$new.dmg/" \
          -e "s/CacaoTrans $cur ／/CacaoTrans $new ／/" manual/CacaoTrans-マニュアル.md
echo "$cur → $new"
