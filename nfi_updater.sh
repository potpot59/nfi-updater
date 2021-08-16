#!/bin/bash

# NFI UPDATER

# /!\
# You need bc to run this script, please install it: 'sudo apt install bc'
# Please adapt the command used for the backtest to your installation (freqtrade backtesting...)
# /!\

########################################## FEATURES ##########################################
# - Automatically get the latest version of NFI from the repo via HTTP (no git)
# - Compare the new strategy file with the current strategy file
#   - If there is no difference no action is taken
#   - It allows to not restart the bot if a commit does not modify the strategy
# - Update freqtrade
# - Customize the strategy ('has_downtime_protection = True' for example)
# - Perform a comparative backtest between the new strategy and the current strategy
#   - The result is saved in /backtest_result folder and sent via Telegram
#   - If there is an error during the backtest the update is canceled and a message is sent via Telegram
#   - If the results do not respect a certain threshold the update is canceled and a message is sent via Telegram
# - Git: commit, push... (freqtrade installation on private git repo)
# - Docker: Update the docker-compose.yml file, then restart the bots
#   - Will restart "at the middle candle" because we are running on a timeframe of 5m (2m, 7m, 12m, 17m...)
# - A message is sent via Telegram:
#   - With the results of the backtest (if new version)
#   - If the update was successful
#   - If the update is canceled because there is an error during the backtest
#   - If the update is canceled because the results of the backtest do not respect a certain threshold
# - A lock allows to not be able to launch the update twice (if a backtest take times for example...)

########################################## CRON EXAMPLE ##########################################

# crontab -e
# Every 15 min
# */15 * * * * cd /home/potpot/freqtrade && ./update_nfi.sh

########################################## LOCK ##########################################

# create a lock using flock, so this script cannot run twice simultaneously (need util-linux)
[ "${FLOCKER}" != "$0" ] && exec env FLOCKER="$0" flock -en "$0" "$0" "$@" || :

########################################## VERIFICATION ##########################################

if ! command -v bc &> /dev/null; then
    echo "/!\ You need 'bc', please run 'sudo apt install bc' /!\\"
    exit 1
fi

########################################## CONFIG ##########################################

telegram_api_key="YOU_API_KEY"
telegram_user_id="YOUR_USER_ID"

defaultStrategiesDirectory="user_data/strategies"
strategiesDirectory1="user_data_nfi_busd/strategies"
strategiesDirectory2="user_data_nfi_usdt/strategies"
backtestResultDirectory="backtest_result"
backtestTimerange="20210612-20210812"
previousNfiStrategyPath="/tmp/previous_nfi_strategy.py"

backtestMinimumAvgProfit="2.40"
backtestMinimumWinPercentage="95"
backtestMaximumDrawdown="30"

########################################## PREPARE VARIABLE ##########################################

newStrategyName='NostalgiaForInfinityNext_'$(date +'%Y_%m_%d_%Hh%M')
newStrategyPath="$defaultStrategiesDirectory/$newStrategyName.py"

oldStrategyPath1="$(find "$strategiesDirectory1" -type f -name "NostalgiaForInfinityNext*.py")"
oldStrategyPath2="$(find "$strategiesDirectory2" -type f -name "NostalgiaForInfinityNext*.py")"
oldStrategyName=$(echo "$oldStrategyPath1" | cut -d'/' -f 3 | cut -d'.' -f 1)

########################################## VERIFICATIONS ##########################################

numberOfStrategyFound=$(echo "$oldStrategyPath1" | sed '/^\s*$/d' | wc -l | tr -d '[:blank:]')

if [ "$numberOfStrategyFound" != "1" ];then
    echo "$oldStrategyPath1"
    echo "/!\ You need only one NFI strategy in $strategiesDirectory1, we found $numberOfStrategyFound strategies /!\\"
    exit 1
fi

numberOfStrategyFound=$(echo "$oldStrategyPath2" | sed '/^\s*$/d' | wc -l | tr -d '[:blank:]')

if [ "$numberOfStrategyFound" != "1" ];then
    echo "$oldStrategyPath2"
    echo "/!\ You need only one NFI strategy in $strategiesDirectory2, we found $numberOfStrategyFound strategies /!\\"
    exit 1
fi

########################################## DOWNLOAD ##########################################

