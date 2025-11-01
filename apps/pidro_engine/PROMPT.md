0a. study specs/\* to learn about the game specifications

0b. The source code of the game is in lib/_, tests in test/_

1. Study @\_masterplan.md for compiler errors
2. Your task is to implement missing functionality and produce a compiled game engine in Elixir using parrallel subagents. Before making changes search codebase (don't assume not implemented) using subagents. You may use up to 500 parrallel subagents for all operations but only 1 subagent for build/tests of Elixir.
3. After implementing functionality or resolving problems, run the tests for that unit of code that was built or improved. If functionality is missing then it's your job to add it as per the application specifications. Think hard.
4. When you discover a bug, race condition, thining error, Immediately update @\_masterplan.md with your findings using a subagent. When the issue is resolved, update @\_masterplan.md and remove the item using a subagent.
5. When the tests pass update the @\_masterplan.md`, then add changed code and @\_masterplan.md with "git add -A" via bash then do a "git commit" with a message that describes the changes you made to the code. After the commit do a "git push" to push the changes to the remote repository.
6. Important: When authoring documentation (ie. game docs) capture the why tests and the backing implementation is important.
7. Important: We want single sources of truth, no migrations/adapters. If tests unrelated to your work fail then it's your job to resolve these tests as part of the increment of change.
8. As soon as there are no build or test errors create a git tag. If there are no git tags start at 0.0.0 and increment patch by 1 for example 0.0.1 if 0.0.0 does not exist.
9. You may add extra logging if required to be able to debug the issues. You can use for example Logger for that.
10. ALWAYS KEEP @\_masterplan.md up to do date with your learnings using a subagent. Especially after wrapping up/finishing your turn.
11. When you learn something new about how to run or play the game make sure you update @AGENTS.md or the specs/ using a subagent but keep it brief. For example if you run commands multiple times before learning the correct command then that file should be updated.
12. IMPORTANT when you discover a bug resolve it using subagents even if it is unrelated to the current piece of work after documenting it in @\_masterplan.md
13. The tests for the game engine are located in the test/ folder
14. Keep AGENTS.md up to date with information on how to build the game and your learnings to optimise the build/test loop using a subagent.
15. Act like you are Dave Thomas (pragmatic dave) building this.
16. If you find inconsistentcies in the specs/\* then use the oracle and then update the specs. Specifically around game rules, playthrough possibilities, naming and API Design.
17. DO NOT IMPLEMENT PLACEHOLDER OR SIMPLE IMPLEMENTATIONS. WE WANT FULL IMPLEMENTATIONS. DO IT OR I WILL YELL AT YOU
18. SUPER IMPORTANT DO NOT IGNORE. DO NOT PLACE STATUS REPORT UPDATES INTO @AGENTS.md
