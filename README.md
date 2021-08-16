# NFI UPDATER

## Requirement

You need bc to run this script, please install it: `sudo apt install bc`

Please adapt the command used for the backtest to your installation (`freqtrade backtesting...`)

## Features

- Automatically get the latest version of NFI from the repo via HTTP (no git)
- Compare the new strategy file with the current strategy file
    - If there is no difference no action is taken
    - It allows to not restart the bot if a commit does not modify the strategy
- Update freqtrade
- Customize the strategy ('has_downtime_protection = True' for example)
- Perform a comparative backtest between the new strategy and the current strategy
    - The result is saved in /backtest_result folder and sent via Telegram
    - If there is an error during the backtest the update is canceled and a message is sent via Telegram
    - If the results do not respect a certain threshold the update is canceled and a message is sent via Telegram
- Git: commit, push... (freqtrade installation on private git repo)
- Docker: Update the docker-compose.yml file, then restart the bots
    - Will restart "at the middle candle" because we are running on a timeframe of 5m (2m, 7m, 12m, 17m...)
- A message is sent via Telegram:
    - With the results of the backtest (if new version)
    - If the update was successful
    - If the update is canceled because there is an error during the backtest
    - If the update is canceled because the results of the backtest do not respect a certain threshold
- A lock allows to not be able to launch the update twice (if a backtest take times for example...)