echo "Downloading $newStrategyPath..."
wget -rq --tries=50 --output-document="$newStrategyPath" "https://raw.githubusercontent.com/iterativv/NostalgiaForInfinity/main/NostalgiaForInfinityNext.py"

# replace some part of the strategy
sed -i "s/NostalgiaForInfinityNext/$newStrategyName/g" "$newStrategyPath"
sed -i "s/has_bt_agefilter = False/has_bt_agefilter = True/g" "$newStrategyPath"
sed -i "s/bt_min_age_days = 3/bt_min_age_days = 7/g" "$newStrategyPath"
sed -i "s/has_downtime_protection = False/has_downtime_protection = True/g" "$newStrategyPath"

########################################## COMPARE NEW VS OLD ##########################################

# make a temp copy of the strategy
tempNewStratPath="/tmp/new_strat.py"
tempOldStratPath="/tmp/old_strat.py"
cp "$newStrategyPath" "$tempNewStratPath"
if [ -f $previousNfiStrategyPath ]; then
  # a previous nfi strategy was found, use it
  cp "$previousNfiStrategyPath" "$tempOldStratPath"
else
  # first time we run this script, use the strategy from freqtrade for the comparison
  cp "$oldStrategyPath1" "$tempOldStratPath"
fi

# delete name in the file because we don't want to compare name
sed -i "/NostalgiaForInfinityNext/d" "$tempNewStratPath"
sed -i "/NostalgiaForInfinityNext/d" "$tempOldStratPath"

oldNewDiff=$(diff "$tempNewStratPath" "$tempOldStratPath")

rm "$tempNewStratPath"
rm "$tempOldStratPath"

# We save the new strategy in a temporary folder for the next comparison.
# This prevents backtesting this strategy again if for some reason the update is canceled.
cp "$newStrategyPath" "$previousNfiStrategyPath"

if [ -z "$oldNewDiff" ]; then

  echo "NFI is up to date :)"
  rm "$newStrategyPath"
  exit 0

fi

echo "!!! New version of NFI available !!!"

########################################## NFI COMMIT MESSAGE ##########################################

# retrieve latest commit message and author from the github repo
latestCommitUrl="$(curl -s "https://api.github.com/repos/iterativv/NostalgiaForInfinity/git/refs/heads/main" -q | jq -r ".object.url")"
latestCommitContent="$(curl -s "$latestCommitUrl")"
latestCommitMessage="$(echo "$latestCommitContent" | jq -r ".message")"
latestCommitAuthor="$(echo "$latestCommitContent" | jq -r ".author.name")"

########################################## BACKTEST ##########################################

# update freqtrade installation
echo "Update freqtrade..."
printf 'y\ny\ny\n' | ./setup.sh -u >/dev/null
source ./.env/bin/activate

# run backtest
echo "Running backtest..."

# create backtest result directory
mkdir -p "$backtestResultDirectory"
backtestResultPath="$backtestResultDirectory/$newStrategyName"

# ensure old strategy is in the default strategy directory
cp "$oldStrategyPath1" "$defaultStrategiesDirectory"

echo "###########################################################################"
# Binance / USDT / max-open-trades 10 / stake_amount: $100 / wallet $1000
freqtrade backtesting -c ./user_data/config.json -c ./common-config.json --fee 0.00075 --timerange=$backtestTimerange --timeframe 5m --max-open-trades 10 --dry-run-wallet 1000 --stake-amount 100 --strategy-list "$newStrategyName" "$oldStrategyName" > "$backtestResultPath"
echo "###########################################################################"

