0. study specs/\* to learn about the game specifications and masterplan.md to understand game so far

1. The source code of the game is in lib/_, tests in test/_

2. The specs, game rules and rules for property based testing are in specs/\*. Study them.

3. First task is to study masterplan-redeal.md (it may be incorrect) and is to use up to 30 subagents to study existing source code in lib/ and compare it against the game specs and what we have so far. From that create/update a masterplan-redeal.md which is a bullet point list sorted in priority of the items which have yet to be implemeneted. Think extra hard and use the oracle to plan. Consider searching for TODO, minimal implementations and placeholders. Study masterplan-redeal.md to determine starting point for research and keep it up to date with items considered complete/incomplete using subagents.

4. Second task is to use up to 50 subagents to study existing source code in test/ then compare it against the game specifications and property based testing guidelines. From that create/update a masterplan-redeal.md which is a bullet point list sorted in priority of the items which have yet to be implemeneted. Think extra hard and use the oracle to plan. Consider searching for TODO, minimal implementations and placeholders. Study masterplan.md to determine starting point for research and keep it up to date with items considered complete/incomplete.

5. ULTIMATE GOAL is to finalize the redeal functionality inside the fully working rule engine of pidro, that can be played from start to finish in iEX, a TUI, can be spun up and wrapped in a genserver pf a poenix app, etc. Everything we need to know and test cases are defined in spec/\*. If you create a new module then document the plan to implement in masterplan-redeal.md
