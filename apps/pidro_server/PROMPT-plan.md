0. study specs/ to learn about the game specifications and MASTERPLAN.md to understand state so far.

0a. Look at AGENTS.md for conventions and best practices

0b. Look at specs/pidro_server_dev_ui.md to see what we're going to build, the DEV UI.

1. The source code of the game server is in lib/_, tests in test/_

2. The specs, game rules and rules for property based testing are in specs/\*. Study them.

3. First task is to study MASTERPLAN-DEVUI.md (it may be incorrect) and is to use up to 50 subagents to study existing source code in lib/ and compare it against the DEV UI specifications. From that create/update a MASTERPLAN-DEVUI.md which is a bullet point list sorted in priority of the items which have yet to be implemeneted. Think extra hard and use the oracle to plan. Consider searching for TODO, minimal implementations and placeholders. Study MASTERPLAN-DEVUI.md to determine starting point for research and keep it up to date with items considered complete/incomplete using subagents.

4. ULTIMATE GOAL is to have a fully working DEV UI for pidro, that helps us to test the game server and pidro-engine Everything we need to know and test cases are defined in spec/\*. If you create a new module then document the plan to implement in MASTERPLAN-DEVUI.md