# cleanup backtest results (we have the output in $backtestResultPath)
/bin/rm -f ./user_data/backtest_results/.last_result.json
/bin/rm -f ./user_data/backtest_results/*
/bin/rm -f ./user_data/strategies/*.json

# parse backtest result
resultLine1=$(tail -n 5 "$backtestResultPath" | head -1)
resultLine2=$(tail -n 4 "$backtestResultPath" | head -1)

if [ "$(echo "$resultLine1" | cut -d'|' -f 2 | tr -d "[:blank:]")" = "$newStrategyName" ]; then
  lineNewStrat="$resultLine1"
  lineOldStrat="$resultLine2"
else
  lineNewStrat="$resultLine2"
  lineOldStrat="$resultLine1"
fi

nameNewStrat=$(echo "$lineNewStrat" | cut -d'|' -f 2 | tr -d "[:blank:]")
nameOldStrat=$(echo "$lineOldStrat" | cut -d'|' -f 2 | tr -d "[:blank:]")

buyNewStrat=$(echo "$lineNewStrat" | cut -d'|' -f 3 | tr -d "[:blank:]")
buyOldStrat=$(echo "$lineOldStrat" | cut -d'|' -f 3 | tr -d "[:blank:]")

avgProfitNewStrat=$(echo "$lineNewStrat" | cut -d'|' -f 4 | tr -d "[:blank:]")
avgProfitOldStrat=$(echo "$lineOldStrat" | cut -d'|' -f 4 | tr -d "[:blank:]")

totProfitUsdtNewStrat=$(echo "$lineNewStrat" | cut -d'|' -f 6 | tr -d "[:blank:]")
totProfitUsdtOldStrat=$(echo "$lineOldStrat" | cut -d'|' -f 6 | tr -d "[:blank:]")

avgDurationNewStrat=$(echo "$lineNewStrat" | cut -d'|' -f 8 | tr -d "[:blank:]")
avgDurationOldStrat=$(echo "$lineOldStrat" | cut -d'|' -f 8 | tr -d "[:blank:]")

winNewStrat=$(echo "$lineNewStrat" | cut -d'|' -f 9 | tr -s ' ' | cut -d' ' -f 2 | tr -d "[:blank:]")
winOldStrat=$(echo "$lineOldStrat" | cut -d'|' -f 9 | tr -s ' ' | cut -d' ' -f 2 | tr -d "[:blank:]")

lossNewStrat=$(echo "$lineNewStrat" | cut -d'|' -f 9 | tr -s ' ' | cut -d' ' -f 4 | tr -d "[:blank:]")
lossOldStrat=$(echo "$lineOldStrat" | cut -d'|' -f 9 | tr -s ' ' | cut -d' ' -f 4 | tr -d "[:blank:]")

winPercentNewStrat=$(echo "$lineNewStrat" | cut -d'|' -f 9 | tr -s ' ' | cut -d' ' -f 5 | tr -d "[:blank:]")
winPercentOldStrat=$(echo "$lineOldStrat" | cut -d'|' -f 9 | tr -s ' ' | cut -d' ' -f 5 | tr -d "[:blank:]")

drawdownNewStrat=$(echo "$lineNewStrat" | cut -d'|' -f 10 | tr -s ' ' | cut -d' ' -f 4 | tr -d "[:blank:]" | cut -d'%' -f 1)
drawdownOldStrat=$(echo "$lineOldStrat" | cut -d'|' -f 10 | tr -s ' ' | cut -d' ' -f 4 | tr -d "[:blank:]" | cut -d'%' -f 1)

########################################## TELEGRAM ##########################################

# build the message
newStratOutput="New NFI: $nameNewStrat\n"
newStratOutput+="Buys: $buyNewStrat / Win: $winNewStrat / Loss: $lossNewStrat / Win%: $winPercentNewStrat%\n"
newStratOutput+="Avg Profit: $avgProfitNewStrat% / Tot Profit: $totProfitUsdtNewStrat USDT\n"
newStratOutput+="Avg Duration: $avgDurationNewStrat / Drawdown: $drawdownNewStrat%"

oldStratOutput="Old NFI: $nameOldStrat\n"
oldStratOutput+="Buys: $buyOldStrat / Win: $winOldStrat / Loss: $lossOldStrat / Win%: $winPercentOldStrat%\n"
oldStratOutput+="Avg Profit: $avgProfitOldStrat% / Tot Profit: $totProfitUsdtOldStrat USDT\n"
oldStratOutput+="Avg Duration: $avgDurationOldStrat / Drawdown: $drawdownOldStrat%"

telegramMessage="Backtest result for the timerange $backtestTimerange\n\n"
telegramMessage+="$newStratOutput\n\n"
telegramMessage+="$oldStratOutput\n\n"
telegramMessage+="Latest commit by @$latestCommitAuthor: $latestCommitMessage"
# replace \n by %0A (new line in Telegram)
telegramMessage="${telegramMessage//\\n/%0A}"

# Send telegram message
echo "Send backtest result using telegram..."

curl -s --data "text=$telegramMessage" \
        --data "chat_id=$telegram_user_id" \
        "https://api.telegram.org/bot$telegram_api_key/sendMessage" > /dev/null

########################################## VERIFY BACKTEST RESULT ##########################################

if [ -z "$avgProfitNewStrat" ]; then
  errorMessage="We are unable to retrieve the backtest results, there must be an error in the strategy file\n"
else
  if (( $(echo "$avgProfitNewStrat < $backtestMinimumAvgProfit" | bc -l) )); then
    errorMessage="Avg Profit: $avgProfitNewStrat% < $backtestMinimumAvgProfit%\n"
  fi
  if (( $(echo "$winPercentNewStrat < $backtestMinimumWinPercentage" | bc -l) )); then
    errorMessage="Win%: $winPercentNewStrat% < $backtestMinimumWinPercentage%\n"
  fi
  if (( $(echo "$drawdownNewStrat >= $backtestMaximumDrawdown" | bc -l) )); then
    errorMessage="Drawdown: $drawdownNewStrat% >= $backtestMaximumDrawdown%\n"
  fi
fi

if [ -n "$errorMessage" ]; then
  errorMessage+="We do not update the strategy..."
  echo -e "$errorMessage"
  errorMessage="${errorMessage//\\n/%0A}" # replace \n by %0A (new line in Telegram)
  curl -s --data "text=$errorMessage" \
          --data "chat_id=$telegram_user_id" \
          "https://api.telegram.org/bot$telegram_api_key/sendMessage" > /dev/null

  # cleanup logs
  find user_data* -regextype sed -regex ".*\.log[.1-9]*" -exec rm {} \;

  # push the strategy and the backtest result for analyze
  git pull -q &&
    git add . &&
    git commit -m "Problem with $newStrategyName" -q &&
    git push -q &&
    git gc -q

  exit 0
fi

########################################## UPDATE ##########################################

# copy new strat and remove old strat
cp "$newStrategyPath" "$strategiesDirectory1"
cp "$newStrategyPath" "$strategiesDirectory2"
rm "$oldStrategyPath1"
rm "$oldStrategyPath2"

# update docker-compose
sed -i "s/$oldStrategyName/$newStrategyName/g" "docker-compose.yml"

########################################## GIT ##########################################

echo "Git commit and push..."

# cleanup logs
find user_data* -regextype sed -regex ".*\.log[.1-9]*" -exec rm {} \;

git pull -q &&
  git add . &&
  git commit -m "Update to $newStrategyName" -q &&
  git push -q &&
  git gc -q

########################################## DOCKER ##########################################

echo "Docker build..."

/usr/local/bin/docker-compose pull > /dev/null &&
  /usr/local/bin/docker-compose build --no-cache > /dev/null

# MIDDLE CANDLE PROTECTION
# Will restart "at the middle candle" because we are running on a timeframe of 5m (2m, 7m, 12m, 17m...)
currentMinute=$(date +'%M')
currentMinuteDiff=99 # fake large number to simplify the algorithm
for i in $(seq 2 5 62); do # 62 allows to manage the minutes after 57
  minuteDiff=$(echo "$i - $currentMinute" | bc);
  if (( $(echo "$minuteDiff >= 0 && $minuteDiff < $currentMinuteDiff" | bc -l) )); then
    currentMinuteDiff=$minuteDiff
    currentMinuteWeWait=$i
  fi
done
echo "We have to wait $currentMinuteDiff minute(s) to restart the bot at $currentMinuteWeWait"
if (( $(echo "$currentMinuteDiff > 0" | bc -l) )); then
  sleepTime="$((currentMinuteDiff*60))"
  echo "go sleep for $sleepTime seconds"
  sleep "$sleepTime"
fi

echo "Docker restart..."

/usr/local/bin/docker-compose stop > /dev/null &&
  /usr/local/bin/docker-compose up -d --remove-orphans > /dev/null &&
  docker system prune --volumes -af > /dev/null

########################################## SUCCESS ##########################################

telegramMessage="The update was successful!"
curl -s --data "text=$telegramMessage" \
        --data "chat_id=$telegram_user_id" \
        "https://api.telegram.org/bot$telegram_api_key/sendMessage" > /dev/null

echo "The update was successful!"
